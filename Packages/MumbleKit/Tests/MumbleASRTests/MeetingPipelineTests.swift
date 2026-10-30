import Foundation
import Testing
@testable import MumbleASR
import MumbleCore

/// Real-model tests of the meeting pipeline (diarization + transcription + echo gate). Like the
/// other integration tests they download models on first run, so they need MUMBLE_INTEGRATION=1.
///
/// Three synthetic voices stand in for a meeting: two remote participants (Samantha, Daniel) in
/// the meeting app's audio and you (Karen) on the microphone.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MUMBLE_INTEGRATION"] == "1"), .serialized)
struct MeetingPipelineTests {
    static let engine = TranscriptionEngine()
    static let diarizer = MeetingDiarizer()

    struct Line {
        let voice: String
        let text: String
        var isMe: Bool { voice == "Karen" }
    }

    static let script = [
        Line(voice: "Samantha", text: "So the new annual plan is live on staging. Do we show the monthly price crossed out, or just the savings badge?"),
        Line(voice: "Daniel", text: "Crossed out tested better last time. Conversion was up about eight percent on the checkout experiment."),
        Line(voice: "Karen", text: "Okay, let's go with crossed out. Sarah, can you ship it behind the flag by Friday?"),
        Line(voice: "Samantha", text: "Yes, I will do that. I also want to update the pricing copy on the landing page."),
        Line(voice: "Daniel", text: "I will send the experiment numbers to everyone this afternoon."),
        Line(voice: "Karen", text: "Great. I will ask legal about grandfathering the old plan."),
        Line(voice: "Samantha", text: "Sounds good. Let's check in again next Tuesday."),
    ]

