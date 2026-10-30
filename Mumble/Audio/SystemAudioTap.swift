@preconcurrency import AVFoundation
import CoreAudio
import MumbleCore
import Synchronization

/// Records what an app plays (the other people in a call) with a Core Audio process tap: no
/// virtual audio driver, no bot. Needs the "System Audio Recording" permission
/// (NSAudioCaptureUsageDescription); macOS asks the first time a tap starts.
///
/// Delivers 16 kHz mono Float32 chunks with the host time of their first sample.
final class SystemAudioTap: @unchecked Sendable {
    enum Target: Equatable, Sendable {
        /// Every process whose bundle ID starts with one of these prefixes (an app and its helpers).
        case bundlePrefixes([String])
        case pids([pid_t])
        /// Everything playing on the Mac except Mumble.
        case everythingButMumble
    }

    enum TapError: LocalizedError {
        case noProcesses
        case coreAudio(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .noProcesses: "The meeting app isn't playing any audio yet."
            case let .coreAudio(what, status): "Couldn't record the meeting audio (\(what), error \(status))."
            }
        }
    }

    /// Called on the tap's queue with 16 kHz mono samples and the host time (seconds) of the first one.
    var onSamples: (@Sendable ([Float], Double) -> Void)?

    private(set) var target: Target
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tappedProcesses: [AudioObjectID] = []
    /// The output device the aggregate was built on; the tap follows the system output when it changes.
    private var outputUID: String?
    private let queue = DispatchQueue(label: "dev.mumble.tap", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let levelStore = Mutex<Float>(0)
    private let receivedAudio = Atomic<Bool>(false)

    var level: Float { levelStore.withLock { $0 } }
    /// True once any non-silent audio arrived (false if permission was denied: taps then deliver zeros).
    var hasReceivedAudio: Bool { receivedAudio.load(ordering: .relaxed) }
    var isRunning: Bool { procID != nil }

    init(target: Target) {
        self.target = target
    }

    deinit { stop() }

    // MARK: Process discovery

    struct AudioProcess: Sendable, Hashable {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String?
        let isRunningOutput: Bool
        let isRunningInput: Bool
    }

    static func processes() -> [AudioProcess] {
        let ids: [AudioObjectID] = (try? arrayProperty(AudioObjectID(kAudioObjectSystemObject),
                                                      kAudioHardwarePropertyProcessObjectList)) ?? []
        return ids.map { id in
            AudioProcess(
                objectID: id,
                pid: (try? scalarProperty(id, kAudioProcessPropertyPID, as: pid_t.self)) ?? -1,
                bundleID: try? stringProperty(id, kAudioProcessPropertyBundleID),
                isRunningOutput: ((try? scalarProperty(id, kAudioProcessPropertyIsRunningOutput, as: UInt32.self)) ?? 0) != 0,
                isRunningInput: ((try? scalarProperty(id, kAudioProcessPropertyIsRunningInput, as: UInt32.self)) ?? 0) != 0)
        }
    }

    func matchingProcesses() -> [AudioObjectID] {
        let all = Self.processes()
        switch target {
        case let .bundlePrefixes(prefixes):
            return all.filter { p in prefixes.contains { p.bundleID?.hasPrefix($0) == true } }.map(\.objectID)
        case let .pids(pids):
            return all.filter { pids.contains($0.pid) }.map(\.objectID)
        case .everythingButMumble:
            return all.filter { $0.pid == getpid() }.map(\.objectID)
        }
    }

    // MARK: Lifecycle

    func start() throws {
        stop()
        let processes = matchingProcesses()
        let description: CATapDescription
        if target == .everythingButMumble {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
        } else {
            guard !processes.isEmpty else { throw TapError.noProcesses }
            description = CATapDescription(stereoMixdownOfProcesses: processes)
        }
        description.uuid = UUID()
        description.name = "Mumble meeting notes"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "create tap")
        tapID = tap
        tappedProcesses = processes

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "read tap format")
        guard let input = AVAudioFormat(streamDescription: &format) else { throw TapError.coreAudio("tap format", -1) }
        inputFormat = input
        converter = AVAudioConverter(from: input, to: outputFormat)

        let outputUID = try Self.defaultOutputUID()
        self.outputUID = outputUID
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mumble Meeting Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice), "create aggregate device")
        aggregateID = aggregateDevice

        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { [weak self] _, inputData, inputTime, _, _ in
            self?.handle(inputData, time: inputTime)
        }, "create IO proc")
        procID = proc
        try check(AudioDeviceStart(aggregateID, procID), "start")
        AppLog.info("Meeting tap started on \(processes.count) process(es), \(input.sampleRate) Hz × \(input.channelCount)")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tappedProcesses = []
        levelStore.withLock { $0 = 0 }
    }

    /// Rebuilds the tap when the set of matching processes changed (e.g. Chrome started a new
    /// audio helper). Returns true when it restarted.
    @discardableResult
    func refreshIfNeeded() -> Bool {
        // Headphones connected or disconnected: rebuild on the new output device.
        if let outputUID, let current = try? Self.defaultOutputUID(), current != outputUID {
            AppLog.info("Meeting tap: output device changed, restarting")
            do { try start() } catch { AppLog.error("Meeting tap restart failed: \(error)") }
            return true
        }
        guard target != .everythingButMumble else { return false }
        let now = matchingProcesses()
        guard !now.isEmpty, Set(now) != Set(tappedProcesses) else { return false }
        AppLog.info("Meeting tap: processes changed (\(tappedProcesses.count) → \(now.count)), restarting")
        do { try start() } catch { AppLog.error("Meeting tap restart failed: \(error)") }
        return true
    }

    // MARK: Audio

    private func handle(_ data: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>) {
        guard let inputFormat, let converter,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: data, deallocator: nil),
              input.frameLength > 0
        else { return }
        let hostSeconds = Self.seconds(fromHostTime: time.pointee.mHostTime)
        let capacity = AVAudioFrameCount(Double(input.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let channel = output.floatChannelData, output.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
        let rms = AudioAnalysis.rms(samples)
        levelStore.withLock { $0 = AudioAnalysis.meterLevel(rms: rms) }
        if rms > 0.0005 { receivedAudio.store(true, ordering: .relaxed) }
        onSamples?(samples, hostSeconds)
    }

    static func seconds(fromHostTime hostTime: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(hostTime) * Double(info.numer) / Double(info.denom) / 1e9
    }

    static func hostSecondsNow() -> Double { seconds(fromHostTime: mach_absolute_time()) }

    // MARK: Core Audio helpers

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else {
            stop()
            throw TapError.coreAudio(what, status)
        }
    }

    static func defaultOutputUID() throws -> String {
        let device = try scalarProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice,
                                        as: AudioObjectID.self)
        return try stringProperty(device, kAudioDevicePropertyDeviceUID)
    }

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func scalarProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as: T.Type) throws -> T {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, value)
        guard status == noErr else { throw TapError.coreAudio("read property", status) }
        return value.pointee
    }

    static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { throw TapError.coreAudio("read string", status) }
        return value.takeRetainedValue() as String
    }

    static func arrayProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var values = [T](unsafeUninitializedCapacity: Int(size) / MemoryLayout<T>.stride) { _, count in count = 0 }
        values = Array(unsafeUninitializedCapacity: Int(size) / MemoryLayout<T>.stride) { buffer, count in
            var s = size
            let status = AudioObjectGetPropertyData(object, &address, 0, nil, &s, buffer.baseAddress!)
            count = status == noErr ? Int(s) / MemoryLayout<T>.stride : 0
        }
        return values
    }
}
