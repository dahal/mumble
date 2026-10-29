import AppKit
import MumbleASR
import MumbleCore
import Observation
import os

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
    @ObservationIgnored private let log = Logger(subsystem: "dev.mumble.Mumble", category: "dictation")

    @ObservationIgnored private var session: UUID?
    @ObservationIgnored private var recordingStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var vocabularyTask: Task<Void, Never>?
    @ObservationIgnored private var trustPollTask: Task<Void, Never>?

    static let settingsKey = "settings.v1"
    /// Preview re-transcribes at most this much trailing audio, keeping each tick cheap on long dictations.
    static let previewWindowSeconds = 20.0
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
        hotkey.trigger = settings.triggerKey
        hotkey.onPress = { [weak self] in self?.apply(self?.gesture.press(at: Self.now) ?? .none) }
        hotkey.onRelease = { [weak self] in self?.apply(self?.gesture.release(at: Self.now) ?? .none) }
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
                log.info("Model \(model.rawValue, privacy: .public) ready")
            } catch {
                guard !Task.isCancelled else { return }
                modelStatus = .failed(error.localizedDescription)
                log.error("Model load failed: \(error.localizedDescription, privacy: .public)")
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

    private func beginRecording() {
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
            Task { _ = await AudioRecorder.requestPermission() }
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
            notify(error.localizedDescription)
            return
        }
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

        if samples.count < AudioAnalysis.sampleRate / 4 || AudioAnalysis.isLikelySilence(samples) {
            islandPanel.hide()
            return
        }

        island.phase = .finishing
        if settings.playSounds { Sounds.stop() }

        do {
            let (text, transcript) = try await transcribeForInsertion(samples)
            guard !text.isEmpty else {
                islandPanel.hide()
                return
            }

            let preceding = settings.smartSpacing ? TextInserter.precedingText() : nil
            let output = InsertionFormatter.format(text, preceding: preceding)
            let outcome = await TextInserter.insert(output)
            let elapsed = released.duration(to: .now)
            let latency = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            lastLatencyMs = latency
            log.info("Inserted \(text.count) chars; \(transcript.processingMs) ms ASR, \(latency) ms release→paste")

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
            }
        } catch {
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

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

@MainActor
enum Sounds {
    static func start() { play("Tink", volume: 0.25) }
    static func stop() { play("Pop", volume: 0.2) }

    private static func play(_ name: String, volume: Float) {
        guard let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }
}
