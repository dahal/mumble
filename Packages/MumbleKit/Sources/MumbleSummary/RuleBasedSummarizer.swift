import Foundation
import MumbleCore

/// Built-in, deterministic notes extractor. Works on every Mac with no model: finds decisions,
/// commitments ("I'll…", "Sarah, can you…") and open questions, and builds an extractive summary.
public struct RuleBasedSummarizer: Summarizer {
    public let providerID = "builtin"
    public init() {}

    struct Sentence {
        var line: Int
        var speakerKey: String
        var text: String
    }

    public func summarize(_ input: SummaryInput) async throws -> MeetingNotes {
        Self.extract(input)
    }

    public static func extract(_ input: SummaryInput) -> MeetingNotes {
        let sentences = input.lines.enumerated().flatMap { i, line in
            split(line.text).map { Sentence(line: i, speakerKey: line.speakerKey, text: $0) }
        }
        let names = input.speakers.filter { !$0.value.hasPrefix("Speaker ") && $0.key != MeetingSpeaker.meKey }

        var actions: [MeetingNotes.Action] = []
        var decisions: [MeetingNotes.Item] = []
        var questions: [MeetingNotes.Item] = []
        for (index, sentence) in sentences.enumerated() {
            if let action = action(sentence, names: names, next: sentences[safe: index + 1]) {
                actions.append(action)
            } else if let decision = decision(sentence) {
                decisions.append(.init(text: decision, sourceSegmentIndex: sentence.line))
            } else if let question = openQuestion(sentence, following: Array(sentences.dropFirst(index + 1).prefix(3))) {
                questions.append(.init(text: question, sourceSegmentIndex: sentence.line))
            }
        }
        let notes = MeetingNotes(
            summary: summary(input, sentences: sentences, decisions: decisions, actions: actions),
            decisions: Array(decisions.prefix(8)), actionItems: Array(actions.prefix(12)),
            openQuestions: Array(questions.prefix(6)))
        return NotesValidator.validate(notes, input: input)
    }

    // MARK: Sentences

