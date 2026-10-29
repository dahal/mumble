import Testing
@testable import MumbleCore

@Suite struct InsertionFormatterTests {
    @Test func unknownContextLeavesTextAlone() {
        #expect(InsertionFormatter.format("Hello there.", preceding: nil) == "Hello there.")
        #expect(InsertionFormatter.format("Hello there.", preceding: "") == "Hello there.")
    }

    @Test func afterWhitespaceOrNewlineNoSpaceAdded() {
        #expect(InsertionFormatter.format("Hello.", preceding: "Done. ") == "Hello.")
        #expect(InsertionFormatter.format("Hello.", preceding: "Done.\n") == "Hello.")
    }

    @Test func afterSentenceEndAddsSpaceKeepsCapital() {
        #expect(InsertionFormatter.format("Next one.", preceding: "First one.") == " Next one.")
    }

    @Test func midSentenceLowercasesCommonWord() {
        #expect(InsertionFormatter.format("And then we left.", preceding: "We ate,") == " and then we left.")
        #expect(InsertionFormatter.format("Then we left.", preceding: "We ate") == " then we left.")
    }

    @Test(arguments: ["I think so.", "I'm here.", "NASA launched.", "iPhone sales.", "McDonald waved."])
    func midSentenceKeepsSpecialWords(text: String) {
        #expect(InsertionFormatter.format(text, preceding: "and") == " " + text)
    }

    @Test func midSentenceKeepsPersonalNames() {
        #expect(
            InsertionFormatter.format("Sarah Connor said hello.", preceding: "and")
                == " Sarah Connor said hello.")
    }

    @Test func afterOpeningBracketOrQuoteNoSpace() {
        #expect(InsertionFormatter.format("note", preceding: "(") == "note")
        #expect(InsertionFormatter.format("Quote", preceding: "\"") == "Quote")
    }

    @Test func punctuationStartNeedsNoSpace() {
        #expect(InsertionFormatter.format(", right?", preceding: "fine") == ", right?")
    }
}
