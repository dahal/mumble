@preconcurrency import AVFoundation
import MumbleCore
import Synchronization

/// Records a meeting as two aligned 16 kHz mono tracks: `local.caf` (your microphone) and
/// `remote.caf` (the meeting app's audio, via `SystemAudioTap`).
///
/// It can also *hold* (spec R4 "catch the start"): capture into memory-only rings of the last
/// `holdSeconds` without touching the disk, then either `commit` (the rings become the start of the
/// recording) or `discard` (the rings are zeroed).
final class MeetingRecorder: @unchecked Sendable {
    enum Mode { case idle, holding, recording }

    static let holdSeconds = 120.0

    private struct Track {
        var aligner: TimelineAligner
        var ring: SampleRing
        var file: AVAudioFile?
        var recent: [Float] = []   // last ~15 s, for the live preview
        var level: Float = 0
    }

    private struct State {
        var mode: Mode = .idle
        var local: Track
        var remote: Track
        var startHost: Double
        var recordingStartHost: Double
    }

    private let state: Mutex<State>
    private let mic = AudioRecorder()
    private var tap: SystemAudioTap?
    private var refreshTask: Task<Void, Never>?
    private static let recentLimit = 15 * AudioAnalysis.sampleRate
    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    let folder: URL
    private(set) var tapError: String?

    init(folder: URL) {
        self.folder = folder
        let now = SystemAudioTap.hostSecondsNow()
        let ring = SampleRing(capacity: Int(Self.holdSeconds) * AudioAnalysis.sampleRate)
        state = Mutex(State(local: Track(aligner: TimelineAligner(startHostSeconds: now), ring: ring),
                            remote: Track(aligner: TimelineAligner(startHostSeconds: now), ring: ring),
                            startHost: now, recordingStartHost: now))
        mic.keepsBuffer = false
        mic.standbySeconds = 0
    }

    var mode: Mode { state.withLock { $0.mode } }
    var isTapRunning: Bool { tap?.isRunning ?? false }
    var tapHasAudio: Bool { tap?.hasReceivedAudio ?? false }
    var localLevel: Float { state.withLock { $0.local.level } }
    var remoteLevel: Float { state.withLock { $0.remote.level } }

    /// Seconds recorded to disk so far (including any held start).
    var elapsed: Double {
        state.withLock { s in
            guard s.mode == .recording else { return 0 }
            return SystemAudioTap.hostSecondsNow() - s.recordingStartHost
        }
    }

    // MARK: Lifecycle

