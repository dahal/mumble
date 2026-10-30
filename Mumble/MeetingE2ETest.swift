import AppKit
import AVFoundation
import CoreAudio
import MumbleASR
import MumbleCore
import MumbleStore

/// Acoustic end-to-end test of meeting notes on this Mac:
///
///   Mumble --e2e-meeting <result-file>
///
/// Two synthetic participants (Samantha, Daniel) play from an `afplay` process that Mumble records
/// with a real Core Audio process tap. "You" (Karen) play from a second `afplay` through the
/// speakers, so the real microphone hears you and the echo of the others. Uses a temporary database
/// and folder; your settings are restored afterwards. Nothing is pasted anywhere.
@MainActor
enum MeetingE2ETest {
    struct Line {
        let voice: String
        let text: String
        var isMe: Bool { voice == "Karen" }
    }

    static let meeting1 = [
        Line(voice: "Samantha", text: "So the new annual plan is live on staging. Should we show the monthly price crossed out, or just a savings badge?"),
        Line(voice: "Daniel", text: "Crossed out tested better last time. Conversion was up about eight percent on the checkout experiment."),
        Line(voice: "Karen", text: "Okay, let's go with crossed out. Can you ship it behind the flag by Friday?"),
        Line(voice: "Samantha", text: "Yes, I will do that. I also want to update the pricing copy on the landing page."),
        Line(voice: "Daniel", text: "I will send the experiment numbers to everyone this afternoon."),
        Line(voice: "Karen", text: "Great. I will ask legal about grandfathering the old plan before Friday."),
        Line(voice: "Samantha", text: "What do we tell customers who already paid for the monthly plan this year?"),
        Line(voice: "Daniel", text: "Let's check in again next Tuesday and decide that with support."),
    ]

    static let meeting2 = [
        Line(voice: "Daniel", text: "Morning everyone, quick update on the billing migration before we start the review."),
        Line(voice: "Samantha", text: "Thanks. The design review moved to Thursday afternoon, so please plan around it."),
        Line(voice: "Karen", text: "Sounds good. I will move our sync to Friday morning."),
        Line(voice: "Daniel", text: "I will also share the dashboard numbers after lunch today."),
        Line(voice: "Samantha", text: "Perfect, and let's keep the meeting short today because of the launch."),
    ]

    private static var lines: [String] = []
    private static var resultURL: URL!
    private static var failures = 0

    private static func report(_ line: String) {
        lines.append(line)
        AppLog.info("E2E-MEETING " + line)
        print(line)
        try? lines.joined(separator: "\n").appending("\n").write(to: resultURL, atomically: true, encoding: .utf8)
    }

