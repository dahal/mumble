import Testing
@testable import MumbleCore

@Suite struct TextPipelineTests {
    let defaults = TextPipelineOptions()

    @Test func passesCleanTextThrough() {
        #expect(TextPipeline.process("Hello there, how are you?", options: defaults) == "Hello there, how are you?")
    }

    @Test func emptyAndWhitespaceBecomeEmpty() {
        #expect(TextPipeline.process("", options: defaults) == "")
        #expect(TextPipeline.process("   \n ", options: defaults) == "")
    }

    @Test(arguments: [
        ("Um, so I think we should ship it.", "So I think we should ship it."),
        ("I think, uh, we should ship it.", "I think, we should ship it."),
        ("So uhm the plan is fine.", "So the plan is fine."),
        ("Hmm. Let me check.", "Let me check."),
        ("We need, um, about uh three days.", "We need, about three days."),
    ])
    func removesFillers(input: String, expected: String) {
        #expect(TextPipeline.process(input, options: defaults) == expected)
    }

    @Test func keepsWordsThatContainFillerLetters() {
        let text = "The umbrella and the human hummed along."
        #expect(TextPipeline.process(text, options: defaults) == text)
    }

    @Test func fillerRemovalCanBeDisabled() {
        var options = defaults
        options.removeFillers = false
        #expect(TextPipeline.process("Um, hello.", options: options) == "Um, hello.")
    }

    @Test func spokenNewLineAndParagraph() {
        #expect(
            TextPipeline.process("Dear team, new line. Thanks for the update. New paragraph. Cheers", options: defaults)
                == "Dear team\nThanks for the update.\n\nCheers")
    }

    @Test func spokenCommandsCanBeDisabled() {
        var options = defaults
        options.spokenCommands = false
        #expect(TextPipeline.process("Add a new line here.", options: options) == "Add a new line here.")
    }

    @Test func appliesReplacementsCaseInsensitivelyOnWordBoundaries() {
        var options = defaults
        options.replacements = [
            Replacement(spoken: "cube control", written: "kubectl"),
            Replacement(spoken: "smiley", written: "🙂"),
        ]
        #expect(
            TextPipeline.process("Run Cube Control apply, smiley", options: options) == "Run kubectl apply, 🙂")
        // "smileys" is a different word and must not be rewritten.
        #expect(TextPipeline.process("Smileys everywhere", options: options) == "Smileys everywhere")
    }

    @Test func replacementTemplatesAreLiteral() {
        var options = defaults
        options.replacements = [Replacement(spoken: "price", written: "$5 \\1")]
        #expect(TextPipeline.process("The price is fine", options: options) == "The $5 \\1 is fine")
    }

    @Test func normalizerRunsFirst() {
        let result = TextPipeline.process("um twenty five dollars", options: defaults) {
            $0.replacingOccurrences(of: "twenty five dollars", with: "$25")
        }
        #expect(result == "$25")
    }

    @Test func tidyCollapsesSpacingAndPunctuation() {
        #expect(TextPipeline.tidy("Hello  ,  world  .") == "Hello, world.")
        #expect(TextPipeline.tidy(", leading comma") == "leading comma")
        #expect(TextPipeline.tidy("a ,, b") == "a, b")
    }

    @Test func recapitalizesSentenceStarts() {
        #expect(TextPipeline.recapitalizeSentences("one. two? three!\nfour") == "One. Two? Three!\nFour")
        #expect(TextPipeline.recapitalizeSentences("version 2.5 is out") == "Version 2.5 is out")
    }
}