    static func speech(_ text: String, voice: String) throws -> [Float] {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mumble-meeting-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appending(path: "s.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "-o", wav.path, "--file-format=WAVE", "--data-format=LEF32@16000", text]
        try say.run()
        say.waitUntilExit()
        let data = try Data(contentsOf: wav)
        guard let range = data.range(of: Data("data".utf8)) else { return [] }
        return data[(range.upperBound + 4)...].withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Builds aligned local and remote tracks. Remote lines play in the meeting audio; your lines go
    /// to the mic. With `echo`, the mic also hears the remote audio, delayed and quieter (laptop speakers).
    static func meeting(echo: Bool) throws -> (local: [Float], remote: [Float], times: [(Line, Double, Double)]) {
        var local: [Float] = [], remote: [Float] = []
        var times: [(Line, Double, Double)] = []
        let gap = [Float](repeating: 0, count: 12_000)   // 0.75 s between turns
        for line in script {
            let samples = try speech(line.text, voice: line.voice)
            let start = Double(local.count) / 16_000
            if line.isMe {
                local += samples
                remote += [Float](repeating: 0, count: samples.count)
            } else {
                remote += samples
                local += [Float](repeating: 0, count: samples.count)
            }
            times.append((line, start, Double(local.count) / 16_000))
            local += gap
            remote += gap
        }
        var rng = SystemRandomNumberGenerator()
        if echo {
            let delay = 640  // 40 ms acoustic path
            for i in delay..<local.count { local[i] += remote[i - delay] * 0.25 }
        }
        for i in local.indices { local[i] += Float.random(in: -0.0015...0.0015, using: &rng) }
        return (local, remote, times)
    }

    @Test func labelsWhoSaidWhatAndTranscribes() async throws {
        try await Self.engine.load(.phonon2)
        let (local, remote, times) = try Self.meeting(echo: false)
        let output = try await MeetingPipeline.run(local: local, remote: remote, engine: Self.engine,
                                                   diarizer: Self.diarizer, boostVocabulary: false)
        #expect(!output.diarizationFailed)
        let remoteKeys = Set(output.spans.map(\.speakerKey))
        #expect(remoteKeys.count == 2, "found speakers \(remoteKeys)")

        // Each script line's midpoint must be attributed to a consistent speaker per voice.
        var keyByVoice: [String: Set<String>] = [:]
        for (line, start, end) in times {
            let mid = (start + end) / 2
            let segment = output.texts.first { $0.start - 0.5 <= mid && mid <= $0.end + 0.5 }
            keyByVoice[line.voice, default: []].insert(segment?.speakerKey ?? "none")
        }
        #expect(keyByVoice["Karen"] == ["me"])
        #expect(keyByVoice["Samantha"]?.count == 1 && keyByVoice["Daniel"]?.count == 1)
        #expect(keyByVoice["Samantha"] != keyByVoice["Daniel"])

        let reference = Self.script.map(\.text).joined(separator: " ")
        let hypothesis = output.texts.map(\.text).joined(separator: " ")
        let wer = WordErrorRate.compute(reference: reference, hypothesis: hypothesis)
        #expect(wer.rate < 0.15, "WER \(wer.rate): \(hypothesis)")
        #expect(output.embeddings.count == 2)
    }

    @Test func echoFromSpeakersIsNotTranscribedAsYou() async throws {
        try await Self.engine.load(.phonon2)
        let (local, remote, _) = try Self.meeting(echo: true)
        let output = try await MeetingPipeline.run(local: local, remote: remote, engine: Self.engine,
                                                   diarizer: Self.diarizer, boostVocabulary: false)
        #expect(output.echoSecondsRemoved > 10, "removed \(output.echoSecondsRemoved) s")
        let mine = output.texts.filter { $0.speakerKey == MeetingSpeaker.meKey }.map(\.text).joined(separator: " ").lowercased()
        let myReference = Self.script.filter(\.isMe).map(\.text).joined(separator: " ")
        let myWER = WordErrorRate.compute(reference: myReference, hypothesis: mine).rate
        #expect(myWER < 0.2, "your lines (WER \(myWER)): \(mine)")
        #expect(!mine.contains("eight percent"), "remote speech leaked into your lines: \(mine)")
        #expect(!mine.contains("staging"), "remote speech leaked into your lines: \(mine)")
    }

    @Test func savedVoicesMatchAcrossMeetings() async throws {
        // Meeting 1: learn the two remote voices. Meeting 2: different sentences, same voices.
        let first = try Self.meeting(echo: false)
        let a = try await Self.diarizer.diarize(first.remote)
        var second: [Float] = []
        for (voice, text) in [("Daniel", "Morning everyone, quick update on the billing migration before we start."),
                              ("Samantha", "Thanks. The design review moved to Thursday afternoon, so please plan around it."),
                              ("Daniel", "Got it. I will also share the dashboard numbers after lunch today."),
                              ("Samantha", "Perfect, and let's keep the meeting short today because of the launch.")] {
            second += try Self.speech(text, voice: voice) + [Float](repeating: 0, count: 12_000)
        }
        let b = try await Self.diarizer.diarize(second)
        #expect(a.embeddings.count == 2 && b.embeddings.count == 2)

        // Meeting 1 speaks Samantha first (S1), meeting 2 speaks Daniel first (S1).
        let samantha1 = try #require(a.embeddings["S1"]), daniel1 = try #require(a.embeddings["S2"])
        let daniel2 = try #require(b.embeddings["S1"]), samantha2 = try #require(b.embeddings["S2"])
        let same = [VoiceMatching.cosineDistance(samantha1, samantha2), VoiceMatching.cosineDistance(daniel1, daniel2)]
        let different = [VoiceMatching.cosineDistance(samantha1, daniel2), VoiceMatching.cosineDistance(daniel1, samantha2)]
        print("voice distances same: \(same) different: \(different)")
        let threshold = NameVoting.Config().voiceThreshold
        #expect(same.allSatisfy { $0 < threshold }, "same-voice distances \(same)")
        #expect(different.allSatisfy { $0 > threshold }, "different-voice distances \(different)")
    }
}
