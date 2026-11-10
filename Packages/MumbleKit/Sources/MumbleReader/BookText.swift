import Foundation
import NaturalLanguage

/// A stretch of one PDF page's text, in UTF-16 units of `PDFPage.string` (what `PDFPage.selection(for:)` takes).
public struct PageSpan: Sendable, Hashable, Codable {
    public var page: Int
    public var location: Int
    public var length: Int

    public init(page: Int, location: Int, length: Int) {
        self.page = page
        self.location = location
        self.length = length
    }

    public var range: NSRange { NSRange(location: location, length: length) }
}

/// One thing the narrator says: usually a sentence, sometimes a heading or part of a long sentence.
public struct Utterance: Sendable, Hashable {
    public var index: Int
    /// Cleaned text to synthesize (line breaks joined, hyphenation undone, ligatures expanded).
    public var text: String
    /// Where it sits in the PDF, for highlighting. A sentence that crosses a page break has two spans.
    public var spans: [PageSpan]

    public var page: Int { spans.first?.page ?? 0 }
}

/// Turns the raw text of PDF pages into the sentences a narrator reads, skipping running headers,
/// footers and page numbers, and remembering where each sentence is on the page.
public enum BookText {
    /// Longest utterance in UTF-16 units. Longer sentences are split at a comma or space, so the first
    /// audio is ready quickly and the highlight stays close to what you hear.
    public static let defaultMaxLength = 300

    public static func utterances(pages: [String], maxLength: Int = defaultMaxLength) -> [Utterance] {
        let lines = pages.enumerated().map { page, text in Self.lines(of: text, page: page) }
        let repeated = repeatedEdgeLines(lines)
        var kept: [Line] = []
        for pageLines in lines {
            let edges = edgeIndices(pageLines)
            for (i, line) in pageLines.enumerated() {
                if line.text.isEmpty {
                    kept.append(line)  // blank lines mark paragraphs
                    continue
                }
                if edges.contains(i), isPageNumber(line.text) || repeated.contains(edgeKey(line.text)) { continue }
                kept.append(line)
            }
        }
        let stream = Stream(lines: kept)
        return sentences(in: stream, maxLength: maxLength)
    }

    // MARK: Lines

    struct Line {
        var page: Int
        /// Trimmed text and its range in the page string.
        var text: String
        var location: Int
    }

