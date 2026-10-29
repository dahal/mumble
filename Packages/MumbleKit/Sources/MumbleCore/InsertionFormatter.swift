import Foundation
import NaturalLanguage

/// Adapts a finished transcript to the text that already sits before the cursor,
/// so dictating mid-sentence doesn't produce "word.New sentence" or a stray capital.
public enum InsertionFormatter {
    /// - Parameter preceding: the characters immediately before the insertion point, if known.
    ///   `nil` means unknown (no Accessibility info), in which case the text is left as-is.
    public static func format(_ text: String, preceding: String?) -> String {
        guard !text.isEmpty, let preceding, let last = preceding.last else { return text }

        var result = text
        if isMidSentence(last) {
            result = lowercasingFirstWordIfSafe(result)
        }
        if needsLeadingSpace(after: last), let first = result.first,
           !first.isWhitespace, !",.;:!?)]}".contains(first) {
            result = " " + result
        }
        return result
    }

    static func isMidSentence(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || ",;:".contains(c)
    }

    static func needsLeadingSpace(after c: Character) -> Bool {
        !(c.isWhitespace || "([{\"'“‘/-".contains(c))
    }

    /// Mid-sentence, "Hello" should become "hello" — but never "I", acronyms ("NASA"),
    /// mixed-case words ("iPhone", "McDonald") or names ("John").
    static func lowercasingFirstWordIfSafe(_ text: String) -> String {
        let firstWord = String(text.prefix { $0.isLetter || $0 == "'" || $0 == "’" })
        guard let first = firstWord.first, first.isUppercase else { return text }
        if firstWord.dropFirst().contains(where: { $0.isUppercase }) { return text }
        let stem = firstWord.split(whereSeparator: { $0 == "'" || $0 == "’" }).first.map(String.init) ?? firstWord
        if stem == "I" || isName(firstWord, in: text) { return text }
        return first.lowercased() + text.dropFirst()
    }

    static func isName(_ word: String, in text: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let (tag, _) = tagger.tag(at: text.startIndex, unit: .word, scheme: .nameType)
        return tag == .personalName || tag == .placeName || tag == .organizationName
    }
}
