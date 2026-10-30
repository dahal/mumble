import AppKit
import MumbleASR
import MumbleCore
import MumbleStore
import MumbleSummary
import Observation

/// Meeting notes (spec): reminders, recording, processing, speaker naming, notes and storage.
@MainActor @Observable
final class MeetingController {
    enum Phase: Equatable {
        case idle
        /// A call was detected and we're asking; with "catch the start", audio is held in memory.
        case asking(ReminderScheduler.Detected)
        case recording(UUID)
    }

    private(set) var phase: Phase = .idle
    private(set) var elapsed: Double = 0
    private(set) var storeError: String?
    /// Meetings currently being processed, in order.
    private(set) var processingQueue: [UUID] = []
    private(set) var tapWarning: String?
    var calendarAuthorized = CalendarService.isAuthorized

    let store: MeetingStore?
    @ObservationIgnored let dictation: DictationController
    @ObservationIgnored private let diarizer = MeetingDiarizer()
    @ObservationIgnored private let calendar = CalendarService()
    @ObservationIgnored private let detector = MeetingDetector()
    @ObservationIgnored private let shortcuts = GlobalShortcuts()
    @ObservationIgnored private var scheduler = ReminderScheduler()
    @ObservationIgnored private var recorder: MeetingRecorder?
    @ObservationIgnored private var recordingCall: MeetingDetector.Call?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var processTask: Task<Void, Never>?
    @ObservationIgnored private var signalTask: Task<Void, Never>?
    @ObservationIgnored private var signals: [NameSignal] = []
    @ObservationIgnored private var liveVoices: [Voice] = []
    @ObservationIgnored private var consent: ConsentPanel?
    @ObservationIgnored private var headsUpHide: Task<Void, Never>?

    /// Tests point this at a temporary folder.
    static var meetingsFolderOverride: URL?

    static var meetingsFolder: URL {
        meetingsFolderOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Mumble/Meetings")
    }

    static func folder(for id: UUID) -> URL { meetingsFolder.appending(path: id.uuidString) }

    var prefs: MeetingPreferences { dictation.settings.meetings }
    var island: IslandModel { dictation.island }
    var isRecording: Bool { if case .recording = phase { true } else { false } }
    var recordingMeetingID: UUID? { if case let .recording(id) = phase { id } else { nil } }
    var askingTitle: String? { if case let .asking(d) = phase { d.title } else { nil } }

    init(dictation: DictationController, store: MeetingStore? = nil) {
        self.dictation = dictation
        if let store {
            self.store = store
        } else {
            do {
                self.store = try MeetingStore(url: MeetingStore.defaultURL)
            } catch {
                self.store = nil
                storeError = error.localizedDescription
                AppLog.error("Meeting store failed to open: \(error)")
            }
        }
    }

    func updatePrefs(_ change: (inout MeetingPreferences) -> Void) {
        dictation.update { change(&$0.meetings) }
        scheduler.options = prefs.reminderOptions
        if prefs.enabled { detector.start() } else { detector.stop() }
    }

    // MARK: Lifecycle

    func start() {
        guard store != nil else { return }
        scheduler.options = prefs.reminderOptions
        shortcuts.register(.toggleMeeting, id: 1) { [weak self] in self?.toggle() }
        shortcuts.register(.bookmark, id: 2) { [weak self] in self?.bookmark() }
        Notifier.shared.onAction = { [weak self] action, info in self?.handleNotification(action, info: info) }
        Notifier.shared.configure()
        detector.onStart = { [weak self] call in self?.callStarted(call) }
        detector.onEnd = { [weak self] call in self?.callEnded(call) }
        if prefs.enabled { detector.start() }
        dictation.privateNoteHandler = { [weak self] text in self?.addPrivateNote(text) ?? false }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        cleanUpExpiredAudio()
        resumeUnfinished()
        Task { try? await diarizer.prepare() }  // download the diarization models ahead of the first meeting
    }

    // MARK: Reminders (spec §4.1.1)

    private func detected(for call: MeetingDetector.Call) -> ReminderScheduler.Detected {
        let event = prefs.useCalendar ? calendar.currentEvent(url: call.url) : nil
        let title = event?.title ?? "\(call.app.displayName == "Call" ? call.appName : call.app.displayName) call"
        return .init(app: call.app, url: call.url ?? event?.url, title: title, seriesID: event?.seriesID)
    }

