import Foundation

/// A user rule that rewrites a spoken phrase into fixed text, applied after recognition.
public struct Replacement: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var spoken: String
    public var written: String

    public init(id: UUID = UUID(), spoken: String, written: String) {
        self.id = id
        self.spoken = spoken
        self.written = written
    }
}

public struct TextPipelineOptions: Sendable, Equatable {
    public var removeFillers: Bool
    public var spokenCommands: Bool
    public var replacements: [Replacement]
    public var vocabulary: [VocabularyEntry]

    public init(
        removeFillers: Bool = true, spokenCommands: Bool = true, replacements: [Replacement] = [],
        vocabulary: [VocabularyEntry] = []
    ) {
        self.removeFillers = removeFillers
        self.spokenCommands = spokenCommands
        self.replacements = replacements
        self.vocabulary = vocabulary
    }
}

/// Deterministic post-processing of a raw transcript. Runs in well under a millisecond.
public enum TextPipeline {
    /// - Parameter normalizer: inverse text normalization (numbers, dates, emails), injected so
    ///   this module stays free of the model dependency.
    public static func process(
        _ raw: String,
        options: TextPipelineOptions,
        normalizer: ((String) -> String)? = nil
    ) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        if let normalizer { text = normalizer(text) }
        if options.removeFillers { text = removeFillers(text) }
        if options.spokenCommands { text = applySpokenCommands(text) }
        text = Vocabulary.applyCanonicalForms(text, entries: options.vocabulary)
        text = applyReplacements(text, options.replacements)
        return tidy(text)
    }

    // MARK: Fillers

    static let fillerPattern = try! NSRegularExpression(
        pattern: #"(?i)(^|(?<=[\s,.;:!?]))(?:u+m+|u+h+m*|e+r+m+|h+m+|m{2,}|a+h+)(?=$|[\s,.;:!?])[,.]?"#
    )

    public static func removeFillers(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let stripped = fillerPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return recapitalizeSentences(tidy(stripped))
    }

    // MARK: Spoken commands

    static let newParagraphPattern = try! NSRegularExpression(
        pattern: #"(?i)[,;]?\s*\bnew paragraph\b[,.;]?\s*"#
    )
    static let newLinePattern = try! NSRegularExpression(
        pattern: #"(?i)[,;]?\s*\bnew line\b[,.;]?\s*"#
    )

    public static func applySpokenCommands(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in [(newParagraphPattern, "\n\n"), (newLinePattern, "\n")] {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return recapitalizeSentences(result)
    }

    // MARK: Replacements

    public static func applyReplacements(_ text: String, _ replacements: [Replacement]) -> String {
        var result = text
        for rule in replacements {
            let spoken = rule.spoken.trimmingCharacters(in: .whitespaces)
            guard !spoken.isEmpty else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: spoken)
            // Only anchor on word boundaries where the phrase itself starts/ends with a word character,
            // so rules like ":)" still match.
            let lead = spoken.first!.isLetterOrDigit ? #"\b"# : ""
            let trail = spoken.last!.isLetterOrDigit ? #"\b"# : ""
            guard let regex = try? NSRegularExpression(pattern: "(?i)\(lead)\(escaped)\(trail)") else { continue }
            let template = NSRegularExpression.escapedTemplate(for: rule.written)
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }

    // MARK: Whitespace and casing

    /// Collapses runs of spaces, removes spaces before punctuation and around newlines,
    /// and drops leading punctuation left behind by removed words.
    public static func tidy(_ text: String) -> String {
        var result = text
        let rules: [(String, String)] = [
            (#"[ \t]+"#, " "),
            (#" +([,.;:!?])"#, "$1"),
            (#"([,;:])(?:\s*[,;:])+"#, "$1"),
            (#" *\n *"#, "\n"),
            (#"^[\s,;:.]+"#, ""),
            (#"\n[,;:.]+ ?"#, "\n"),
        ]
        for (pattern, template) in rules {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Uppercases the first letter of the text and of every sentence or line that follows a terminator.
    public static func recapitalizeSentences(_ text: String) -> String {
        var chars = Array(text)
        var capitalizeNext = true
        for i in chars.indices {
            let c = chars[i]
            if c.isLetter {
                if capitalizeNext, c.isLowercase { chars[i] = Character(c.uppercased()) }
                capitalizeNext = false
            } else if c == "." || c == "!" || c == "?" || c == "\n" {
                capitalizeNext = true
            } else if !c.isWhitespace {
                capitalizeNext = capitalizeNext && !c.isNumber
            }
        }
        return String(chars)
    }
}

private extension Character {
    var isLetterOrDigit: Bool { isLetter || isNumber }
}
