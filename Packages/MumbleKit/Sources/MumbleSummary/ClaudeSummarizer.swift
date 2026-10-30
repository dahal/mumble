import Foundation
import MumbleCore

/// Opt-in summaries with Claude (spec §9.2). Sends transcript text with speaker names, never audio.
/// Raw HTTP to the Messages API (there is no official Swift SDK), with structured JSON output.
public struct ClaudeSummarizer: Summarizer {
    public let providerID = "claude"
    let apiKey: String
    let model: String
    let session: URLSession

    public static let defaultModel = "claude-opus-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init(apiKey: String, model: String = Self.defaultModel, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    public func summarize(_ input: SummaryInput) async throws -> MeetingNotes {
        let request = try makeRequest(input)
        var attempt = 0
        while true {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Retry rate limits, overload and server errors with backoff; never retry 4xx input errors.
            if (status == 429 || status == 529 || status >= 500), attempt < 2 {
                attempt += 1
                let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                try await Task.sleep(for: .seconds(retryAfter ?? Double(attempt * 2)))
                continue
            }
            return try Self.parse(data, status: status, input: input)
        }
    }

    func makeRequest(_ input: SummaryInput) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // Server-side fallback on a policy decline, routed by category.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(input, model: model))
        return request
    }

    static func body(_ input: SummaryInput, model: String) -> [String: Any] {
        let speakers = input.speakers.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: "\n")
        let user = """
            Meeting: \(input.title)

            Speakers (key = name):
            \(speakers)

            Transcript (each line starts with its line number):
            \(input.numberedTranscript())
            """
        return [
            "model": model,
            "max_tokens": 16000,
            "system": systemPrompt,
            "messages": [["role": "user", "content": user]],
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": schema]],
            "fallbacks": "default",
        ]
    }

    static let systemPrompt = """
        You write meeting notes from a speaker-labeled transcript. Return only what the transcript supports.
        summary: 2-4 plain sentences on what the meeting covered and concluded.
        decisions: things the group agreed or decided.
        action_items: concrete commitments or requests someone accepted. owner is the speaker key of the person \
        who will do it, or null if nobody took it. due is the deadline exactly as said (e.g. "by Friday"), or null.
        open_questions: questions raised and left unresolved.
        Every item cites the line number it comes from in `line`. Never invent owners, dates or facts. \
        Write in the language of the meeting.
        """

    static var schema: [String: Any] {
        let item: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["text", "line"],
            "properties": ["text": ["type": "string"], "line": ["type": "integer"]],
        ]
        let nullableString: [String: Any] = ["anyOf": [["type": "string"], ["type": "null"]]]
        let action: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["text", "owner", "due", "line"],
            "properties": ["text": ["type": "string"], "owner": nullableString, "due": nullableString,
                           "line": ["type": "integer"]],
        ]
        return [
            "type": "object", "additionalProperties": false,
            "required": ["summary", "decisions", "action_items", "open_questions"],
            "properties": [
                "summary": ["type": "string"],
                "decisions": ["type": "array", "items": item],
                "action_items": ["type": "array", "items": action],
                "open_questions": ["type": "array", "items": item],
            ],
        ]
    }

    struct Response: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        struct StopDetails: Decodable {
            let category: String?
            let explanation: String?
        }
        let content: [Block]
        let stop_reason: String?
        let stop_details: StopDetails?
    }

    struct APIErrorBody: Decodable {
        struct Inner: Decodable { let type: String; let message: String }
        let error: Inner
    }

    struct Notes: Decodable {
        struct Item: Decodable { let text: String; let line: Int? }
        struct Action: Decodable { let text: String; let owner: String?; let due: String?; let line: Int? }
        let summary: String
        let decisions: [Item]
        let action_items: [Action]
        let open_questions: [Item]
    }

    static func parse(_ data: Data, status: Int, input: SummaryInput) throws -> MeetingNotes {
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.error.message
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw SummaryError.http(status, message)
        }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw SummaryError.badResponse("unexpected response format")
        }
        if response.stop_reason == "refusal" {
            throw SummaryError.refused(response.stop_details?.category ?? "")
        }
        if response.stop_reason == "max_tokens" {
            throw SummaryError.badResponse("the notes were cut off")
        }
        guard let text = response.content.first(where: { $0.type == "text" })?.text,
              let json = text.data(using: .utf8),
              let notes = try? JSONDecoder().decode(Notes.self, from: json)
        else { throw SummaryError.badResponse("no notes in the response") }
        let result = MeetingNotes(
            summary: notes.summary,
            decisions: notes.decisions.map { .init(text: $0.text, sourceSegmentIndex: $0.line) },
            actionItems: notes.action_items.map { .init(text: $0.text, ownerSpeakerKey: $0.owner, due: $0.due, sourceSegmentIndex: $0.line) },
            openQuestions: notes.open_questions.map { .init(text: $0.text, sourceSegmentIndex: $0.line) })
        return NotesValidator.validate(result, input: input)
    }
}
