import AVFoundation
import MumbleCore
import MumbleStore
import MumbleSummary
import SwiftUI

/// Notes' signature yellow, a touch deeper so checkmarks read on white.
let notesAccent = Color(red: 0.90, green: 0.65, blue: 0.0)

/// The Meetings window, laid out like Apple Notes: folders, a list of notes grouped by date, and the
/// selected meeting as a document.
struct MeetingsWindow: View {
    let meetings: MeetingController
    @Bindable private var navigation = AppNavigation.shared
    @State private var items: [MeetingListItem] = []
    @State private var query = ""
    @State private var matching: Set<UUID>?
    @State private var folder: Folder = .all
    @State private var confirmDelete: MeetingListItem?
    @State private var columns = NavigationSplitViewVisibility.all

    enum Folder: String, CaseIterable, Identifiable {
        case all = "All Meetings", actions = "Open Action Items", processing = "In Progress"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .all: "folder"
            case .actions: "checklist"
            case .processing: "waveform"
            }
        }

        func contains(_ item: MeetingListItem) -> Bool {
            switch self {
            case .all: true
            case .actions: item.openActionCount > 0
            case .processing: !item.meeting.stage.isFinal || item.meeting.stage == .failed
            }
        }
    }

    private var filtered: [MeetingListItem] {
        items.filter { folder.contains($0) && (matching?.contains($0.id) ?? true) }
            .sorted { $0.meeting.startedAt > $1.meeting.startedAt }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
        } content: {
            list
        } detail: {
            if let id = navigation.selectedMeetingID {
                MeetingNoteView(meetings: meetings, meetingID: id)
                    .id(id)
            } else {
                ContentUnavailableView("No meeting selected", systemImage: "note.text")
            }
        }
        .tint(notesAccent)
        .searchable(text: $query, placement: .toolbar, prompt: "Search")
        .task { await observe() }
        .onChange(of: query) { _, q in
            let trimmed = q.trimmingCharacters(in: .whitespaces)
            matching = trimmed.isEmpty ? nil : (try? meetings.store?.meetingIDs(matching: trimmed)) ?? []
        }
        .confirmationDialog("Delete “\(confirmDelete?.meeting.title ?? "meeting")”?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { delete(confirmDelete, markdown: false) }
            if confirmDelete?.meeting.markdownPath != nil {
                Button("Delete Notes and Markdown File", role: .destructive) { delete(confirmDelete, markdown: true) }
            }
        } message: {
            Text("The transcript, notes and any kept audio are deleted from this Mac.")
        }
    }

    private func delete(_ item: MeetingListItem?, markdown: Bool) {
        guard let item else { return }
        if navigation.selectedMeetingID == item.id { navigation.selectedMeetingID = nil }
        meetings.delete(item.id, deleteMarkdown: markdown)
    }

    private func observe() async {
        guard let store = meetings.store else { return }
        do {
            for try await value in store.observeListItems() {
                items = value
                if navigation.selectedMeetingID == nil, let first = filtered.first { navigation.selectedMeetingID = first.id }
            }
        } catch {
            AppLog.error("Meetings list observation failed: \(error)")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { folder }, set: { if let f = $0 { folder = f } })) {
            Section("On My Mac") {
                ForEach(Folder.allCases) { f in
                    HStack {
                        Label { Text(f.rawValue) } icon: { Image(systemName: f.icon).foregroundStyle(notesAccent) }
                        Spacer()
                        Text("\(items.filter(f.contains).count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag(f)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 200)
    }

    // MARK: List

    private var list: some View {
        List(selection: $navigation.selectedMeetingID) {
            if let error = meetings.storeError {
                Label("Meeting notes are unavailable: \(error)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let warning = meetings.tapWarning, meetings.isRecording {
                Label(warning, systemImage: "speaker.slash").foregroundStyle(.orange).font(.callout)
            }
            ForEach(DateSections.group(filtered, date: { $0.meeting.startedAt })) { section in
                Section {
                    ForEach(section.items) { item in
                        MeetingNoteRow(item: item, meetings: meetings)
                            .tag(item.id)
                            .contextMenu {
                                Button("Copy as Markdown") { meetings.copyMarkdown(item.id) }
                                Divider()
                                Button("Delete…", role: .destructive) { confirmDelete = item }
                            }
                    }
                } header: {
                    Text(section.title).font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                }
            }
        }
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView(
                    items.isEmpty ? "No Meetings" : (query.isEmpty ? "Nothing here" : "No Results"),
                    systemImage: items.isEmpty ? "note.text" : "magnifyingglass",
                    description: Text(items.isEmpty
                        ? "Press \(GlobalShortcuts.Shortcut.toggleMeeting.display) or click the compose button during a call. Mumble also asks when a call starts."
                        : ""))
            }
        }
        .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        .navigationTitle(folder.rawValue)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button {
                    meetings.toggle()
                } label: {
                    Label(meetings.isRecording ? "Stop Notes" : "New Meeting Notes",
                          systemImage: meetings.isRecording ? "stop.circle.fill" : "square.and.pencil")
                }
                .help("\(meetings.isRecording ? "Stop" : "Start") meeting notes (\(GlobalShortcuts.Shortcut.toggleMeeting.display))")
                .disabled(meetings.store == nil)
            }
        }
    }

    private var subtitle: String {
        let count = filtered.count
        return count == 1 ? "1 meeting" : "\(count) meetings"
    }
}

