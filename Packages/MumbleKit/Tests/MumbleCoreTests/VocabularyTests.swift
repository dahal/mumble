import Testing
@testable import MumbleCore

@Suite struct VocabularyTests {
    let entries = [
        VocabularyEntry(term: "kubectl", aliases: ["cube control", "cube cuddle"]),
        VocabularyEntry(term: "pgvector"),
        VocabularyEntry(term: "FluidAudio", aliases: ["fluid audio"]),
        VocabularyEntry(term: "Parakeet"),
    ]
    let terms = ["kubectl", "pgvector", "FluidAudio", "Parakeet", "Purushottam", "Supabase"]

    @Test func mapsAliasesAndFixesCasing() {
        #expect(
            Vocabulary.applyCanonicalForms("Run cube control on parakeet with Pgvector.", entries: entries)
                == "Run kubectl on Parakeet with pgvector.")
        #expect(
            Vocabulary.applyCanonicalForms("The Fluid Audio SDK", entries: entries) == "The FluidAudio SDK")
    }

    @Test func compoundTermsMatchTheirSpokenSplit() {
        let entries = [VocabularyEntry(term: "FluidAudio"), VocabularyEntry(term: "GitHub")]
        #expect(
            Vocabulary.applyCanonicalForms("The Fluid Audio SDK is on git hub.", entries: entries)
                == "The FluidAudio SDK is on GitHub.")
        #expect(Vocabulary.applyCanonicalForms("I pushed to Git Hub", entries: entries) == "I pushed to GitHub")
        #expect(Vocabulary.spokenSplit("pgvector") == "pgvector")
    }

    @Test func canonicalFormsRespectWordBoundaries() {
        #expect(Vocabulary.applyCanonicalForms("parakeets are birds", entries: entries) == "parakeets are birds")
    }

    @Test func guardAcceptsCleanSwap() {
        #expect(
            Vocabulary.guardRescore(
                original: "Please ask Pure Shatum to review the config.",
                rescored: "Please ask Purushottam to review the config.", terms: terms)
                == "Please ask Purushottam to review the config.")
    }

    @Test func guardRestoresDroppedFinalPunctuation() {
        #expect(
            Vocabulary.guardRescore(
                original: "Schedule a sync with the Super Bay's team.",
                rescored: "Schedule a sync with the Supabase team", terms: terms)
                == "Schedule a sync with the Supabase team.")
    }

    @Test func guardRejectsDroppedWords() {
        let original = "Send the mumble build to Onirood before Friday."
        #expect(Vocabulary.guardRescore(original: original, rescored: "Mumble to Parakeet", terms: terms) == original)
        let original2 = "Run cubect will get pods in the staging cluster."
        #expect(
            Vocabulary.guardRescore(original: original2, rescored: "Run kubectl will get pods in the pgvector", terms: terms)
                == original2)
    }

    @Test func guardRejectsReorderedOrForeignWords() {
        let original = "The quick brown fox."
        #expect(Vocabulary.guardRescore(original: original, rescored: "The brown quick fox.", terms: terms) == original)
        #expect(Vocabulary.guardRescore(original: original, rescored: "The quick red fox.", terms: terms) == original)
    }

    @Test func guardNeverReplacesRealWords() {
        let dictionary: Set = ["the", "deployment", "failed", "database", "pure"]
        let original = "The deployment failed because the database migration timed out."
        #expect(
            Vocabulary.guardRescore(
                original: original, rescored: "The deployment failed because the Supabase migration timed out.",
                terms: terms, isDictionaryWord: dictionary.contains) == original)
        // A span with a non-word in it is still eligible.
        #expect(
            Vocabulary.guardRescore(
                original: "Ask Pure Shatum.", rescored: "Ask Purushottam.", terms: terms,
                isDictionaryWord: dictionary.contains) == "Ask Purushottam.")
    }

    @Test func guardKeepsOriginalWhenNothingChanged() {
        #expect(Vocabulary.guardRescore(original: "Hello there.", rescored: "Hello there", terms: terms) == "Hello there.")
    }

    @Test func pipelineAppliesVocabularyCanonicalForms() {
        var options = TextPipelineOptions()
        options.vocabulary = entries
        #expect(TextPipeline.process("um run cube control now", options: options) == "Run kubectl now")
    }
}

@Suite struct SimilarityTests {
    @Test func similarityScores() {
        #expect(Vocabulary.similarity("kubectl", "kubectl") == 1)
        #expect(Vocabulary.similarity("pureshatum", "purushottam") >= 0.5)
        #expect(Vocabulary.similarity("cubect", "kubectl") >= 0.5)
        #expect(Vocabulary.similarity("stagingcluster", "pgvector") < 0.5)
        #expect(Vocabulary.similarity("", "") == 1)
    }
}
