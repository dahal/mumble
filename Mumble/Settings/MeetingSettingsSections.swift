import AppKit
import MumbleCore
import MumbleStore
import MumbleSummary
import SwiftUI

/// The meeting notes part of Settings → General (spec §4.6; Paper: "Settings, Meetings section").
struct MeetingSettingsSections: View {
    let meetings: MeetingController
    @State private var rules: [MeetingRule] = []
    @State private var people: [MeetingStore.PersonSummary] = []
    @State private var showVoices = false
    @State private var claudeKey = Keychain.load() ?? ""
    @State private var screenAccess = CGPreflightScreenCaptureAccess()

    private func binding<T>(_ keyPath: WritableKeyPath<MeetingPreferences, T>) -> Binding<T> {
        Binding(get: { meetings.prefs[keyPath: keyPath] }, set: { value in meetings.updatePrefs { $0[keyPath: keyPath] = value } })
    }

    private var provider: SummaryProvider { SummaryProvider(rawValue: meetings.prefs.summaryProvider) ?? .automatic }

    var body: some View {
        Section {
            LabeledContent("Start or stop meeting notes") {
                Text(GlobalShortcuts.Shortcut.toggleMeeting.display)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.background).shadow(radius: 0.5))
            }
            LabeledContent("Bookmark this moment") { Text(GlobalShortcuts.Shortcut.bookmark.display).foregroundStyle(.secondary) }
            Toggle(isOn: binding(\.remindOnDetect)) {
                Text("Remind me when a meeting starts")
                Text("When Meet, Zoom, Teams or Slack starts using the microphone.")
            }
            Toggle(isOn: Binding(get: { meetings.prefs.headsUp && meetings.prefs.useCalendar },
                                 set: { on in
                                     meetings.updatePrefs { $0.headsUp = on }
                                     if on, !meetings.prefs.useCalendar { Task { await meetings.enableCalendar() } }
                                 })) {
                Text("Heads-up 1 minute before calendar meetings")
                Text("Uses the calendars on this Mac. Nothing is sent anywhere.")
            }
            Toggle(isOn: binding(\.catchTheStart)) {
                Text("Catch the start of meetings")
                Text("While Mumble asks, it holds the last 2 minutes in memory so your notes start at the beginning. Wiped if you choose Not Now. Never saved to disk.")
            }
            Toggle(isOn: binding(\.showConsentSheet)) {
                Text("Offer a message to tell others you're taking notes")
            }
            Toggle(isOn: binding(\.privateNotesWhileMeeting)) {
                Text("While taking notes, dictation becomes a private note")
                Text("Hold \(meetings.dictation.settings.triggerKey.displayName) to add a note only you see, instead of pasting.")
            }
            Toggle("Show live transcript in the island", isOn: binding(\.showLiveTranscript))
        } header: {
            Text("Meetings")
        } footer: {
            Text("Meeting notes are experimental. Speaker names and notes can be wrong, so check them before sharing.")
        }

        Section {
            if rules.isEmpty {
                Text("None yet. Choose Always for This Meeting on a reminder's Options menu.").foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                HStack {
                    VStack(alignment: .leading) {
                        Text(rule.title)
                        Text(rule.calendarSeriesID != nil ? "Recurring calendar meeting" : (rule.meetingURL ?? ""))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { try? meetings.store?.deleteRule(rule.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Always take notes for")
        } footer: {
            Text("Recording still shows the red indicator and the consent message.").font(.callout).foregroundStyle(.secondary)
        }

        Section {
            Picker("Summaries", selection: binding(\.summaryProvider)) {
                ForEach(SummaryProvider.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            if provider == .apple || provider == .automatic, let reason = AppleIntelligence.unavailableReason {
                Text(provider == .automatic ? "\(reason) Until then, Mumble's built-in notes are used." : reason)
                    .font(.callout).foregroundStyle(.secondary)
            }
            if provider == .claude {
                SecureField("Claude API key", text: $claudeKey)
                    .onSubmit { Keychain.save(claudeKey) }
                    .onChange(of: claudeKey) { _, key in Keychain.save(key) }
                Text("Only the transcript text and names are sent to Anthropic, never audio. The key is stored in your keychain.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Picker("Meeting audio", selection: binding(\.audioRetention)) {
                ForEach(MeetingPreferences.AudioRetention.allCases) { Text($0.displayName).tag($0) }
            }
            HStack {
                VStack(alignment: .leading) {
                    Text("Saved voices")
                    Text(voicesSummary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Manage…") { showVoices = true }
            }
            Toggle(isOn: binding(\.markdownCopy)) {
                Text("Also save notes as Markdown")
                Text(meetings.markdownFolder?.path(percentEncoded: false) ?? "Choose a folder, e.g. an Obsidian vault or iCloud Drive.")
            }
            if meetings.prefs.markdownCopy {
                Button(meetings.markdownFolder == nil ? "Choose Folder…" : "Change Folder…") { chooseFolder() }
            }
        }

        Section("Speaker names") {
            Toggle(isOn: Binding(get: { meetings.prefs.useCalendar && meetings.calendarAuthorized },
                                 set: { on in
                                     if on { Task { await meetings.enableCalendar() } } else { meetings.updatePrefs { $0.useCalendar = false } }
                                 })) {
                Text("Suggest names from calendar invites")
                if meetings.prefs.useCalendar && !meetings.calendarAuthorized {
                    Text("Allow calendar access in System Settings → Privacy & Security → Calendars.")
                }
            }
            Toggle(isOn: binding(\.readCaptions)) {
                Text("Read live captions to identify speakers")
                Text("Experimental. Turn on captions in the meeting app; Mumble reads them through Accessibility.")
            }
            Toggle(isOn: Binding(get: { meetings.prefs.readMeetingWindow },
                                 set: { on in
                                     meetings.updatePrefs { $0.readMeetingWindow = on }
                                     if on, !CGPreflightScreenCaptureAccess() { screenAccess = CGRequestScreenCaptureAccess() }
                                 })) {
                Text("Read names from the meeting window")
                Text("Needs Screen Recording. Only the meeting window, never saved. Names are offered as suggestions.")
            }
        }
        .task { await observeRules() }
        .task { await observePeople() }
        .sheet(isPresented: $showVoices) { VoicesSheet(meetings: meetings, people: people) }
    }

    private var voicesSummary: String {
        let withVoice = people.filter { $0.voiceCount > 0 }.count
        if meetings.prefs.rememberVoices == false { return "Off · Mumble won't remember voices" }
        return withVoice == 0 ? "None yet · stored only on this Mac" : "\(withVoice) \(withVoice == 1 ? "person" : "people") · stored only on this Mac"
    }

    private func observeRules() async {
        guard let store = meetings.store else { return }
        do { for try await value in store.observeRules() { rules = value } } catch {}
    }

    private func observePeople() async {
        guard let store = meetings.store else { return }
        do { for try await value in store.observePeople() { people = value } } catch {}
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Mumble writes one Markdown file per meeting here."
        if panel.runModal() == .OK, let url = panel.url { meetings.setMarkdownFolder(url) }
    }
}

/// Settings → Saved voices → Manage… (spec §11.3).
struct VoicesSheet: View {
    let meetings: MeetingController
    let people: [MeetingStore.PersonSummary]
    @Environment(\.dismiss) private var dismiss
    @State private var confirmAll = false
    @State private var renaming: MeetingStore.PersonSummary?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("People and saved voices").font(.headline)
            Text("Voice fingerprints let Mumble name people automatically. They stay on this Mac and can't be turned back into audio.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Remember voices", isOn: Binding(get: { meetings.prefs.rememberVoices == true },
                                                    set: { on in meetings.updatePrefs { $0.rememberVoices = on } }))
            List {
                if people.filter({ !$0.person.isMe }).isEmpty {
                    Text("Nobody yet. Name a speaker in a meeting to add them.").foregroundStyle(.secondary)
                }
                ForEach(people.filter { !$0.person.isMe }) { p in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(p.person.displayName)
                            Text("\(p.meetingCount) meeting\(p.meetingCount == 1 ? "" : "s") · \(p.voiceCount > 0 ? "voice saved" : "no voice saved")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button("Rename…") { renaming = p; newName = p.person.displayName }
                            if p.voiceCount > 0 { Button("Forget Voice") { try? meetings.store?.deleteVoices(of: p.person.id) } }
                            Menu("Merge Into") {
                                ForEach(people.filter { $0.id != p.id && !$0.person.isMe }) { other in
                                    Button(other.person.displayName) { try? meetings.store?.mergePerson(p.person.id, into: other.person.id) }
                                }
                            }
                            Divider()
                            Button("Delete Person", role: .destructive) { try? meetings.store?.deletePerson(p.person.id) }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }
            .frame(minHeight: 220)
            HStack {
                Button("Delete All Saved Voices…", role: .destructive) { confirmAll = true }
                    .disabled(!people.contains { $0.voiceCount > 0 })
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 440)
        .confirmationDialog("Delete all saved voices?", isPresented: $confirmAll) {
            Button("Delete All", role: .destructive) { try? meetings.store?.deleteAllVoices() }
        } message: {
            Text("Mumble will stop recognizing people automatically until you name them again.")
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let p = renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    try? meetings.store?.renamePerson(p.person.id, to: newName.trimmingCharacters(in: .whitespaces))
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