    func callStarted(_ call: MeetingDetector.Call) {
        guard !isRecording else { return }
        let detected = detected(for: call)
        let rules = (try? store?.rules()) ?? []
        AppLog.info("Meeting detected: \(call.app.rawValue) in \(call.appName)")
        switch scheduler.meetingStarted(detected, rules: rules, now: Date(), isRecording: isRecording) {
        case .autoStart:
            startRecording(detected: detected, call: call)
        case let .prompt(d, _):
            recordingCall = call
            ask(d, call: call)
        default:
            break
        }
    }

    private func callEnded(_ call: MeetingDetector.Call) {
        if isRecording, recordingCall?.pid == call.pid {
            AppLog.info("Meeting app stopped using the microphone: stopping notes")
            stop()
            return
        }
        if scheduler.meetingEnded() == .withdraw { withdrawPrompt() }
    }

    private func ask(_ detected: ReminderScheduler.Detected, call: MeetingDetector.Call?) {
        if case .idle = phase, prefs.catchTheStart, let call {
            // R4: hold the last two minutes in memory only, until the user answers.
            let id = UUID()
            let recorder = MeetingRecorder(folder: Self.folder(for: id))
            do {
                try recorder.start(inputUID: dictation.settings.inputDeviceUID, tapTarget: call.tapTarget, hold: true)
                self.recorder = recorder
            } catch {
                AppLog.error("Catch-the-start hold failed: \(error)")
            }
        }
        phase = .asking(detected)
        island.onTakeNotes = { [weak self] in self?.takeNotes() }
        island.onDismiss = { [weak self] in self?.notNow() }
        island.reset()
        island.phase = .suggest(title: detected.title, appBundleID: recordingCall?.bundlePrefixes.first)
        dictation.islandPanel.show()
        dictation.islandPanel.hide(after: .seconds(12))
        let canAlways = detected.seriesID != nil || detected.url != nil
        Notifier.shared.post(
            id: "meeting", title: "Take notes for \(detected.title)?",
            body: "\(detected.app.displayName) started using your microphone.",
            category: canAlways ? "MEETING" : "MEETING_ONCE")
    }

    /// Take Notes from the island, the notification or the menu.
    func takeNotes() {
        guard case let .asking(detected) = phase else { return }
        scheduler.answered(now: Date())
        Notifier.shared.remove(id: "meeting")
        startRecording(detected: detected, call: recordingCall)
    }

    func notNow() {
        scheduler.answered(now: Date())
        withdrawPrompt()
    }

    func alwaysForThisMeeting() {
        guard case let .asking(detected) = phase else { return }
        try? store?.addRule(MeetingRule(calendarSeriesID: detected.seriesID, meetingURL: detected.url, title: detected.title))
        takeNotes()
    }

    private func withdrawPrompt() {
        Notifier.shared.remove(id: "meeting")
        if case .asking = phase {
            recorder?.discard()   // zeroes anything held
            recorder = nil
            phase = .idle
            if case .suggest = island.phase { dictation.islandPanel.hide() }
        }
    }

    private func handleNotification(_ action: Notifier.Action, info: [AnyHashable: Any]) {
        switch action {
        case .takeNotes: takeNotes()
        case .always: alwaysForThisMeeting()
        case .notNow: notNow()
        case .open:
            if let id = (info["meetingID"] as? String).flatMap(UUID.init(uuidString:)) {
                AppNavigation.shared.showMeeting(id)
            } else if case .asking = phase {
                takeNotes()
            }
        }
    }

    private func tick() {
        calendarAuthorized = CalendarService.isAuthorized
        let upcoming = prefs.useCalendar ? calendar.upcoming() : []
        switch scheduler.tick(now: Date(), upcoming: upcoming, isRecording: isRecording) {
        case let .headsUp(title):
            guard case .idle = phase, !dictation.isRecording else { return }
            island.onTakeNotes = { [weak self] in
                self?.startRecording(detected: .init(app: .other("calendar"), url: nil, title: title), call: nil)
            }
            island.onDismiss = { [weak self] in self?.dictation.islandPanel.hide() }
            island.reset()
            island.phase = .headsUp(title: title)
            dictation.islandPanel.show()
            dictation.islandPanel.hide(after: .seconds(10))
        case let .prompt(detected, _):
            ask(detected, call: recordingCall)
        default:
            break
        }
        // Keep the "kept for 7 days" promise even if the app runs for weeks.
        cleanUpExpiredAudio()
    }

    // MARK: Recording

