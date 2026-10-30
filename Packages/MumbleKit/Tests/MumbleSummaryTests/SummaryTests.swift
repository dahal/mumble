import Foundation
import MumbleCore
import Testing
@testable import MumbleSummary

let speakers = ["me": "Me", "S1": "Sarah Chen", "S2": "Dev Patel", "S3": "Speaker 4"]

func input(_ lines: [(String, String)]) -> SummaryInput {
    SummaryInput(
        title: "Pricing page rollout",
        lines: lines.enumerated().map { i, l in
            .init(speakerKey: l.0, speakerName: speakers[l.0] ?? l.0, start: Double(i * 10), text: l.1)
        },
        speakers: speakers)
}

let pricingMeeting = input([
    ("S1", "So the new annual plan is live on staging. Do we show the monthly price crossed out, or just the savings badge?"),
    ("S2", "Crossed out tested better last time. Conversion was up about eight percent on the checkout experiment."),
    ("me", "Okay, let's go with crossed out. Sarah, can you ship it behind the flag by Friday?"),
    ("S1", "Yes, I'll do that."),
    ("me", "Dev, can you send me the experiment numbers so I can share them?"),
    ("S2", "Sure."),
    ("S3", "One thing from support: people on the old plan keep asking if they'll be migrated."),
    ("me", "I'll ask legal about grandfathering the old plan before Friday."),
    ("S1", "What do we tell customers who already paid for the monthly plan this year?"),
])

@Suite struct RuleBasedSummarizerTests {
    @Test func findsDecisionsActionsAndOwners() {
        let notes = RuleBasedSummarizer.extract(pricingMeeting)
        #expect(notes.decisions.map(\.text) == ["Go with crossed out"])
        let actions = notes.actionItems
        let ship = actions.first { $0.text.hasPrefix("Ship it behind the flag") }
        #expect(ship?.ownerSpeakerKey == "S1")
        #expect(ship?.due == "by Friday")
        #expect(ship?.sourceSegmentIndex == 2)
        let numbers = actions.first { $0.text.hasPrefix("Send me the experiment numbers") }
        #expect(numbers?.ownerSpeakerKey == "S2")
        let legal = actions.first { $0.text.hasPrefix("Ask legal about grandfathering") }
        #expect(legal?.ownerSpeakerKey == "me")
        #expect(legal?.due == "before Friday")
        // "I'll do that." is an acceptance, not a task of its own.
        #expect(!actions.contains { $0.text.lowercased().hasPrefix("do that") })
    }

    @Test func openQuestionsSkipAnsweredOnesAndRequests() {
        let notes = RuleBasedSummarizer.extract(pricingMeeting)
        let questions = notes.openQuestions.map(\.text)
        #expect(questions.contains("What do we tell customers who already paid for the monthly plan this year?"))
        // Answered by a decision right after: not open.
        #expect(!questions.contains { $0.hasPrefix("So the new annual plan") || $0.hasPrefix("Do we show") })
        #expect(!questions.contains { $0.contains("can you") })
    }

    @Test func summaryIsExtractiveAndMentionsTheDecision() {
        let notes = RuleBasedSummarizer.extract(pricingMeeting)
        #expect(!notes.summary.isEmpty)
        #expect(notes.summary.contains("Decided: go with crossed out.") || notes.summary.lowercased().contains("crossed out"))
        #expect(notes.summary.contains("action items"))
    }

    @Test func emptyMeetingHasEmptyNotes() {
        let notes = RuleBasedSummarizer.extract(input([]))
        #expect(notes == MeetingNotes(summary: ""))
    }

    @Test func unnamedRequestsGoToWhoeverAgrees() {
        let notes = RuleBasedSummarizer.extract(input([
            ("me", "Can you write up the launch checklist for the team?"),
            ("S2", "Yeah, will do."),
        ]))
        #expect(notes.actionItems.first?.ownerSpeakerKey == "S2")
        #expect(notes.actionItems.first?.text == "Write up the launch checklist for the team")
    }
}

@Suite struct NotesValidatorTests {
    @Test func dropsInventedOwnersDatesAndLines() {
        let raw = MeetingNotes(
            summary: "  Summary.  ",
            decisions: [.init(text: "- Ship it", sourceSegmentIndex: 99), .init(text: "ship it", sourceSegmentIndex: 2)],
            actionItems: [
                .init(text: "Ship it", ownerSpeakerKey: "Sarah Chen", due: "by Friday", sourceSegmentIndex: 2),
                .init(text: "Send numbers", ownerSpeakerKey: "Maya", due: "by Monday", sourceSegmentIndex: 4),
                .init(text: "  ", ownerSpeakerKey: nil),
            ])
        let notes = NotesValidator.validate(raw, input: pricingMeeting)
        #expect(notes.summary == "Summary.")
        #expect(notes.decisions.count == 1)
        #expect(notes.decisions[0].sourceSegmentIndex == nil)
        #expect(notes.actionItems.count == 2)
        #expect(notes.actionItems[0].ownerSpeakerKey == "S1")   // display name mapped to key
        #expect(notes.actionItems[0].due == "by Friday")
        #expect(notes.actionItems[1].ownerSpeakerKey == nil)     // not a speaker
        #expect(notes.actionItems[1].due == nil)                 // not in the source line
    }
}

