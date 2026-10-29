import AVFoundation
import MumbleASR
import MumbleCore
import SwiftUI

struct SettingsView: View {
    let controller: DictationController
    @State private var tab = Tab.general

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case vocabulary = "Vocabulary"
        case replacements = "Replacements"
        case history = "History"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .vocabulary: "character.book.closed"
            case .replacements: "arrow.triangle.swap"
            case .history: "clock"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $tab) { tab in
                Label(tab.rawValue, systemImage: tab.icon).tag(tab)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            switch tab {
            case .general: GeneralPane(controller: controller)
            case .vocabulary: VocabularyPane(controller: controller)
            case .replacements: ReplacementsPane(controller: controller)
            case .history: HistoryPane(controller: controller)
            }
        }
        .frame(minWidth: 640, minHeight: 500)
    }
}

// MARK: General

struct GeneralPane: View {
    let controller: DictationController
    @State private var micStatus = AudioRecorder.permission
    @State private var launchAtLogin = Permissions.launchesAtLogin

    private func binding<T>(_ keyPath: WritableKeyPath<MumbleSettings, T>) -> Binding<T> {
        Binding(get: { controller.settings[keyPath: keyPath] }, set: { value in controller.update { $0[keyPath: keyPath] = value } })
    }

    var body: some View {
        Form {
            Section("Setup") {
                PermissionRow(
                    title: "Microphone", detail: "Records only while you hold the key.",
                    granted: micStatus == .authorized,
                    action: {
                        if micStatus == .notDetermined {
                            Task {
                                _ = await AudioRecorder.requestPermission()
                                micStatus = AudioRecorder.permission
                            }
                        } else {
                            Permissions.openMicrophoneSettings()
                        }
                    })
                PermissionRow(
                    title: "Accessibility", detail: "Needed to hear the shortcut and paste into other apps.",
                    granted: controller.accessibilityTrusted,
                    action: { Permissions.requestAccessibility() })
                ModelRow(controller: controller)
            }

            Section("Dictation") {
                Picker("Hold to talk", selection: binding(\.triggerKey)) {
                    ForEach(TriggerKey.allCases) { Text($0.displayName).tag($0) }
                }
                if controller.settings.triggerKey == .function, !Permissions.fnKeyDoesNothing {
                    HStack {
                        Label("Set “Press 🌐 key to” → “Do Nothing”, or fn will also open the emoji picker.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                        Spacer()
                        Button("Keyboard Settings…") { Permissions.openKeyboardSettings() }
                    }
                }
                Text("Hold to dictate, release to insert. Double-tap to lock hands-free, press again to finish. Esc cancels.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Speech model", selection: binding(\.model)) {
                    ForEach(SpeechModel.allCases) { model in
                        Text("\(model.displayName) — \(model.tier)").tag(model)
                    }
                }
                Text("\(controller.settings.model.summary) Download \(controller.settings.model.approximateDownload), once.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Text") {
                Toggle("Remove filler words (um, uh)", isOn: binding(\.removeFillers))
                Toggle("Spoken “new line” / “new paragraph”", isOn: binding(\.spokenCommands))
                Toggle("Match spacing and capitalization to the cursor", isOn: binding(\.smartSpacing))
                Toggle(isOn: binding(\.inverseTextNormalization)) {
                    Text("Write numbers as digits")
                    Text("Experimental: “twenty five dollars” → “$25”. Can misread times.")
                }
            }

            Section("Behavior") {
                Toggle("Show live transcript while speaking", isOn: binding(\.showLivePreview))
                Toggle("Play start and stop sounds", isOn: binding(\.playSounds))
                Toggle("Keep history on this Mac", isOn: binding(\.keepHistory))
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in Permissions.launchesAtLogin = on }
            }

            Section {
                Label("Everything runs on this Mac. Audio and text never leave it.", systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
                if let ms = controller.lastLatencyMs {
                    Text("Last dictation: \(ms) ms from release to text.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .task {
            while !Task.isCancelled {
                micStatus = AudioRecorder.permission
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant…", action: action)
            }
        }
    }
}

struct ModelRow: View {
    let controller: DictationController

    var body: some View {
        HStack {
            switch controller.modelStatus {
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                VStack(alignment: .leading) {
                    Text("Speech model ready")
                    Text(controller.settings.model.displayName).font(.callout).foregroundStyle(.secondary)
                }
            case let .loading(progress, label):
                ProgressView().controlSize(.small)
                VStack(alignment: .leading) {
                    Text(label)
                    ProgressView(value: progress).frame(maxWidth: 260)
                }
            case let .failed(message):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.title3)
                VStack(alignment: .leading) {
                    Text("Model failed to load")
                    Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Retry") { controller.loadModel() }
            case .idle:
                Text("Starting…")
            }
            Spacer()
        }
    }
}

// MARK: Vocabulary

struct VocabularyPane: View {
    let controller: DictationController
    @State private var newTerm = ""
    @State private var newAliases = ""

    var body: some View {
        Form {
            Section {
                Text("Names, products and jargon Mumble should get right. Add how people say it as aliases, e.g. kubectl ← “cube control”.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("Term", text: $newTerm)
                    TextField("Aliases (comma separated, optional)", text: $newAliases)
                    Button("Add", action: add).disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .onSubmit(add)
                if let status = controller.vocabularyStatus {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("\(controller.settings.vocabulary.count) terms") {
                ForEach(controller.settings.vocabulary) { entry in
                    HStack {
                        Text(entry.term).bold()
                        if !entry.aliases.isEmpty {
                            Text("← " + entry.aliases.joined(separator: ", ")).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            controller.update { $0.vocabulary.removeAll { $0.id == entry.id } }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Vocabulary")
    }

    private func add() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        let aliases = newAliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        controller.update { $0.vocabulary.append(VocabularyEntry(term: term, aliases: aliases)) }
        newTerm = ""
        newAliases = ""
    }
}

// MARK: Replacements

struct ReplacementsPane: View {
    let controller: DictationController
    @State private var spoken = ""
    @State private var written = ""

    var body: some View {
        Form {
            Section {
                Text("Exact rewrites applied after transcription, e.g. “my email” → you@example.com.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("When I say", text: $spoken)
                    TextField("Write", text: $written)
                    Button("Add", action: add).disabled(spoken.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .onSubmit(add)
            }
            Section("\(controller.settings.replacements.count) rules") {
                ForEach(controller.settings.replacements) { rule in
                    HStack {
                        Text(rule.spoken)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(rule.written).bold()
                        Spacer()
                        Button(role: .destructive) {
                            controller.update { $0.replacements.removeAll { $0.id == rule.id } }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Replacements")
    }

    private func add() {
        let s = spoken.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        controller.update { $0.replacements.append(Replacement(spoken: s, written: written)) }
        spoken = ""
        written = ""
    }
}

// MARK: History

struct HistoryPane: View {
    let controller: DictationController
    @State private var query = ""

    private var items: [HistoryItem] {
        guard !query.isEmpty else { return controller.history }
        return controller.history.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView(
                    controller.history.isEmpty ? "No dictations yet" : "No matches",
                    systemImage: "waveform",
                    description: Text(controller.history.isEmpty
                        ? "Hold \(controller.settings.triggerKey.displayName) and speak."
                        : "Try a different search."))
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.text).textSelection(.enabled)
                    HStack(spacing: 8) {
                        Text(item.date, style: .relative)
                        if let app = item.appName { Text("· \(app)") }
                        Text(String(format: "· %.1f s audio · %d ms", item.audioSeconds, item.latencyMs))
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Copy") { TextInserter.copy(item.text) }
                    Button("Delete", role: .destructive) { controller.deleteHistory(item) }
                }
            }
        }
        .searchable(text: $query)
        .toolbar {
            Button("Clear All", role: .destructive) { controller.clearHistory() }
                .disabled(controller.history.isEmpty)
        }
        .navigationTitle("History")
    }
}
