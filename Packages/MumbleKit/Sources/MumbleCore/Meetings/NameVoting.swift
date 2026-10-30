import Foundation

/// A timestamped hint that someone was talking: a caption line or the meeting app's speaking highlight.
public struct NameSignal: Sendable, Hashable, Codable {
    public enum Source: String, Sendable, Codable { case captions, screen }
    public var time: Double
    public var name: String
    public var source: Source
    /// Caption text, when the source is captions.
    public var text: String?

    public init(time: Double, name: String, source: Source, text: String? = nil) {
        self.time = time
        self.name = name
        self.source = source
        self.text = text
    }
}

/// Decides which name belongs to which diarized voice.
///
/// Order: saved voices, then caption alignment, then speaking-highlight co-occurrence, then the
/// single-candidate rule. The screen never decides who is talking; it votes on names, and only
/// assignments with clear, sufficient evidence are accepted.
public enum NameVoting {
    public struct VoiceMatch: Sendable, Hashable {
        public var personID: UUID
        public var distance: Float
        public init(personID: UUID, distance: Float) {
            self.personID = personID
            self.distance = distance
        }
    }

    public struct Config: Sendable {
        public var voiceThreshold: Float = 0.45
        public var minShare: Double = 0.6
        public var minHighlightSeconds: Double = 10
        public var minCaptionWords: Double = 15
        /// The highlight lags speech: credit the speaker active in [t - lead, t + lag].
        public var highlightLead: Double = 1.0
        public var highlightLag: Double = 0.3
        public var captionWindow: Double = 10
        public var singleCandidateMinSeconds: Double = 60
        public init() {}
    }

    public enum Identity: Sendable, Hashable {
        case person(UUID)
        case name(String)
    }

    public struct Assignment: Sendable, Hashable {
        public var identity: Identity
        public var source: NamingSource
        public var confidence: Double
    }

    public struct Input: Sendable {
        /// Remote diarized speech, keyed by cluster.
        public var spans: [SpeakerSpan]
        /// Transcribed remote text, for caption alignment.
        public var texts: [TimedText]
        /// Best saved-voice match per cluster (already filtered to one embedding model).
        public var voiceMatches: [String: VoiceMatch]
        public var signals: [NameSignal]
        /// Candidate names from the calendar invite (excluding you).
        public var rosterNames: [String]
        /// Clusters already named by the user; never changed.
        public var fixed: [String: Identity]

        public init(
            spans: [SpeakerSpan], texts: [TimedText] = [], voiceMatches: [String: VoiceMatch] = [:],
            signals: [NameSignal] = [], rosterNames: [String] = [], fixed: [String: Identity] = [:]
        ) {
            self.spans = spans
            self.texts = texts
            self.voiceMatches = voiceMatches
            self.signals = signals
            self.rosterNames = rosterNames
            self.fixed = fixed
        }
    }

