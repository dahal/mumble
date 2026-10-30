import Foundation

/// Places audio chunks from one source on the meeting's shared clock.
///
/// Each chunk arrives with the host time of its first sample. The aligner pads silence when the
/// source paused (or started late) and drops overlap when it runs ahead, so the microphone and the
/// meeting audio stay aligned within a frame for the whole meeting despite device clock drift.
public struct TimelineAligner: Sendable {
    public let sampleRate: Double
    public let startHostSeconds: Double
    /// Samples placed on the timeline so far.
    public private(set) var position = 0
    /// Corrections smaller than this are ignored (jitter).
    public var tolerance = 320

    public init(startHostSeconds: Double, sampleRate: Double = Double(AudioAnalysis.sampleRate)) {
        self.startHostSeconds = startHostSeconds
        self.sampleRate = sampleRate
    }

    /// Returns the samples to append for a chunk whose first sample played at `hostSeconds`.
    public mutating func place(_ samples: [Float], hostSeconds: Double) -> [Float] {
        let expected = Int(((hostSeconds - startHostSeconds) * sampleRate).rounded())
        var output: [Float]
        if expected - position > tolerance {
            output = [Float](repeating: 0, count: expected - position) + samples
        } else if position - expected > tolerance {
            let drop = min(samples.count, position - expected)
            output = Array(samples.dropFirst(drop))
        } else {
            output = samples
        }
        // Chunks from before the meeting started are discarded.
        if expected + samples.count <= 0 { output = [] }
        position += output.count
        return output
    }

    /// Pads to `seconds` so both tracks end at the same length.
    public mutating func padding(toSeconds seconds: Double) -> [Float] {
        let target = Int((seconds * sampleRate).rounded())
        guard target > position else { return [] }
        defer { position = target }
        return [Float](repeating: 0, count: target - position)
    }
}
