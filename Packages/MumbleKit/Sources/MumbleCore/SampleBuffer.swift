import Foundation
import Synchronization

/// Thread-safe accumulator for 16 kHz mono samples. The audio thread appends;
/// the transcription side takes snapshots. The lock is held only for a memcpy.
public final class SampleBuffer: Sendable {
    private let storage = Mutex<[Float]>([])

    public init(reservingSeconds seconds: Double = 60) {
        storage.withLock { $0.reserveCapacity(Int(seconds * Double(AudioAnalysis.sampleRate))) }
    }

    public func append(_ samples: UnsafeBufferPointer<Float>) {
        storage.withLock { $0.append(contentsOf: samples) }
    }

    public func append(_ samples: [Float]) {
        storage.withLock { $0.append(contentsOf: samples) }
    }

    public func snapshot() -> [Float] {
        storage.withLock { $0 }
    }

    public var count: Int {
        storage.withLock { $0.count }
    }

    public var durationSeconds: Double {
        Double(count) / Double(AudioAnalysis.sampleRate)
    }

    public func reset() {
        storage.withLock { $0.removeAll(keepingCapacity: true) }
    }
}
