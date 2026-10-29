import AppKit
import AudioToolbox
import MumbleASR
import MumbleCore
import Observation

enum ModelStatus: Equatable {
    case idle
    case loading(progress: Double, label: String)
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }
}

/// Orchestrates one dictation: hotkey → capture → live preview → final pass → text pipeline → paste.
@MainActor @Observable
final class DictationController {
    private(set) var settings: MumbleSettings
    private(set) var modelStatus: ModelStatus = .idle
    private(set) var vocabularyStatus: String?
    private(set) var history: [HistoryItem] = []
    private(set) var lastLatencyMs: Int?
    var accessibilityTrusted = Permissions.isAccessibilityTrusted

    let island = IslandModel()
    @ObservationIgnored private lazy var islandPanel = IslandPanel(model: island)
    @ObservationIgnored private let engine = TranscriptionEngine()
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let hotkey = HotkeyMonitor()
    @ObservationIgnored private var gesture = HotkeyGesture()
    @ObservationIgnored private let historyStore = HistoryStore(fileURL: HistoryStore.defaultURL)

    @ObservationIgnored private var session: UUID?
    @ObservationIgnored private var testInputOverride = false
    @ObservationIgnored private var recordingStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var vocabularyTask: Task<Void, Never>?
    @ObservationIgnored private var trustPollTask: Task<Void, Never>?

    static let settingsKey = "settings.v1"
    /// Preview re-transcribes at most this much trailing audio, keeping each tick cheap on long dictations.
    static let previewWindowSeconds = 12.0
    static let previewInterval: Duration = .milliseconds(450)

