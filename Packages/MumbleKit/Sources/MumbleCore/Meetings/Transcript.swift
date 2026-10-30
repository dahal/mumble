import Foundation

/// A stretch of time attributed to one speaker, before or after transcription.
public struct SpeakerSpan: Sendable, Hashable {
    public var speakerKey: String
    public var start: Double
    public var end: Double

    public init(speakerKey: String, start: Double, end: Double) {
        self.speakerKey = speakerKey
        self.start = start
        self.end = end
    }

    public var duration: Double { end - start }
}

/// A transcribed span, ready to become a stored `Segment`.
public struct TimedText: Sendable, Hashable {
    public var speakerKey: String
    public var start: Double
    public var end: Double
    public var text: String

    public init(speakerKey: String, start: Double, end: Double, text: String) {
        self.speakerKey = speakerKey
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum SpeakerTurns {
    /// Turns diarizer output into transcription units: drops blips, merges a speaker's consecutive
    /// spans separated by short gaps, and splits turns longer than `maxDuration` so each fits the
    /// ASR window.
    public static func build(
        _ spans: [SpeakerSpan], minDuration: Double = 0.4, mergeGap: Double = 0.8, maxDuration: Double = 14
    ) -> [SpeakerSpan] {
        let sorted = spans.filter { $0.duration >= minDuration }.sorted { $0.start < $1.start }
        var merged: [SpeakerSpan] = []
        for span in sorted {
            if var last = merged.last, last.speakerKey == span.speakerKey, span.start - last.end <= mergeGap {
                last.end = max(last.end, span.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(span)
            }
        }
        return merged.flatMap { split($0, maxDuration: maxDuration) }
    }

    /// Splits a span into near-equal pieces no longer than `maxDuration`.
    static func split(_ span: SpeakerSpan, maxDuration: Double) -> [SpeakerSpan] {
        guard span.duration > maxDuration else { return [span] }
        let count = Int((span.duration / maxDuration).rounded(.up))
        let size = span.duration / Double(count)
        var pieces: [SpeakerSpan] = []
        for i in 0..<count {
            let start = span.start + Double(i) * size
            let end = i == count - 1 ? span.end : start + size
            pieces.append(SpeakerSpan(speakerKey: span.speakerKey, start: start, end: end))
        }
        return pieces
    }

    /// Seconds of speech per speaker.
    public static func talkSeconds(_ spans: [SpeakerSpan]) -> [String: Double] {
        spans.reduce(into: [:]) { $0[$1.speakerKey, default: 0] += $1.duration }
    }

    /// The speaker talking at `time`, if any (the longest overlapping span wins).
    public static func speaker(at time: Double, in spans: [SpeakerSpan]) -> String? {
        spans.filter { $0.start <= time && time < $0.end }.max { $0.duration < $1.duration }?.speakerKey
    }

    /// Seconds each speaker talked inside [start, end].
    public static func overlap(start: Double, end: Double, in spans: [SpeakerSpan]) -> [String: Double] {
        var result: [String: Double] = [:]
        for span in spans {
            let o = min(end, span.end) - max(start, span.start)
            if o > 0 { result[span.speakerKey, default: 0] += o }
        }
        return result
    }
}

public enum TranscriptMerger {
    /// Interleaves the local (you) and remote (others) transcripts by time, drops empty text and
    /// joins consecutive pieces from the same speaker when the gap is short and the result stays readable.
    public static func merge(_ pieces: [TimedText], joinGap: Double = 1.5, maxSegmentSeconds: Double = 30) -> [TimedText] {
        let sorted = pieces
            .map { TimedText(speakerKey: $0.speakerKey, start: $0.start, end: $0.end,
                             text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var result: [TimedText] = []
        for piece in sorted {
            if var last = result.last, last.speakerKey == piece.speakerKey, piece.start - last.end <= joinGap,
               piece.end - last.start <= maxSegmentSeconds {
                last.end = max(last.end, piece.end)
                last.text = last.text + " " + piece.text
                result[result.count - 1] = last
            } else {
                result.append(piece)
            }
        }
        return result
    }
}

/// Detects microphone audio that is only the meeting playing through the speakers.
public enum EchoGate {
    /// True when `local` within `range` is mostly a delayed copy of `remote`: the normalized
    /// cross-correlation peak within ±`maxLag` samples exceeds `threshold`, and the remote signal is
    /// active there. Both arrays are 16 kHz mono on the same clock.
    public static func isEcho(
        local: [Float], remote: [Float], range: Range<Int>, maxLag: Int = 4_800, threshold: Float = 0.5
    ) -> Bool {
        let lower = max(0, range.lowerBound), upper = min(local.count, range.upperBound)
        guard upper - lower > 1_600, remote.count > lower else { return false }
        let localWindow = Array(local[lower..<upper])
        let remoteRMS = AudioAnalysis.rms(Array(remote[lower..<min(upper, remote.count)]))
        guard remoteRMS > 0.003 else { return false }
        // Compare energy envelopes (10 ms frames) rather than raw samples: robust to the room's
        // filtering and the speaker/mic frequency response, and cheap.
        let frame = 160
        let localEnv = envelope(localWindow, frame: frame)
        guard localEnv.count > 10 else { return false }
        var best: Float = 0
        let lagFrames = maxLag / frame
        for lag in 0...lagFrames {
            // The mic hears the speakers later than the tap, so remote leads local.
            let start = lower - lag * frame
            guard start >= 0, start + localWindow.count <= remote.count else { continue }
            let remoteEnv = envelope(Array(remote[start..<(start + localWindow.count)]), frame: frame)
            best = max(best, correlation(localEnv, remoteEnv))
        }
        return best >= threshold
    }

    /// Silences microphone frames that are only the meeting playing through the speakers.
    ///
    /// Estimates the speaker→mic gain from frames where the meeting audio is active (you're usually
    /// quiet then), and mutes local frames no louder than that echo level (with a margin). You talking
    /// over someone stays: your voice is much louder than the echo. Returns the cleaned track and the
    /// seconds removed.
    public static func suppress(
        local: [Float], remote: [Float], frame: Int = 480, maxLagFrames: Int = 10, margin: Float = 3
    ) -> (cleaned: [Float], removedSeconds: Double) {
        guard !remote.isEmpty, local.count >= frame else { return (local, 0) }
        let localEnv = envelope(local, frame: frame)
        let remoteEnv = envelope(remote, frame: frame)
        guard !remoteEnv.isEmpty else { return (local, 0) }
        // The mic hears the speakers slightly later: compare with the loudest recent remote frame.
        let remoteRecent: [Float] = localEnv.indices.map { i in
            let lo = max(0, i - maxLagFrames), hi = min(remoteEnv.count - 1, i)
            return lo <= hi ? remoteEnv[lo...hi].max() ?? 0 : 0
        }
        let active = localEnv.indices.filter { remoteRecent[$0] > 0.003 }
        guard active.count > 10 else { return (local, 0) }
        let ratios = active.map { localEnv[$0] / remoteRecent[$0] }.sorted()
        let gain = ratios[ratios.count / 2]

        var cleaned = local
        var removed = 0
        for i in active where localEnv[i] <= gain * remoteRecent[i] * margin {
            let start = i * frame
            for j in start..<min(start + frame, cleaned.count) { cleaned[j] = 0 }
            removed += 1
        }
        return (cleaned, Double(removed * frame) / Double(AudioAnalysis.sampleRate))
    }

    static func envelope(_ samples: [Float], frame: Int) -> [Float] {
        stride(from: 0, to: samples.count - frame + 1, by: frame).map { i in
            var sum: Float = 0
            for j in i..<(i + frame) { sum += samples[j] * samples[j] }
            return (sum / Float(frame)).squareRoot()
        }
    }

    /// Pearson correlation of two equal-length series.
    static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 1 else { return 0 }
        let ma = a.prefix(n).reduce(0, +) / Float(n), mb = b.prefix(n).reduce(0, +) / Float(n)
        var num: Float = 0, da: Float = 0, db: Float = 0
        for i in 0..<n {
            let x = a[i] - ma, y = b[i] - mb
            num += x * y
            da += x * x
            db += y * y
        }
        guard da > 0, db > 0 else { return 0 }
        return num / (da.squareRoot() * db.squareRoot())
    }
}
