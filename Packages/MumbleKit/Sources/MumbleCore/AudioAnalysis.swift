import Accelerate
import Foundation

/// Cheap signal measurements used to skip silent clips, trim dead air before the
/// final pass, and drive the level meter.
public enum AudioAnalysis {
    public static let sampleRate = 16_000

    public static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return samples.withUnsafeBufferPointer { vDSP.rootMeanSquare($0) }
    }

    public static func rms(_ samples: [Float]) -> Float { rms(samples[...]) }

    public static func peak(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return vDSP.maximumMagnitude(samples)
    }

    /// Short, near-silent recordings (an accidental key press, a cough) are treated as a cancel
    /// rather than sent to the model, which can hallucinate words from noise.
    /// Thresholds follow FluidVoice's production values.
    public static func isLikelySilence(_ samples: [Float], maxDurationSeconds: Double = 4) -> Bool {
        let duration = Double(samples.count) / Double(sampleRate)
        guard duration <= maxDurationSeconds else { return false }
        guard peak(samples) < 0.01, rms(samples) < 0.002 else { return false }
        return maxFrameRMS(samples) < 0.0045
    }

    static func maxFrameRMS(_ samples: [Float], frame: Int = 320) -> Float {
        stride(from: 0, to: samples.count, by: frame)
            .map { rms(samples[$0..<min($0 + frame, samples.count)]) }
            .max() ?? 0
    }

    /// Removes leading/trailing stretches quieter than `threshold`, keeping `padding` seconds
    /// of context on each side so word onsets and tails are not clipped.
    public static func trimSilence(
        _ samples: [Float],
        threshold: Float = 0.006,
        frameSeconds: Double = 0.02,
        paddingSeconds: Double = 0.25
    ) -> [Float] {
        let frame = max(1, Int(frameSeconds * Double(sampleRate)))
        let frames = stride(from: 0, to: samples.count, by: frame).map {
            rms(samples[$0..<min($0 + frame, samples.count)])
        }
        guard let firstLoud = frames.firstIndex(where: { $0 >= threshold }),
              let lastLoud = frames.lastIndex(where: { $0 >= threshold })
        else { return samples }
        let pad = Int(paddingSeconds * Double(sampleRate))
        let start = max(0, firstLoud * frame - pad)
        let end = min(samples.count, (lastLoud + 1) * frame + pad)
        return Array(samples[start..<end])
    }

    /// Maps RMS to a 0...1 meter value on a perceptual (dB) scale: -60 dBFS → 0, 0 dBFS → 1.
    public static func meterLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 60) / 60))
    }
}