    static func split(_ text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { result.append(s) }
        }
        return result.isEmpty && !text.isEmpty ? [text] : result
    }

    static let duePattern = #"\b(by|before|until|on)\s+(the\s+)?(end of (the )?(day|week|month|quarter)|eod|eow|tomorrow|tonight|today|next (week|month|monday|tuesday|wednesday|thursday|friday)|monday|tuesday|wednesday|thursday|friday|saturday|sunday|\d{1,2}(st|nd|rd|th)?( of [a-z]+)?|[a-z]+ \d{1,2}(st|nd|rd|th)?)\b"#

    static func due(in text: String) -> String? {
        guard let r = text.range(of: duePattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[r])
    }

    /// Uppercases the first letter and ends with a period.
    static func tidy(_ text: String) -> String {
        var t = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.?!;:"))
        guard let first = t.first else { return t }
        t = first.uppercased() + t.dropFirst()
        return t
    }

    // MARK: Action items

    static let requestPattern = #"^(?:(?:okay|ok|so|and|also|then|great),?\s+)*(?:([a-z][a-z .'-]{1,40}),\s+)?(?:can|could|would|will)\s+you(?:\s+please)?\s+(.+?)(?:\?|$)"#
    static let commitmentPattern = #"^(?:(?:okay|ok|so|and|yeah|yes|sure|then|great),?\s+)*(?:i'll|i will|i'm going to|i am going to|i can|let me)\s+(.+)$"#
    static let assignedPattern = #"^(?:(?:okay|ok|so|and|then),?\s+)*([a-z][a-z .'-]{1,40}?)\s+(?:will|is going to|is gonna|to)\s+(.+)$"#
    static let genericPattern = #"(?:action item|todo|to-do|follow up|we need to|we should|someone needs to|someone should)[:,]?\s+(.+)$"#

    static func action(_ s: Sentence, names: [String: String], next: Sentence?) -> MeetingNotes.Action? {
        let lower = s.text.lowercased()
        if let m = match(requestPattern, lower), let task = m.last, let task, isTask(task) {
            // "Sarah, can you…" → Sarah. "Can you…" with no name → whoever answers next, if they agree.
            var owner: String?
            if let name = m.first ?? nil, let key = speakerKey(for: name, names: names) {
                owner = key
            } else if let next, next.speakerKey != s.speakerKey, isAgreement(next.text) {
                owner = next.speakerKey
            }
            let original = substring(of: s.text, matchingLower: task)
            return .init(text: tidy(original), ownerSpeakerKey: owner, due: due(in: s.text), sourceSegmentIndex: s.line)
        }
        if let m = match(commitmentPattern, lower), let task = m.first ?? nil, isTask(task), !isHedge(task) {
            let original = substring(of: s.text, matchingLower: task)
            return .init(text: tidy(original), ownerSpeakerKey: s.speakerKey, due: due(in: s.text), sourceSegmentIndex: s.line)
        }
        if let m = match(assignedPattern, lower), let name = m.first ?? nil, let task = m.last ?? nil,
           let key = speakerKey(for: name, names: names), isTask(task) {
            let original = substring(of: s.text, matchingLower: task)
            return .init(text: tidy(original), ownerSpeakerKey: key, due: due(in: s.text), sourceSegmentIndex: s.line)
        }
        if let m = match(genericPattern, lower), let task = m.first ?? nil, isTask(task), !lower.hasSuffix("?") {
            let original = substring(of: s.text, matchingLower: task)
            return .init(text: tidy(original), ownerSpeakerKey: nil, due: due(in: s.text), sourceSegmentIndex: s.line)
        }
        return nil
    }

    static let taskVerbs: Set<String> = [
        "send", "ship", "share", "write", "review", "fix", "update", "check", "follow", "schedule", "book", "draft",
        "prepare", "set", "create", "add", "remove", "test", "deploy", "email", "call", "ask", "talk", "look",
        "finish", "merge", "file", "document", "investigate", "reach", "ping", "post", "publish", "sync", "loop",
        "put", "make", "get", "move", "run", "build", "design", "plan", "organize", "confirm", "clean", "upload",
        "find", "figure", "take", "handle", "own", "follow-up", "circle", "present", "demo", "estimate", "order",
    ]

    static func isTask(_ text: String) -> Bool {
        let words = WordErrorRate.normalizedWords(text)
        guard words.count >= 2, let first = words.first else { return false }
        return taskVerbs.contains(first)
    }

    static func isHedge(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["think", "guess", "try to remember", "be honest", "say"].contains { lower.hasPrefix($0) }
    }

    static func isAgreement(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return ["yes", "yeah", "yep", "sure", "will do", "on it", "sounds good", "of course", "absolutely", "can do",
                "no problem", "i'll", "i will", "okay", "ok"].contains { lower.hasPrefix($0) }
    }

    static func speakerKey(for name: String, names: [String: String]) -> String? {
        let cleaned = name.trimmingCharacters(in: .whitespaces)
        guard !["okay", "so", "and", "yeah", "then", "we", "they", "it", "that", "this", "you", "he", "she"].contains(cleaned) else {
            return nil
        }
        let matches = names.filter { NameMatcher.score(cleaned, $0.value) >= 0.75 }
        return matches.count == 1 ? matches.first?.key : nil
    }

    // MARK: Decisions and questions

    static let decisionMarkers = [
        "let's go with", "lets go with", "we'll go with", "we will go with", "we're going with", "we are going with",
        "we decided", "we've decided", "decided to", "the decision is", "we agreed", "agreed to", "we're going to go with",
        "let's do", "final answer", "we'll ship", "we will ship", "we're not going to", "we won't",
    ]

    static func decision(_ s: Sentence) -> String? {
        let lower = s.text.lowercased()
        guard !lower.hasSuffix("?"), let marker = decisionMarkers.first(where: { lower.contains($0) }) else { return nil }
        // Keep from the marker on: "Okay, let's go with crossed out." → "Go with crossed out".
        var text = s.text
        if let r = lower.range(of: marker) {
            let offset = lower.distance(from: lower.startIndex, to: r.lowerBound)
            text = String(s.text.dropFirst(offset))
            for prefix in ["let's ", "lets ", "we'll ", "we will ", "we're ", "we are ", "we "] where text.lowercased().hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                break
            }
        }
        let words = WordErrorRate.normalizedWords(text)
        return words.count >= 2 ? tidy(text) : nil
    }

    static func openQuestion(_ s: Sentence, following: [Sentence]) -> String? {
        let lower = s.text.lowercased()
        let explicit = ["open question", "we still need to decide", "not sure whether", "not sure if", "need to figure out",
                        "we should figure out", "tbd", "to be decided"].contains { lower.contains($0) }
        guard explicit || lower.hasSuffix("?") else { return nil }
        let words = WordErrorRate.normalizedWords(s.text)
        guard words.count >= 5 else { return nil }
        // Requests ("can you…") are action items, not questions.
        if match(requestPattern, lower) != nil { return nil }
        // Answered right away with a decision or a clear yes/no → not open.
        if !explicit, following.contains(where: { decision($0) != nil }) { return nil }
        return tidy(s.text) + (lower.hasSuffix("?") ? "?" : "")
    }

    // MARK: Summary

    static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "so", "to", "of", "in", "on", "for", "with", "at", "by", "it", "is", "are",
        "was", "were", "be", "been", "this", "that", "these", "those", "i", "you", "we", "they", "he", "she", "me", "my",
        "our", "your", "their", "do", "does", "did", "have", "has", "had", "will", "would", "can", "could", "should",
        "just", "like", "yeah", "okay", "ok", "um", "uh", "think", "know", "going", "get", "got", "about", "there", "here",
        "what", "when", "where", "which", "who", "how", "if", "then", "than", "also", "not", "no", "yes", "all", "some",
        "one", "can't", "don't", "i'm", "it's", "that's", "we're", "let's", "i'll", "we'll", "really", "right", "well",
        "maybe", "kind", "sort", "thing", "things", "lot", "much", "more", "very", "too", "still", "want", "need", "now",
    ]

    static func summary(_ input: SummaryInput, sentences: [Sentence], decisions: [MeetingNotes.Item],
                        actions: [MeetingNotes.Action]) -> String {
        guard !sentences.isEmpty else { return "" }
        // Score sentences by the frequency of their content words across the meeting.
        var freq: [String: Int] = [:]
        for s in sentences {
            for w in WordErrorRate.normalizedWords(s.text) where !stopwords.contains(w) && w.count > 2 { freq[w, default: 0] += 1 }
        }
        let scored = sentences.enumerated().map { i, s -> (Int, Double) in
            let words = WordErrorRate.normalizedWords(s.text).filter { !stopwords.contains($0) && $0.count > 2 }
            guard words.count >= 4, !s.text.hasSuffix("?") else { return (i, 0) }
            let score = Double(words.reduce(0) { $0 + (freq[$1] ?? 0) }) / Double(words.count).squareRoot()
            return (i, score)
        }
        let top = scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(2).map(\.0).sorted()
        var parts = top.map { tidy(sentences[$0].text) + "." }
        if let decision = decisions.first, !parts.contains(where: { $0.lowercased().contains(decision.text.lowercased()) }) {
            parts.append("Decided: \(decision.text.prefix(1).lowercased() + decision.text.dropFirst()).")
        }
        if !actions.isEmpty {
            parts.append("\(actions.count) action item\(actions.count == 1 ? "" : "s").")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Regex helpers

    /// Capture groups of the first match (nil for groups that didn't participate).
    static func match(_ pattern: String, _ text: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) }
        }
    }

    /// The part of `original` corresponding to the lowercased `fragment` (keeps original casing).
    static func substring(of original: String, matchingLower fragment: String) -> String {
        if let r = original.range(of: fragment, options: [.caseInsensitive]) { return String(original[r]) }
        return fragment
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
