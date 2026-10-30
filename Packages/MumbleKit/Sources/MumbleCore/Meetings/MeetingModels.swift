import Foundation

// Record types for meeting notes. They are plain values: MumbleStore persists them with GRDB,
// MumbleCore stays free of any database dependency.

/// Where a meeting happened. Stored as its raw value ("meet", "zoom", … or "other:<bundle id>").
public struct MeetingApp: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let meet = MeetingApp(rawValue: "meet")
    public static let zoom = MeetingApp(rawValue: "zoom")
    public static let teams = MeetingApp(rawValue: "teams")
    public static let slack = MeetingApp(rawValue: "slack")
    public static let webex = MeetingApp(rawValue: "webex")
    public static let facetime = MeetingApp(rawValue: "facetime")
    public static func other(_ bundleID: String) -> MeetingApp { MeetingApp(rawValue: "other:\(bundleID)") }

    public var displayName: String {
        switch rawValue {
        case "meet": "Google Meet"
        case "zoom": "Zoom"
        case "teams": "Microsoft Teams"
        case "slack": "Slack huddle"
        case "webex": "Webex"
        case "facetime": "FaceTime"
        default: "Call"
        }
    }
}

public enum ProcessingStage: String, Codable, Sendable, CaseIterable {
    case recording, transcribing, diarizing, identifying, summarizing, done, failed

    public var isFinal: Bool { self == .done || self == .failed }

    public var label: String {
        switch self {
        case .recording: "Recording…"
        case .transcribing: "Transcribing…"
        case .diarizing: "Finding speakers…"
        case .identifying: "Naming speakers…"
        case .summarizing: "Summarizing…"
        case .done: "Done"
        case .failed: "Failed"
        }
    }

    /// Rough share of processing completed when this stage starts, for progress bars.
    public var progress: Double {
        switch self {
        case .recording: 0
        case .transcribing: 0.1
        case .diarizing: 0.45
        case .identifying: 0.7
        case .summarizing: 0.8
        case .done, .failed: 1
        }
    }
}

public struct Meeting: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var app: MeetingApp
    public var meetingURL: String?
    public var calendarEventID: String?
    public var calendarSeriesID: String?
    public var stage: ProcessingStage
    public var failure: String?
    public var summary: String?
    public var summaryProvider: String?
    public var language: String?
    public var audioRetained: Bool
    public var audioExpiresAt: Date?
    public var markdownPath: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), title: String, startedAt: Date, endedAt: Date? = nil, app: MeetingApp,
        meetingURL: String? = nil, calendarEventID: String? = nil, calendarSeriesID: String? = nil,
        stage: ProcessingStage = .recording, failure: String? = nil, summary: String? = nil,
        summaryProvider: String? = nil, language: String? = nil, audioRetained: Bool = false,
        audioExpiresAt: Date? = nil, markdownPath: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.app = app
        self.meetingURL = meetingURL
        self.calendarEventID = calendarEventID
        self.calendarSeriesID = calendarSeriesID
        self.stage = stage
        self.failure = failure
        self.summary = summary
        self.summaryProvider = summaryProvider
        self.language = language
        self.audioRetained = audioRetained
        self.audioExpiresAt = audioExpiresAt
        self.markdownPath = markdownPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}

public struct Person: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var displayName: String
    public var isMe: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), displayName: String, isMe: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.isMe = isMe
        self.createdAt = createdAt
    }
}

/// An email address or a name a person was seen under (calendar, captions, tiles).
public struct PersonIdentifier: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case email, alias }
    public var personID: UUID
    public var kind: Kind
    public var value: String

    public init(personID: UUID, kind: Kind, value: String) {
        self.personID = personID
        self.kind = kind
        self.value = value
    }
}

/// A saved voice fingerprint. Biometric: kept on this Mac only, never exported.
public struct Voice: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var personID: UUID
    public var embedding: [Float]
    public var model: String
    public var sourceMeetingID: UUID?
    public var createdAt: Date

    public init(
        id: UUID = UUID(), personID: UUID, embedding: [Float], model: String, sourceMeetingID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.personID = personID
        self.embedding = embedding
        self.model = model
        self.sourceMeetingID = sourceMeetingID
        self.createdAt = createdAt
    }
}

/// Someone expected in or seen in a meeting (calendar invite, meeting window).
public struct RosterEntry: Codable, Sendable, Hashable {
    public enum Source: String, Codable, Sendable { case calendar, window }
    public var meetingID: UUID
    public var name: String
    public var email: String?
    public var isMe: Bool
    public var source: Source

    public init(meetingID: UUID, name: String, email: String? = nil, isMe: Bool = false, source: Source) {
        self.meetingID = meetingID
        self.name = name
        self.email = email
        self.isMe = isMe
        self.source = source
    }
}

/// How a speaker got their name.
public enum NamingSource: String, Codable, Sendable {
    case voice, captions, screen, user, calendarSingleCandidate, me

    public var caption: String {
        switch self {
        case .voice: "Recognized from a saved voice"
        case .captions: "From captions"
        case .screen: "From the meeting window"
        case .user: "Named by you"
        case .calendarSingleCandidate: "Suggested from the invite"
        case .me: "Your microphone"
        }
    }
}

/// One voice in one meeting: "me" (the microphone) or a diarization cluster.
public struct MeetingSpeaker: Codable, Sendable, Hashable {
    public static let meKey = "me"