@Suite struct SummaryChunkerTests {
    @Test func chunksAtTurnsWithinBudget() {
        let long = input((0..<40).map { _ in ("S1", String(repeating: "word ", count: 50)) })
        let chunks = SummaryChunker.chunks(long, maxTokens: 300)
        #expect(chunks.count > 1)
        #expect(chunks.first?.lowerBound == 0 && chunks.last?.upperBound == 40)
        for (a, b) in zip(chunks, chunks.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
    }
}

/// Serves canned responses for the Claude summarizer tests.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [(Int, Data)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            Self.bodies.append(data)
        }
        let (status, body) = Self.responses.isEmpty ? (500, Data()) : Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["retry-after": "0"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
}

@Suite(.serialized) struct ClaudeSummarizerTests {
    static func message(_ notes: [String: Any], stop: String = "end_turn") -> Data {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: notes), as: UTF8.self)
        return try! JSONSerialization.data(withJSONObject: [
            "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": text]],
            "stop_reason": stop,
        ])
    }

    static var goodNotes: [String: Any] { [
        "summary": "Agreed on crossed-out pricing.",
        "decisions": [["text": "Show the crossed-out monthly price", "line": 2]],
        "action_items": [["text": "Ship behind the flag", "owner": "S1", "due": "by Friday", "line": 2],
                         ["text": "Ask legal", "owner": NSNull(), "due": NSNull(), "line": 7]],
        "open_questions": [["text": "What do we tell monthly customers?", "line": 8]],
    ] }

    @Test func sendsCorrectRequestAndParsesNotes() async throws {
        StubProtocol.requests = []
        StubProtocol.bodies = []
        StubProtocol.responses = [(200, Self.message(Self.goodNotes))]
        let summarizer = ClaudeSummarizer(apiKey: "sk-test", session: StubProtocol.session())
        let notes = try await summarizer.summarize(pricingMeeting)
        #expect(notes.summary == "Agreed on crossed-out pricing.")
        #expect(notes.actionItems.first?.ownerSpeakerKey == "S1")
        #expect(notes.actionItems.first?.due == "by Friday")
        #expect(notes.actionItems.last?.ownerSpeakerKey == nil)
        #expect(notes.openQuestions.count == 1)

        let request = try #require(StubProtocol.requests.first)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        let body = try #require(StubProtocol.bodies.first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "claude-opus-5-5")
        let format = (json["output_config"] as? [String: Any])?["format"] as? [String: Any]
        #expect(format?["type"] as? String == "json_schema")
        let content = ((json["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        #expect(content.contains("[2] Me (0:20): Okay, let's go with crossed out."))
        #expect(content.contains("S1 = Sarah Chen"))
    }

    @Test func retriesOverloadThenSucceeds() async throws {
        StubProtocol.responses = [(529, Data("{}".utf8)), (200, Self.message(Self.goodNotes))]
        let notes = try await ClaudeSummarizer(apiKey: "k", session: StubProtocol.session()).summarize(pricingMeeting)
        #expect(notes.decisions.count == 1)
    }

    @Test func reportsAPIErrorsRefusalsAndTruncation() async {
        let error = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        StubProtocol.responses = [(401, Data(error.utf8))]
        await #expect(throws: SummaryError.http(401, "invalid x-api-key")) {
            try await ClaudeSummarizer(apiKey: "bad", session: StubProtocol.session()).summarize(pricingMeeting)
        }
        StubProtocol.responses = [(200, try! JSONSerialization.data(withJSONObject: [
            "content": [], "stop_reason": "refusal", "stop_details": ["category": "cyber"]]))]
        await #expect(throws: SummaryError.refused("cyber")) {
            try await ClaudeSummarizer(apiKey: "k", session: StubProtocol.session()).summarize(pricingMeeting)
        }
        StubProtocol.responses = [(200, Self.message(Self.goodNotes, stop: "max_tokens"))]
        await #expect(throws: SummaryError.badResponse("the notes were cut off")) {
            try await ClaudeSummarizer(apiKey: "k", session: StubProtocol.session()).summarize(pricingMeeting)
        }
    }

    @Test func factoryFallsBackToBuiltIn() {
        #expect(SummarizerFactory.make(.off, claudeAPIKey: nil) == nil)
        #expect(SummarizerFactory.make(.claude, claudeAPIKey: nil)?.providerID == "builtin")
        #expect(SummarizerFactory.make(.claude, claudeAPIKey: "k")?.providerID == "claude")
        let automatic = SummarizerFactory.make(.automatic, claudeAPIKey: nil)?.providerID
        #expect(automatic == (AppleIntelligence.isAvailable ? "apple" : "builtin"))
    }
}
