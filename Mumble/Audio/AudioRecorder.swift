@preconcurrency import AVFoundation
import MumbleCore
import Synchronization

/// Captures the microphone as 16 kHz mono Float32 into a `SampleBuffer`.
///
/// Uses AVCaptureSession rather than AVAudioEngine: it records from a specific device without
/// touching the system default (switching AVAudioEngine's input device hung the main thread),
/// and macOS converts to 16 kHz mono float for us.
///
/// The session stays running for a short standby period after each dictation so a quick
/// follow-up starts instantly, and while it runs it keeps a ~300 ms pre-roll so the first
/// syllable isn't clipped. After standby it stops fully, releasing the mic (and the orange dot).
final class AudioRecorder: NSObject, @unchecked Sendable {
    enum RecorderError: LocalizedError {
        case noInputDevice
        case cannotUse(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice: "No microphone is available."
            case let .cannotUse(name): "Can't record from \(name)."
            }
        }
    }

    let buffer = SampleBuffer(reservingSeconds: 120)
    /// Latest input level, 0...1, updated from the capture queue.
    var level: Float { levelStore.withLock { $0 } }

    private let capturing = Atomic<Bool>(false)
    private let levelStore = Mutex<Float>(0)
    private let preroll = Mutex<[Float]>([])
    private static let prerollSamples = 4_800
    private let captureQueue = DispatchQueue(label: "dev.mumble.capture", qos: .userInteractive)

    // Touched only from the main actor.
    private var session: AVCaptureSession?
    private var sessionDeviceUID: String?
    private var standbyTask: Task<Void, Never>?
    private var runtimeErrorObserver: NSObjectProtocol?

    static let standbySeconds: Double = 8

    /// Input device chosen in settings; nil = Automatic (see `AudioDevices.resolveInput`).
    @MainActor var preferredInputUID: String? {
        didSet { if preferredInputUID != oldValue { tearDown() } }
    }
    /// Name of the device the session records from, for logging and UI.
    @MainActor private(set) var activeDeviceName: String?

    @MainActor
    func start() throws {
        standbyTask?.cancel()
        buffer.reset()
        let wanted = AudioDevices.resolveInput(preferredUID: preferredInputUID)
        if let session, session.isRunning, sessionDeviceUID == wanted?.uid {
            buffer.append(preroll.withLock { $0 })
        } else {
            tearDown()
            try startSession(device: wanted)
        }
        capturing.store(true, ordering: .releasing)
    }

    /// Stops capturing; the session idles in standby, then shuts down.
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
    private func startSession(device: AudioDevices.Device?) throws {
        let captureDevice = device.flatMap { AVCaptureDevice(uniqueID: $0.uid) } ?? AVCaptureDevice.default(for: .audio)
        guard let captureDevice else { throw RecorderError.noInputDevice }

        let session = AVCaptureSession()
        session.beginConfiguration()
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: captureDevice)
        } catch {
            throw RecorderError.cannotUse(captureDevice.localizedName)
        }
        guard session.canAddInput(input) else { throw RecorderError.cannotUse(captureDevice.localizedName) }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else { throw RecorderError.cannotUse(captureDevice.localizedName) }
        session.addOutput(output)
        session.commitConfiguration()

        preroll.withLock { $0.removeAll(keepingCapacity: true) }
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                AppLog.error("Capture session error: \(String(describing: note.userInfo?[AVCaptureSessionErrorKey]))")
                self?.tearDown()
            }
        }
        // startRunning blocks until audio flows (~50–150 ms). Do it off the main thread; samples
        // that arrive after `capturing` is set are recorded.
        captureQueue.async { session.startRunning() }

        self.session = session
        sessionDeviceUID = captureDevice.uniqueID
        activeDeviceName = captureDevice.localizedName
    }

    @MainActor
    private func tearDown() {
        capturing.store(false, ordering: .releasing)
        if let runtimeErrorObserver { NotificationCenter.default.removeObserver(runtimeErrorObserver) }
        runtimeErrorObserver = nil
        if let session {
            captureQueue.async { session.stopRunning() }
            AppLog.info("Microphone released")
        }
        session = nil
        sessionDeviceUID = nil
    }

    static var permission: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

extension AudioRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    /// Runs on `captureQueue`.
    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer, length >= MemoryLayout<Float>.size
        else { return }
        let samples = UnsafeBufferPointer(
            start: UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self),
            count: length / MemoryLayout<Float>.size)

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
}
