import AVFoundation
import MumbleCore
import MumbleStore
import MumbleSummary
import SwiftUI

/// Meetings list (mirrors the History pane) with a pushed detail (a grouped form like General).
/// Design: Paper, file Mumble, page v0-meeting-notes.
struct MeetingsPane: View {
    let meetings: MeetingController
    @Bindable var navigation = AppNavigation.shared
    @State private var items: [MeetingListItem] = []
    @State private var query = ""
    @State private var matching: Set<UUID>?
    @State private var confirmDelete: MeetingListItem?

    private var filtered: [MeetingListItem] {
        guard let matching else { return items }
        return items.filter { matching.contains($0.id) }
    }

    var body: some View {
        NavigationStack(path: Binding(
            get: { navigation.selectedMeetingID.map { [$0] } ?? [] },
            set: { navigation.selectedMeetingID = $0.last })) {
            list
                .navigationDestination(for: UUID.self) { id in
                    MeetingDetailView(meetings: meetings, meetingID: id)
                }
        }
        .task { await observe() }
        .onChange(of: query) { _, q in
            let trimmed = q.trimmingCharacters(in: .whitespaces)
            matching = trimmed.isEmpty ? nil : (try? meetings.store?.meetingIDs(matching: trimmed)) ?? []
        }
    }

    private func observe() async {
        guard let store = meetings.store else { return }
        do {
            for try await value in store.observeListItems() { items = value }
        } catch {
            AppLog.error("Meetings list observation failed: \(error)")
        }
    }

