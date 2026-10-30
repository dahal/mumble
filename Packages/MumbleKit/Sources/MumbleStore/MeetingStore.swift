import Foundation
import GRDB
import MumbleCore

/// One row of the Meetings list.
public struct MeetingListItem: Sendable, Identifiable, Hashable {
    public var meeting: Meeting
    public var participantNames: [String]
    public var openActionCount: Int
    public var id: UUID { meeting.id }
}

public struct SearchHit: Sendable, Identifiable, Hashable {
    public var meetingID: UUID
    public var meetingTitle: String
    public var meetingStartedAt: Date
    public var segmentID: Int64
    public var start: Double
    public var snippet: String
    public var id: Int64 { segmentID }
}

public struct OpenActionItem: Sendable, Identifiable, Hashable {
    public var item: ActionItem
    public var meetingTitle: String
    public var ownerName: String?
    public var id: UUID { item.id }
}

/// The meeting notes database (spec §12). One SQLite file in WAL mode; safe to use from any thread.
public final class MeetingStore: Sendable {
    public let writer: any DatabaseWriter

    /// Opens (creating if needed) the database at `url`, with file protection, and migrates it.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        writer = try DatabasePool(path: url.path, configuration: config)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        // auto_vacuum only takes effect if set before the first table is created.
        try writer.writeWithoutTransaction { db in
            if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master") == 0 {
                try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
            }
        }
        try Self.migrator.migrate(writer)
    }

    /// An in-memory database, for tests and previews.
    public init(inMemory: Void = ()) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        writer = try DatabaseQueue(configuration: config)
        try Self.migrator.migrate(writer)
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Mumble/Mumble.sqlite")
    }

    // MARK: Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE meetings (
                  id TEXT PRIMARY KEY, title TEXT NOT NULL, started_at REAL NOT NULL, ended_at REAL,
                  app TEXT NOT NULL, meeting_url TEXT, calendar_event_id TEXT, calendar_series_id TEXT,
                  stage TEXT NOT NULL, failure TEXT, summary TEXT, summary_provider TEXT, language TEXT,
                  audio_retained INTEGER NOT NULL DEFAULT 0, audio_expires_at REAL, markdown_path TEXT,
                  created_at REAL NOT NULL, updated_at REAL NOT NULL);
                CREATE INDEX meetings_started ON meetings(started_at DESC);

                CREATE TABLE people (
                  id TEXT PRIMARY KEY, display_name TEXT NOT NULL, is_me INTEGER NOT NULL DEFAULT 0,
                  created_at REAL NOT NULL);
                CREATE TABLE person_identifiers (
                  person_id TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                  kind TEXT NOT NULL, value TEXT NOT NULL COLLATE NOCASE,
                  PRIMARY KEY (kind, value));
                CREATE INDEX person_identifiers_person ON person_identifiers(person_id);

                CREATE TABLE voices (
                  id TEXT PRIMARY KEY,
                  person_id TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                  embedding BLOB NOT NULL, dimensions INTEGER NOT NULL, model TEXT NOT NULL,
                  source_meeting_id TEXT REFERENCES meetings(id) ON DELETE SET NULL,
                  created_at REAL NOT NULL);
                CREATE INDEX voices_person ON voices(person_id);

                CREATE TABLE meeting_roster (
                  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                  name TEXT NOT NULL, email TEXT, is_me INTEGER NOT NULL DEFAULT 0, source TEXT NOT NULL);
                CREATE INDEX meeting_roster_meeting ON meeting_roster(meeting_id);

                CREATE TABLE meeting_speakers (
                  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                  speaker_key TEXT NOT NULL, label TEXT NOT NULL,
                  person_id TEXT REFERENCES people(id) ON DELETE SET NULL,
                  source TEXT, confidence REAL, talk_seconds REAL NOT NULL, embedding BLOB,
                  PRIMARY KEY (meeting_id, speaker_key));
                CREATE INDEX meeting_speakers_person ON meeting_speakers(person_id);

                CREATE TABLE segments (
                  id INTEGER PRIMARY KEY,
                  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                  speaker_key TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL, text TEXT NOT NULL,
                  is_live INTEGER NOT NULL DEFAULT 0);
                CREATE INDEX segments_meeting ON segments(meeting_id, start);

                CREATE TABLE action_items (
                  id TEXT PRIMARY KEY,
                  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                  text TEXT NOT NULL,
                  owner_person_id TEXT REFERENCES people(id) ON DELETE SET NULL,
                  owner_speaker_key TEXT, due TEXT, done INTEGER NOT NULL DEFAULT 0,
                  source_segment_id INTEGER REFERENCES segments(id) ON DELETE SET NULL,
                  position INTEGER NOT NULL);
                CREATE INDEX action_items_open ON action_items(done, owner_person_id);
                CREATE INDEX action_items_meeting ON action_items(meeting_id);

                CREATE TABLE note_items (
                  id TEXT PRIMARY KEY,
                  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                  kind TEXT NOT NULL, text TEXT NOT NULL,
                  source_segment_id INTEGER REFERENCES segments(id) ON DELETE SET NULL,
                  position INTEGER NOT NULL);
                CREATE INDEX note_items_meeting ON note_items(meeting_id);

                CREATE TABLE marks (
                  id TEXT PRIMARY KEY,
                  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                  kind TEXT NOT NULL, time REAL NOT NULL, text TEXT);
                CREATE INDEX marks_meeting ON marks(meeting_id);

                CREATE TABLE meeting_rules (
                  id TEXT PRIMARY KEY, calendar_series_id TEXT UNIQUE, meeting_url TEXT UNIQUE,
                  title TEXT NOT NULL, created_at REAL NOT NULL,
                  CHECK (calendar_series_id IS NOT NULL OR meeting_url IS NOT NULL));
                """)
            // Multilingual full-text index kept in sync with `segments` by triggers.
            try db.create(virtualTable: "segments_fts", using: FTS5()) { t in
                t.synchronize(withTable: "segments")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("text")
            }
        }
        return migrator
    }

    // MARK: Meetings

    public func create(_ meeting: Meeting) throws {
        try writer.write { try meeting.insert($0) }
    }

    public func update(_ meeting: Meeting) throws {
        var m = meeting
        m.updatedAt = Date()
        try writer.write { [m] in try m.update($0) }
    }

    /// Reads, changes and saves one meeting in a single transaction.
    @discardableResult
    public func updateMeeting(_ id: UUID, _ change: @Sendable (inout Meeting) -> Void) throws -> Meeting? {
        try writer.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: id.uuidString) else { return nil }
            change(&meeting)
            meeting.updatedAt = Date()
            try meeting.update(db)
            return meeting
        }
    }

    public func meeting(_ id: UUID) throws -> Meeting? {
        try writer.read { try Meeting.fetchOne($0, key: id.uuidString) }
    }

    public func meetings(limit: Int = 500) throws -> [Meeting] {
        try writer.read { try Meeting.order(sql: "started_at DESC").limit(limit).fetchAll($0) }
    }

    /// Meetings that didn't finish processing (crash or quit), oldest first.
    public func unfinishedMeetings() throws -> [Meeting] {
        try writer.read {
            try Meeting.filter(sql: "stage NOT IN ('done', 'failed')").order(sql: "started_at").fetchAll($0)
        }
    }

    public func listItems(limit: Int = 500) throws -> [MeetingListItem] {
        try writer.read { try Self.listItems($0, limit: limit) }
    }

    static func listItems(_ db: Database, limit: Int) throws -> [MeetingListItem] {
        let meetings = try Meeting.order(sql: "started_at DESC").limit(limit).fetchAll(db)
        let names = try Row.fetchAll(db, sql: """
            SELECT s.meeting_id AS mid, COALESCE(CASE WHEN p.is_me THEN 'Me' ELSE p.display_name END,
                   CASE WHEN s.speaker_key = 'me' THEN 'Me' ELSE s.label END) AS name
            FROM meeting_speakers s LEFT JOIN people p ON p.id = s.person_id
            ORDER BY s.meeting_id, (s.speaker_key = 'me') DESC, s.talk_seconds DESC
            """)
        var byMeeting: [String: [String]] = [:]
        for row in names {
            let mid: String = row["mid"], name: String = row["name"]
            if !(byMeeting[mid]?.contains(name) ?? false) { byMeeting[mid, default: []].append(name) }
        }
        let open = try Row.fetchAll(db, sql: "SELECT meeting_id, COUNT(*) AS n FROM action_items WHERE done = 0 GROUP BY meeting_id")
        let openBy = Dictionary(uniqueKeysWithValues: open.map { ($0["meeting_id"] as String, $0["n"] as Int) })
        return meetings.map {
            MeetingListItem(meeting: $0, participantNames: byMeeting[$0.id.uuidString] ?? [],
                            openActionCount: openBy[$0.id.uuidString] ?? 0)
        }
    }

    /// Live list updates for SwiftUI.
    public func observeListItems(limit: Int = 500) -> AsyncThrowingStream<[MeetingListItem], Error> {
        stream(ValueObservation.tracking { try Self.listItems($0, limit: limit) })
    }

    /// Live updates of one meeting's full document.
    public func observeDocument(_ id: UUID) -> AsyncThrowingStream<MeetingDocument?, Error> {
        stream(ValueObservation.tracking { try Self.document($0, id: id) })
    }

    public func observeRules() -> AsyncThrowingStream<[MeetingRule], Error> {
        stream(ValueObservation.tracking { try MeetingRule.order(sql: "created_at").fetchAll($0) })
    }

    public func observePeople() -> AsyncThrowingStream<[PersonSummary], Error> {
        stream(ValueObservation.tracking { try Self.peopleSummaries($0) })
    }

    private func stream<T: Sendable>(_ observation: ValueObservation<ValueReducers.Fetch<T>>) -> AsyncThrowingStream<T, Error> {
        let writer = self.writer
        return AsyncThrowingStream { continuation in
            let cancellable = observation.start(
                in: writer, scheduling: .async(onQueue: .main),
                onError: { continuation.finish(throwing: $0) },
                onChange: { continuation.yield($0) })
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    /// Deletes a meeting and everything attached to it, then reclaims the freed pages so deleted
    /// text doesn't linger in the file.
    public func deleteMeeting(_ id: UUID) throws {
        try writer.write { db in
            _ = try Meeting.deleteOne(db, key: id.uuidString)
        }
        try writer.writeWithoutTransaction { try $0.execute(sql: "PRAGMA incremental_vacuum") }
    }

    // MARK: Transcript

    /// Appends live checkpoint segments (spec §12.7).
    public func appendLiveSegments(_ segments: [Segment]) throws {
        try writer.write { db in
            for var segment in segments {
                segment.isLive = true
                try segment.insert(db)
            }
        }
    }

    /// Replaces a meeting's transcript and speakers with the final result, in one transaction.
    /// Speakers already named by the user keep their person.
    @discardableResult
    public func saveFinalTranscript(meetingID: UUID, segments: [Segment], speakers: [MeetingSpeaker]) throws -> [Segment] {
        try writer.write { db in
            let previous = try MeetingSpeaker.filter(sql: "meeting_id = ?", arguments: [meetingID.uuidString]).fetchAll(db)
            try db.execute(sql: "DELETE FROM segments WHERE meeting_id = ?", arguments: [meetingID.uuidString])
            try db.execute(sql: "DELETE FROM meeting_speakers WHERE meeting_id = ?", arguments: [meetingID.uuidString])
            for var speaker in speakers {
                if let old = previous.first(where: { $0.speakerKey == speaker.speakerKey }), old.source == .user {
                    speaker.personID = old.personID
                    speaker.source = .user
                }
                try speaker.insert(db)
            }
            var saved: [Segment] = []
            for var segment in segments.sorted(by: { $0.start < $1.start }) {
                segment.isLive = false
                segment.id = nil
                try segment.insert(db)
                saved.append(segment)
            }
            return saved
        }
    }

    public func segments(_ meetingID: UUID) throws -> [Segment] {
        try writer.read {
            try Segment.filter(sql: "meeting_id = ?", arguments: [meetingID.uuidString]).order(sql: "start").fetchAll($0)
        }
    }

    // MARK: Speakers and people

    public func speakers(_ meetingID: UUID) throws -> [MeetingSpeaker] {
        try writer.read {
            try MeetingSpeaker.filter(sql: "meeting_id = ?", arguments: [meetingID.uuidString])
                .order(sql: "(speaker_key = 'me') DESC, talk_seconds DESC").fetchAll($0)
        }
    }

    public func updateSpeaker(_ speaker: MeetingSpeaker) throws {
        try writer.write { try speaker.update($0) }
    }

    /// Names a speaker. Re-points their action items too.
    public func assign(meetingID: UUID, speakerKey: String, personID: UUID?, source: NamingSource?, confidence: Double? = nil) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE meeting_speakers SET person_id = ?, source = ?, confidence = ? WHERE meeting_id = ? AND speaker_key = ?
                """, arguments: [personID?.uuidString, source?.rawValue, confidence, meetingID.uuidString, speakerKey])
            try db.execute(sql: """
                UPDATE action_items SET owner_person_id = ? WHERE meeting_id = ? AND owner_speaker_key = ?
                """, arguments: [personID?.uuidString, meetingID.uuidString, speakerKey])
        }
    }

    public func people() throws -> [Person] {
        try writer.read { try Person.order(sql: "display_name COLLATE NOCASE").fetchAll($0) }
    }

    public func person(_ id: UUID) throws -> Person? {
        try writer.read { try Person.fetchOne($0, key: id.uuidString) }
    }

    /// The person representing you, created on first use.
    public func me(defaultName: String) throws -> Person {
        try writer.write { db in
            if let me = try Person.filter(sql: "is_me = 1").fetchOne(db) { return me }
            let me = Person(displayName: defaultName, isMe: true)
            try me.insert(db)
            return me
        }
    }

    @discardableResult
    public func createPerson(name: String, email: String? = nil) throws -> Person {
        try writer.write { db in
            let person = Person(displayName: name)
            try person.insert(db)
            try PersonIdentifier(personID: person.id, kind: .alias, value: name).insert(db, onConflict: .ignore)
            if let email, !email.isEmpty {
                try PersonIdentifier(personID: person.id, kind: .email, value: email).insert(db, onConflict: .ignore)
            }
            return person
        }
    }

    /// Records another name or email for a person (first writer wins for each value).
    public func addIdentifier(_ personID: UUID, kind: PersonIdentifier.Kind, value: String) throws {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        try writer.write { try PersonIdentifier(personID: personID, kind: kind, value: value).insert($0, onConflict: .ignore) }
    }

    public func identifiers(_ personID: UUID) throws -> [PersonIdentifier] {
        try writer.read { try PersonIdentifier.filter(sql: "person_id = ?", arguments: [personID.uuidString]).fetchAll($0) }
    }

    /// Finds a person by exact email, exact alias, or a confident unambiguous fuzzy name match.
    public func findPerson(name: String?, email: String?) throws -> Person? {
        try writer.read { db in
            if let email, !email.isEmpty,
               let id = try String.fetchOne(db, sql: "SELECT person_id FROM person_identifiers WHERE kind = 'email' AND value = ?", arguments: [email]) {
                return try Person.fetchOne(db, key: id)
            }
            guard let name, !name.isEmpty else { return nil }
            if let id = try String.fetchOne(db, sql: "SELECT person_id FROM person_identifiers WHERE kind = 'alias' AND value = ?", arguments: [name]) {
                return try Person.fetchOne(db, key: id)
            }
            let people = try Person.filter(sql: "is_me = 0").fetchAll(db)
            let aliases = try PersonIdentifier.filter(sql: "kind = 'alias'").fetchAll(db)
            var candidates: [(Person, String)] = people.map { ($0, $0.displayName) }
            for alias in aliases {
                if let p = people.first(where: { $0.id == alias.personID }) { candidates.append((p, alias.value)) }
            }
            let matches = candidates.filter { NameMatcher.score(name, $0.1) >= 0.9 }
            let ids = Set(matches.map(\.0.id))
            if ids.count == 1 { return matches[0].0 }
            guard ids.isEmpty else { return nil }
            let firstName = candidates.filter { NameMatcher.score(name, $0.1) >= 0.75 }
            return Set(firstName.map(\.0.id)).count == 1 ? firstName[0].0 : nil
        }
    }

    public func renamePerson(_ id: UUID, to name: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE people SET display_name = ? WHERE id = ?", arguments: [name, id.uuidString])
            try PersonIdentifier(personID: id, kind: .alias, value: name).insert(db, onConflict: .ignore)
        }
    }

    /// Moves everything from `source` to `target` and deletes `source`, in one transaction.
    public func mergePerson(_ source: UUID, into target: UUID) throws {
        guard source != target else { return }
        try writer.write { db in
            let args: StatementArguments = [target.uuidString, source.uuidString]
            try db.execute(sql: "UPDATE meeting_speakers SET person_id = ? WHERE person_id = ?", arguments: args)
            try db.execute(sql: "UPDATE action_items SET owner_person_id = ? WHERE owner_person_id = ?", arguments: args)
            try db.execute(sql: "UPDATE voices SET person_id = ? WHERE person_id = ?", arguments: args)
            try db.execute(sql: "UPDATE OR IGNORE person_identifiers SET person_id = ? WHERE person_id = ?", arguments: args)
            _ = try Person.deleteOne(db, key: source.uuidString)
        }
    }

    public func deletePerson(_ id: UUID) throws {
        try writer.write { _ = try Person.deleteOne($0, key: id.uuidString) }
    }

    public struct PersonSummary: Sendable, Hashable, Identifiable {
        public var person: Person
        public var voiceCount: Int
        public var meetingCount: Int
        public var id: UUID { person.id }
    }

    public func peopleSummaries() throws -> [PersonSummary] {
        try writer.read { try Self.peopleSummaries($0) }
    }

    static func peopleSummaries(_ db: Database) throws -> [PersonSummary] {
        let people = try Person.order(sql: "is_me DESC, display_name COLLATE NOCASE").fetchAll(db)
        let voices = try Row.fetchAll(db, sql: "SELECT person_id, COUNT(*) AS n FROM voices GROUP BY person_id")
        let meetings = try Row.fetchAll(db, sql: "SELECT person_id, COUNT(DISTINCT meeting_id) AS n FROM meeting_speakers WHERE person_id IS NOT NULL GROUP BY person_id")
        let v = Dictionary(uniqueKeysWithValues: voices.map { ($0["person_id"] as String, $0["n"] as Int) })
        let m = Dictionary(uniqueKeysWithValues: meetings.map { ($0["person_id"] as String, $0["n"] as Int) })
        return people.map { PersonSummary(person: $0, voiceCount: v[$0.id.uuidString] ?? 0, meetingCount: m[$0.id.uuidString] ?? 0) }
    }

    /// Meetings a person spoke in, newest first.
    public func meetings(with personID: UUID) throws -> [Meeting] {
        try writer.read {
            try Meeting.fetchAll($0, sql: """
                SELECT m.* FROM meetings m WHERE m.id IN (SELECT meeting_id FROM meeting_speakers WHERE person_id = ?)
                ORDER BY m.started_at DESC
                """, arguments: [personID.uuidString])
        }
    }

    // MARK: Voices (biometric; spec §11.3)

    public func addVoice(_ voice: Voice, keepingAtMost limit: Int = 10) throws {
        try writer.write { db in
            try voice.insert(db)
            // Keep the newest `limit` embeddings per person and model.
            try db.execute(sql: """
                DELETE FROM voices WHERE person_id = ? AND model = ? AND id NOT IN (
                  SELECT id FROM voices WHERE person_id = ? AND model = ? ORDER BY created_at DESC LIMIT ?)
                """, arguments: [voice.personID.uuidString, voice.model, voice.personID.uuidString, voice.model, limit])
        }
    }

    public func voices(model: String) throws -> [Voice] {
        try writer.read { try Voice.filter(sql: "model = ?", arguments: [model]).fetchAll($0) }
    }

    public func voiceCount() throws -> Int {
        try writer.read { try Voice.fetchCount($0) }
    }

    public func deleteVoices(of personID: UUID) throws {
        try writer.write { try $0.execute(sql: "DELETE FROM voices WHERE person_id = ?", arguments: [personID.uuidString]) }
    }

    public func deleteAllVoices() throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM voices")
            try db.execute(sql: "UPDATE meeting_speakers SET embedding = NULL")
        }
        try writer.writeWithoutTransaction { try $0.execute(sql: "PRAGMA incremental_vacuum") }
    }

    /// Drops per-meeting cluster embeddings (used when the user doesn't want voices remembered).
    public func clearSpeakerEmbeddings(_ meetingID: UUID) throws {
        try writer.write {
            try $0.execute(sql: "UPDATE meeting_speakers SET embedding = NULL WHERE meeting_id = ?", arguments: [meetingID.uuidString])
        }
    }

    // MARK: Roster

    public func setRoster(_ meetingID: UUID, _ entries: [RosterEntry]) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM meeting_roster WHERE meeting_id = ?", arguments: [meetingID.uuidString])
            for entry in entries { try entry.insert(db) }
        }
    }

    public func roster(_ meetingID: UUID) throws -> [RosterEntry] {
        try writer.read { try RosterEntry.filter(sql: "meeting_id = ?", arguments: [meetingID.uuidString]).fetchAll($0) }
    }

    // MARK: Notes

    /// Replaces a meeting's generated notes. Checkbox state survives regeneration for identical items.
    public func saveNotes(meetingID: UUID, summary: String?, provider: String?, actions: [ActionItem], notes: [NoteItem]) throws {
        try writer.write { db in
            let previousDone = try String.fetchAll(db, sql: "SELECT text FROM action_items WHERE meeting_id = ? AND done = 1",
                                                   arguments: [meetingID.uuidString])
            try db.execute(sql: "DELETE FROM action_items WHERE meeting_id = ?", arguments: [meetingID.uuidString])
            try db.execute(sql: "DELETE FROM note_items WHERE meeting_id = ?", arguments: [meetingID.uuidString])
            for var item in actions {
                if previousDone.contains(item.text) { item.done = true }
                try item.insert(db)
            }
            for item in notes { try item.insert(db) }
            try db.execute(sql: "UPDATE meetings SET summary = ?, summary_provider = ?, updated_at = ? WHERE id = ?",
                           arguments: [summary, provider, Date().timeIntervalSince1970, meetingID.uuidString])
        }
    }

    public func setActionItem(_ id: UUID, done: Bool) throws {
        try writer.write {
            try $0.execute(sql: "UPDATE action_items SET done = ? WHERE id = ?", arguments: [done, id.uuidString])
        }
    }

    public func openActionItems() throws -> [OpenActionItem] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.*, m.title AS meeting_title, p.display_name AS owner_name, p.is_me AS owner_is_me
                FROM action_items a JOIN meetings m ON m.id = a.meeting_id
                LEFT JOIN people p ON p.id = a.owner_person_id
                WHERE a.done = 0 ORDER BY m.started_at DESC, a.position
                """)
            return rows.map { row in
                let isMe: Bool? = row["owner_is_me"]
                return OpenActionItem(item: ActionItem(row: row), meetingTitle: row["meeting_title"],
                                      ownerName: isMe == true ? "Me" : row["owner_name"])
            }
        }
    }

    // MARK: Marks

    public func addMark(_ mark: Mark) throws {
        try writer.write { try mark.insert($0) }
    }

    public func deleteMark(_ id: UUID) throws {
        try writer.write { _ = try Mark.deleteOne($0, key: id.uuidString) }
    }

    // MARK: Rules

    public func rules() throws -> [MeetingRule] {
        try writer.read { try MeetingRule.order(sql: "created_at").fetchAll($0) }
    }

    /// Adds a rule; an existing rule for the same series or link is kept instead.
    public func addRule(_ rule: MeetingRule) throws {
        try writer.write { try rule.insert($0, onConflict: .ignore) }
    }

    public func deleteRule(_ id: UUID) throws {
        try writer.write { _ = try MeetingRule.deleteOne($0, key: id.uuidString) }
    }

    // MARK: Search

    /// Full-text search across every meeting's final transcript, best matches first.
    public func search(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        return try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.id AS sid, s.start, s.meeting_id, m.title, m.started_at,
                       snippet(segments_fts, 0, '**', '**', '…', 12) AS snip
                FROM segments_fts JOIN segments s ON s.id = segments_fts.rowid
                JOIN meetings m ON m.id = s.meeting_id
                WHERE segments_fts MATCH ? AND s.is_live = 0
                ORDER BY bm25(segments_fts) LIMIT ?
                """, arguments: [pattern, limit]).map { row in
                SearchHit(meetingID: UUID(db: row["meeting_id"])!, meetingTitle: row["title"],
                          meetingStartedAt: Date(db: row["started_at"])!, segmentID: row["sid"], start: row["start"],
                          snippet: row["snip"])
            }
        }
    }

    /// IDs of meetings matching a search, for filtering the list.
    public func meetingIDs(matching query: String) throws -> Set<UUID> {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        let titleLike = "%\(query)%"
        return try writer.read { db in
            let byText = try String.fetchAll(db, sql: """
                SELECT DISTINCT s.meeting_id FROM segments_fts JOIN segments s ON s.id = segments_fts.rowid
                WHERE segments_fts MATCH ?
                """, arguments: [pattern])
            let byTitle = try String.fetchAll(db, sql: "SELECT id FROM meetings WHERE title LIKE ? OR summary LIKE ?",
                                              arguments: [titleLike, titleLike])
            return Set((byText + byTitle).compactMap(UUID.init(uuidString:)))
        }
    }

    // MARK: Documents

    public func document(_ id: UUID) throws -> MeetingDocument? {
        try writer.read { try Self.document($0, id: id) }
    }

    static func document(_ db: Database, id: UUID) throws -> MeetingDocument? {
        guard let meeting = try Meeting.fetchOne(db, key: id.uuidString) else { return nil }
        let key = id.uuidString
        let speakers = try MeetingSpeaker.filter(sql: "meeting_id = ?", arguments: [key])
            .order(sql: "(speaker_key = 'me') DESC, talk_seconds DESC").fetchAll(db)
        let segments = try Segment.filter(sql: "meeting_id = ?", arguments: [key]).order(sql: "start").fetchAll(db)
        let actions = try ActionItem.filter(sql: "meeting_id = ?", arguments: [key]).order(sql: "position").fetchAll(db)
        let notes = try NoteItem.filter(sql: "meeting_id = ?", arguments: [key]).order(sql: "position").fetchAll(db)
        let marks = try Mark.filter(sql: "meeting_id = ?", arguments: [key]).order(sql: "time").fetchAll(db)
        let personIDs = Set(speakers.compactMap(\.personID) + actions.compactMap(\.ownerPersonID)).map(\.uuidString)
        let people = try Person.fetchAll(db, keys: personIDs)
        return MeetingDocument(
            meeting: meeting, speakers: speakers, people: Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) }),
            segments: segments, actionItems: actions, noteItems: notes, marks: marks)
    }
}
