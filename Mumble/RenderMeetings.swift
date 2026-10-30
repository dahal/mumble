import AppKit
import MumbleCore
import MumbleStore
import SwiftUI

/// Dev tool: renders the meeting windows with sample data to PNGs, for design review without
/// screen recording.
///
///   Mumble --render-meetings <dir>
@MainActor
enum RenderMeetings {
    static func run(_ dictation: DictationController, to dir: URL) async {
        let work = FileManager.default.temporaryDirectory.appending(path: "mumble-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            MeetingController.meetingsFolderOverride = work.appending(path: "Meetings")
            let store = try MeetingStore(url: work.appending(path: "Mumble.sqlite"))
            let id = try sample(store)
            let meetings = MeetingController(dictation: dictation, store: store)
            AppNavigation.shared.openWindow = { AppDelegate.showSettings() }
            AppDelegate.meetingsOverride = meetings
            let nav = AppNavigation.shared
            nav.showMeeting(nil)
            try await dump(to: dir.appending(path: "meetings-list.txt"))
            nav.showMeeting(id)
            try await dump(to: dir.appending(path: "meeting-detail.txt"))
            nav.selectedMeetingID = nil
            nav.tab = .general
            try await dump(to: dir.appending(path: "settings-general.txt"))
            print("RENDERED \(dir.path)")
            exit(0)
        } catch {
            print("RENDER failed: \(error)")
            exit(1)
        }
    }

    /// Every text the window shows, in Accessibility order (what VoiceOver would read).
    static func dump(to url: URL) async throws {
        try await Task.sleep(for: .seconds(2.5))
        let app = AXUIElementCreateApplication(getpid())
        var out: [String] = []
        for window in AXHelpers.children(app, attribute: kAXWindowsAttribute) {
            AXHelpers.walk(window, depth: 40) { node in
                let role = AXHelpers.string(node, kAXRoleAttribute) ?? ""
                let texts = [AXHelpers.string(node, kAXValueAttribute), AXHelpers.string(node, kAXTitleAttribute),
                             AXHelpers.string(node, kAXDescriptionAttribute)].compactMap { $0 }.filter { !$0.isEmpty }
                if !texts.isEmpty, role != "AXWindow" { out.append("\(role): \(texts.joined(separator: " | "))") }
                return true
            }
        }
        try out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// The Paper design's "Pricing page rollout" meeting, plus a few list rows.
    static func sample(_ store: MeetingStore) throws -> UUID {
        let cal = Calendar.current
        let today = cal.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        var m = Meeting(title: "Pricing page rollout", startedAt: today, endedAt: today.addingTimeInterval(34 * 60), app: .meet, stage: .done)
        m.summary = "Agreed to show the monthly price crossed out next to the annual plan. Ship behind a flag by Friday. Open question on migrating customers on the old plan."
        m.summaryProvider = "builtin"
        try store.create(m)
        let me = try store.me(defaultName: "Puru")
        let sarah = try store.createPerson(name: "Sarah Chen", email: "sarah@example.com")
        let dev = try store.createPerson(name: "Dev Patel")
        try store.addVoice(Voice(personID: sarah.id, embedding: [1, 0], model: "x"))
        try store.addVoice(Voice(personID: dev.id, embedding: [0, 1], model: "x"))
        let segs = try store.saveFinalTranscript(meetingID: m.id, segments: [
            Segment(meetingID: m.id, speakerKey: "S1", start: 252, end: 260, text: "So the new annual plan is live on staging. Do we show the monthly price crossed out, or just the savings badge?"),
            Segment(meetingID: m.id, speakerKey: "S2", start: 271, end: 280, text: "Crossed out tested better last time. Conversion was up about eight percent."),
            Segment(meetingID: m.id, speakerKey: "me", start: 288, end: 296, text: "Okay, let's go with crossed out. Sarah, can you ship it behind the flag by Friday?"),
            Segment(meetingID: m.id, speakerKey: "S3", start: 306, end: 314, text: "One thing from support: people on the old plan keep asking if they'll be migrated."),
        ], speakers: [
            MeetingSpeaker(meetingID: m.id, speakerKey: "me", label: "Me", personID: me.id, source: .me, talkSeconds: 420),
            MeetingSpeaker(meetingID: m.id, speakerKey: "S1", label: "Speaker 2", personID: sarah.id, source: .voice, talkSeconds: 660),
            MeetingSpeaker(meetingID: m.id, speakerKey: "S2", label: "Speaker 3", personID: dev.id, source: .voice, talkSeconds: 420),
            MeetingSpeaker(meetingID: m.id, speakerKey: "S3", label: "Speaker 4", talkSeconds: 240),
        ])
        try store.saveNotes(meetingID: m.id, summary: m.summary, provider: "builtin", actions: [
            ActionItem(meetingID: m.id, text: "Ship the crossed-out price behind the flag", ownerPersonID: sarah.id, due: "by Friday", sourceSegmentID: segs[2].id, position: 0),
            ActionItem(meetingID: m.id, text: "Send the checkout experiment numbers", ownerPersonID: dev.id, position: 1),
            ActionItem(meetingID: m.id, text: "Ask legal about grandfathering the old plan", ownerPersonID: me.id, done: true, position: 2),
        ], notes: [
            NoteItem(meetingID: m.id, kind: .decision, text: "Crossed-out monthly price on the annual plan", position: 0),
            NoteItem(meetingID: m.id, kind: .question, text: "Do customers on the old plan get migrated?", position: 0),
        ])
        try store.setRoster(m.id, [RosterEntry(meetingID: m.id, name: "Maya Ross", email: "maya@example.com", source: .calendar)])
        try store.addMark(Mark(meetingID: m.id, kind: .bookmark, time: 290))

        var design = Meeting(title: "Design sync", startedAt: today.addingTimeInterval(-45 * 60), endedAt: today.addingTimeInterval(-23 * 60), app: .meet, stage: .done)
        design.summary = "Reviewed the new onboarding screens. Maya to tighten copy on step two."
        try store.create(design)
        let old = cal.date(byAdding: .day, value: -2, to: today)!
        try store.create(Meeting(title: "Q4 planning", startedAt: old, endedAt: old.addingTimeInterval(51 * 60), app: .zoom, stage: .diarizing))
        var failed = Meeting(title: "Support triage", startedAt: old.addingTimeInterval(-86_400), endedAt: old.addingTimeInterval(-85_000), app: .slack, stage: .failed)
        failed.failure = "No audio was recorded."
        try store.create(failed)
        return m.id
    }
}
