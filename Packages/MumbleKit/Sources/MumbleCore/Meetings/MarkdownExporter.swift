import Foundation

/// Everything needed to render one meeting, with speakers resolved to display names.
public struct MeetingDocument: Sendable {
    public var meeting: Meeting
    public var speakers: [MeetingSpeaker]
    public var people: [UUID: Person]
    public var segments: [Segment]
    public var actionItems: [ActionItem]
    public var noteItems: [NoteItem]
    public var marks: [Mark]

    public init(
        meeting: Meeting, speakers: [MeetingSpeaker], people: [UUID: Person], segments: [Segment],
        actionItems: [ActionItem] = [], noteItems: [NoteItem] = [], marks: [Mark] = []
    ) {
        self.meeting = meeting
        self.speakers = speakers
        self.people = people
        self.segments = segments
        self.actionItems = actionItems
        self.noteItems = noteItems
        self.marks = marks
    }

    /// The name shown for a speaker key: the linked person, "Me", or the diarizer label.
    public func name(forSpeaker key: String) -> String {
        if let speaker = speakers.first(where: { $0.speakerKey == key }) {
            if let id = speaker.personID, let person = people[id] { return person.isMe ? "Me" : person.displayName }
            return speaker.isMe ? "Me" : speaker.label
        }
        return key == MeetingSpeaker.meKey ? "Me" : key
    }

    public func ownerName(_ item: ActionItem) -> String? {
        if let id = item.ownerPersonID, let person = people[id] { return person.isMe ? "Me" : person.displayName }
        return item.ownerSpeakerKey.map(name(forSpeaker:))
    }

    /// Keys of voices marked "Not a person".
    public var ignoredKeys: Set<String> { Set(speakers.filter(\.isIgnored).map(\.speakerKey)) }

    /// Transcript without ignored voices, in time order.
    public var visibleSegments: [Segment] {
        let ignored = ignoredKeys
        return segments.filter { !ignored.contains($0.speakerKey) }.sorted { $0.start < $1.start }
    }

    /// Participants in order of first speech.
    public var participantNames: [String] {
        var seen: [String] = []
        for segment in visibleSegments {
            let name = name(forSpeaker: segment.speakerKey)
            if !seen.contains(name) { seen.append(name) }
        }
        return seen
    }
}

public enum MarkdownExporter {
    public static func timestamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    public static func render(_ doc: MeetingDocument, includePrivateNotes: Bool = false, now: Date = Date()) -> String {
        var out = "# \(doc.meeting.title)\n"
        out += header(doc.meeting) + "\n"
        let participants = doc.participantNames
        if !participants.isEmpty { out += "Participants: \(participants.joined(separator: ", "))\n" }

        if let summary = doc.meeting.summary, !summary.isEmpty {
            out += "\n## Summary\n\(summary)\n"
        }
        let decisions = doc.noteItems.filter { $0.kind == .decision }.sorted { $0.position < $1.position }
        if !decisions.isEmpty {
            out += "\n## Decisions\n" + decisions.map { "- \($0.text)\n" }.joined()
        }
        let actions = doc.actionItems.sorted { $0.position < $1.position }
        if !actions.isEmpty {
            out += "\n## Action items\n"
            for item in actions {
                let owner = doc.ownerName(item).map { "\($0): " } ?? ""
                let due = item.due.map { " (\($0))" } ?? ""
                out += "- [\(item.done ? "x" : " ")] \(owner)\(item.text)\(due)\n"
            }
        }
        let questions = doc.noteItems.filter { $0.kind == .question }.sorted { $0.position < $1.position }
        if !questions.isEmpty {
            out += "\n## Open questions\n" + questions.map { "- \($0.text)\n" }.joined()
        }
        let bookmarks = doc.marks.filter { $0.kind == .bookmark }.sorted { $0.time < $1.time }
        let notes = includePrivateNotes ? doc.marks.filter { $0.kind == .privateNote }.sorted { $0.time < $1.time } : []
        if !bookmarks.isEmpty || !notes.isEmpty {
            out += "\n## Bookmarks\n"
            for mark in (bookmarks + notes).sorted(by: { $0.time < $1.time }) {
                let label = mark.kind == .privateNote ? "My note" : "Bookmark"
                out += "- \(timestamp(mark.time)) \(label)\(mark.text.map { ": \($0)" } ?? "")\n"
            }
        }
        let segments = doc.visibleSegments
        if !segments.isEmpty {
            out += "\n## Transcript\n"
            for segment in segments {
                out += "**\(doc.name(forSpeaker: segment.speakerKey))** (\(timestamp(segment.start))): \(segment.text)\n\n"
            }
        }
        return out.trimmingCharacters(in: .newlines) + "\n"
    }

    static func header(_ meeting: Meeting) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "EEE, MMM d yyyy"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"
        var line = "\(day.string(from: meeting.startedAt)) · \(time.string(from: meeting.startedAt))"
        if let end = meeting.endedAt { line += "–\(time.string(from: end))" }
        return line + " · \(meeting.app.displayName)"
    }

    /// "2026-10-30 Pricing page rollout.md", with characters that are unsafe in file names removed.
    public static func fileName(for meeting: Meeting) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        let title = meeting.title.components(separatedBy: unsafe).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let base = "\(f.string(from: meeting.startedAt)) \(title.isEmpty ? "Meeting" : String(title.prefix(80)))"
        return base + ".md"
    }
}
