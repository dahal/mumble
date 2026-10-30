import Foundation

/// Finds where someone is speaking in a long recording (the microphone track of a meeting), using
/// frame energy against the recording's own noise floor.
public enum SpeechRegions {
    public struct Config: Sendable {
        public var frameSamples = 480            // 30 ms
        public var floorPercentile = 0.05
        public var floorMultiplier: Float = 3.5
        public var absoluteMinimum: Float = 0.004
        public var hangoverFrames = 12           // keep 360 ms after energy drops
        public var mergeGapSeconds = 0.6
        public var minRegionSeconds = 0.35
        public var maxRegionSeconds = 14.0
        public var paddingSeconds = 0.15
        public init() {}
    }

    public static func detect(_ samples: [Float], config: Config = Config()) -> [Range<Int>] {
        let rate = AudioAnalysis.sampleRate
        let frame = config.frameSamples
        guard samples.count >= frame * 4 else { return [] }
        let energies: [Float] = stride(from: 0, to: samples.count - frame + 1, by: frame).map {
            AudioAnalysis.rms(samples[$0..<($0 + frame)])
        }
        let floor = energies.sorted()[Int(Double(energies.count - 1) * config.floorPercentile)]
        let threshold = max(floor * config.floorMultiplier, config.absoluteMinimum)

        var regions: [Range<Int>] = []
        var start: Int?
        var quiet = 0
        for (i, e) in energies.enumerated() {
            if e >= threshold {
                if start == nil { start = i }
                quiet = 0
            } else if let s = start {
                quiet += 1
                if quiet > config.hangoverFrames {
                    regions.append(s..<(i - quiet + 1))
                    start = nil
                    quiet = 0
                }
            }
        }
        if let s = start { regions.append(s..<energies.count) }

        // Frames → samples, padded, merged across short gaps, filtered and capped.
        let pad = Int(config.paddingSeconds * Double(rate))
        var merged: [Range<Int>] = []
        for r in regions {
            let range = max(0, r.lowerBound * frame - pad)..<min(samples.count, r.upperBound * frame + pad)
            if let last = merged.last, range.lowerBound - last.upperBound <= Int(config.mergeGapSeconds * Double(rate)) {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        let minLength = Int(config.minRegionSeconds * Double(rate))
        let maxLength = Int(config.maxRegionSeconds * Double(rate))
        return merged.filter { $0.count >= minLength }.flatMap { range -> [Range<Int>] in
            guard range.count > maxLength else { return [range] }
            // Split long speech at its quietest frames near each cut.
            var pieces: [Range<Int>] = []
            var cursor = range.lowerBound
            while range.upperBound - cursor > maxLength {
                let searchStart = cursor + maxLength / 2, searchEnd = cursor + maxLength
                var best = searchEnd, bestEnergy = Float.greatestFiniteMagnitude
                for f in stride(from: searchStart, to: searchEnd - frame, by: frame) {
                    let e = AudioAnalysis.rms(samples[f..<(f + frame)])
                    if e < bestEnergy { bestEnergy = e; best = f }
                }
                pieces.append(cursor..<best)
                cursor = best
            }
            pieces.append(cursor..<range.upperBound)
            return pieces
        }
    }
}

/// Saved-voice matching (spec §10.3 step 1).
public enum VoiceMatching {
    /// Cosine distance, 0 (same direction) … 2 (opposite).
    public static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 2 }
        return 1 - dot / (na.squareRoot() * nb.squareRoot())
    }

    /// For each cluster, the closest saved person (by their nearest stored embedding).
    public static func bestMatches(clusters: [String: [Float]], voices: [Voice]) -> [String: NameVoting.VoiceMatch] {
        var result: [String: NameVoting.VoiceMatch] = [:]
        let byPerson = Dictionary(grouping: voices, by: \.personID)
        for (key, embedding) in clusters {
            var best: NameVoting.VoiceMatch?
            for (person, personVoices) in byPerson {
                let d = personVoices.map { cosineDistance(embedding, $0.embedding) }.min() ?? 2
                if d < (best?.distance ?? .greatestFiniteMagnitude) { best = .init(personID: person, distance: d) }
            }
            if let best { result[key] = best }
        }
        return result
    }
}