    func toggle() {
        switch phase {
        case .recording: stop()
        case .asking: takeNotes()
        case .idle: startRecording(detected: nil, call: MeetingDetector.detect())
        }
    }

    /// Starts taking notes. `call` decides which app's audio is recorded; without one, everything
    /// playing on the Mac except Mumble is recorded.
    func startRecording(detected: ReminderScheduler.Detected?, call: MeetingDetector.Call?) {
        guard let store, !isRecording else { return }
        guard AudioRecorder.permission == .authorized else {
            Task {
                if await AudioRecorder.requestPermission() { startRecording(detected: detected, call: call) }
            }
            return
        }
        let now = Date()
        let event = prefs.useCalendar ? calendar.currentEvent(url: call?.url ?? detected?.url) : nil
        let app = call?.app ?? detected?.app ?? .other("unknown")
        let title = event?.title ?? detected?.title ?? Self.defaultTitle(app: app, date: now)
        var meeting = Meeting(title: title, startedAt: now, app: app, meetingURL: call?.url ?? detected?.url ?? event?.url,
                              calendarEventID: event?.id, calendarSeriesID: event?.seriesID ?? detected?.seriesID)

        // Reuse the held capture (catch the start) when there is one.
        let recorder: MeetingRecorder
        if let held = self.recorder, held.mode == .holding {
            recorder = held
            meeting.id = UUID(uuidString: held.folder.lastPathComponent) ?? meeting.id
            do {
                try recorder.commit()
                meeting.startedAt = now.addingTimeInterval(-recorder.elapsed)
            } catch {
                AppLog.error("Couldn't keep the held start: \(error)")
            }
        } else {
            self.recorder?.discard()
            recorder = MeetingRecorder(folder: Self.folder(for: meeting.id))
            let target: SystemAudioTap.Target = call?.tapTarget ?? .everythingButMumble
            do {
                try recorder.start(inputUID: dictation.settings.inputDeviceUID, tapTarget: target, hold: false)
            } catch {
                AppLog.error("Meeting recording failed to start: \(error)")
                notify("Couldn't start meeting notes: \(error.localizedDescription)")
                return
            }
        }
        do {
            try store.create(meeting)
            if let event { try store.setRoster(meeting.id, Self.roster(event, meetingID: meeting.id)) }
        } catch {
            AppLog.error("Couldn't save the meeting: \(error)")
        }
        self.recorder = recorder
        recordingCall = call ?? recordingCall
        tapWarning = recorder.tapError
        signals = []
        liveVoices = (try? store.voices(model: MeetingDiarizer.embeddingModelID)) ?? []
        phase = .recording(meeting.id)
        AppLog.info("Meeting notes started (\(app.rawValue)); tap: \(recorder.isTapRunning)")

        island.reset()
        island.showPreview = prefs.showLiveTranscript
        island.restingPhase = .meeting
        island.phase = .meeting
        dictation.islandPanel.show()
        startLiveLoop(meetingID: meeting.id, recorder: recorder)
        startSignalReaders(call: call)
        if prefs.showConsentSheet { showConsent() }
    }

    static func defaultTitle(app: MeetingApp, date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        let name = app.displayName == "Call" ? "Meeting" : app.displayName
        return "\(name) · \(f.string(from: date))"
    }

    static func roster(_ event: CalendarService.Event, meetingID: UUID) -> [RosterEntry] {
        event.attendees.map { RosterEntry(meetingID: meetingID, name: $0.name, email: $0.email, isMe: $0.isMe, source: .calendar) }
    }

    func stop() {
        guard case let .recording(id) = phase, let recorder else { return }
        liveTask?.cancel()
        signalTask?.cancel()
        let seconds = recorder.stop()
        self.recorder = nil
        phase = .idle
        recordingCall = nil
        consent?.close()
        island.restingPhase = nil
        if case .meeting = island.phase { dictation.islandPanel.hide() }
        let started = (try? store?.meeting(id))?.startedAt ?? Date().addingTimeInterval(-seconds)
        _ = try? store?.updateMeeting(id) { $0.endedAt = started.addingTimeInterval(seconds); $0.stage = .transcribing }
        saveSignals(signals, for: id)
        AppLog.info(String(format: "Meeting notes stopped after %.0f s", seconds))
        enqueue(id)
    }

    func bookmark() {
        guard case let .recording(id) = phase, let recorder else { return }
        try? store?.addMark(Mark(meetingID: id, kind: .bookmark, time: max(0, recorder.elapsed - 5)))
        flash("Bookmarked")
    }

