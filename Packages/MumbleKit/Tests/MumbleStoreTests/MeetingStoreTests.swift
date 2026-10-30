import Foundation
import GRDB
import MumbleCore
import Testing
@testable import MumbleStore

/// Each test gets its own database file in a temporary folder (WAL mode, like the app).
struct TempStore {
    let folder: URL
    let store: MeetingStore

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "mumble-tests-\(UUID().uuidString)")
        store = try MeetingStore(url: folder.appending(path: "Mumble.sqlite"))
    }
}

func makeMeeting(_ store: MeetingStore, title: String = "Pricing page rollout", started: Date = Date()) throws -> Meeting {
    let meeting = Meeting(title: title, startedAt: started, endedAt: started.addingTimeInterval(1800), app: .meet, stage: .done)
    try store.create(meeting)
    return meeting
}

@Suite struct MeetingStoreTests {
    @Test func migratesFreshDatabase() throws {
        let t = try TempStore()
        let tables = try t.store.writer.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") }
        for name in ["meetings", "people", "person_identifiers", "voices", "meeting_roster", "meeting_speakers",
                     "segments", "segments_fts", "action_items", "note_items", "marks", "meeting_rules"] {
            #expect(tables.contains(name), "missing table \(name)")
        }
        // Reopening an existing database is a no-op migration.
        _ = try MeetingStore(url: t.folder.appending(path: "Mumble.sqlite"))
    }

    @Test func meetingRoundTripAndUpdate() throws {
        let t = try TempStore()
        var m = Meeting(title: "Standup", startedAt: Date(timeIntervalSince1970: 1_700_000_000), app: .zoom,
                        meetingURL: "https://zoom.us/j/1", calendarSeriesID: "S", audioRetained: true)
        try t.store.create(m)
        #expect(try t.store.meeting(m.id)?.title == "Standup")
        #expect(try t.store.meeting(m.id)?.app == .zoom)
        m.stage = .transcribing
        try t.store.update(m)
        #expect(try t.store.unfinishedMeetings().map(\.id) == [m.id])
        try t.store.updateMeeting(m.id) { $0.stage = .done; $0.summary = "S" }
        #expect(try t.store.meeting(m.id)?.summary == "S")
        #expect(try t.store.unfinishedMeetings().isEmpty)
    }

    @Test func finalTranscriptReplacesLiveRowsAndKeepsUserNames() throws {
        let t = try TempStore()
        let m = try makeMeeting(t.store)
        try t.store.appendLiveSegments([Segment(meetingID: m.id, speakerKey: "me", start: 0, end: 2, text: "live text")])
        let sarah = try t.store.createPerson(name: "Sarah Chen")
        try t.store.saveFinalTranscript(meetingID: m.id, segments: [], speakers: [
            MeetingSpeaker(meetingID: m.id, speakerKey: "S1", label: "Speaker 2", talkSeconds: 5)])
        try t.store.assign(meetingID: m.id, speakerKey: "S1", personID: sarah.id, source: .user)

        let saved = try t.store.saveFinalTranscript(meetingID: m.id, segments: [
            Segment(meetingID: m.id, speakerKey: "S1", start: 3, end: 5, text: "second"),
            Segment(meetingID: m.id, speakerKey: "me", start: 0, end: 2, text: "first"),
        ], speakers: [
            MeetingSpeaker(meetingID: m.id, speakerKey: "me", label: "Me", talkSeconds: 2),
            MeetingSpeaker(meetingID: m.id, speakerKey: "S1", label: "Speaker 2", talkSeconds: 2),
        ])
        #expect(saved.allSatisfy { $0.id != nil })
        let segments = try t.store.segments(m.id)
        #expect(segments.map(\.text) == ["first", "second"])
        #expect(segments.allSatisfy { !$0.isLive })
        let s1 = try t.store.speakers(m.id).first { $0.speakerKey == "S1" }
        #expect(s1?.personID == sarah.id && s1?.source == .user)
    }

