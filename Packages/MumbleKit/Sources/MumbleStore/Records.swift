import Foundation
import GRDB
import MumbleCore

// GRDB conformances for the MumbleCore record types. Column mapping is explicit: UUIDs are stored as
// text, dates as Unix seconds, embeddings as little-endian Float32 blobs.

extension UUID {
    init?(db value: String?) {
        guard let value, let uuid = UUID(uuidString: value) else { return nil }
        self = uuid
    }
}

extension Date {
    init?(db value: Double?) {
        guard let value else { return nil }
        self.init(timeIntervalSince1970: value)
    }
}

enum EmbeddingCoding {
    static func encode(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * 4)
        for v in values {
            var bits = v.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data) -> [Float] {
        stride(from: 0, to: data.count - 3, by: 4).map { i in
            let bits = UInt32(data[data.startIndex + i])
                | UInt32(data[data.startIndex + i + 1]) << 8
                | UInt32(data[data.startIndex + i + 2]) << 16
                | UInt32(data[data.startIndex + i + 3]) << 24
            return Float(bitPattern: bits)
        }
    }
}

extension Meeting: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meetings"

    public init(row: Row) {
        self.init(
            id: UUID(db: row["id"])!, title: row["title"], startedAt: Date(db: row["started_at"])!,
            endedAt: Date(db: row["ended_at"]), app: MeetingApp(rawValue: row["app"]), meetingURL: row["meeting_url"],
            calendarEventID: row["calendar_event_id"], calendarSeriesID: row["calendar_series_id"],
            stage: ProcessingStage(rawValue: row["stage"]) ?? .failed, failure: row["failure"], summary: row["summary"],
            summaryProvider: row["summary_provider"], language: row["language"],
            audioRetained: row["audio_retained"], audioExpiresAt: Date(db: row["audio_expires_at"]),
            markdownPath: row["markdown_path"], createdAt: Date(db: row["created_at"])!,
            updatedAt: Date(db: row["updated_at"])!)
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["title"] = title
        container["started_at"] = startedAt.timeIntervalSince1970
        container["ended_at"] = endedAt?.timeIntervalSince1970
        container["app"] = app.rawValue
        container["meeting_url"] = meetingURL
        container["calendar_event_id"] = calendarEventID
        container["calendar_series_id"] = calendarSeriesID
        container["stage"] = stage.rawValue
        container["failure"] = failure
        container["summary"] = summary
        container["summary_provider"] = summaryProvider
        container["language"] = language
        container["audio_retained"] = audioRetained
        container["audio_expires_at"] = audioExpiresAt?.timeIntervalSince1970
        container["markdown_path"] = markdownPath
        container["created_at"] = createdAt.timeIntervalSince1970
        container["updated_at"] = updatedAt.timeIntervalSince1970
    }
}

extension Person: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "people"

    public init(row: Row) {
        self.init(id: UUID(db: row["id"])!, displayName: row["display_name"], isMe: row["is_me"],
                  createdAt: Date(db: row["created_at"])!)
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["display_name"] = displayName
        container["is_me"] = isMe
        container["created_at"] = createdAt.timeIntervalSince1970
    }
}

extension PersonIdentifier: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "person_identifiers"

    public init(row: Row) {
        self.init(personID: UUID(db: row["person_id"])!, kind: Kind(rawValue: row["kind"]) ?? .alias, value: row["value"])
    }

    public func encode(to container: inout PersistenceContainer) {
        container["person_id"] = personID.uuidString
        container["kind"] = kind.rawValue
        container["value"] = value
    }
}

extension Voice: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "voices"

    public init(row: Row) {
        self.init(id: UUID(db: row["id"])!, personID: UUID(db: row["person_id"])!,
                  embedding: EmbeddingCoding.decode(row["embedding"]), model: row["model"],
                  sourceMeetingID: UUID(db: row["source_meeting_id"]), createdAt: Date(db: row["created_at"])!)
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["person_id"] = personID.uuidString
        container["embedding"] = EmbeddingCoding.encode(embedding)
        container["dimensions"] = embedding.count
        container["model"] = model
        container["source_meeting_id"] = sourceMeetingID?.uuidString
        container["created_at"] = createdAt.timeIntervalSince1970
    }
}

