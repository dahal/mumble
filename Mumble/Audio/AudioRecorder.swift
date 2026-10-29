@preconcurrency import AVFoundation
import MumbleCore
import Synchronization

/// Captures the microphone as 16 kHz mono Float32 into a `SampleBuffer`.
///
/// The engine stays running for a short standby period after each dictation so a quick
/// follow-up starts instantly, and while it runs it keeps a ~300 ms pre-roll so the first
/// syllable isn't clipped. After standby it stops fully, releasing the mic (and the orange dot).
final class AudioRecorder: @unchecked Sendable {
    enum RecorderError: LocalizedError {
        case noInputDevice

        var errorDescription: String? {
            switch self {
            case .noInputDevice: "No microphone is available."
            }
        }
    }

    let buffer = SampleBuffer(reservingSeconds: 120)
    /// Latest input level, 0...1, updated from the audio thread.
    var level: Float { levelStore.withLock { $0 } }

    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let capturing = Atomic<Bool>(false)
    private let levelStore = Mutex<Float>(0)
    private let preroll = Mutex<[Float]>([])
    private static let prerollSamples = 4_800

    // Touched only from the main actor.
    private var converter: AVAudioConverter?
    private var isEngineRunning = false
    private var standbyTask: Task<Void, Never>?
    private var configObserver: NSObjectProtocol?

    static let standbySeconds: Double = 8

    init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // The input device or its format changed (e.g. AirPods connected). Rebuild on next start.
            MainActor.assumeIsolated { self?.tearDown() }
        }
    }

    @MainActor
    func start() throws {
        standbyTask?.cancel()
        buffer.reset()
        if isEngineRunning {
            buffer.append(preroll.withLock { $0 })
        } else {
            try startEngine()
        }
        capturing.store(true, ordering: .releasing)
    }

    /// Stops capturing; the engine idles in standby, then shuts down.
    @MainActor
    func stop() {
        capturing.store(false, ordering: .releasing)
        levelStore.withLock { $0 = 0 }
        standbyTask?.cancel()
        standbyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.standbySeconds))
            guard !Task.isCancelled else { return }
            self?.tearDown()
        }
    }

    @MainActor
    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputDevice }
        guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
            throw RecorderError.noInputDevice
        }
        self.converter = converter
        preroll.withLock { $0.removeAll(keepingCapacity: true) }

        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] pcm, _ in
            self?.process(pcm, converter: converter)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isEngineRunning = true
    }

    @MainActor
    private func tearDown() {
        guard isEngineRunning else { return }
        capturing.store(false, ordering: .releasing)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isEngineRunning = false
        converter = nil
    }

    /// Runs on the audio thread.
    private func process(_ pcm: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let ratio = targetFormat.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        nonisolated(unsafe) var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return pcm
        }
        guard error == nil, let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let samples = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))

        if capturing.load(ordering: .acquiring) {
            buffer.append(samples)
            let rms = AudioAnalysis.rms(Array(samples))
            levelStore.withLock { $0 = AudioAnalysis.meterLevel(rms: rms) }
        } else {
            preroll.withLock { ring in
                ring.append(contentsOf: samples)
                if ring.count > Self.prerollSamples { ring.removeFirst(ring.count - Self.prerollSamples) }
            }
        }
    }

    static var permission: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