    @Test func searchFindsAcrossMeetingsWithDiacriticsAndPrefixes() throws {
        let t = try TempStore()
        let a = try makeMeeting(t.store, title: "Pricing")
        let b = try makeMeeting(t.store, title: "Design")
        try t.store.saveFinalTranscript(meetingID: a.id, segments: [
            Segment(meetingID: a.id, speakerKey: "me", start: 10, end: 12, text: "We decided the annual pricing plan."),
        ], speakers: [])
        try t.store.saveFinalTranscript(meetingID: b.id, segments: [
            Segment(meetingID: b.id, speakerKey: "me", start: 1, end: 2, text: "Le café est prêt pour la démo."),
        ], speakers: [])
        try t.store.appendLiveSegments([Segment(meetingID: b.id, speakerKey: "me", start: 5, end: 6, text: "pricing live only")])

        let hits = try t.store.search("pric")
        #expect(hits.map(\.meetingID) == [a.id])
        #expect(hits[0].snippet.contains("**pricing**"))
        #expect(hits[0].start == 10)
        #expect(try t.store.search("cafe demo").map(\.meetingID) == [b.id])
        #expect(try t.store.meetingIDs(matching: "Design") == [b.id])
        #expect(try t.store.search("").isEmpty)
    }

    @Test func ftsStaysInSyncOnUpdateAndDelete() throws {
        let t = try TempStore()
        let m = try makeMeeting(t.store)
        try t.store.saveFinalTranscript(meetingID: m.id, segments: [
            Segment(meetingID: m.id, speakerKey: "me", start: 0, end: 1, text: "kubernetes rollout")], speakers: [])
        #expect(try t.store.search("kubernetes").count == 1)
        try t.store.saveFinalTranscript(meetingID: m.id, segments: [
            Segment(meetingID: m.id, speakerKey: "me", start: 0, end: 1, text: "something else")], speakers: [])
        #expect(try t.store.search("kubernetes").isEmpty)
        try t.store.deleteMeeting(m.id)
        #expect(try t.store.search("something").isEmpty)
    }