    static func lines(of page: String, page index: Int) -> [Line] {
        let ns = page as NSString
        var out: [Line] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let raw = ns.substring(with: range)
            let leading = raw.utf16.prefix { Self.isSpace($0) }.count
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(Line(page: index, text: trimmed, location: range.location + leading))
        }
        return out
    }

    private static func isSpace(_ unit: UTF16.CodeUnit) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0xA0
    }

    /// The first and last two non-empty lines of a page, where running headers and page numbers live.
    static func edgeIndices(_ lines: [Line]) -> Set<Int> {
        let filled = lines.indices.filter { !lines[$0].text.isEmpty }
        // On short pages only the very first and last line can be a header or footer.
        let depth = filled.count >= 6 ? 2 : 1
        return Set(filled.prefix(depth) + filled.suffix(depth))
    }

    /// Header/footer text with numbers wildcarded, so "Chapter 3 · 47" matches "Chapter 3 · 48".
    static func edgeKey(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
        return lowered.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Edge lines that repeat on many pages: running heads, book titles, copyright footers.
    static func repeatedEdgeLines(_ pages: [[Line]]) -> Set<String> {
        guard pages.count >= 4 else { return [] }
        var counts: [String: Int] = [:]
        for lines in pages {
            let keys = Set(edgeIndices(lines).map { edgeKey(lines[$0].text) })
            for key in keys { counts[key, default: 0] += 1 }
        }
        let threshold = max(3, Int((Double(pages.count) * 0.3).rounded(.up)))
        return Set(counts.filter { $0.value >= threshold && $0.key.contains(where: \.isLetter) }.keys)
    }

    private static let pageNumberPattern = try! NSRegularExpression(
        pattern: #"^[\-–—\s]*(page\s+)?([0-9]{1,4}|[ivxlcdm]{1,7})(\s*(of|/)\s*[0-9]{1,4})?[\-–—\s]*$"#,
        options: [.caseInsensitive])

    static func isPageNumber(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return pageNumberPattern.firstMatch(in: text, range: range) != nil
    }

    // MARK: Stream

    /// The book's kept text joined into one string, with a map back to page ranges.
    struct Stream {
        struct Piece { var streamLocation: Int; var page: Int; var pageLocation: Int; var length: Int }
        var text = NSMutableString()
        var pieces: [Piece] = []

        init(lines: [Line]) {
            let lengths = lines.map { ($0.text as NSString).length }.filter { $0 > 0 }.sorted()
            let typical = lengths.isEmpty ? 60 : lengths[lengths.count * 3 / 4]
            var previous: Line?
            var sawBlank = false
            for line in lines {
                if line.text.isEmpty {
                    sawBlank = previous != nil
                    continue
                }
                if let previous {
                    append(joiner: Self.joiner(previous, line, typical: typical, blankBetween: sawBlank))
                }
                pieces.append(Piece(streamLocation: text.length, page: line.page, pageLocation: line.location,
                                    length: (line.text as NSString).length))
                text.append(line.text)
                previous = line
                sawBlank = false
            }
        }

        private enum Joiner { case none, space, paragraph }

        private mutating func append(joiner: Joiner) {
            switch joiner {
            case .none:
                // Undo end-of-line hyphenation: drop the hyphen that ends the stream.
                text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
                pieces[pieces.count - 1].length -= 1
            case .space: text.append(" ")
            case .paragraph: text.append("\n\n")
            }
        }

        private static func joiner(_ previous: Line, _ next: Line, typical: Int, blankBetween: Bool) -> Joiner {
            let prev = previous.text
            if blankBetween, previous.page == next.page { return .paragraph }
            if prev.count >= 2, prev.hasSuffix("-") {
                let beforeHyphen = prev[prev.index(prev.endIndex, offsetBy: -2)]
                if beforeHyphen.isLetter, next.text.first?.isLowercase == true { return .none }
            }
            let terminal = prev.last.map { ".!?:;,\"”’)]…".contains($0) } ?? false
            // A short line with no closing punctuation is a heading ("Chapter 1", "Introduction"):
            // read it as its own sentence instead of running it into the next one.
            if !terminal, !prev.hasSuffix("-"), (prev as NSString).length * 2 <= typical, next.text.first?.isLowercase != true {
                return .paragraph
            }
            return .space
        }

        /// Page spans covered by a stream range, one per page.
        func spans(for range: NSRange) -> [PageSpan] {
            var byPage: [(page: Int, start: Int, end: Int)] = []
            for piece in pieces {
                let pieceRange = NSRange(location: piece.streamLocation, length: piece.length)
                let overlap = NSIntersectionRange(pieceRange, range)
                guard overlap.length > 0 else { continue }
                let start = piece.pageLocation + overlap.location - piece.streamLocation
                let end = start + overlap.length
                if let last = byPage.last, last.page == piece.page {
                    byPage[byPage.count - 1].end = max(last.end, end)
                } else {
                    byPage.append((piece.page, start, end))
                }
            }
            return byPage.map { PageSpan(page: $0.page, location: $0.start, length: $0.end - $0.start) }
        }
    }

    // MARK: Sentences

    static func sentences(in stream: Stream, maxLength: Int) -> [Utterance] {
        let string = stream.text as String
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = string
        var ranges: [NSRange] = []
        tokenizer.enumerateTokens(in: string.startIndex..<string.endIndex) { range, _ in
            let ns = NSRange(range, in: string)
            // NLTokenizer keeps paragraph breaks inside a token when the line has no final punctuation.
            ranges.append(contentsOf: split(ns, in: stream.text, at: "\n\n"))
            return true
        }
        var out: [Utterance] = []
        for range in ranges {
            for piece in limit(range, in: stream.text, maxLength: maxLength) {
                let trimmed = trim(piece, in: stream.text)
                guard trimmed.length > 0 else { continue }
                let raw = stream.text.substring(with: trimmed)
                guard raw.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                let text = raw.precomposedStringWithCompatibilityMapping
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                out.append(Utterance(index: out.count, text: text, spans: stream.spans(for: trimmed)))
            }
        }
        return out
    }

    private static func split(_ range: NSRange, in text: NSString, at separator: String) -> [NSRange] {
        var out: [NSRange] = []
        var start = range.location
        let end = NSMaxRange(range)
        while start < end {
            let found = text.range(of: separator, range: NSRange(location: start, length: end - start))
            if found.location == NSNotFound {
                out.append(NSRange(location: start, length: end - start))
                break
            }
            out.append(NSRange(location: start, length: found.location - start))
            start = NSMaxRange(found)
        }
        return out
    }

    private static func trim(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        let spaces = CharacterSet.whitespacesAndNewlines
        while start < end, let scalar = Unicode.Scalar(text.character(at: start)), spaces.contains(scalar) { start += 1 }
        while end > start, let scalar = Unicode.Scalar(text.character(at: end - 1)), spaces.contains(scalar) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Splits an over-long sentence at the last clause break (or space) before the limit.
    static func limit(_ range: NSRange, in text: NSString, maxLength: Int) -> [NSRange] {
        var out: [NSRange] = []
        var rest = trim(range, in: text)
        while rest.length > maxLength {
            let window = NSRange(location: rest.location, length: maxLength)
            let minCut = rest.location + maxLength / 3
            var cut: Int?
            for marks in [";:—–", ",", " "] {
                let set = CharacterSet(charactersIn: marks)
                let found = text.rangeOfCharacter(from: set, options: .backwards, range: window)
                if found.location != NSNotFound, found.location >= minCut {
                    cut = NSMaxRange(found)
                    break
                }
            }
            let end = cut ?? NSMaxRange(window)
            out.append(NSRange(location: rest.location, length: end - rest.location))
            rest = trim(NSRange(location: end, length: NSMaxRange(rest) - end), in: text)
        }
        if rest.length > 0 { out.append(rest) }
        return out
    }
}