    private var list: some View {
        List {
            Label("Meeting notes are experimental. Speaker names and notes can be wrong, so check them before sharing.",
                  systemImage: "flask")
                .font(.callout).foregroundStyle(.secondary)
            if let error = meetings.storeError {
                Label("Meeting notes are unavailable: \(error)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let warning = meetings.tapWarning, meetings.isRecording {
                Label(warning, systemImage: "speaker.slash").foregroundStyle(.orange).font(.callout)
            }
            if filtered.isEmpty {
                ContentUnavailableView(
                    items.isEmpty ? "No meetings yet" : "No matches",
                    systemImage: "person.2.wave.2",
                    description: Text(items.isEmpty
                        ? "Press \(GlobalShortcuts.Shortcut.toggleMeeting.display) or choose Start Notes during a call. Mumble also asks when a call starts."
                        : "Try a different search."))
            }
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        NavigationLink(value: item.id) { MeetingRow(item: item, meetings: meetings) }
                            .contextMenu {
                                Button("Copy as Markdown") { meetings.copyMarkdown(item.id) }
                                Divider()
                                Button("Delete…", role: .destructive) { confirmDelete = item }
                            }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search")
        .toolbar {
            ToolbarItem {
                Button {
                    meetings.toggle()
                } label: {
                    Label {
                        Text(meetings.isRecording ? "Stop Notes" : "Start Notes")
                    } icon: {
                        Image(systemName: meetings.isRecording ? "stop.circle.fill" : "record.circle")
                            .foregroundStyle(.red)
                    }
                    .labelStyle(.titleAndIcon)
                }
                .help("\(meetings.isRecording ? "Stop" : "Start") meeting notes (\(GlobalShortcuts.Shortcut.toggleMeeting.display))")
                .disabled(meetings.store == nil)
            }
        }
        .navigationTitle("Meetings")
        .confirmationDialog("Delete \(confirmDelete?.meeting.title ?? "meeting")?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let item = confirmDelete { meetings.delete(item.id, deleteMarkdown: false) }
            }
            if confirmDelete?.meeting.markdownPath != nil {
                Button("Delete Notes and Markdown File", role: .destructive) {
                    if let item = confirmDelete { meetings.delete(item.id, deleteMarkdown: true) }
                }
            }
        } message: {
            Text("The transcript, notes and any kept audio are deleted from this Mac.")
        }
    }

    private struct DaySection { let title: String; let items: [MeetingListItem] }

    private var sections: [DaySection] {
        let calendar = Calendar.current
        let now = Date()
        var today: [MeetingListItem] = [], week: [MeetingListItem] = [], earlier: [MeetingListItem] = []
        for item in filtered {
            if calendar.isDateInToday(item.meeting.startedAt) { today.append(item) }
            else if now.timeIntervalSince(item.meeting.startedAt) < 7 * 86_400 { week.append(item) }
            else { earlier.append(item) }
        }
        return [DaySection(title: "Today", items: today), DaySection(title: "This week", items: week),
                DaySection(title: "Earlier", items: earlier)].filter { !$0.items.isEmpty }
    }
}

struct MeetingRow: View {
    let item: MeetingListItem
    let meetings: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.meeting.title).fontWeight(.semibold)
            if meetings.recordingMeetingID == item.id {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("Recording · \(MarkdownExporter.timestamp(meetings.elapsed))").foregroundStyle(.secondary)
                }
            } else if !item.meeting.stage.isFinal {
                HStack(spacing: 8) {
                    ProgressView(value: item.meeting.stage.progress).frame(width: 120)
                    Text(meetings.processingQueue.first == item.id || item.meeting.stage != .transcribing
                         ? item.meeting.stage.label : "Waiting…").foregroundStyle(.secondary)
                }
            } else if item.meeting.stage == .failed {
                Label(item.meeting.failure ?? "Processing failed", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if let summary = item.meeting.summary {
                Text(summary).lineLimit(1)
            }
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var caption: String {
        var parts: [String] = []
        let start = item.meeting.startedAt
        if Calendar.current.isDateInToday(start) {
            parts.append(start.formatted(date: .omitted, time: .shortened))
        } else {
            parts.append(start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        }
        if let duration = item.meeting.duration { parts.append("\(max(1, Int(duration / 60))) min") }
        parts.append(item.meeting.app.displayName)
        if !item.participantNames.isEmpty {
            let names = item.participantNames
            parts.append(names.count > 4 ? "\(names.count) people" : names.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Detail

struct MeetingDetailView: View {
    let meetings: MeetingController
    let meetingID: UUID
    @State private var doc: MeetingDocument?
    @State private var people: [MeetingStore.PersonSummary] = []
    @State private var transcriptQuery = ""
    @State private var newPersonFor: String?
    @State private var newPersonName = ""
    @State private var askVoicesFor: (key: String, choice: MeetingController.NameChoice)?
    @State private var includePrivate = false
    @State private var confirmDelete = false
    @State private var player = MeetingPlayer()
    @State private var highlightedSegment: Int64?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let doc {
                ScrollViewReader { proxy in
                    form(doc, proxy: proxy)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(doc?.meeting.title ?? "Meeting")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Copy as Markdown") { meetings.copyMarkdown(meetingID) }
                    Button("Copy with My Notes") { meetings.copyMarkdown(meetingID, includePrivateNotes: true) }
                    Divider()
                    Button("Summarize Again") { meetings.resummarize(meetingID) }
                        .disabled(doc?.meeting.stage.isFinal != true)
                } label: {
                    Label("Copy as Markdown", systemImage: "doc.on.doc")
                } primaryAction: {
                    meetings.copyMarkdown(meetingID)
                }
                .labelStyle(.titleAndIcon)
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    .help("Delete this meeting")
            }
        }
        .task(id: meetingID) { await observe() }
        .onDisappear { player.stop() }
        .alert("New person", isPresented: Binding(get: { newPersonFor != nil }, set: { if !$0 { newPersonFor = nil } })) {
            TextField("Name", text: $newPersonName)
            Button("Save") {
                if let key = newPersonFor, !newPersonName.trimmingCharacters(in: .whitespaces).isEmpty {
                    choose(key, .newPerson(name: newPersonName.trimmingCharacters(in: .whitespaces), email: nil))
                }
                newPersonName = ""
            }
            Button("Cancel", role: .cancel) { newPersonName = "" }
        }
        .alert("Remember voices?", isPresented: Binding(get: { askVoicesFor != nil }, set: { if !$0 { askVoicesFor = nil } })) {
            Button("Remember") { finishVoiceQuestion(true) }
            Button("Not Now", role: .cancel) { finishVoiceQuestion(false) }
        } message: {
            Text("Mumble can recognize people automatically next time from their voice. Voice fingerprints stay on this Mac, and you can delete them anytime in Settings.")
        }
        .confirmationDialog("Delete this meeting?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                meetings.delete(meetingID, deleteMarkdown: false)
                dismiss()
            }
        } message: {
            Text("The transcript, notes and any kept audio are deleted from this Mac.")
        }
    }

    private func observe() async {
        guard let store = meetings.store else { return }
        people = (try? store.peopleSummaries()) ?? []
        do {
            for try await value in store.observeDocument(meetingID) {
                doc = value
                people = (try? store.peopleSummaries()) ?? people
            }
        } catch {
            AppLog.error("Meeting observation failed: \(error)")
        }
    }

    private func choose(_ key: String, _ choice: MeetingController.NameChoice) {
        if case .ignore = choice {
            meetings.name(meetingID: meetingID, speakerKey: key, as: choice)
        } else if meetings.prefs.rememberVoices == nil {
            askVoicesFor = (key, choice)
        } else {
            meetings.name(meetingID: meetingID, speakerKey: key, as: choice)
        }
    }

    private func finishVoiceQuestion(_ remember: Bool) {
        meetings.updatePrefs { $0.rememberVoices = remember }
        if let pending = askVoicesFor { meetings.name(meetingID: meetingID, speakerKey: pending.key, as: pending.choice) }
        askVoicesFor = nil
    }

    // MARK: Form

    @ViewBuilder
    private func form(_ doc: MeetingDocument, proxy: ScrollViewProxy) -> some View {
        Form {
            summarySection(doc)
            let actions = doc.actionItems
            if !actions.isEmpty {
                Section("Action items") {
                    ForEach(actions) { item in
                        HStack(spacing: 10) {
                            Toggle(isOn: Binding(get: { item.done }, set: { meetings.setActionItem(item, done: $0) })) {
                                Text(item.text + (item.due.map { " (\($0))" } ?? ""))
                                    .strikethrough(item.done)
                                    .foregroundStyle(item.done ? .secondary : .primary)
                            }
                            .toggleStyle(.checkbox)
                            Spacer()
                            Text(doc.ownerName(item) ?? "").foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { jump(to: item.sourceSegmentID, proxy: proxy) }
                        .help("Double-click to see where this was said")
                    }
                }
            }
            let questions = doc.noteItems.filter { $0.kind == .question }
            if !questions.isEmpty {
                Section("Open questions") {
                    ForEach(questions) { q in
                        Text(q.text).onTapGesture(count: 2) { jump(to: q.sourceSegmentID, proxy: proxy) }
                    }
                }
            }
            speakersSection(doc)
            let marks = doc.marks
            if !marks.isEmpty {
                Section("Bookmarks & notes") {
                    ForEach(marks) { mark in
                        HStack {
                            Image(systemName: mark.kind == .bookmark ? "bookmark.fill" : "note.text")
                                .foregroundStyle(mark.kind == .bookmark ? .orange : .secondary)
                            Text(mark.kind == .bookmark ? "Bookmark" : (mark.text ?? "My note"))
                            Spacer()
                            Button(MarkdownExporter.timestamp(mark.time)) {
                                jump(toTime: mark.time, in: doc, proxy: proxy)
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }
            transcriptSection(doc)
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func summarySection(_ doc: MeetingDocument) -> some View {
        Section {
            if !doc.meeting.stage.isFinal {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(meetings.recordingMeetingID == doc.meeting.id ? "Recording…" : doc.meeting.stage.label)
                    Spacer()
                }
            } else if doc.meeting.stage == .failed {
                HStack {
                    Label(doc.meeting.failure ?? "Processing failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Retry") { meetings.retry(doc.meeting.id) }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if let summary = doc.meeting.summary, !summary.isEmpty {
                    Text(summary).textSelection(.enabled)
                } else if doc.meeting.stage == .done {
                    Text("No summary.").foregroundStyle(.secondary)
                }
                Text(caption(doc.meeting)).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(doc.noteItems.filter { $0.kind == .decision }) { decision in
                LabeledContent("Decision") { Text(decision.text).multilineTextAlignment(.trailing) }
            }
        }
    }

    private func caption(_ meeting: Meeting) -> String {
        var parts = [meeting.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                     meeting.startedAt.formatted(date: .omitted, time: .shortened)]
        if let d = meeting.duration { parts.append("\(max(1, Int(d / 60))) min") }
        parts.append(meeting.app.displayName)
        if meeting.stage == .done { parts.append(SummaryProvider.label(forStored: meeting.summaryProvider)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func speakersSection(_ doc: MeetingDocument) -> some View {
        let speakers = doc.speakers.filter { !$0.isMe }
        if !speakers.isEmpty {
            Section("Speakers") {
                ForEach(speakers, id: \.speakerKey) { speaker in
                    SpeakerRow(speaker: speaker, doc: doc, people: people,
                               roster: meetings.calendarAttendees(for: doc.meeting.id),
                               choose: { choose(speaker.speakerKey, $0) },
                               newPerson: { newPersonFor = speaker.speakerKey })
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptSection(_ doc: MeetingDocument) -> some View {
        let all = doc.visibleSegments
        let segments = transcriptQuery.isEmpty ? all
            : all.filter { $0.text.localizedCaseInsensitiveContains(transcriptQuery)
                || doc.name(forSpeaker: $0.speakerKey).localizedCaseInsensitiveContains(transcriptQuery) }
        Section {
            if all.isEmpty {
                Text(doc.meeting.stage.isFinal ? "Nothing was transcribed." : "The transcript appears when processing finishes.")
                    .foregroundStyle(.secondary)
            }
            ForEach(segments) { segment in
                VStack(alignment: .leading, spacing: 3) {
                    Text(segment.text).textSelection(.enabled)
                    HStack(spacing: 4) {
                        Text(doc.name(forSpeaker: segment.speakerKey)).fontWeight(segment.speakerKey == MeetingSpeaker.meKey ? .semibold : .regular)
                        Text("·")
                        if doc.meeting.audioRetained {
                            Button(MarkdownExporter.timestamp(segment.start)) {
                                player.play(meetingID: doc.meeting.id, from: segment.start)
                            }
                            .buttonStyle(.link)
                            .help("Play from here")
                        } else {
                            Text(MarkdownExporter.timestamp(segment.start))
                        }
                        if doc.marks.contains(where: { $0.kind == .bookmark && segment.start - 5 <= $0.time && $0.time <= segment.end }) {
                            Text("· ★ Bookmarked").foregroundStyle(.orange)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 1)
                .listRowBackground(highlightedSegment == segment.id ? Color.accentColor.opacity(0.12) : nil)
                .id(segment.id)
            }
        } header: {
            HStack {
                Text("Transcript")
                Spacer()
                TextField("Search transcript", text: $transcriptQuery)
                    .textFieldStyle(.roundedBorder).frame(width: 180).font(.callout)
            }
        }
    }

    private func jump(to segmentID: Int64?, proxy: ScrollViewProxy) {
        guard let segmentID else { return }
        transcriptQuery = ""
        highlightedSegment = segmentID
        withAnimation { proxy.scrollTo(segmentID, anchor: .center) }
    }

    private func jump(toTime time: Double, in doc: MeetingDocument, proxy: ScrollViewProxy) {
        let target = doc.visibleSegments.last { $0.start <= time + 1 } ?? doc.visibleSegments.first
        jump(to: target?.id, proxy: proxy)
    }
}

/// One voice: a PermissionRow-style row with a Choose name… picker (spec §4.5).
struct SpeakerRow: View {
    let speaker: MeetingSpeaker
    let doc: MeetingDocument
    let people: [MeetingStore.PersonSummary]
    let roster: [RosterEntry]
    let choose: (MeetingController.NameChoice) -> Void
    let newPerson: () -> Void

    private var named: Bool { speaker.personID != nil }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(named ? (speaker.source == .calendarSingleCandidate ? .orange : .green) : .secondary)
                .font(.title3)
            VStack(alignment: .leading) {
                Text(speaker.isIgnored ? "Not a person" : doc.name(forSpeaker: speaker.speakerKey))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Menu(named ? "Change…" : "Choose name…") {
                let assigned = Set(doc.speakers.compactMap(\.personID))
                let assignedNames = doc.speakers.compactMap { $0.personID.flatMap { doc.people[$0]?.displayName } }
                let suggestions = roster.filter { entry in
                    !assignedNames.contains { NameMatcher.score($0, entry.name) >= 0.9 }
                }
                if !suggestions.isEmpty {
                    Section(roster.contains { $0.source == .calendar } ? "From the invite" : "In the meeting") {
                        ForEach(suggestions, id: \.name) { entry in
                            Button(entry.name) { choose(.newPerson(name: entry.name, email: entry.email)) }
                        }
                    }
                }
                let saved = people.filter { !$0.person.isMe && !assigned.contains($0.person.id) }
                if !saved.isEmpty {
                    Section("People") {
                        ForEach(saved) { p in
                            Button(p.person.displayName + (p.voiceCount > 0 ? "  ·  voice saved" : "")) { choose(.person(p.person.id)) }
                        }
                    }
                }
                Divider()
                Button("New Person…", action: newPerson)
                Button("Not a Person (ignore)") { choose(.ignore) }
            }
            .fixedSize()
        }
    }

    private var icon: String {
        if speaker.isIgnored { return "speaker.slash" }
        if !named { return "circle" }
        return speaker.source == .calendarSingleCandidate ? "checkmark.circle" : "checkmark.circle.fill"
    }

    private var detail: String {
        let minutes = max(1, Int((speaker.talkSeconds / 60).rounded()))
        if speaker.isIgnored { return "Hidden from the transcript" }
        if !named { return "New voice · \(minutes) min" }
        return "\(speaker.source?.caption ?? "Named") · \(minutes) min"
    }
}

/// Plays a meeting's kept audio (both tracks together) from a point in the transcript.
@MainActor
final class MeetingPlayer {
    private var players: [AVAudioPlayer] = []

    func play(meetingID: UUID, from seconds: Double) {
        stop()
        let folder = MeetingController.folder(for: meetingID)
        let urls = ["local", "remote"].compactMap { name -> URL? in
            for ext in ["m4a", "caf"] {
                let url = folder.appending(path: "\(name).\(ext)")
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
            return nil
        }
        players = urls.compactMap { try? AVAudioPlayer(contentsOf: $0) }
        guard let first = players.first else { return }
        let start = first.deviceCurrentTime + 0.1
        for player in players {
            player.currentTime = max(0, seconds - 0.5)
            player.prepareToPlay()
            player.play(atTime: start)
        }
    }

    func stop() {
        players.forEach { $0.stop() }
        players = []
    }
}