    @Test func deletingMeetingCascades() throws {
        let t = try TempStore()
        let m = try makeMeeting(t.store)
        let p = try t.store.createPerson(name: "Dev")
        try t.store.saveFinalTranscript(meetingID: m.id, segments: [
            Segment(meetingID: m.id, speakerKey: "S1", start: 0, end: 1, text: "hi")],
            speakers: [MeetingSpeaker(meetingID: m.id, speakerKey: "S1", label: "Speaker 2", personID: p.id, talkSeconds: 1)])
        try t.store.saveNotes(meetingID: m.id, summary: "s", provider: "builtin",
                              actions: [ActionItem(meetingID: m.id, text: "do it", position: 0)],
                              notes: [NoteItem(meetingID: m.id, kind: .decision, text: "yes", position: 0)])
        try t.store.addMark(Mark(meetingID: m.id, kind: .bookmark, time: 1))
        try t.store.setRoster(m.id, [RosterEntry(meetingID: m.id, name: "Dev", source: .calendar)])
        try t.store.addVoice(Voice(personID: p.id, embedding: [0.1, 0.2], model: "m", sourceMeetingID: m.id))

        try t.store.deleteMeeting(m.id)
        let counts = try t.store.writer.read { db in
            try ["segments", "meeting_speakers", "action_items", "note_items", "marks", "meeting_roster"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)")!
            }
        }
        #expect(counts == [0, 0, 0, 0, 0, 0])
        // The person and their voice survive; the voice just loses its source meeting.
        #expect(try t.store.voices(model: "m").first?.sourceMeetingID == nil)
        #expect(try t.store.person(p.id) != nil)
    }

    @Test func deletingPersonDeletesVoicesAndUnlinksSpeakers() throws {
        let t = try TempStore()
        let m = try makeMeeting(t.store)
        let p = try t.store.createPerson(name: "Sarah Chen", email: "sarah@acme.com")
        try t.store.saveFinalTranscript(meetingID: m.id, segments: [], speakers: [
            MeetingSpeaker(meetingID: m.id, speakerKey: "S1", label: "Speaker 2", personID: p.id, talkSeconds: 1)])
        try t.store.addVoice(Voice(personID: p.id, embedding: [1, 2, 3], model: "m"))
        try t.store.deletePerson(p.id)
        #expect(try t.store.voiceCount() == 0)
        #expect(try t.store.speakers(m.id).first?.personID == nil)
        #expect(try t.store.findPerson(name: nil, email: "sarah@acme.com") == nil)
    }

    @Test func embeddingsRoundTripAndAreCapped() throws {
        let t = try TempStore()
        let p = try t.store.createPerson(name: "Sarah")
        let embedding: [Float] = [0.5, -1.25, 3.0e-7, .pi]
        for i in 0..<12 {
            try t.store.addVoice(Voice(personID: p.id, embedding: embedding, model: "wespeaker",
                                       createdAt: Date(timeIntervalSince1970: Double(i))), keepingAtMost: 10)
        }
        let voices = try t.store.voices(model: "wespeaker")
        #expect(voices.count == 10)
        #expect(voices[0].embedding == embedding)
        #expect(try t.store.voices(model: "other").isEmpty)
        try t.store.deleteAllVoices()
        #expect(try t.store.voiceCount() == 0)
    }

    @Test func findPersonByEmailAliasAndFuzzyName() throws {
        let t = try TempStore()
        let sarah = try t.store.createPerson(name: "Sarah Chen", email: "sarah.chen@acme.com")
        let dev = try t.store.createPerson(name: "Dev Patel")
        try t.store.addIdentifier(sarah.id, kind: .alias, value: "S. Chen")
        #expect(try t.store.findPerson(name: nil, email: "SARAH.CHEN@acme.com")?.id == sarah.id)
        #expect(try t.store.findPerson(name: "S. Chen", email: nil)?.id == sarah.id)
        #expect(try t.store.findPerson(name: "Sarah C.", email: nil)?.id == sarah.id)
        #expect(try t.store.findPerson(name: "dev", email: nil)?.id == dev.id)
        _ = try t.store.createPerson(name: "Sarah Lopez")
        #expect(try t.store.findPerson(name: "Sarah", email: nil) == nil)   // ambiguous
        #expect(try t.store.findPerson(name: "Maya", email: nil) == nil)
    }

    @Test func renameAndMergeInOneTransaction() throws {
        let t = try TempStore()
        let m = try makeMeeting(t.store)
        let a = try t.store.createPerson(name: "sarah")
        let b = try t.store.createPerson(name: "Sarah Chen", email: "sarah@acme.com")
        try t.store.saveFinalTranscript(meetingID: m.id, segments: [], speakers: [
            MeetingSpeaker(meetingID: m.id, speakerKey: "S1", label: "Speaker 2", personID: a.id, talkSeconds: 1)])
        try t.store.saveNotes(meetingID: m.id, summary: nil, provider: nil,
                              actions: [ActionItem(meetingID: m.id, text: "x", ownerPersonID: a.id, position: 0)], notes: [])
        try t.store.addVoice(Voice(personID: a.id, embedding: [1], model: "m"))

        try t.store.mergePerson(a.id, into: b.id)
        #expect(try t.store.person(a.id) == nil)
        #expect(try t.store.speakers(m.id).first?.personID == b.id)
        #expect(try t.store.document(m.id)?.actionItems.first?.ownerPersonID == b.id)
        #expect(try t.store.voices(model: "m").first?.personID == b.id)
        #expect(try t.store.findPerson(name: "sarah", email: nil)?.id == b.id)  // alias moved over

        try t.store.renamePerson(b.id, to: "Sarah C. Chen")
        #expect(try t.store.person(b.id)?.displayName == "Sarah C. Chen")
    }

    @Test func assigningSpeakerRepointsActionItems() throws {
        let t = try TempStore()
        let m = try makeMeeting(t.store)
        try t.store.saveFinalTranscript(meetingID: m.id, segments: [], speakers: [
            MeetingSpeaker(meetingID: m.id, speakerKey: "S4", label: "Speaker 4", talkSeconds: 1)])
        try t.store.saveNotes(meetingID: m.id, summary: nil, provider: nil,
                              actions: [ActionItem(meetingID: m.id, text: "send numbers", ownerSpeakerKey: "S4", position: 0)],
                              notes: [])
        let dev = try t.store.createPerson(name: "Dev Patel")
        try t.store.assign(meetingID: m.id, speakerKey: "S4", personID: dev.id, source: .user)
        let doc = try #require(try t.store.document(m.id))
        #expect(doc.ownerName(doc.actionItems[0]) == "Dev Patel")
        #expect(doc.name(forSpeaker: "S4") == "Dev Patel")
    }

    @Test func notesKeepCheckedItemsAcrossRegeneration() throws {
        let t = try TempStore()
        let m = try makeMeeting(t.store)
        let item = ActionItem(meetingID: m.id, text: "Ship it", position: 0)
        try t.store.saveNotes(meetingID: m.id, summary: "a", provider: "builtin", actions: [item], notes: [])
        try t.store.setActionItem(item.id, done: true)
        #expect(try t.store.openActionItems().isEmpty)
        try t.store.saveNotes(meetingID: m.id, summary: "b", provider: "apple",
                              actions: [ActionItem(meetingID: m.id, text: "Ship it", position: 0),
                                        ActionItem(meetingID: m.id, text: "New one", position: 1)], notes: [])
        let open = try t.store.openActionItems()
        #expect(open.map(\.item.text) == ["New one"])
        #expect(try t.store.meeting(m.id)?.summaryProvider == "apple")
    }

    @Test func listItemsShowParticipantsAndOpenCounts() throws {
        let t = try TempStore()
        let m = try makeMeeting(t.store)
        let me = try t.store.me(defaultName: "Puru")
        #expect(try t.store.me(defaultName: "Other").id == me.id)
        let sarah = try t.store.createPerson(name: "Sarah Chen")
        try t.store.saveFinalTranscript(meetingID: m.id, segments: [], speakers: [
            MeetingSpeaker(meetingID: m.id, speakerKey: "S2", label: "Speaker 3", talkSeconds: 3),
            MeetingSpeaker(meetingID: m.id, speakerKey: "S1", label: "Speaker 2", personID: sarah.id, talkSeconds: 9),
            MeetingSpeaker(meetingID: m.id, speakerKey: "me", label: "Me", personID: me.id, talkSeconds: 1),
        ])
        try t.store.saveNotes(meetingID: m.id, summary: nil, provider: nil,
                              actions: [ActionItem(meetingID: m.id, text: "a", position: 0)], notes: [])
        let item = try #require(try t.store.listItems().first)
        #expect(item.participantNames == ["Me", "Sarah Chen", "Speaker 3"])
        #expect(item.openActionCount == 1)
        #expect(try t.store.meetings(with: sarah.id).map(\.id) == [m.id])
    }

    @Test func rulesAreUniquePerSeriesOrLink() throws {
        let t = try TempStore()
        try t.store.addRule(MeetingRule(calendarSeriesID: "S1", title: "Standup"))
        try t.store.addRule(MeetingRule(calendarSeriesID: "S1", title: "Standup again"))
        try t.store.addRule(MeetingRule(meetingURL: "https://meet.google.com/abc-defg-hij", title: "Design"))
        let rules = try t.store.rules()
        #expect(rules.map(\.title) == ["Standup", "Design"])
        #expect(rules[1].meetingURL == "meet.google.com/abc-defg-hij")
        try t.store.deleteRule(rules[0].id)
        #expect(try t.store.rules().count == 1)
    }

    @Test func observationDeliversChanges() async throws {
        let t = try TempStore()
        var iterator = t.store.observeListItems().makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty == true)
        _ = try makeMeeting(t.store)
        #expect(try await iterator.next()?.count == 1)
    }

    @Test func queriesStayFastWithTwoThousandMeetings() throws {
        let t = try TempStore()
        let words = ["pricing", "roadmap", "launch", "hiring", "budget", "design", "kubernetes", "customer", "billing", "support"]
        try t.store.writer.write { db in
            for i in 0..<2_000 {
                let m = Meeting(title: "Meeting \(i)", startedAt: Date(timeIntervalSince1970: Double(i) * 3600), app: .meet, stage: .done)
                try m.insert(db)
                try MeetingSpeaker(meetingID: m.id, speakerKey: "me", label: "Me", talkSeconds: 60).insert(db)
                for j in 0..<20 {
                    var s = Segment(meetingID: m.id, speakerKey: "me", start: Double(j * 10), end: Double(j * 10 + 9),
                                    text: "We talked about \(words[(i + j) % 10]) and \(words[(i * 3 + j) % 10]) today number \(j)")
                    try s.insert(db)
                }
                try ActionItem(meetingID: m.id, text: "Follow up \(i)", done: i % 3 == 0, position: 0).insert(db)
            }
        }
        func ms(_ block: () throws -> Void) rethrows -> Double {
            let start = Date()
            try block()
            return Date().timeIntervalSince(start) * 1000
        }
        let list = try ms { _ = try t.store.listItems(limit: 50) }
        let search = try ms { _ = try t.store.search("kubernetes budget") }
        let open = try ms { _ = try t.store.openActionItems() }
        #expect(list < 100, "list took \(list) ms")
        #expect(search < 150, "search took \(search) ms")
        #expect(open < 150, "open actions took \(open) ms")
    }
}

