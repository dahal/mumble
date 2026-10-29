import Foundation
import Testing
@testable import MumbleCore

@Suite struct WordErrorRateTests {
    @Test func identicalIsZero() {
        let wer = WordErrorRate.compute(reference: "Hello, World!", hypothesis: "hello world")
        #expect(wer.errors == 0)
        #expect(wer.rate == 0)
    }

    @Test func countsEachOperation() {
        #expect(WordErrorRate.compute(reference: "a b c", hypothesis: "a x c").substitutions == 1)
        #expect(WordErrorRate.compute(reference: "a b c", hypothesis: "a c").deletions == 1)
        #expect(WordErrorRate.compute(reference: "a c", hypothesis: "a b c").insertions == 1)
        let wer = WordErrorRate.compute(reference: "the quick brown fox jumps", hypothesis: "the quack brown jumps over")
        #expect(wer.errors == 3)
        #expect(abs(wer.rate - 0.6) < 1e-9)
    }

    @Test func emptySides() {
        #expect(WordErrorRate.compute(reference: "", hypothesis: "").rate == 0)
        #expect(WordErrorRate.compute(reference: "", hypothesis: "extra").rate == 1)
        #expect(WordErrorRate.compute(reference: "a b", hypothesis: "").deletions == 2)
    }

    @Test func apostrophesAreKept() {
        #expect(WordErrorRate.normalizedWords("Don’t stop, it's 'fine'") == ["don't", "stop", "it's", "fine"])
    }
}

@Suite struct AudioAnalysisTests {
    func sine(seconds: Double, amplitude: Float, frequency: Float = 220) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * sin(2 * .pi * frequency * Float($0) / 16_000) }
    }

    @Test func rmsOfSine() {
        #expect(abs(AudioAnalysis.rms(sine(seconds: 1, amplitude: 1)) - 0.7071) < 0.001)
        #expect(AudioAnalysis.rms([Float]()) == 0)
    }

    @Test func silenceDetection() {
        #expect(AudioAnalysis.isLikelySilence([Float](repeating: 0.0005, count: 16_000)))
        #expect(!AudioAnalysis.isLikelySilence(sine(seconds: 1, amplitude: 0.2)))
        // Long recordings are never skipped, even if quiet.
        #expect(!AudioAnalysis.isLikelySilence([Float](repeating: 0, count: 16_000 * 5)))
    }

    @Test func trimKeepsSpeechWithPadding() {
        let audio = [Float](repeating: 0, count: 16_000) + sine(seconds: 1, amplitude: 0.3)
            + [Float](repeating: 0, count: 32_000)
        let trimmed = AudioAnalysis.trimSilence(audio)
        let seconds = Double(trimmed.count) / 16_000
        #expect(seconds > 1.4 && seconds < 1.6)
    }

    @Test func trimLeavesAllQuietAudioUntouched() {
        let quiet = [Float](repeating: 0, count: 8_000)
        #expect(AudioAnalysis.trimSilence(quiet).count == quiet.count)
    }

    @Test func meterLevelRange() {
        #expect(AudioAnalysis.meterLevel(rms: 0) == 0)
        #expect(AudioAnalysis.meterLevel(rms: 1) == 1)
        #expect(abs(AudioAnalysis.meterLevel(rms: 0.001) - 0) < 0.01)
        #expect(AudioAnalysis.meterLevel(rms: 0.1) > 0.6)
    }
}

@Suite struct SampleBufferTests {
    @Test func appendsSnapshotsAndResets() {
        let buffer = SampleBuffer(reservingSeconds: 1)
        buffer.append([1, 2, 3])
        [Float](arrayLiteral: 4, 5).withUnsafeBufferPointer { buffer.append($0) }
        #expect(buffer.snapshot() == [1, 2, 3, 4, 5])
        #expect(buffer.count == 5)
        buffer.reset()
        #expect(buffer.count == 0)
    }

    @Test func concurrentAppendsAreNotLost() async {
        let buffer = SampleBuffer()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask { for _ in 0..<100 { buffer.append([0, 0, 0, 0]) } }
            }
        }
        #expect(buffer.count == 50 * 100 * 4)
    }
}

@Suite struct SettingsAndHistoryTests {
    @Test func settingsRoundTripAndTolerateMissingKeys() throws {
        var settings = MumbleSettings()
        settings.model = .ultra
        settings.vocabulary = [VocabularyEntry(term: "kubectl", aliases: ["cube control"])]
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(MumbleSettings.self, from: data) == settings)

        let partial = try JSONDecoder().decode(MumbleSettings.self, from: Data(#"{"model":"v2"}"#.utf8))
        #expect(partial.model == .v2)
        #expect(partial.triggerKey == .function)
    }

    @Test func historyPersistsNewestFirstWithLimit() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "mumble-test-\(UUID())/history.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = HistoryStore(fileURL: url)
        #expect(store.load().isEmpty)

        var items: [HistoryItem] = []
        for i in 0..<5 {
            let item = HistoryItem(text: "t\(i)", rawText: "t\(i)", audioSeconds: 1, latencyMs: 50)
            items = HistoryStore.inserting(item, into: items, limit: 3)
        }
        try store.save(items)
        #expect(store.load().map(\.text) == ["t4", "t3", "t2"])
    }
}