    var isRecording: Bool { session != nil }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(MumbleSettings.self, from: data) {
            settings = saved
        } else {
            settings = MumbleSettings()
        }
        history = historyStore.load()
    }

    // MARK: Lifecycle

    func start() {
        AppLog.info("Launch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?"); model \(settings.model.rawValue), trigger \(settings.triggerKey), accessibility \(Permissions.isAccessibilityTrusted), mic \(AudioRecorder.permission.rawValue)")
        // Ask for the microphone up front, so the first key press records instead of prompting.
        if AudioRecorder.permission == .notDetermined {
            Task { AppLog.info("Microphone permission granted: \(await AudioRecorder.requestPermission())") }
        }
        if !testInputOverride { recorder.preferredInputUID = settings.inputDeviceUID }
        hotkey.trigger = settings.triggerKey
        hotkey.onPress = { [weak self] time in self?.apply(self?.gesture.press(at: time) ?? .none) }
        hotkey.onRelease = { [weak self] time in self?.apply(self?.gesture.release(at: time) ?? .none) }
        hotkey.onEscape = { [weak self] in self?.apply(self?.gesture.cancel() ?? .none) }
        hotkey.onOtherKey = { [weak self] in
            // ⌥+key typed a special character, or ⌘+key ran a shortcut: not a dictation.
            guard let self, !self.gesture.isLatched else { return }
            self.apply(self.gesture.cancel())
        }
        hotkey.install()
        watchAccessibilityTrust()
        loadModel()
        applyVocabulary()
        Sounds.preload()
    }

    func update(_ change: (inout MumbleSettings) -> Void) {
        let old = settings
        change(&settings)
        guard settings != old else { return }
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        if settings.triggerKey != old.triggerKey {
            hotkey.trigger = settings.triggerKey
            gesture.reset()
        }
        if settings.model != old.model { loadModel() }
        if settings.inputDeviceUID != old.inputDeviceUID { recorder.preferredInputUID = settings.inputDeviceUID }
        if settings.vocabulary != old.vocabulary { applyVocabulary() }
        if !settings.keepHistory, old.keepHistory { clearHistory() }
    }

    func loadModel() {
        loadTask?.cancel()
        let model = settings.model
        modelStatus = .loading(progress: 0, label: "Preparing \(model.displayName)")
        loadTask = Task {
            do {
                try await engine.load(model) { fraction, label in
                    Task { @MainActor [weak self] in
                        guard let self, case .loading = self.modelStatus else { return }
                        self.modelStatus = .loading(progress: fraction, label: label)
                    }
                }
                guard !Task.isCancelled else { return }
                modelStatus = .ready
                AppLog.info("Model \(model.rawValue) ready")
            } catch {
                guard !Task.isCancelled else { return }
                modelStatus = .failed(error.localizedDescription)
                AppLog.error("Model load failed: \(error)")
            }
        }
    }

    private func applyVocabulary() {
        vocabularyTask?.cancel()
        let entries = settings.vocabulary
        vocabularyStatus = entries.isEmpty ? nil : "Preparing vocabulary boosting…"
        vocabularyTask = Task {
            // Debounce typing in the vocabulary editor.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            do {
                try await engine.setVocabulary(entries)
                vocabularyStatus = entries.isEmpty ? nil : "Boosting \(entries.count) term\(entries.count == 1 ? "" : "s")"
            } catch {
                vocabularyStatus = "Vocabulary boosting unavailable: \(error.localizedDescription)"
            }
        }
    }

    private func watchAccessibilityTrust() {
        trustPollTask?.cancel()
        trustPollTask = Task {
            while !Task.isCancelled {
                let trusted = Permissions.isAccessibilityTrusted
                if trusted != accessibilityTrusted {
                    accessibilityTrusted = trusted
                    // Monitors added before trust was granted never receive events; re-add them.
                    if trusted { hotkey.install() }
                }
                try? await Task.sleep(for: .seconds(trusted ? 5 : 1))
            }
        }
    }

    // MARK: Gesture handling

    private func apply(_ action: HotkeyGesture.Action) {
        switch action {
        case .none: break
        case .start: beginRecording()
        case .latch: island.isLatched = true
        case .commit: Task { await finishRecording() }
        case .discard: discardRecording()
        }
    }

    static func ms(_ d: Duration) -> Int {
        Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }

    private func beginRecording() {
        let began = ContinuousClock.now
        defer { if session != nil { AppLog.info("Recording start took \(Self.ms(began.duration(to: .now))) ms") } }
        guard modelStatus.isReady else {
            gesture.reset()
            switch modelStatus {
            case let .loading(progress, _):
                notify("Model is still loading (\(Int(progress * 100))%)")
            case let .failed(message):
                notify("Model failed to load: \(message)")
            default:
                notify("Model isn't loaded")
            }
            return
        }
        switch AudioRecorder.permission {
        case .authorized: break
        case .notDetermined:
            gesture.reset()
            Task {
                let granted = await AudioRecorder.requestPermission()
                AppLog.info("Microphone permission granted: \(granted)")
                notify(granted ? "Microphone on. Hold the key again to dictate." : "Microphone access was denied.")
            }
            return
        default:
            gesture.reset()
            notify("Microphone access is off. Enable it in System Settings.")
            Permissions.openMicrophoneSettings()
            return
        }

        do {
            try recorder.start()
        } catch {
            gesture.reset()
            AppLog.error("Recorder failed to start: \(error)")
            notify(error.localizedDescription)
            return
        }
        AppLog.info("Recording started on \(recorder.activeDeviceName ?? "default input")")
        let id = UUID()
        session = id
        recordingStartedAt = .now
        island.reset()
        island.showPreview = settings.showLivePreview
        island.phase = .listening
        islandPanel.show()
        if settings.playSounds { Sounds.start() }
        startMeter(for: id)
        if settings.showLivePreview { startPreview(for: id) }
    }

    private func discardRecording() {
        guard session != nil else { return }
        stopCapture()
        islandPanel.hide()
    }

    private func stopCapture() {
        session = nil
        previewTask?.cancel()
        meterTask?.cancel()
        recorder.stop()
    }

    private func finishRecording() async {
        guard session != nil else { return }
        let released = ContinuousClock.now
        let samples = recorder.buffer.snapshot()
        stopCapture()

        let seconds = Double(samples.count) / Double(AudioAnalysis.sampleRate)
        AppLog.info(String(format: "Recording stopped: %.2f s, peak %.4f, rms %.4f",
                           seconds, AudioAnalysis.peak(samples), AudioAnalysis.rms(samples)))
        if samples.count < AudioAnalysis.sampleRate / 4 {
            islandPanel.hide()
            return
        }
        if AudioAnalysis.isLikelySilence(samples) {
            notify("Didn't hear anything. Check the input device in Sound settings.")
            return
        }

        island.phase = .finishing
        let soundStart = ContinuousClock.now
        if settings.playSounds { Sounds.stop() }
        let soundMs = Self.ms(soundStart.duration(to: .now))

        do {
            let preMs = Self.ms(released.duration(to: .now))
            let asrStart = ContinuousClock.now
            let (text, transcript) = try await transcribeForInsertion(samples)
            let asrWallMs = Self.ms(asrStart.duration(to: .now))
            AppLog.info("Transcribed \(transcript.audioSeconds) s → \(text.count) chars; pre \(preMs) ms, engine \(transcript.processingMs) ms, engine call incl. queue \(asrWallMs) ms, sound \(soundMs) ms")
            guard !text.isEmpty else {
                notify("Didn't catch any words.")
                return
            }

            let axStart = ContinuousClock.now
            let preceding = settings.smartSpacing ? TextInserter.precedingText() : nil
            let axMs = Self.ms(axStart.duration(to: .now))
            let output = InsertionFormatter.format(text, preceding: preceding)
            var latency = 0
            let outcome = await TextInserter.insert(output) { latency = Self.ms(released.duration(to: .now)) }
            lastLatencyMs = latency
            AppLog.info("Insert outcome \(outcome); \(latency) ms release→paste (ASR \(transcript.processingMs) ms, cursor lookup \(axMs) ms)")

            record(HistoryItem(
                text: text, rawText: transcript.text, audioSeconds: transcript.audioSeconds, latencyMs: latency,
                appName: NSWorkspace.shared.frontmostApplication?.localizedName))

            switch outcome {
            case .inserted:
                island.phase = .done(text)
                islandPanel.hide(after: .milliseconds(900))
            case .copiedSecureField:
                island.phase = .notice("Secure field — copied to clipboard instead")
                islandPanel.hide(after: .seconds(2))
            case .blockedOutsideTest:
                island.phase = .notice("Test window wasn't in front; nothing pasted")
                islandPanel.hide(after: .seconds(2))
            case .copiedNoAccessibility:
                island.phase = .notice("Copied. Grant Accessibility in Settings to paste automatically.")
                islandPanel.hide(after: .seconds(3))
            }
        } catch {
            AppLog.error("Transcription failed: \(error)")
            notify("Transcription failed: \(error.localizedDescription)")
        }
    }

    /// The final pass: trim silence, transcribe with vocabulary boosting, run the text pipeline.
    func transcribeForInsertion(_ samples: [Float]) async throws -> (text: String, transcript: Transcript) {
        let settings = self.settings
        let transcript = try await engine.transcribe(
            AudioAnalysis.trimSilence(samples), boostVocabulary: !settings.vocabulary.isEmpty)
        let normalizer: ((String) -> String)? =
            settings.inverseTextNormalization ? { TranscriptionEngine.normalize($0) } : nil
        let text = TextPipeline.process(transcript.text, options: settings.pipelineOptions, normalizer: normalizer)
        return (text, transcript)
    }

    /// Dev/test only: records from this device without saving it to settings.
    func setTestInputDevice(_ uid: String?) {
        testInputOverride = true
        recorder.preferredInputUID = uid
    }

    var testInputDeviceName: String {
        AudioDevices.resolveInput(preferredUID: recorder.preferredInputUID)?.name ?? "default"
    }

    /// Waits until the model has loaded (or failed). Used by the developer self-test.
    func waitUntilModelSettles() async {
        while case .loading = modelStatus { try? await Task.sleep(for: .milliseconds(200)) }
        while case .idle = modelStatus { try? await Task.sleep(for: .milliseconds(200)) }
        await vocabularyTask?.value
    }

    // MARK: Live updates

    private func startMeter(for id: UUID) {
        meterTask = Task {
            while !Task.isCancelled, session == id {
                island.pushLevel(recorder.level)
                if let start = recordingStartedAt {
                    let d = start.duration(to: .now)
                    island.elapsed = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Re-transcribes the audio so far on a fixed cadence. Ticks never queue: each awaits the previous.
    private func startPreview(for id: UUID) {
        previewTask = Task {
            while !Task.isCancelled, session == id {
                try? await Task.sleep(for: Self.previewInterval)
                guard !Task.isCancelled, session == id else { return }
                let all = recorder.buffer.snapshot()
                guard all.count > AudioAnalysis.sampleRate / 2 else { continue }
                let window = Int(Self.previewWindowSeconds) * AudioAnalysis.sampleRate
                let samples = all.count > window ? Array(all.suffix(window)) : all
                guard let transcript = try? await engine.transcribe(samples, boostVocabulary: false),
                      session == id
                else { continue }
                island.previewText = transcript.text
            }
        }
    }

    private func notify(_ message: String) {
        island.reset()
        island.phase = .notice(message)
        islandPanel.show()
        islandPanel.hide(after: .seconds(2.5))
    }

    // MARK: History

    private func record(_ item: HistoryItem) {
        guard settings.keepHistory else { return }
        history = HistoryStore.inserting(item, into: history, limit: settings.historyLimit)
        try? historyStore.save(history)
    }

    func deleteHistory(_ item: HistoryItem) {
        history.removeAll { $0.id == item.id }
        try? historyStore.save(history)
    }

    func clearHistory() {
        history = []
        try? historyStore.save(history)
    }

    /// Pastes the most recent transcript again (menu bar action).
    func reinsertLast() {
        guard let last = history.first else { return }
        Task { _ = await TextInserter.insert(last.text) }
    }

}

/// Start/stop cues via System Sound Services, which plays asynchronously. `NSSound.play()`
/// blocked the main thread for 150–200 ms (waking a Bluetooth output route) right when the
/// user released the key, which was most of Mumble's release-to-text latency.
@MainActor
enum Sounds {
    private static let startID = load("Tink")
    private static let stopID = load("Pop")

    static func preload() { _ = (startID, stopID) }
    static func start() { startID.map(AudioServicesPlaySystemSound) }
    static func stop() { stopID.map(AudioServicesPlaySystemSound) }

    private static func load(_ name: String) -> SystemSoundID? {
        var id: SystemSoundID = 0
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff") as CFURL
        return AudioServicesCreateSystemSoundID(url, &id) == noErr ? id : nil
    }
}