@Suite struct MarkdownCopyTests {
    func document() throws -> (TempStore, MeetingDocument) {
        let t = try TempStore()
        let m = try makeMeeting(t.store)
        try t.store.saveFinalTranscript(meetingID: m.id, segments: [
            Segment(meetingID: m.id, speakerKey: "me", start: 0, end: 2, text: "Hello")], speakers: [])
        try t.store.addMark(Mark(meetingID: m.id, kind: .privateNote, time: 1, text: "secret note"))
        return (t, try #require(try t.store.document(m.id)))
    }

    @Test func writesRewritesAndNeverOverwritesMovedFiles() throws {
        let (t, doc) = try document()
        let folder = t.folder.appending(path: "Notes")
        let first = try MarkdownCopy.write(doc, to: folder, previousPath: nil)
        #expect(first.hasSuffix(MarkdownExporter.fileName(for: doc.meeting)))
        let content = try String(contentsOfFile: first, encoding: .utf8)
        #expect(content.contains("Hello") && !content.contains("secret note"))

        // Rewrite in place.
        #expect(try MarkdownCopy.write(doc, to: folder, previousPath: first) == first)

        // The user renamed the file: a new one is written; the renamed one is untouched.
        let renamed = folder.appending(path: "mine.md").path
        try FileManager.default.moveItem(atPath: first, toPath: renamed)
        try "my edits".write(toFile: renamed, atomically: true, encoding: .utf8)
        let second = try MarkdownCopy.write(doc, to: folder, previousPath: first)
        #expect(second == first)
        #expect(try String(contentsOfFile: renamed, encoding: .utf8) == "my edits")

        // A different file already has the name: de-duplicated.
        let third = try MarkdownCopy.write(doc, to: folder, previousPath: nil)
        #expect(third.hasSuffix(" (2).md"))
    }
}