    public var meetingID: UUID
    public var speakerKey: String
    public var label: String
    public var personID: UUID?
    public var source: NamingSource?
    public var confidence: Double?
    public var talkSeconds: Double
    public var embedding: [Float]?

    public init(
        meetingID: UUID, speakerKey: String, label: String, personID: UUID? = nil, source: NamingSource? = nil,
        confidence: Double? = nil, talkSeconds: Double, embedding: [Float]? = nil
    ) {
        self.meetingID = meetingID
        self.speakerKey = speakerKey
        self.label = label
        self.personID = personID
        self.source = source
        self.confidence = confidence
        self.talkSeconds = talkSeconds
        self.embedding = embedding
    }

    public var isMe: Bool { speakerKey == Self.meKey }

    /// Label of a voice the user marked "Not a person" (a TV, a notification sound…); hidden everywhere.
    public static let ignoredLabel = "Not a person"
    public var isIgnored: Bool { label == Self.ignoredLabel && personID == nil }
}

/// A run of speech by one speaker. Times are seconds since the meeting started.
public struct Segment: Codable, Sendable, Identifiable, Hashable {
    public var id: Int64?
    public var meetingID: UUID
    public var speakerKey: String
    public var start: Double
    public var end: Double
    public var text: String
    public var isLive: Bool

    public init(
        id: Int64? = nil, meetingID: UUID, speakerKey: String, start: Double, end: Double, text: String,
        isLive: Bool = false
    ) {
        self.id = id
        self.meetingID = meetingID
        self.speakerKey = speakerKey
        self.start = start
        self.end = end
        self.text = text
        self.isLive = isLive
    }
}

public struct ActionItem: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var meetingID: UUID
    public var text: String
    public var ownerPersonID: UUID?
    /// Owner as written in the notes when it isn't a known person yet (e.g. "Speaker 4").
    public var ownerSpeakerKey: String?
    public var due: String?
    public var done: Bool
    public var sourceSegmentID: Int64?
    public var position: Int

    public init(
        id: UUID = UUID(), meetingID: UUID, text: String, ownerPersonID: UUID? = nil, ownerSpeakerKey: String? = nil,
        due: String? = nil, done: Bool = false, sourceSegmentID: Int64? = nil, position: Int
    ) {
        self.id = id
        self.meetingID = meetingID
        self.text = text
        self.ownerPersonID = ownerPersonID
        self.ownerSpeakerKey = ownerSpeakerKey
        self.due = due
        self.done = done
        self.sourceSegmentID = sourceSegmentID
        self.position = position
    }
}

public struct NoteItem: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable { case decision, question }
    public var id: UUID
    public var meetingID: UUID
    public var kind: Kind
    public var text: String
    public var sourceSegmentID: Int64?
    public var position: Int

    public init(
        id: UUID = UUID(), meetingID: UUID, kind: Kind, text: String, sourceSegmentID: Int64? = nil, position: Int
    ) {
        self.id = id
        self.meetingID = meetingID
        self.kind = kind
        self.text = text
        self.sourceSegmentID = sourceSegmentID
        self.position = position
    }
}

/// A bookmark or a private note made during the meeting.
public struct Mark: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable { case bookmark, privateNote = "private_note" }
    public var id: UUID
    public var meetingID: UUID
    public var kind: Kind
    public var time: Double
    public var text: String?

    public init(id: UUID = UUID(), meetingID: UUID, kind: Kind, time: Double, text: String? = nil) {
        self.id = id
        self.meetingID = meetingID
        self.kind = kind
        self.time = time
        self.text = text
    }
}

/// "Always take notes for this meeting" (reminder R5).
public struct MeetingRule: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var calendarSeriesID: String?
    public var meetingURL: String?
    public var title: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(), calendarSeriesID: String? = nil, meetingURL: String? = nil, title: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.calendarSeriesID = calendarSeriesID
        self.meetingURL = meetingURL.map(MeetingLink.normalize)
        self.title = title
        self.createdAt = createdAt
    }

    public func matches(seriesID: String?, url: String?) -> Bool {
        if let calendarSeriesID, calendarSeriesID == seriesID { return true }
        if let meetingURL, let url, meetingURL == MeetingLink.normalize(url) { return true }
        return false
    }
}

/// Typed notes produced by a summarizer, before they are stored.
public struct MeetingNotes: Codable, Sendable, Equatable {
    public struct Action: Codable, Sendable, Equatable {
        public var text: String
        /// Speaker key of the owner ("me" or a cluster key), when known.
        public var ownerSpeakerKey: String?
        public var due: String?
        public var sourceSegmentIndex: Int?

        public init(text: String, ownerSpeakerKey: String? = nil, due: String? = nil, sourceSegmentIndex: Int? = nil) {
            self.text = text
            self.ownerSpeakerKey = ownerSpeakerKey
            self.due = due
            self.sourceSegmentIndex = sourceSegmentIndex
        }
    }

    public struct Item: Codable, Sendable, Equatable {
        public var text: String
        public var sourceSegmentIndex: Int?

        public init(text: String, sourceSegmentIndex: Int? = nil) {
            self.text = text
            self.sourceSegmentIndex = sourceSegmentIndex
        }
    }

    public var summary: String
    public var decisions: [Item]
    public var actionItems: [Action]
    public var openQuestions: [Item]

    public init(summary: String, decisions: [Item] = [], actionItems: [Action] = [], openQuestions: [Item] = []) {
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
    }
}
