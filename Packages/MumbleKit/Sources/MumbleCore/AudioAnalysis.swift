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

    /// Removes leading/trailing silence, keeping `paddingSeconds` of context on each side so word
    /// onsets and tails are not clipped.
    ///
    /// The threshold adapts to each recording: a fixed level trimmed real speech away on quiet
    /// microphones (a Bluetooth headset mic peaks around 0.002–0.005 RMS). Speech is anything
    /// clearly above the recording's own noise floor.
    public static func trimSilence(
        _ samples: [Float],
        frameSeconds: Double = 0.02,
        paddingSeconds: Double = 0.3
    ) -> [Float] {
        let frame = max(1, Int(frameSeconds * Double(sampleRate)))
        let frames = stride(from: 0, to: samples.count, by: frame).map {
            rms(samples[$0..<min($0 + frame, samples.count)])
        }
        guard frames.count > 4 else { return samples }
        let sorted = frames.sorted()
        let noiseFloor = sorted[sorted.count / 10]
        let loudest = sorted[sorted.count - 1]
        // 3× the noise floor, but never above 15% of the loudest frame (so quiet speech in a
        // loud recording still counts) and never below an absolute floor of digital near-silence.
        let threshold = max(min(noiseFloor * 3, loudest * 0.15), 0.0003)
        guard loudest > threshold,
              let firstLoud = frames.firstIndex(where: { $0 >= threshold }),
              let lastLoud = frames.lastIndex(where: { $0 >= threshold })
        else { return samples }
        let pad = Int(paddingSeconds * Double(sampleRate))
        let start = max(0, firstLoud * frame - pad)
        let end = min(samples.count, (lastLoud + 1) * frame + pad)
        return Array(samples[start..<end])
    }

    /// Splits a long recording into segments no longer than `maxSeconds`, cutting at the quietest
    /// moment in the last part of each window, so no word straddles a cut.
    ///
    /// Parakeet's window is ~15 s; longer audio is chunked inside FluidAudio with overlapping windows,
    /// and its seam merging can duplicate a word cut in half ("meeting" → "meetingeting").
    /// Cutting in pauses avoids seams inside words entirely.
    public static func splitAtPauses(
        _ samples: [Float], maxSeconds: Double = 13.5, searchFromSeconds: Double = 7, frameSeconds: Double = 0.02
    ) -> [Range<Int>] {
        let maxLength = Int(maxSeconds * Double(sampleRate))
        guard samples.count > maxLength else { return [0..<samples.count] }
        let frame = max(1, Int(frameSeconds * Double(sampleRate)))
        let searchFrom = Int(searchFromSeconds * Double(sampleRate))

        var segments: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxLength {
            // Quietest 200 ms stretch between searchFrom and maxLength into this segment.
            let windowFrames = 10
            var bestCut = start + maxLength
            var bestEnergy = Float.greatestFiniteMagnitude
            var position = start + searchFrom
            while position + windowFrames * frame <= start + maxLength {
                let energy = rms(samples[position..<(position + windowFrames * frame)])
                if energy < bestEnergy {
                    bestEnergy = energy
                    bestCut = position + windowFrames * frame / 2
                }
                position += frame
            }
            segments.append(start..<bestCut)
            start = bestCut
        }
        segments.append(start..<samples.count)
        return segments
    }

    /// Maps RMS to a 0...1 meter value on a perceptual (dB) scale: -60 dBFS → 0, 0 dBFS → 1.
    public static func meterLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 60) / 60))
    }
}