    /// Starts capturing. `hold: true` keeps audio in memory only until `commit()`.
    @MainActor
    func start(inputUID: String?, tapTarget: SystemAudioTap.Target?, hold: Bool) throws {
        let now = SystemAudioTap.hostSecondsNow()
        state.withLock { s in
            s.startHost = now
            s.recordingStartHost = now
            s.local.aligner = TimelineAligner(startHostSeconds: now)
            s.remote.aligner = TimelineAligner(startHostSeconds: now)
            s.mode = hold ? .holding : .recording
        }
        if !hold { try openFiles() }

        mic.onSamples = { [weak self] samples, host in self?.receive(samples, host: host, remote: false) }
        mic.preferredInputUID = inputUID
        try mic.start()

        if let tapTarget { startTap(tapTarget) }
        refreshTask = Task { [weak self] in
            // Meeting apps start new audio helper processes mid-call, and the output device can
            // change (headphones); follow both. Cheap: one process-list query per second.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let tap = self.tap else { continue }
                if !tap.isRunning, let target = Optional(tap.target) { self.startTap(target) } else { tap.refreshIfNeeded() }
            }
        }
    }

    private func startTap(_ target: SystemAudioTap.Target) {
        tap?.stop()
        let tap = SystemAudioTap(target: target)
        tap.onSamples = { [weak self] samples, host in self?.receive(samples, host: host, remote: true) }
        do {
            try tap.start()
            tapError = nil
        } catch {
            tapError = error.localizedDescription
            AppLog.error("Meeting tap: \(error)")
        }
        self.tap = tap
    }

    /// Turns a held capture into a recording: the held audio becomes its start.
    func commit() throws {
        let opened: Bool = try state.withLock { s in
            guard s.mode == .holding else { return false }
            // Level both tracks to the same length, then flush the rings to disk.
            let end = max(s.local.aligner.position, s.remote.aligner.position)
            let seconds = Double(end) / Double(AudioAnalysis.sampleRate)
            s.local.ring.append(s.local.aligner.padding(toSeconds: seconds))
            s.remote.ring.append(s.remote.aligner.padding(toSeconds: seconds))
            let local = s.local.ring.snapshot(), remote = s.remote.ring.snapshot()
            let held = min(local.count, remote.count)
            s.recordingStartHost = SystemAudioTap.hostSecondsNow() - Double(held) / Double(AudioAnalysis.sampleRate)
            s.local.file = try Self.makeFile(folder.appending(path: "local.caf"))
            s.remote.file = try Self.makeFile(folder.appending(path: "remote.caf"))
            try Self.write(Array(local.suffix(held)), to: s.local.file)
            try Self.write(Array(remote.suffix(held)), to: s.remote.file)
            s.local.ring.wipe()
            s.remote.ring.wipe()
            s.mode = .recording
            return true
        }
        if opened { AppLog.info("Meeting recording: kept the held start") }
    }

    /// Stops a held capture and zeroes everything it held.
    @MainActor
    func discard() {
        stopCapture()
        state.withLock { s in
            s.local.ring.wipe()
            s.remote.ring.wipe()
            s.local.recent = []
            s.remote.recent = []
            s.mode = .idle
        }
    }

    /// Stops recording, levels both files to the same length and closes them. Returns the duration.
    @MainActor
    @discardableResult
    func stop() -> Double {
        stopCapture()
        return state.withLock { s in
            let end = max(s.local.aligner.position, s.remote.aligner.position)
            let seconds = Double(end) / Double(AudioAnalysis.sampleRate)
            try? Self.write(s.local.aligner.padding(toSeconds: seconds), to: s.local.file)
            try? Self.write(s.remote.aligner.padding(toSeconds: seconds), to: s.remote.file)
            s.local.file = nil
            s.remote.file = nil
            s.local.recent = []
            s.remote.recent = []
            s.mode = .idle
            return seconds
        }
    }

    @MainActor
    private func stopCapture() {
        refreshTask?.cancel()
        refreshTask = nil
        mic.onSamples = nil
        mic.stop()
        tap?.onSamples = nil
        tap?.stop()
        tap = nil
    }

    // MARK: Samples

    private func receive(_ samples: [Float], host: Double, remote: Bool) {
        let level = AudioAnalysis.meterLevel(rms: AudioAnalysis.rms(samples))
        state.withLock { s in
            guard s.mode != .idle else { return }
            var track = remote ? s.remote : s.local
            let placed = track.aligner.place(samples, hostSeconds: host)
            track.level = level
            if s.mode == .holding {
                track.ring.append(placed)
            } else {
                try? Self.write(placed, to: track.file)
            }
            track.recent.append(contentsOf: placed)
            if track.recent.count > Self.recentLimit + 16_000 { track.recent.removeFirst(track.recent.count - Self.recentLimit) }
            if remote { s.remote = track } else { s.local = track }
        }
    }

    /// The last `seconds` of each track, for the live preview.
    func recent(seconds: Double) -> (local: [Float], remote: [Float]) {
        let n = Int(seconds * Double(AudioAnalysis.sampleRate))
        return state.withLock { (Array($0.local.recent.suffix(n)), Array($0.remote.recent.suffix(n))) }
    }

    // MARK: Files

    private func openFiles() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let local = try Self.makeFile(folder.appending(path: "local.caf"))
        let remote = try Self.makeFile(folder.appending(path: "remote.caf"))
        state.withLock { s in
            s.local.file = local
            s.remote.file = remote
        }
    }

    private static func makeFile(_ url: URL) throws -> AVAudioFile {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var u = url
        try? u.setResourceValues(values)
        return file
    }

    private static func write(_ samples: [Float], to file: AVAudioFile?) throws {
        guard let file, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }

    /// Reads both tracks of a recorded meeting, padded to the same length.
    static func loadTracks(in folder: URL) throws -> (local: [Float], remote: [Float]) {
        func read(_ name: String) throws -> [Float] {
            let url = folder.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.length > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
            else { return [] }
            try file.read(into: buffer)
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        var local = try read("local.caf"), remote = try read("remote.caf")
        let n = max(local.count, remote.count)
        local += [Float](repeating: 0, count: n - local.count)
        if !remote.isEmpty { remote += [Float](repeating: 0, count: n - remote.count) }
        return (local, remote)
    }

    /// Re-encodes kept audio to compact AAC (spec §6.4) and removes the CAF originals.
    static func compressAudio(in folder: URL) {
        for name in ["local", "remote"] {
            let source = folder.appending(path: "\(name).caf")
            guard let input = try? AVAudioFile(forReading: source) else { continue }
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                                           AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
            guard let output = try? AVAudioFile(forWriting: folder.appending(path: "\(name).m4a"), settings: settings),
                  let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_000 * 10)
            else { continue }
            var ok = true
            while input.framePosition < input.length {
                do {
                    try input.read(into: buffer)
                    try output.write(from: buffer)
                } catch {
                    ok = false
                    break
                }
            }
            if ok { try? FileManager.default.removeItem(at: source) }
        }
    }
}