    public static func assign(_ input: Input, config: Config = Config()) -> [String: Assignment] {
        let clusters = Set(input.spans.map(\.speakerKey))
        var result: [String: Assignment] = [:]
        for (key, identity) in input.fixed where clusters.contains(key) {
            result[key] = Assignment(identity: identity, source: .user, confidence: 1)
        }

        // 1. Saved voices: each person at most once, closest cluster wins.
        let byPerson = Dictionary(grouping: input.voiceMatches.filter { clusters.contains($0.key) && result[$0.key] == nil },
                                  by: { $0.value.personID })
        for (person, matches) in byPerson {
            guard !result.values.contains(where: { $0.identity == .person(person) }),
                  let best = matches.min(by: { $0.value.distance < $1.value.distance }),
                  best.value.distance <= config.voiceThreshold
            else { continue }
            result[best.key] = Assignment(identity: .person(person), source: .voice,
                                          confidence: Double(max(0, 1 - best.value.distance)))
        }

        // 2 + 3. Votes from captions (weight = matched words) and highlights (weight = overlap seconds).
        var votes: [String: [String: Double]] = [:]
        var sourceOf: [String: [String: NamingSource]] = [:]
        for (cluster, name, weight) in captionVotes(input, config: config) {
            votes[cluster, default: [:]][canonical(name), default: 0] += weight / config.minCaptionWords * config.minHighlightSeconds
            sourceOf[cluster, default: [:]][canonical(name)] = .captions
        }
        for signal in input.signals where signal.source == .screen {
            let overlap = SpeakerTurns.overlap(
                start: signal.time - config.highlightLead, end: signal.time + config.highlightLag, in: input.spans)
            for (cluster, seconds) in overlap {
                votes[cluster, default: [:]][canonical(signal.name), default: 0] += seconds
                if sourceOf[cluster]?[canonical(signal.name)] == nil {
                    sourceOf[cluster, default: [:]][canonical(signal.name)] = .screen
                }
            }
        }
        let displayFor = Dictionary(input.signals.map { (canonical($0.name), $0.name) }, uniquingKeysWith: { a, _ in a })

        // Greedy maximum-weight assignment: strongest (cluster, name) pairs first, each name once.
        var candidates: [(cluster: String, name: String, weight: Double, share: Double)] = []
        for (cluster, names) in votes where result[cluster] == nil {
            let total = names.values.reduce(0, +)
            for (name, weight) in names {
                candidates.append((cluster, name, weight, total > 0 ? weight / total : 0))
            }
        }
        let takenNames = Set(result.values.compactMap { if case let .name(n) = $0.identity { canonical(n) } else { nil } })
        var usedNames = takenNames
        for c in candidates.sorted(by: { ($0.weight, $0.cluster) > ($1.weight, $1.cluster) }) {
            guard result[c.cluster] == nil, !usedNames.contains(c.name),
                  c.share >= config.minShare, c.weight >= config.minHighlightSeconds
            else { continue }
            usedNames.insert(c.name)
            result[c.cluster] = Assignment(identity: .name(displayFor[c.name] ?? c.name),
                                           source: sourceOf[c.cluster]?[c.name] ?? .screen, confidence: c.share)
        }

        // 4. Single candidate: one unnamed voice with real speech, one unassigned invitee.
        let unnamed = clusters.filter { result[$0] == nil }
        let talk = SpeakerTurns.talkSeconds(input.spans)
        let assignedNames = Set(result.values.compactMap { if case let .name(n) = $0.identity { canonical(n) } else { nil } })
        let remainingRoster = input.rosterNames.filter { name in
            !assignedNames.contains(where: { NameMatcher.score($0, name) >= 0.9 })
        }
        if unnamed.count == 1, remainingRoster.count == 1, let cluster = unnamed.first,
           talk[cluster, default: 0] >= config.singleCandidateMinSeconds, clusters.count == result.count + 1 {
            result[cluster] = Assignment(identity: .name(remainingRoster[0]), source: .calendarSingleCandidate,
                                         confidence: 0.5)
        }
        return result
    }

    /// Aligns caption lines to transcribed text: a caption votes for the cluster whose text in the
    /// time window shares the most words with it.
    static func captionVotes(_ input: Input, config: Config) -> [(String, String, Double)] {
        var out: [(String, String, Double)] = []
        let texts = input.texts.map { ($0, Set(WordErrorRate.normalizedWords($0.text))) }
        for signal in input.signals where signal.source == .captions {
            guard let caption = signal.text else { continue }
            let words = WordErrorRate.normalizedWords(caption)
            guard words.count >= 2 else { continue }
            let captionSet = Set(words)
            var bestCluster: String?
            var bestCount = 0
            for (text, set) in texts where abs(text.start - signal.time) <= config.captionWindow
                || (text.start - config.captionWindow...text.end + config.captionWindow).contains(signal.time) {
                let shared = captionSet.intersection(set).count
                if shared > bestCount {
                    bestCount = shared
                    bestCluster = text.speakerKey
                }
            }
            // Require most of the caption to be found, so a stray common word doesn't vote.
            if let bestCluster, Double(bestCount) >= Double(captionSet.count) * 0.5 {
                out.append((bestCluster, signal.name, Double(bestCount)))
            }
        }
        return out
    }

    static func canonical(_ name: String) -> String {
        NameMatcher.tokens(name).joined(separator: " ")
    }
}
