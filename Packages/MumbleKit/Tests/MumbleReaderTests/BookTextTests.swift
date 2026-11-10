import Foundation
import Testing

@testable import MumbleReader

@Suite struct BookTextTests {
    /// Text the way PDFKit returns it: hard-wrapped lines, a running head, a page number.
    func page(_ n: Int, _ body: String) -> String {
        "The Long Road · Chapter One\n\(body)\n\(n)"
    }

    @Test func dropsRunningHeadsAndPageNumbers() {
        let words = ["apples", "rivers", "lanterns", "harbors", "meadows"]
        let pages = (1...5).map { page($0, "This is page \($0). It talks about \(words[$0 - 1]).") }
        let texts = BookText.utterances(pages: pages).map(\.text)
        #expect(texts.first == "This is page 1.")
        #expect(texts.count == 10)
        #expect(!texts.contains { $0.contains("Long Road") })
        #expect(!texts.contains { $0 == "1" || $0 == "2" })
    }

    @Test func keepsHeadersOnShortDocuments() {
        // With under four pages nothing counts as a running head.
        let texts = BookText.utterances(pages: ["Memo\nPlease review the plan."]).map(\.text)
        #expect(texts == ["Memo", "Please review the plan."])
    }

    @Test func joinsWrappedLinesAndUndoesHyphenation() {
        let pages = ["It was a bright cold day in April, and the clocks were strik-\ning thirteen. Winston Smith hur-\nried home."]
        let texts = BookText.utterances(pages: pages).map(\.text)
        #expect(texts == ["It was a bright cold day in April, and the clocks were striking thirteen.", "Winston Smith hurried home."])
    }

    @Test func keepsRealHyphens() {
        let texts = BookText.utterances(pages: ["This is a well-\nKnown fact about the long and winding road."]).map(\.text)
        #expect(texts.first?.contains("well- Known") == true)
    }

    @Test func headingsAreTheirOwnUtterance() {
        let body = "The morning was quiet and the streets of the town were nearly empty of people."
        let texts = BookText.utterances(pages: ["Chapter 1\n\(body)\nIt rained later in the afternoon, as it always did there."]).map(\.text)
        #expect(texts.first == "Chapter 1")
        #expect(texts[1].hasPrefix("The morning"))
    }

    @Test func blankLinesSplitParagraphs() {
        let texts = BookText.utterances(pages: ["Introduction\n\nWe begin here"]).map(\.text)
        #expect(texts == ["Introduction", "We begin here"])
    }

    @Test func sentenceAcrossPagesHasTwoSpans() {
        let a = "The first page ends in the middle of a"
        let b = "sentence that continues here. Then another."
        let utterances = BookText.utterances(pages: [a, b])
        #expect(utterances.first?.text == "The first page ends in the middle of a sentence that continues here.")
        #expect(utterances.first?.spans.map(\.page) == [0, 1])
        #expect(utterances.first?.spans.first?.location == 0)
        #expect(utterances.first?.spans.first?.length == (a as NSString).length)
        #expect(utterances.first?.spans.last == PageSpan(page: 1, location: 0, length: ("sentence that continues here." as NSString).length))
    }

    @Test func spansPointAtThePageText() {
        let pageText = "  Header line here\nFirst sentence is here. Second one\nwraps onto a new line."
        let pages = [pageText]
        for u in BookText.utterances(pages: pages) {
            for span in u.spans {
                let raw = (pages[span.page] as NSString).substring(with: span.range)
                let flat = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                #expect(flat == u.text)
            }
        }
    }

    @Test func splitsLongSentencesAtClauseBreaks() {
        let clause = "and the river ran on past the old mill"
        let long = Array(repeating: clause, count: 12).joined(separator: ", ") + "."
        let utterances = BookText.utterances(pages: [long], maxLength: 120)
        #expect(utterances.count > 1)
        #expect(utterances.allSatisfy { ($0.text as NSString).length <= 120 })
        #expect(utterances.first?.text.hasSuffix(",") == true)
        let rejoined = utterances.map(\.text).joined(separator: " ")
        #expect(rejoined == long)
    }

    @Test func expandsLigaturesAndSkipsPunctuationOnly() {
        let texts = BookText.utterances(pages: ["The ﬁrst ﬂight.\n* * *\nThe end."]).map(\.text)
        #expect(texts == ["The first flight.", "The end."])
    }

    @Test func pageNumberPatterns() {
        for text in ["12", "- 12 -", "xiv", "Page 3", "page 3 of 10", "3 / 10"] {
            #expect(BookText.isPageNumber(text), "\(text)")
        }
        for text in ["12 Angry Men", "Chapter 3", "I went home."] {
            #expect(!BookText.isPageNumber(text), "\(text)")
        }
    }

    @Test func emptyAndImageOnlyPages() {
        #expect(BookText.utterances(pages: []).isEmpty)
        #expect(BookText.utterances(pages: ["", "  \n "]).isEmpty)
    }

    @Test func indicesAreSequential() {
        let u = BookText.utterances(pages: ["One. Two. Three."])
        #expect(u.map(\.index) == [0, 1, 2])
    }
}