extension RosterEntry: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meeting_roster"

    public init(row: Row) {
        self.init(meetingID: UUID(db: row["meeting_id"])!, name: row["name"], email: row["email"], isMe: row["is_me"],
                  source: Source(rawValue: row["source"]) ?? .calendar)
    }

    public func encode(to container: inout PersistenceContainer) {
        container["meeting_id"] = meetingID.uuidString
        container["name"] = name
        container["email"] = email
        container["is_me"] = isMe
        container["source"] = source.rawValue
    }
}

extension MeetingSpeaker: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meeting_speakers"

    public init(row: Row) {
        let blob: Data? = row["embedding"]
        self.init(
            meetingID: UUID(db: row["meeting_id"])!, speakerKey: row["speaker_key"], label: row["label"],
            personID: UUID(db: row["person_id"]), source: (row["source"] as String?).flatMap(NamingSource.init(rawValue:)),
            confidence: row["confidence"], talkSeconds: row["talk_seconds"], embedding: blob.map(EmbeddingCoding.decode))
    }

    public func encode(to container: inout PersistenceContainer) {
        container["meeting_id"] = meetingID.uuidString
        container["speaker_key"] = speakerKey
        container["label"] = label
        container["person_id"] = personID?.uuidString
        container["source"] = source?.rawValue
        container["confidence"] = confidence
        container["talk_seconds"] = talkSeconds
        container["embedding"] = embedding.map(EmbeddingCoding.encode)
    }
}

extension Segment: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "segments"

    public init(row: Row) {
        self.init(id: row["id"], meetingID: UUID(db: row["meeting_id"])!, speakerKey: row["speaker_key"],
                  start: row["start"], end: row["end"], text: row["text"], isLive: row["is_live"])
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["meeting_id"] = meetingID.uuidString
        container["speaker_key"] = speakerKey
        container["start"] = start
        container["end"] = end
        container["text"] = text
        container["is_live"] = isLive
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension ActionItem: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "action_items"

    public init(row: Row) {
        self.init(id: UUID(db: row["id"])!, meetingID: UUID(db: row["meeting_id"])!, text: row["text"],
                  ownerPersonID: UUID(db: row["owner_person_id"]), ownerSpeakerKey: row["owner_speaker_key"],
                  due: row["due"], done: row["done"], sourceSegmentID: row["source_segment_id"], position: row["position"])
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["meeting_id"] = meetingID.uuidString
        container["text"] = text
        container["owner_person_id"] = ownerPersonID?.uuidString
        container["owner_speaker_key"] = ownerSpeakerKey
        container["due"] = due
        container["done"] = done
        container["source_segment_id"] = sourceSegmentID
        container["position"] = position
    }
}

extension NoteItem: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "note_items"

    public init(row: Row) {
        self.init(id: UUID(db: row["id"])!, meetingID: UUID(db: row["meeting_id"])!,
                  kind: Kind(rawValue: row["kind"]) ?? .decision, text: row["text"],
                  sourceSegmentID: row["source_segment_id"], position: row["position"])
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["meeting_id"] = meetingID.uuidString
        container["kind"] = kind.rawValue
        container["text"] = text
        container["source_segment_id"] = sourceSegmentID
        container["position"] = position
    }
}

extension Mark: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "marks"

    public init(row: Row) {
        self.init(id: UUID(db: row["id"])!, meetingID: UUID(db: row["meeting_id"])!,
                  kind: Kind(rawValue: row["kind"]) ?? .bookmark, time: row["time"], text: row["text"])
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["meeting_id"] = meetingID.uuidString
        container["kind"] = kind.rawValue
        container["time"] = time
        container["text"] = text
    }
}

extension MeetingRule: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meeting_rules"

    public init(row: Row) {
        self.init(id: UUID(db: row["id"])!, calendarSeriesID: row["calendar_series_id"], meetingURL: row["meeting_url"],
                  title: row["title"], createdAt: Date(db: row["created_at"])!)
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["calendar_series_id"] = calendarSeriesID
        container["meeting_url"] = meetingURL
        container["title"] = title
        container["created_at"] = createdAt.timeIntervalSince1970
    }
}
