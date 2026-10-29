import Foundation
import Testing
@testable import MumbleASR
import MumbleCore

/// End-to-end tests against the real model. They need the model on disk (downloaded on first
/// run, ~330 MB), so they only run when MUMBLE_INTEGRATION=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MUMBLE_INTEGRATION"] == "1"), .serialized)
struct TranscriptionEngineTests {
    static let engine = TranscriptionEngine()

    /// Renders `text` with macOS's built-in speech synthesizer to 16 kHz mono samples.
    static func speech(_ text: String) throws -> [Float] {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mumble-asr-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appending(path: "speech.wav")

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", wav.path, "--file-format=WAVE", "--data-format=LEF32@16000", text]
        try say.run()
        say.waitUntilExit()

        let data = try Data(contentsOf: wav)
        // Skip the RIFF header: find the "data" chunk and read Float32 samples after its size field.
        guard let range = data.range(of: Data("data".utf8)) else { return [] }
        let payload = data[(range.upperBound + 4)...]
        return payload.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    @Test func transcribesSynthesizedSpeechAccurately() async throws {
        try await Self.engine.load(.phonon2)
        let reference = "The quick brown fox jumps over the lazy dog near the river bank."
        let transcript = try await Self.engine.transcribe(try Self.speech(reference), boostVocabulary: false)
        let wer = WordErrorRate.compute(reference: reference, hypothesis: transcript.text)
        #expect(wer.rate <= 0.1, "got: \(transcript.text)")
        #expect(transcript.processingMs < 1_000)
    }

    @Test func shortClipsAreFastAndDoNotThrow() async throws {
        try await Self.engine.load(.phonon2)
        let transcript = try await Self.engine.transcribe(try Self.speech("Yes."), boostVocabulary: false)
        #expect(transcript.text.lowercased().contains("yes"))
        let tiny = try await Self.engine.transcribe([Float](repeating: 0, count: 800), boostVocabulary: false)
        #expect(tiny.processingMs < 1_000)
    }

    @Test func vocabularyBoostingFixesNamesWithoutTouchingOtherWords() async throws {
        try await Self.engine.load(.phonon2)
        let clip = try Self.speech("Please ask Purushottam to review the Kubernetes config.")
        let plain = try await Self.engine.transcribe(clip, boostVocabulary: false)
        #expect(!plain.text.contains("Purushottam"), "baseline unexpectedly got the name: \(plain.text)")

        try await Self.engine.setVocabulary([VocabularyEntry(term: "Purushottam"), VocabularyEntry(term: "pgvector")])
        let boosted = try await Self.engine.transcribe(clip, boostVocabulary: true)
        #expect(boosted.text.contains("Purushottam"), "got: \(boosted.text)")
        #expect(boosted.text.contains("review the Kubernetes config"))

        let unrelated = try await Self.engine.transcribe(
            try Self.speech("The deployment failed because the database migration timed out."), boostVocabulary: true)
        #expect(unrelated.text == "The deployment failed because the database migration timed out.")
        try await Self.engine.setVocabulary([])
    }

    @Test func longDictationHasNoSeamArtifacts() async throws {
        try await Self.engine.load(.phonon2)
        let reference = "Here is the plan for next week. On Monday we finish the onboarding flow and fix the login bug. "
            + "On Tuesday the design team reviews the new settings screen with the product managers. "
            + "On Wednesday we run the load tests and write up the results for the leadership meeting. "
            + "On Thursday we ship the release candidate to the beta testers and collect their feedback. "
            + "On Friday we decide whether it is ready to launch."
        let audio = try Self.speech(reference)
        #expect(audio.count > 16_000 * 16, "needs to exceed the model window")
        let transcript = try await Self.engine.transcribe(audio, boostVocabulary: false)
        let wer = WordErrorRate.compute(reference: reference, hypothesis: transcript.text)
        #expect(wer.rate <= 0.03, "WER \(wer.rate): \(transcript.text)")
        #expect(wer.insertions == 0, "inserted words (seam duplication?): \(transcript.text)")
        #expect(transcript.text.hasSuffix("."))
    }

    @Test func normalizesNumbers() {
        #expect(TranscriptionEngine.normalize("it costs twenty five dollars").contains("$25"))
    }
}