    private static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if !ok { failures += 1 }
        report("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : ": " + detail())")
    }

    static func run(_ dictation: DictationController, resultURL: URL) async {
        self.resultURL = resultURL
        let savedSettings = UserDefaults.standard.data(forKey: DictationController.settingsKey)
        let work = FileManager.default.temporaryDirectory.appending(path: "mumble-e2e-meeting-\(UUID().uuidString)")
        defer {
            // Restore the user's settings exactly.
            if let savedSettings { UserDefaults.standard.set(savedSettings, forKey: DictationController.settingsKey) }
            try? FileManager.default.removeItem(at: work)
        }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            MeetingController.meetingsFolderOverride = work.appending(path: "Meetings")
            let store = try MeetingStore(url: work.appending(path: "Mumble.sqlite"))
            let meetings = MeetingController(dictation: dictation, store: store)
            dictation.update {
                $0.meetings.showConsentSheet = false
                $0.meetings.rememberVoices = true
                $0.meetings.useCalendar = false
                $0.meetings.readCaptions = false
                $0.meetings.readMeetingWindow = false
                $0.meetings.summaryProvider = "builtin"
                $0.meetings.audioRetention = .deleteAfterProcessing
                $0.meetings.markdownCopy = true
                $0.meetings.catchTheStart = false
                $0.meetings.remindOnDetect = true
            }
            try FileManager.default.createDirectory(at: work.appending(path: "Notes"), withIntermediateDirectories: true)
            meetings.setMarkdownFolder(work.appending(path: "Notes"))
            guard meetings.markdownFolder != nil else { throw E2EError("couldn't set the Markdown folder") }
            dictation.start()
            meetings.start()
            await dictation.waitUntilModelSettles()
            guard dictation.modelStatus.isReady else { throw E2EError("model not ready: \(dictation.modelStatus)") }
            report("Model ready; mic: \(dictation.testInputDeviceName); output volume must be audible")

            // Meeting 1: record, process, check.
            let first = try await record(meeting1, title: "E2E pricing sync", meetings: meetings, store: store, work: work)
            try verifyMeeting1(first, store: store, meetings: meetings)

            // Name the two voices; meeting 2 should recognize them from their saved voices.
            let speakers = try store.speakers(first).filter { !$0.isMe }
            let samanthaKey = try voiceKey(store: store, meetingID: first, spokenWords: "staging annual plan")
            let danielKey = try voiceKey(store: store, meetingID: first, spokenWords: "experiment numbers afternoon")
            meetings.name(meetingID: first, speakerKey: samanthaKey, as: .newPerson(name: "Sarah Chen", email: "sarah@example.com"))
            meetings.name(meetingID: first, speakerKey: danielKey, as: .newPerson(name: "Dev Patel", email: nil))
            let voiceCount = try store.voiceCount()
            check(voiceCount == 2, "naming saves two voices", "voices: \(voiceCount), speakers \(speakers.map(\.speakerKey))")
            let doc1 = try store.document(first)
            check(doc1?.participantNames.contains("Sarah Chen") == true && doc1?.participantNames.contains("Dev Patel") == true,
                  "named speakers appear in the transcript", "\(doc1?.participantNames ?? [])")

            let second = try await record(meeting2, title: "E2E design sync", meetings: meetings, store: store, work: work)
            let doc2 = try store.document(second)
            let auto = doc2?.speakers.filter { $0.source == .voice }.compactMap { $0.personID.flatMap { doc2?.people[$0]?.displayName } } ?? []
            check(Set(auto) == ["Sarah Chen", "Dev Patel"], "second meeting names both voices automatically", "auto-named: \(auto)")
            let billingLine = doc2?.visibleSegments.first { $0.text.lowercased().contains("billing") }
            check(billingLine.map { doc2?.name(forSpeaker: $0.speakerKey) } == "Dev Patel", "lines carry the recognized names",
                  billingLine.map { doc2?.name(forSpeaker: $0.speakerKey) ?? "?" } ?? "no billing line")

            // Search and Markdown copy.
            let hits = try store.search("dashboard numbers")
            check(hits.first?.meetingID == second, "search finds the meeting", "\(hits.map(\.meetingTitle))")
            let copies = (try? FileManager.default.contentsOfDirectory(atPath: work.appending(path: "Notes").path)) ?? []
            check(copies.count == 2, "Markdown copies written", "\(copies)")
            if let path = try store.meeting(second)?.markdownPath, let md = try? String(contentsOfFile: path, encoding: .utf8) {
                check(md.contains("**Dev Patel**") && md.contains("## Transcript"), "Markdown copy has names and transcript")
            } else {
                check(false, "Markdown copy readable")
            }
            check(!FileManager.default.fileExists(atPath: MeetingController.folder(for: second).appending(path: "remote.caf").path),
                  "audio deleted after processing")

            // Catch the start: a detected call, audio held in memory, then Take Notes keeps it.
            dictation.update { $0.meetings.catchTheStart = true }
            try await catchTheStart(meetings: meetings, store: store, work: work)

            report(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        } catch {
            report("FAIL \(error)")
            exit(1)
        }
    }

    struct E2EError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    // MARK: Audio

    static func speech(_ text: String, voice: String, dir: URL) throws -> [Float] {
        let wav = dir.appending(path: "\(UUID().uuidString).wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "-o", wav.path, "--file-format=WAVE", "--data-format=LEF32@16000", text]
        try say.run()
        say.waitUntilExit()
        let data = try Data(contentsOf: wav)
        try? FileManager.default.removeItem(at: wav)
        guard let range = data.range(of: Data("data".utf8)) else { return [] }
        return data[(range.upperBound + 4)...].withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Two aligned WAV tracks (remote: the others; mine: you), with silence where the other track talks.
    static func tracks(_ script: [Line], dir: URL, lead: Double = 1.5) throws -> (remote: URL, mine: URL, myText: String, otherText: String) {
        var remote = [Float](repeating: 0, count: Int(lead * 16_000)), mine = remote
        let gap = [Float](repeating: 0, count: 14_000)
        for line in script {
            let samples = try speech(line.text, voice: line.voice, dir: dir)
            if line.isMe {
                mine += samples
                remote += [Float](repeating: 0, count: samples.count)
            } else {
                remote += samples
                mine += [Float](repeating: 0, count: samples.count)
            }
            remote += gap
            mine += gap
        }
        let r = dir.appending(path: "remote-\(UUID().uuidString).wav"), m = dir.appending(path: "mine-\(UUID().uuidString).wav")
        try write(remote, to: r)
        try write(mine, to: m)
        return (r, m, script.filter(\.isMe).map(\.text).joined(separator: " "), script.filter { !$0.isMe }.map(\.text).joined(separator: " "))
    }

    static func write(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                                                                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                                                AVLinearPCMIsFloatKey: false])
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }

    /// Plays "your" track through the built-in speakers so the real microphone hears it, even when
    /// the default output is a Bluetooth headset.
    final class SpeakerPlayer {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        private(set) var isPlaying = false

        init(url: URL) throws {
            let file = try AVAudioFile(forReading: url)
            engine.attach(node)
            if let speakers = Self.builtInOutput(), let unit = engine.outputNode.audioUnit {
                var id = speakers
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                     UInt32(MemoryLayout<AudioDeviceID>.size))
            }
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            try engine.start()
            isPlaying = true
            node.scheduleFile(file, at: nil) { [weak self] in self?.isPlaying = false }
            node.play()
        }

        func stop() {
            node.stop()
            engine.stop()
        }

        static func builtInOutput() -> AudioDeviceID? {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
            var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
            return ids.first { id in
                var transport: UInt32 = 0
                var tSize = UInt32(MemoryLayout<UInt32>.size)
                var tAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                          mElement: kAudioObjectPropertyElementMain)
                AudioObjectGetPropertyData(id, &tAddress, 0, nil, &tSize, &transport)
                var streams: UInt32 = 0
                var sAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
                                                          mElement: kAudioObjectPropertyElementMain)
                AudioObjectGetPropertyDataSize(id, &sAddress, 0, nil, &streams)
                return transport == kAudioDeviceTransportTypeBuiltIn && streams > 0
            }
        }
    }

    static func play(_ url: URL) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = [url.path]
        try p.run()
        return p
    }

    // MARK: Meetings

    /// Plays a scripted meeting and records it like a real call (tap on the "others" process).
    static func record(_ script: [Line], title: String, meetings: MeetingController, store: MeetingStore, work: URL) async throws -> UUID {
        let (remoteURL, mineURL, myText, otherText) = try tracks(script, dir: work)
        let remote = try play(remoteURL)
        try await Task.sleep(for: .milliseconds(150))
        let call = MeetingDetector.Call(app: .other("afplay"), bundlePrefixes: [], url: nil, appName: "afplay", pid: remote.processIdentifier)
        meetings.startRecording(detected: .init(app: .other("afplay"), url: nil, title: title), call: call)
        let mine = try SpeakerPlayer(url: mineURL)
        defer { mine.stop() }
        guard let id = meetings.recordingMeetingID else { throw E2EError("recording didn't start") }
        report("Recording \(title)…")
        var bookmarked = false
        while remote.isRunning || mine.isPlaying {
            try await Task.sleep(for: .milliseconds(250))
            if !bookmarked, meetings.elapsed > 8 { meetings.bookmark(); bookmarked = true }
        }
        try await Task.sleep(for: .seconds(1))
        meetings.stop()
        let started = Date()
        while let m = try store.meeting(id), !m.stage.isFinal {
            if Date().timeIntervalSince(started) > 300 { throw E2EError("processing timed out at \(m.stage)") }
            try await Task.sleep(for: .milliseconds(500))
        }
        let meeting = try store.meeting(id)
        report(String(format: "Processed %@ in %.1f s (stage %@)", title, Date().timeIntervalSince(started), meeting?.stage.rawValue ?? "?"))
        check(meeting?.stage == .done, "\(title): processing finished", meeting?.failure ?? "")
        let doc = try store.document(id)
        let mineText = doc?.visibleSegments.filter { $0.speakerKey == MeetingSpeaker.meKey }.map(\.text).joined(separator: " ") ?? ""
        let othersText = doc?.visibleSegments.filter { $0.speakerKey != MeetingSpeaker.meKey }.map(\.text).joined(separator: " ") ?? ""
        let myWER = WordErrorRate.compute(reference: myText, hypothesis: mineText).rate
        let otherWER = WordErrorRate.compute(reference: otherText, hypothesis: othersText).rate
        report(String(format: "  your lines WER %.2f: %@", myWER, mineText))
        report(String(format: "  others' lines WER %.2f", otherWER))
        check(otherWER < 0.2, "\(title): others transcribed from the tap", String(format: "WER %.2f: %@", otherWER, othersText))
        check(myWER < 0.35, "\(title): your lines transcribed from the microphone", String(format: "WER %.2f", myWER))
        check(doc?.marks.contains { $0.kind == .bookmark } == true, "\(title): bookmark saved")
        return id
    }

    static func voiceKey(store: MeetingStore, meetingID: UUID, spokenWords: String) throws -> String {
        let words = Set(WordErrorRate.normalizedWords(spokenWords))
        let best = try store.segments(meetingID).filter { $0.speakerKey != MeetingSpeaker.meKey }
            .max { Set(WordErrorRate.normalizedWords($0.text)).intersection(words).count < Set(WordErrorRate.normalizedWords($1.text)).intersection(words).count }
        guard let key = best?.speakerKey else { throw E2EError("no segment with \(spokenWords)") }
        return key
    }

    static func verifyMeeting1(_ id: UUID, store: MeetingStore, meetings: MeetingController) throws {
        guard let doc = try store.document(id) else { throw E2EError("meeting missing") }
        let remoteKeys = Set(doc.speakers.filter { !$0.isMe }.map(\.speakerKey))
        check(remoteKeys.count == 2, "two remote speakers found", "\(remoteKeys)")
        let stagingKey = try voiceKey(store: store, meetingID: id, spokenWords: "staging annual plan")
        let numbersKey = try voiceKey(store: store, meetingID: id, spokenWords: "experiment numbers afternoon")
        check(stagingKey != numbersKey, "Samantha and Daniel are different speakers")
        let mine = doc.visibleSegments.filter { $0.speakerKey == MeetingSpeaker.meKey }.map(\.text).joined(separator: " ").lowercased()
        check(!mine.contains("eight percent") && !mine.contains("staging"), "speaker echo isn't attributed to you", mine)
        check(doc.meeting.summary?.isEmpty == false, "summary written", doc.meeting.summary ?? "nil")
        check(!doc.actionItems.isEmpty, "action items found", "\(doc.actionItems.map(\.text))")
        let legal = doc.actionItems.first { $0.text.lowercased().contains("legal") }
        check(legal.flatMap { doc.ownerName($0) } == "Me", "your commitment is owned by you", "\(doc.actionItems.map { ($0.text, doc.ownerName($0) ?? "-") })")
        check(doc.noteItems.contains { $0.kind == .decision }, "decision found", "\(doc.noteItems.map(\.text))")
        report("  summary: \(doc.meeting.summary ?? "")")
        for item in doc.actionItems { report("  action: [\(doc.ownerName(item) ?? "-")] \(item.text)") }
        for item in doc.noteItems { report("  \(item.kind.rawValue): \(item.text)") }
    }

    /// R4: the call is detected, audio is held in memory while Mumble asks, then Take Notes keeps it.
    static func catchTheStart(meetings: MeetingController, store: MeetingStore, work: URL) async throws {
        let script = [Line(voice: "Daniel", text: "Before you started taking notes, I said the budget review is on Monday."),
                      Line(voice: "Samantha", text: "And after that we can talk about hiring for the new team.")]
        let (remoteURL, _, _, _) = try tracks(script, dir: work, lead: 0.5)
        let remote = try play(remoteURL)
        try await Task.sleep(for: .milliseconds(150))
        meetings.callStarted(MeetingDetector.Call(app: .other("afplay"), bundlePrefixes: [], url: nil, appName: "afplay",
                                                  pid: remote.processIdentifier))
        check(meetings.askingTitle != nil, "a detected call asks to take notes")
        try await Task.sleep(for: .seconds(6))   // Daniel's line plays while Mumble is asking
        meetings.takeNotes()
        guard let id = meetings.recordingMeetingID else { throw E2EError("take notes didn't start recording") }
        while remote.isRunning { try await Task.sleep(for: .milliseconds(250)) }
        try await Task.sleep(for: .seconds(1))
        meetings.stop()
        while let m = try store.meeting(id), !m.stage.isFinal { try await Task.sleep(for: .milliseconds(500)) }
        let text = try store.segments(id).map(\.text).joined(separator: " ").lowercased()
        check(text.contains("budget"), "catch the start keeps what was said before Take Notes", text)
        check(text.contains("hiring"), "recording continues after Take Notes", text)

        // Not Now wipes the held audio and records nothing.
        let again = try play(remoteURL)
        try await Task.sleep(for: .milliseconds(150))
        meetings.callStarted(MeetingDetector.Call(app: .other("afplay"), bundlePrefixes: [], url: "e2e://second", appName: "afplay",
                                                  pid: again.processIdentifier))
        try await Task.sleep(for: .seconds(3))
        let before = try store.meetings().count
        meetings.notNow()
        again.terminate()
        let after = try store.meetings().count
        check(!meetings.isRecording && after == before, "Not Now records nothing")
    }
}
