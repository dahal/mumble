import Foundation
import Testing

@testable import MumbleTTS

/// Downloads Kokoro (~once) and synthesizes for real, so it only runs when asked:
///   MUMBLE_TTS_TEST=1 swift test --filter MumbleTTSTests
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MUMBLE_TTS_TEST"] == "1"))
struct NarratorTests {
    @Test func synthesizesASentenceFasterThanRealTime() async throws {
        let narrator = Narrator()
        try await narrator.load()
        let text = "It was a bright cold day in April, and the clocks were striking thirteen."
        let start = Date()
        let samples = try await narrator.speak(text)
        let elapsed = Date().timeIntervalSince(start)
        let seconds = Double(samples.count) / Narrator.sampleRate
        print("NARRATOR \(String(format: "%.2f", seconds)) s of audio in \(String(format: "%.3f", elapsed)) s")
        #expect(seconds > 2 && seconds < 10)
        #expect(elapsed < seconds)
        #expect(samples.contains { abs($0) > 0.05 })
    }

    @Test func everyListedVoiceSpeaks() async throws {
        let narrator = Narrator()
        for voice in Narrator.voices {
            let samples = try await narrator.speak("Hello there.", voice: voice.id)
            #expect(samples.count > Int(Narrator.sampleRate * 0.3), "\(voice.id)")
        }
    }

    @Test func speedChangesLength() async throws {
        let narrator = Narrator()
        let normal = try await narrator.speak("The quick brown fox jumps over the lazy dog.")
        let fast = try await narrator.speak("The quick brown fox jumps over the lazy dog.", speed: 1.5)
        #expect(Double(fast.count) < Double(normal.count) * 0.85)
    }
}
