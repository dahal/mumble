import Foundation
import MumbleCore

/// The transcript as a summarizer sees it: speaker names already resolved.
public struct SummaryInput: Sendable {
    public struct Line: Sendable, Hashable {
        public var speakerKey: String
        public var speakerName: String
        public var start: Double
        public var text: String
        public init(speakerKey: String, speakerName: String, start: Double, text: String) {
            self.speakerKey = speakerKey
            self.speakerName = speakerName
            self.start = start
            self.text = text
        }
    }

    public var title: String
    public var lines: [Line]
    /// Speaker key → display name ("Me" for the microphone).
    public var speakers: [String: String]

    public init(title: String, lines: [Line], speakers: [String: String]) {
        self.title = title
        self.lines = lines
        self.speakers = speakers
    }

    /// "[3] Sarah Chen (4:12): text" — the numbered format every model provider receives.
    public func numberedTranscript(range: Range<Int>? = nil) -> String {
        let r = range ?? lines.indices
        return r.map { i in
            "[\(i)] \(lines[i].speakerName) (\(MarkdownExporter.timestamp(lines[i].start))): \(lines[i].text)"
        }.joined(separator: "\n")
    }
}

public protocol Summarizer: Sendable {
    /// Stored with the meeting ("apple", "claude", "builtin").
    var providerID: String { get }
    func summarize(_ input: SummaryInput) async throws -> MeetingNotes
}

public enum SummaryProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Apple Intelligence when available, otherwise the built-in extractor.
    case automatic
    case apple
    case claude
    case builtin
    case off

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: "Automatic (on this Mac)"
        case .apple: "Apple Intelligence (on this Mac)"
        case .claude: "Claude (sends transcript text)"
        case .builtin: "Built-in (on this Mac)"
        case .off: "Off"
        }
    }

    public static func label(forStored id: String?) -> String {
        switch id {
        case "apple": "Summarized on this Mac with Apple Intelligence"
        case "claude": "Summarized with Claude"
        case "builtin": "Summarized on this Mac"
        default: "Not summarized"
        }
    }
}

public enum SummaryError: LocalizedError, Equatable {
    case unavailable(String)
    case badResponse(String)
    case refused(String)
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(why): "Summaries aren't available: \(why)"
        case let .badResponse(why): "The summary couldn't be read: \(why)"
        case let .refused(why): "The model declined to summarize this meeting\(why.isEmpty ? "" : " (\(why))")."
        case let .http(code, message): "Summary request failed (\(code)): \(message)"
        }
    }
}

/// Post-generation checks (spec §9.3): owners must be meeting speakers, due dates must be in the
/// source line, items must cite a real line. Nothing invented survives.
public enum NotesValidator {
    public static func validate(_ notes: MeetingNotes, input: SummaryInput) -> MeetingNotes {
        var result = notes
        let validKeys = Set(input.speakers.keys)
        func valid(_ index: Int?) -> Int? { index.flatMap { input.lines.indices.contains($0) ? $0 : nil } }

        result.summary = notes.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        result.actionItems = notes.actionItems.compactMap { item in
            var item = item
            item.text = clean(item.text)
            guard !item.text.isEmpty else { return nil }
            item.sourceSegmentIndex = valid(item.sourceSegmentIndex)
            if let owner = item.ownerSpeakerKey, !validKeys.contains(owner) {
                // A model may return a display name instead of a key.
                item.ownerSpeakerKey = input.speakers.first { NameMatcher.score($0.value, owner) >= 0.9 }?.key
            }
            if let due = item.due {
                let source = item.sourceSegmentIndex.map { input.lines[$0].text.lowercased() } ?? ""
                let words = WordErrorRate.normalizedWords(due)
                let found = !words.isEmpty && words.allSatisfy { source.contains($0) }
                item.due = found ? due : nil
            }
            return item
        }
        result.decisions = dedupe(notes.decisions.map { .init(text: clean($0.text), sourceSegmentIndex: valid($0.sourceSegmentIndex)) })
        result.openQuestions = dedupe(notes.openQuestions.map { .init(text: clean($0.text), sourceSegmentIndex: valid($0.sourceSegmentIndex)) })
        return result
    }

    static func clean(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("-") || t.hasPrefix("•") || t.hasPrefix("*") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return t
    }

    static func dedupe(_ items: [MeetingNotes.Item]) -> [MeetingNotes.Item] {
        var seen = Set<String>()
        return items.filter { !$0.text.isEmpty && seen.insert($0.text.lowercased()).inserted }
    }
}

/// Splits a transcript into model-sized chunks at speaker turns (spec §9.2 map-reduce).
public enum SummaryChunker {
    /// Rough token estimate: ~4 characters per token.
    public static func estimateTokens(_ text: String) -> Int { max(1, text.count / 4) }

    public static func chunks(_ input: SummaryInput, maxTokens: Int) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        var tokens = 0
        for (i, line) in input.lines.enumerated() {
            let cost = estimateTokens(line.speakerName + line.text) + 8
            if tokens + cost > maxTokens, i > start {
                result.append(start..<i)
                start = i
                tokens = 0
            }
            tokens += cost
        }
        if start < input.lines.count { result.append(start..<input.lines.count) }
        return result
    }
}

/// Picks the provider for a setting, falling back to the built-in extractor when the chosen one
/// isn't available, so every meeting gets notes.
public enum SummarizerFactory {
    public static func make(_ provider: SummaryProvider, claudeAPIKey: String?) -> (any Summarizer)? {
        switch provider {
        case .off: return nil
        case .builtin: return RuleBasedSummarizer()
        case .claude:
            guard let key = claudeAPIKey, !key.isEmpty else { return RuleBasedSummarizer() }
            return ClaudeSummarizer(apiKey: key)
        case .apple, .automatic:
            if AppleIntelligence.isAvailable, let apple = AppleIntelligence.makeSummarizer() { return apple }
            return RuleBasedSummarizer()
        }
    }
}