/// A Notes-style row: bold title, then time and the first line of the summary, then who was there.
struct MeetingNoteRow: View {
    let item: MeetingListItem
    let meetings: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.meeting.title).font(.headline).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(time).foregroundStyle(.primary)
                preview.foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.subheadline)
            HStack(spacing: 4) {
                Image(systemName: item.openActionCount > 0 ? "checklist" : "person.2")
                Text(footer).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var preview: some View {
        if meetings.recordingMeetingID == item.id {
            Text("Recording · \(MarkdownExporter.timestamp(meetings.elapsed))").foregroundStyle(.red)
        } else if !item.meeting.stage.isFinal {
            Text(meetings.processingQueue.first == item.id || item.meeting.stage != .transcribing
                 ? item.meeting.stage.label : "Waiting…")
        } else if item.meeting.stage == .failed {
            Text(item.meeting.failure ?? "Processing failed").foregroundStyle(.orange)
        } else {
            Text(item.meeting.summary?.isEmpty == false ? item.meeting.summary! : "No summary")
        }
    }

    private var time: String {
        let start = item.meeting.startedAt
        let calendar = Calendar.current
        if calendar.isDateInToday(start) { return start.formatted(date: .omitted, time: .shortened) }
        if Date().timeIntervalSince(start) < 7 * 86_400 { return start.formatted(.dateTime.weekday(.wide)) }
        return start.formatted(date: .numeric, time: .omitted)
    }

    private var footer: String {
        var parts: [String] = []
        if let duration = item.meeting.duration { parts.append("\(max(1, Int(duration / 60))) min") }
        parts.append(item.meeting.app.displayName)
        let names = item.participantNames
        if !names.isEmpty { parts.append(names.count > 3 ? "\(names.count) people" : names.joined(separator: ", ")) }
        if item.openActionCount > 0 { parts.append("\(item.openActionCount) to do") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The note

/// One meeting as a Notes document: date line, big title, summary, checklists, then the transcript.
struct MeetingNoteView: View {
    let meetings: MeetingController
    let meetingID: UUID
    @State private var doc: MeetingDocument?
    @State private var people: [MeetingStore.PersonSummary] = []
    @State private var transcriptQuery = ""
    @State private var newPersonFor: String?
    @State private var newPersonName = ""
    @State private var askVoicesFor: (key: String, choice: MeetingController.NameChoice)?
    @State private var confirmDelete = false
    @State private var player = MeetingPlayer()
    @State private var highlightedSegment: Int64?

    var body: some View {
        Group {
            if let doc {
                ScrollViewReader { proxy in
                    ScrollView {
                        page(doc, proxy: proxy)
                            .frame(maxWidth: 700, alignment: .leading)
                            .padding(.horizontal, 44)
                            .padding(.top, 18)
                            .padding(.bottom, 60)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Copy as Markdown") { meetings.copyMarkdown(meetingID) }
                    Button("Copy with My Notes") { meetings.copyMarkdown(meetingID, includePrivateNotes: true) }
                    Divider()
                    Button("Summarize Again") { meetings.resummarize(meetingID) }
                        .disabled(doc?.meeting.stage.isFinal != true)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .help("Copy or summarize again")
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
                AppNavigation.shared.selectedMeetingID = nil
                meetings.delete(meetingID, deleteMarkdown: false)
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

    // MARK: Page

    @ViewBuilder
    private func page(_ doc: MeetingDocument, proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(dateLine(doc.meeting))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                Text(doc.meeting.title)
                    .font(.system(size: 28, weight: .bold))
                    .textSelection(.enabled)
                Text(caption(doc.meeting)).font(.callout).foregroundStyle(.secondary)
                Label("Meeting notes are experimental. Names and notes can be wrong, so check before sharing.", systemImage: "flask")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            status(doc)
            if let summary = doc.meeting.summary, !summary.isEmpty {
                Text(summary).font(.system(size: 15)).lineSpacing(4).textSelection(.enabled)
            } else if doc.meeting.stage == .done {
                Text("No summary.").font(.system(size: 15)).foregroundStyle(.secondary)
            }
            let decisions = doc.noteItems.filter { $0.kind == .decision }
            if !decisions.isEmpty {
                NoteSection("Decisions") {
                    ForEach(decisions) { Bullet(text: $0.text).onTapGesture(count: 2) {} }
                }
            }
            let actions = doc.actionItems
            if !actions.isEmpty {
                NoteSection("Action Items") {
                    ForEach(actions) { item in
                        ChecklistRow(item: item, owner: doc.ownerName(item),
                                     toggle: { meetings.setActionItem(item, done: !item.done) },
                                     reveal: { jump(to: item.sourceSegmentID, proxy: proxy) })
                    }
                }
            }
            let questions = doc.noteItems.filter { $0.kind == .question }
            if !questions.isEmpty {
                NoteSection("Open Questions") {
                    ForEach(questions) { q in
                        Bullet(text: q.text)
                            .onTapGesture(count: 2) { jump(to: q.sourceSegmentID, proxy: proxy) }
                            .help("Double-click to see where this was asked")
                    }
                }
            }
            speakers(doc)
            let marks = doc.marks
            if !marks.isEmpty {
                NoteSection("Bookmarks & Notes") {
                    ForEach(marks) { mark in
                        HStack(spacing: 8) {
                            Image(systemName: mark.kind == .bookmark ? "bookmark.fill" : "note.text")
                                .foregroundStyle(mark.kind == .bookmark ? notesAccent : .secondary)
                            Text(mark.kind == .bookmark ? "Bookmark" : (mark.text ?? "My note"))
                            Button(MarkdownExporter.timestamp(mark.time)) { jump(toTime: mark.time, in: doc, proxy: proxy) }
                                .buttonStyle(.link)
                        }
                        .font(.system(size: 14))
                    }
                }
            }
            transcript(doc)
        }
    }

    @ViewBuilder
    private func status(_ doc: MeetingDocument) -> some View {
        if !doc.meeting.stage.isFinal {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(meetings.recordingMeetingID == doc.meeting.id ? "Recording… notes appear when you stop." : doc.meeting.stage.label)
                Spacer()
            }
            .padding(12)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        } else if doc.meeting.stage == .failed {
            HStack {
                Label(doc.meeting.failure ?? "Processing failed", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Retry") { meetings.retry(doc.meeting.id) }
            }
            .padding(12)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func speakers(_ doc: MeetingDocument) -> some View {
        let speakers = doc.speakers.filter { !$0.isMe }
        if !speakers.isEmpty {
            NoteSection("People") {
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
    private func transcript(_ doc: MeetingDocument) -> some View {
        let all = doc.visibleSegments
        let segments = transcriptQuery.isEmpty ? all
            : all.filter { $0.text.localizedCaseInsensitiveContains(transcriptQuery)
                || doc.name(forSpeaker: $0.speakerKey).localizedCaseInsensitiveContains(transcriptQuery) }
        VStack(alignment: .leading, spacing: 12) {
            Divider().padding(.vertical, 6)
            HStack {
                Text("Transcript").font(.title3.weight(.bold))
                Spacer()
                TextField("Find in transcript", text: $transcriptQuery)
                    .textFieldStyle(.roundedBorder).frame(width: 190).font(.callout)
            }
            if all.isEmpty {
                Text(doc.meeting.stage.isFinal ? "Nothing was transcribed." : "The transcript appears when processing finishes.")
                    .foregroundStyle(.secondary)
            }
            ForEach(segments) { segment in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(doc.name(forSpeaker: segment.speakerKey)).fontWeight(.semibold)
                        if doc.meeting.audioRetained {
                            Button(MarkdownExporter.timestamp(segment.start)) {
                                player.play(meetingID: doc.meeting.id, from: segment.start)
                            }
                            .buttonStyle(.link)
                            .help("Play from here")
                        } else {
                            Text(MarkdownExporter.timestamp(segment.start)).foregroundStyle(.secondary)
                        }
                        if doc.marks.contains(where: { $0.kind == .bookmark && segment.start - 5 <= $0.time && $0.time <= segment.end }) {
                            Image(systemName: "bookmark.fill").foregroundStyle(notesAccent)
                        }
                    }
                    .font(.caption)
                    Text(segment.text).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(highlightedSegment == segment.id ? notesAccent.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, -8)
                .id(segment.id)
            }
        }
    }

    private func dateLine(_ meeting: Meeting) -> String {
        meeting.startedAt.formatted(.dateTime.month(.wide).day().year().hour().minute())
    }

    private func caption(_ meeting: Meeting) -> String {
        var parts: [String] = []
        if let d = meeting.duration { parts.append("\(max(1, Int(d / 60))) min") }
        parts.append(meeting.app.displayName)
        if meeting.stage == .done { parts.append(SummaryProvider.label(forStored: meeting.summaryProvider)) }
        return parts.joined(separator: " · ")
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

/// A bold heading followed by its lines, like a Notes heading.
private struct NoteSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.title3.weight(.bold))
            content
        }
    }
}

private struct Bullet: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).textSelection(.enabled)
        }
        .font(.system(size: 14))
    }
}

/// A Notes checklist line: round checkbox that fills yellow when done.
private struct ChecklistRow: View {
    let item: ActionItem
    let owner: String?
    let toggle: () -> Void
    let reveal: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Button(action: toggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(item.done ? notesAccent : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(item.done ? "Mark as not done" : "Mark as done")
            .accessibilityLabel(item.done ? "Done" : "Not done")
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text + (item.due.map { " (\($0))" } ?? ""))
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
                if let owner, !owner.isEmpty {
                    Text(owner).font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 14))
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: reveal)
            .help("Double-click to see where this was said")
        }
    }
}

/// One voice in the meeting, with a menu to name it (spec §4.5).
struct SpeakerRow: View {
    let speaker: MeetingSpeaker
    let doc: MeetingDocument
    let people: [MeetingStore.PersonSummary]
    let roster: [RosterEntry]
    let choose: (MeetingController.NameChoice) -> Void
    let newPerson: () -> Void

    private var named: Bool { speaker.personID != nil }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(named ? (speaker.source == .calendarSingleCandidate ? .orange : .green) : .secondary)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 1) {
                Text(speaker.isIgnored ? "Not a person" : doc.name(forSpeaker: speaker.speakerKey)).font(.system(size: 14))
                Text(detail).font(.caption).foregroundStyle(.secondary)
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
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        if speaker.isIgnored { return "speaker.slash" }
        if !named { return "person.crop.circle.badge.questionmark" }
        return speaker.source == .calendarSingleCandidate ? "person.crop.circle.badge.checkmark" : "person.crop.circle.fill.badge.checkmark"
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