    /// Dictation during a meeting becomes a private note when that setting is on. Returns true if handled.
    func addPrivateNote(_ text: String) -> Bool {
        guard prefs.privateNotesWhileMeeting, case let .recording(id) = phase, let recorder else { return false }
        try? store?.addMark(Mark(meetingID: id, kind: .privateNote, time: recorder.elapsed, text: text))
        flash("Note saved")
        return true
    }

    private func flash(_ text: String) {
        island.flash = text
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if island.flash == text { island.flash = nil }
        }
    }

    private func notify(_ message: String) {
        island.reset()
        island.phase = .notice(message)
        dictation.islandPanel.show()
        dictation.islandPanel.hide(after: .seconds(3))
    }

    private func showConsent() {
        let panel = ConsentPanel { [weak self] dontShowAgain in
            if dontShowAgain { self?.updatePrefs { $0.showConsentSheet = false } }
        }
        consent = panel
        panel.show()
    }

    // MARK: Live preview

    private func startLiveLoop(meetingID: UUID, recorder: MeetingRecorder) {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.recordingMeetingID == meetingID else { return }
                self.elapsed = recorder.elapsed
                // Dictation during a meeting borrows the island; only drive it in the meeting state.
                if self.island.phase == .meeting {
                    self.island.elapsed = recorder.elapsed
                    self.island.pushLevel(max(recorder.localLevel, recorder.remoteLevel))
                }
                tick += 1
                if tick % 25 == 0 { await self.updateLivePreview(recorder) }
                if tick % 300 == 0, !recorder.tapHasAudio, recorder.elapsed > 60 {
                    self.tapWarning = "No audio from the meeting app yet. Check Privacy & Security → Screen & System Audio Recording."
                }
            }
        }
    }

    private func updateLivePreview(_ recorder: MeetingRecorder) async {
        guard prefs.showLiveTranscript, !dictation.isRecording, dictation.modelStatus.isReady else { return }
        let (local, remote) = recorder.recent(seconds: 8)
        let recentL = AudioAnalysis.rms(Array(local.suffix(48_000))), recentR = AudioAnalysis.rms(Array(remote.suffix(48_000)))
        guard max(recentL, recentR) > 0.004 else { return }
        let remoteTalking = recentR >= recentL * 0.6
        let samples = remoteTalking ? remote : local
        guard let transcript = try? await dictation.engine.transcribe(samples, boostVocabulary: false),
              !transcript.text.isEmpty
        else { return }
        var speaker = "You"
        if remoteTalking {
            speaker = "Speaker"
            if !liveVoices.isEmpty, let result = try? await diarizer.diarize(samples),
               let last = result.spans.max(by: { $0.end < $1.end }), let embedding = result.embeddings[last.speakerKey],
               let match = VoiceMatching.bestMatches(clusters: ["x": embedding], voices: liveVoices)["x"],
               match.distance <= NameVoting.Config().voiceThreshold,
               let person = try? store?.person(match.personID) {
                speaker = person.displayName
            }
        }
        guard island.phase == .meeting else { return }
        island.meetingSpeaker = speaker
        island.previewText = transcript.text
    }

    // MARK: Naming signals (captions, meeting window)

    private func startSignalReaders(call: MeetingDetector.Call?) {
        signalTask?.cancel()
        guard let call, prefs.readCaptions || prefs.readMeetingWindow else { return }
        let readCaptions = prefs.readCaptions
        signalTask = Task { [weak self] in
            let captions = CaptionReader(pid: call.pid)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let recorder = self.recorder else { return }
                if readCaptions {
                    for line in captions.poll() {
                        self.signals.append(NameSignal(time: recorder.elapsed, name: line.name, source: .captions, text: line.text))
                    }
                }
            }
        }
        if prefs.readMeetingWindow, let id = recordingMeetingID {
            // Names on the meeting window become suggestions in the Choose name… picker.
            ScreenSpeaker.shared.start(pid: call.pid) { [weak self] names in
                guard let self, let store = self.store else { return }
                var roster = ((try? store.roster(id)) ?? []).filter { $0.source == .calendar }
                let known = roster.map(\.name)
                for name in names.sorted() where !known.contains(where: { NameMatcher.score($0, name) >= 0.9 }) {
                    roster.append(RosterEntry(meetingID: id, name: name, source: .window))
                }
                try? store.setRoster(id, roster + ((try? store.roster(id)) ?? []).filter { $0.source == .window && !names.contains($0.name) })
            }
        }
    }

    private func saveSignals(_ signals: [NameSignal], for id: UUID) {
        ScreenSpeaker.shared.stop()
        guard !signals.isEmpty, let data = try? JSONEncoder().encode(signals) else { return }
        try? data.write(to: Self.folder(for: id).appending(path: "signals.json"), options: [.atomic, .completeFileProtection])
    }

    private func loadSignals(for id: UUID) -> [NameSignal] {
        guard let data = try? Data(contentsOf: Self.folder(for: id).appending(path: "signals.json")) else { return [] }
        return (try? JSONDecoder().decode([NameSignal].self, from: data)) ?? []
    }

    // MARK: Processing (spec §8)

    private func enqueue(_ id: UUID) {
        if !processingQueue.contains(id) { processingQueue.append(id) }
        guard processTask == nil else { return }
        processTask = Task { [weak self] in
            while let self, let next = self.processingQueue.first {
                await self.process(next)
                self.processingQueue.removeFirst()
            }
            self?.processTask = nil
        }
    }

    func retry(_ id: UUID) {
        _ = try? store?.updateMeeting(id) { $0.stage = .transcribing; $0.failure = nil }
        enqueue(id)
    }

    private func resumeUnfinished() {
        for meeting in (try? store?.unfinishedMeetings()) ?? [] {
            let folder = Self.folder(for: meeting.id)
            let hasAudio = FileManager.default.fileExists(atPath: folder.appending(path: "local.caf").path)
            if meeting.stage == .recording {
                guard hasAudio, let tracks = try? MeetingRecorder.loadTracks(in: folder), !tracks.local.isEmpty else {
                    _ = try? store?.updateMeeting(meeting.id) { $0.stage = .failed; $0.failure = "The recording was interrupted." }
                    continue
                }
                let seconds = Double(tracks.local.count) / Double(AudioAnalysis.sampleRate)
                _ = try? store?.updateMeeting(meeting.id) { $0.endedAt = $0.startedAt.addingTimeInterval(seconds) }
            }
            AppLog.info("Resuming meeting processing (\(meeting.stage.rawValue))")
            enqueue(meeting.id)
        }
    }

    /// Runs the whole pipeline for one meeting; every stage is saved before the next.
    func process(_ id: UUID) async {
        guard let store, var meeting = try? store.meeting(id) else { return }
        let folder = Self.folder(for: id)
        do {
            // Transcribe + diarize, unless an earlier run already saved the transcript.
            let hasTranscript = !(try store.segments(id)).isEmpty
            if meeting.stage == .recording || meeting.stage == .transcribing || meeting.stage == .diarizing || !hasTranscript {
                await dictation.waitUntilModelSettles()
                guard dictation.modelStatus.isReady else { throw MeetingError.modelUnavailable }
                setStage(id, .transcribing)
                let tracks = try MeetingRecorder.loadTracks(in: folder)
                guard !tracks.local.isEmpty || !tracks.remote.isEmpty else { throw MeetingError.noAudio }
                let output = try await MeetingPipeline.run(
                    local: tracks.local, remote: tracks.remote, engine: dictation.engine, diarizer: diarizer,
                    boostVocabulary: !dictation.settings.vocabulary.isEmpty
                ) { [weak self] stage in
                    await MainActor.run { self?.setStage(id, stage == .diarizing ? .diarizing : .transcribing) }
                }
                try saveTranscript(id, output: output)
                try? JSONEncoder().encode(SavedSpans(spans: output.spans.map { [$0.start, $0.end] },
                                                     keys: output.spans.map(\.speakerKey)))
                    .write(to: folder.appending(path: "spans.json"))
                AppLog.info(String(format: "Meeting transcribed: %d segments, %d remote speakers, %.0f s echo removed%@",
                                   output.texts.count, output.embeddings.count, output.echoSecondsRemoved,
                                   output.diarizationFailed ? ", diarization fell back" : ""))
            }

            setStage(id, .identifying)
            try identifySpeakers(id)

            setStage(id, .summarizing)
            try await summarize(id)

            meeting = try store.meeting(id) ?? meeting
            try applyRetention(meeting)
            setStage(id, .done)
            try writeMarkdownCopy(id)
            if let done = try store.meeting(id), recordingMeetingID != id {
                Notifier.shared.post(id: "ready-\(id)", title: "Notes ready", body: done.title, category: "NOTES_READY",
                                     userInfo: ["meetingID": id.uuidString])
            }
        } catch {
            AppLog.error("Meeting processing failed: \(error)")
            _ = try? store.updateMeeting(id) { $0.stage = .failed; $0.failure = error.localizedDescription }
        }
    }

    enum MeetingError: LocalizedError {
        case modelUnavailable, noAudio
        var errorDescription: String? {
            switch self {
            case .modelUnavailable: "The speech model isn't loaded."
            case .noAudio: "No audio was recorded."
            }
        }
    }

    struct SavedSpans: Codable { var spans: [[Double]]; var keys: [String] }

    private func setStage(_ id: UUID, _ stage: ProcessingStage) {
        _ = try? store?.updateMeeting(id) { $0.stage = stage }
    }

    private func saveTranscript(_ id: UUID, output: MeetingPipeline.Output) throws {
        guard let store else { return }
        let me = try store.me(defaultName: prefs.myName ?? NSFullUserName())
        var speakers: [MeetingSpeaker] = []
        if output.texts.contains(where: { $0.speakerKey == MeetingSpeaker.meKey }) {
            speakers.append(MeetingSpeaker(meetingID: id, speakerKey: MeetingSpeaker.meKey, label: "Me", personID: me.id,
                                           source: .me, talkSeconds: output.talkSeconds[MeetingSpeaker.meKey] ?? 0))
        }
        let remoteKeys = output.spans.map(\.speakerKey).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        for (i, key) in remoteKeys.enumerated() {
            let label = output.diarizationFailed ? "Others" : "Speaker \(i + 2)"
            speakers.append(MeetingSpeaker(meetingID: id, speakerKey: key, label: label,
                                           talkSeconds: output.talkSeconds[key] ?? 0, embedding: output.embeddings[key]))
        }
        let segments = output.texts.map {
            Segment(meetingID: id, speakerKey: $0.speakerKey, start: $0.start, end: $0.end, text: $0.text)
        }
        try store.saveFinalTranscript(meetingID: id, segments: segments, speakers: speakers)
    }

    private func loadSpans(_ id: UUID) -> [SpeakerSpan] {
        guard let data = try? Data(contentsOf: Self.folder(for: id).appending(path: "spans.json")),
              let saved = try? JSONDecoder().decode(SavedSpans.self, from: data)
        else { return [] }
        return zip(saved.spans, saved.keys).compactMap { span, key in
            span.count == 2 ? SpeakerSpan(speakerKey: key, start: span[0], end: span[1]) : nil
        }
    }

    /// Names voices (spec §10.3) and learns voices that were named by evidence.
    private func identifySpeakers(_ id: UUID) throws {
        guard let store else { return }
        let speakers = try store.speakers(id).filter { !$0.isMe && !$0.isIgnored }
        guard !speakers.isEmpty else { return }
        let segments = try store.segments(id)
        let roster = try store.roster(id).filter { !$0.isMe }
        let invitees = roster.filter { $0.source == .calendar }
        var spans = loadSpans(id)
        if spans.isEmpty {
            spans = segments.filter { $0.speakerKey != MeetingSpeaker.meKey }
                .map { SpeakerSpan(speakerKey: $0.speakerKey, start: $0.start, end: $0.end) }
        }
        let voices = prefs.rememberVoices == true ? try store.voices(model: MeetingDiarizer.embeddingModelID) : []
        let clusters = Dictionary(uniqueKeysWithValues: speakers.compactMap { s in s.embedding.map { (s.speakerKey, $0) } })
        var fixed: [String: NameVoting.Identity] = [:]
        for s in speakers where s.source == .user { if let p = s.personID { fixed[s.speakerKey] = .person(p) } }
        let input = NameVoting.Input(
            spans: spans,
            texts: segments.map { TimedText(speakerKey: $0.speakerKey, start: $0.start, end: $0.end, text: $0.text) },
            voiceMatches: VoiceMatching.bestMatches(clusters: clusters, voices: voices),
            signals: loadSignals(for: id), rosterNames: invitees.map(\.name), fixed: fixed)
        for (key, assignment) in NameVoting.assign(input) where assignment.source != .user {
            let person: Person
            switch assignment.identity {
            case let .person(pid):
                guard let p = try store.person(pid) else { continue }
                person = p
            case let .name(name):
                let email = roster.first { NameMatcher.score($0.name, name) >= 0.9 }?.email
                person = try store.findPerson(name: name, email: email) ?? store.createPerson(name: name, email: email)
                try store.addIdentifier(person.id, kind: .alias, value: name)
            }
            try store.assign(meetingID: id, speakerKey: key, personID: person.id, source: assignment.source,
                             confidence: assignment.confidence)
            if assignment.source != .calendarSingleCandidate { learnVoice(meetingID: id, speakerKey: key, personID: person.id) }
        }
        if prefs.rememberVoices != true { try store.clearSpeakerEmbeddings(id) }
    }

    /// Speech needed before a voice is saved; diarizer embeddings are stable well before this.
    static let minVoiceSeconds = 8.0

    private func learnVoice(meetingID: UUID, speakerKey: String, personID: UUID) {
        guard prefs.rememberVoices == true, let store,
              let speaker = try? store.speakers(meetingID).first(where: { $0.speakerKey == speakerKey }),
              let embedding = speaker.embedding, speaker.talkSeconds >= Self.minVoiceSeconds
        else { return }
        try? store.addVoice(Voice(personID: personID, embedding: embedding, model: MeetingDiarizer.embeddingModelID,
                                  sourceMeetingID: meetingID))
    }

    private func summarize(_ id: UUID) async throws {
        guard let store, let doc = try store.document(id) else { return }
        let provider = SummaryProvider(rawValue: prefs.summaryProvider) ?? .automatic
        guard let summarizer = SummarizerFactory.make(provider, claudeAPIKey: Keychain.load()) else {
            try store.saveNotes(meetingID: id, summary: nil, provider: nil, actions: [], notes: [])
            return
        }
        let visible = doc.visibleSegments
        let input = SummaryInput(
            title: doc.meeting.title,
            lines: visible.map { .init(speakerKey: $0.speakerKey, speakerName: doc.name(forSpeaker: $0.speakerKey),
                                       start: $0.start, text: $0.text) },
            speakers: Dictionary(uniqueKeysWithValues: doc.speakers.filter { !$0.isIgnored }
                .map { ($0.speakerKey, doc.name(forSpeaker: $0.speakerKey)) }))
        var notes: MeetingNotes
        var providerID = summarizer.providerID
        do {
            notes = try await summarizer.summarize(input)
        } catch {
            // Never leave a meeting without notes: fall back to the built-in extractor.
            AppLog.error("Summarizer \(summarizer.providerID) failed: \(error); using the built-in extractor")
            notes = RuleBasedSummarizer.extract(input)
            providerID = "builtin"
        }
        let personFor = Dictionary(uniqueKeysWithValues: doc.speakers.map { ($0.speakerKey, $0.personID) })
        let actions = notes.actionItems.enumerated().map { i, a in
            ActionItem(meetingID: id, text: a.text, ownerPersonID: a.ownerSpeakerKey.flatMap { personFor[$0] ?? nil },
                       ownerSpeakerKey: a.ownerSpeakerKey, due: a.due,
                       sourceSegmentID: a.sourceSegmentIndex.flatMap { visible.indices.contains($0) ? visible[$0].id : nil },
                       position: i)
        }
        let items = notes.decisions.enumerated().map { i, d in
            NoteItem(meetingID: id, kind: .decision, text: d.text,
                     sourceSegmentID: d.sourceSegmentIndex.flatMap { visible.indices.contains($0) ? visible[$0].id : nil }, position: i)
        } + notes.openQuestions.enumerated().map { i, q in
            NoteItem(meetingID: id, kind: .question, text: q.text,
                     sourceSegmentID: q.sourceSegmentIndex.flatMap { visible.indices.contains($0) ? visible[$0].id : nil }, position: i)
        }
        try store.saveNotes(meetingID: id, summary: notes.summary.isEmpty ? nil : notes.summary, provider: providerID,
                            actions: actions, notes: items)
    }

    func resummarize(_ id: UUID) {
        Task {
            setStage(id, .summarizing)
            try? await summarize(id)
            setStage(id, .done)
            try? writeMarkdownCopy(id)
        }
    }

    // MARK: Retention (spec §11.2)

    private func applyRetention(_ meeting: Meeting) throws {
        let folder = Self.folder(for: meeting.id)
        switch prefs.audioRetention {
        case .deleteAfterProcessing:
            for name in ["local.caf", "remote.caf", "local.m4a", "remote.m4a"] {
                try? FileManager.default.removeItem(at: folder.appending(path: name))
            }
            try store?.updateMeeting(meeting.id) { $0.audioRetained = false; $0.audioExpiresAt = nil }
        case .keep7Days, .keepUntilDeleted:
            MeetingRecorder.compressAudio(in: folder)
            let expires = prefs.audioRetention == .keep7Days ? Date().addingTimeInterval(7 * 86_400) : nil
            try store?.updateMeeting(meeting.id) { $0.audioRetained = true; $0.audioExpiresAt = expires }
        }
    }

    private func cleanUpExpiredAudio() {
        guard let store else { return }
        for meeting in (try? store.meetings()) ?? [] where meeting.audioRetained {
            guard let expires = meeting.audioExpiresAt, expires < Date() else { continue }
            let folder = Self.folder(for: meeting.id)
            for name in ["local.m4a", "remote.m4a", "local.caf", "remote.caf"] {
                try? FileManager.default.removeItem(at: folder.appending(path: name))
            }
            _ = try? store.updateMeeting(meeting.id) { $0.audioRetained = false; $0.audioExpiresAt = nil }
        }
    }

    // MARK: Editing

    enum NameChoice: Hashable {
        case person(UUID)
        case newPerson(name: String, email: String?)
        case ignore
    }

    /// The Choose name… picker (spec §4.5). Always wins over automatic naming.
    func name(meetingID: UUID, speakerKey: String, as choice: NameChoice) {
        guard let store else { return }
        do {
            switch choice {
            case let .person(pid):
                try store.assign(meetingID: meetingID, speakerKey: speakerKey, personID: pid, source: .user, confidence: 1)
                learnVoice(meetingID: meetingID, speakerKey: speakerKey, personID: pid)
            case let .newPerson(name, email):
                let person = try store.findPerson(name: name, email: email) ?? store.createPerson(name: name, email: email)
                try store.assign(meetingID: meetingID, speakerKey: speakerKey, personID: person.id, source: .user, confidence: 1)
                learnVoice(meetingID: meetingID, speakerKey: speakerKey, personID: person.id)
            case .ignore:
                if var speaker = try store.speakers(meetingID).first(where: { $0.speakerKey == speakerKey }) {
                    speaker.label = MeetingSpeaker.ignoredLabel
                    speaker.personID = nil
                    speaker.source = .user
                    try store.updateSpeaker(speaker)
                }
            }
            try writeMarkdownCopy(meetingID)
        } catch {
            AppLog.error("Naming failed: \(error)")
        }
    }

    func setActionItem(_ item: ActionItem, done: Bool) {
        try? store?.setActionItem(item.id, done: done)
        try? writeMarkdownCopy(item.meetingID)
    }

    func delete(_ id: UUID, deleteMarkdown: Bool) {
        guard let store else { return }
        if deleteMarkdown, let path = (try? store.meeting(id))?.markdownPath { try? FileManager.default.removeItem(atPath: path) }
        try? store.deleteMeeting(id)
        try? FileManager.default.removeItem(at: Self.folder(for: id))
    }

    func markdown(_ id: UUID, includePrivateNotes: Bool) -> String? {
        guard let doc = try? store?.document(id) else { return nil }
        return MarkdownExporter.render(doc, includePrivateNotes: includePrivateNotes)
    }

    func copyMarkdown(_ id: UUID, includePrivateNotes: Bool = false) {
        guard let text = markdown(id, includePrivateNotes: includePrivateNotes) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Markdown copy (spec §12.6)

    var markdownFolder: URL? {
        guard let data = prefs.markdownFolderBookmark else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withoutUI], bookmarkDataIsStale: &stale)
    }

    func setMarkdownFolder(_ url: URL?) {
        updatePrefs { $0.markdownFolderBookmark = try? url?.bookmarkData() }
    }

    private func writeMarkdownCopy(_ id: UUID) throws {
        guard prefs.markdownCopy, let folder = markdownFolder, let store, let doc = try store.document(id),
              doc.meeting.stage == .done
        else { return }
        let path = try MarkdownCopy.write(doc, to: folder, previousPath: doc.meeting.markdownPath)
        if path != doc.meeting.markdownPath { try store.updateMeeting(id) { $0.markdownPath = path } }
    }

    // MARK: Calendar

    func enableCalendar() async {
        let granted = await calendar.requestAccess()
        calendarAuthorized = granted
        updatePrefs { $0.useCalendar = granted }
    }

    func calendarAttendees(for meetingID: UUID) -> [RosterEntry] {
        ((try? store?.roster(meetingID)) ?? []).filter { !$0.isMe }
    }
}
