import Foundation
import MumbleCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence availability, without leaking `FoundationModels` (macOS 26) to callers.
public enum AppleIntelligence {
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Why it isn't available, for Settings.
    public static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings."
            case .unavailable(.deviceNotEligible): return "This Mac doesn't support Apple Intelligence."
            case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading."
            case .unavailable: return "Apple Intelligence is unavailable."
            }
        }
        #endif
        return "Needs macOS 26 with Apple Intelligence."
    }

    static func makeSummarizer() -> (any Summarizer)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return AppleSummarizer() }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
/// On-device summaries with Apple's model (spec §9.2). The model's context is ~4k tokens, so the
/// transcript is summarized in chunks (map), then the partial notes are merged (reduce).
@available(macOS 26.0, *)
struct AppleSummarizer: Summarizer {
    let providerID = "apple"

    @Generable
    struct GeneratedItem {
        @Guide(description: "The item, one short sentence")
        var text: String
        @Guide(description: "Line number the item comes from")
        var line: Int
    }

    @Generable
    struct GeneratedAction {
        @Guide(description: "What will be done, starting with a verb")
        var text: String
        @Guide(description: "Speaker key of the person who will do it, or empty if nobody took it")
        var owner: String
        @Guide(description: "Deadline exactly as said, or empty")
        var due: String
        @Guide(description: "Line number the item comes from")
        var line: Int
    }

    @Generable
    struct GeneratedNotes {
        @Guide(description: "Two or three sentences on what was discussed and concluded")
        var summary: String
        @Guide(description: "Things the group agreed or decided")
        var decisions: [GeneratedItem]
        @Guide(description: "Commitments or accepted requests")
        var actionItems: [GeneratedAction]
        @Guide(description: "Questions raised and left unresolved")
        var openQuestions: [GeneratedItem]
    }

    static let instructions = """
        You write meeting notes from a speaker-labeled transcript excerpt. Use only what the excerpt says. \
        Never invent owners, dates or facts. Cite each item's line number.
        """

    func summarize(_ input: SummaryInput) async throws -> MeetingNotes {
        guard AppleIntelligence.isAvailable else {
            throw SummaryError.unavailable(AppleIntelligence.unavailableReason ?? "unavailable")
        }
        let speakers = input.speakers.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: ", ")
        var partials: [GeneratedNotes] = []
        for range in SummaryChunker.chunks(input, maxTokens: 2_200) {
            let session = LanguageModelSession(instructions: Self.instructions)
            let prompt = "Meeting: \(input.title)\nSpeakers (key = name): \(speakers)\n\n\(input.numberedTranscript(range: range))"
            let response = try await session.respond(to: prompt, generating: GeneratedNotes.self)
            partials.append(response.content)
        }
        var summary = partials.first?.summary ?? ""
        if partials.count > 1 {
            let session = LanguageModelSession(instructions: "Merge partial meeting summaries into one summary of 2-4 sentences.")
            let joined = partials.enumerated().map { "Part \($0.offset + 1): \($0.element.summary)" }.joined(separator: "\n")
            summary = try await session.respond(to: joined).content
        }
        func nonEmpty(_ s: String) -> String? { s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s }
        let notes = MeetingNotes(
            summary: summary,
            decisions: partials.flatMap(\.decisions).map { .init(text: $0.text, sourceSegmentIndex: $0.line) },
            actionItems: partials.flatMap(\.actionItems).map {
                .init(text: $0.text, ownerSpeakerKey: nonEmpty($0.owner), due: nonEmpty($0.due), sourceSegmentIndex: $0.line)
            },
            openQuestions: partials.flatMap(\.openQuestions).map { .init(text: $0.text, sourceSegmentIndex: $0.line) })
        return NotesValidator.validate(notes, input: input)
    }
}
#endif
