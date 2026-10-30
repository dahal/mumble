import Foundation
import Testing
@testable import MumbleCore

@Suite struct MeetingLinkTests {
    @Test func recognizesMeetingURLs() {
        #expect(MeetingLink.app(forURL: "https://meet.google.com/abc-defg-hij") == .meet)
        #expect(MeetingLink.app(forURL: "meet.google.com/abc-defg-hij?authuser=1") == .meet)
        #expect(MeetingLink.app(forURL: "https://meet.google.com/landing") == nil)
        #expect(MeetingLink.app(forURL: "https://acme.zoom.us/j/81234567890?pwd=x") == .zoom)
        #expect(MeetingLink.app(forURL: "https://app.zoom.us/wc/81234567890/join") == .zoom)
        #expect(MeetingLink.app(forURL: "https://zoom.us/pricing") == nil)
        #expect(MeetingLink.app(forURL: "https://teams.microsoft.com/l/meetup-join/19%3ameeting") == .teams)
        #expect(MeetingLink.app(forURL: "https://app.slack.com/huddle/T123/C456") == .slack)
        #expect(MeetingLink.app(forURL: "https://example.com/meet/abc") == nil)
    }

    @Test func recognizesApps() {
        #expect(MeetingLink.app(forBundleID: "us.zoom.xos") == .zoom)
        #expect(MeetingLink.app(forBundleID: "com.microsoft.teams2") == .teams)
        #expect(MeetingLink.app(forBundleID: "com.google.Chrome") == nil)
        #expect(MeetingLink.isBrowser("com.google.Chrome.helper"))
        #expect(!MeetingLink.isBrowser("com.apple.TextEdit"))
    }

    @Test func normalizesForComparison() {
        #expect(MeetingLink.normalize("https://meet.google.com/abc-defg-hij/?authuser=0")
                == MeetingLink.normalize("meet.google.com/ABC-DEFG-HIJ"))
        #expect(MeetingLink.normalize("https://acme.zoom.us/j/812345?pwd=1")
                == MeetingLink.normalize("https://app.zoom.us/wc/812345/join"))
    }

    @Test func findsLinkInCalendarText() {
        let notes = "Agenda: pricing.\nJoin: https://meet.google.com/abc-defg-hij\nDial-in: +1 555"
        #expect(MeetingLink.firstLink(in: notes) == "https://meet.google.com/abc-defg-hij")
        #expect(MeetingLink.firstLink(in: "See https://example.com") == nil)
    }

    @Test func rulesMatchSeriesOrLink() {
        let rule = MeetingRule(calendarSeriesID: "S1", meetingURL: "https://meet.google.com/abc-defg-hij", title: "Standup")
        #expect(rule.matches(seriesID: "S1", url: nil))
        #expect(rule.matches(seriesID: nil, url: "meet.google.com/abc-defg-hij?x=1"))
        #expect(!rule.matches(seriesID: "S2", url: "https://meet.google.com/zzz-zzzz-zzz"))
    }
}

@Suite struct NameMatcherTests {
    @Test func scoresNameVariants() {
        #expect(NameMatcher.score("Sarah Chen", "sarah chen") == 1)
        #expect(NameMatcher.score("Sarah C.", "Sarah Chen") == 0.9)
        #expect(NameMatcher.score("sarah", "Sarah Chen") == 0.75)
        #expect(NameMatcher.score("sarah.chen@acme.com", "Sarah Chen") == 1)
        #expect(NameMatcher.score("Dev Patel", "Sarah Chen") == 0)
        #expect(NameMatcher.score("José Núñez", "jose nunez") == 1)
    }

    @Test func bestMatchRejectsAmbiguousFirstNames() {
        let people = ["Sarah Chen", "Sarah Lopez", "Dev Patel"]
        #expect(NameMatcher.bestMatch(for: "Sarah", in: people, name: { $0 }) == nil)
        #expect(NameMatcher.bestMatch(for: "Sarah C.", in: people, name: { $0 }) == "Sarah Chen")
        #expect(NameMatcher.bestMatch(for: "dev", in: people, name: { $0 }) == "Dev Patel")
    }

    @Test func displayNameFromEmail() {
        #expect(NameMatcher.displayName(fromEmail: "sarah.chen@acme.com") == "Sarah Chen")
    }
}

@Suite struct TranscriptTests {
    @Test func turnsMergeDropAndSplit() {
        let spans = [
            SpeakerSpan(speakerKey: "A", start: 0, end: 3),
            SpeakerSpan(speakerKey: "A", start: 3.5, end: 6),      // merged (gap 0.5)
            SpeakerSpan(speakerKey: "B", start: 6.1, end: 6.3),    // blip dropped
            SpeakerSpan(speakerKey: "B", start: 7, end: 37),       // 30 s → split into 3
        ]
        let turns = SpeakerTurns.build(spans)
        #expect(turns.count == 4)
        #expect(turns[0] == SpeakerSpan(speakerKey: "A", start: 0, end: 6))
        #expect(turns.dropFirst().allSatisfy { $0.speakerKey == "B" && $0.duration <= 14 })
        #expect(abs(turns.last!.end - 37) < 1e-9)
    }

    @Test func overlapAndSpeakerAt() {
        let spans = [SpeakerSpan(speakerKey: "A", start: 0, end: 5), SpeakerSpan(speakerKey: "B", start: 5, end: 9)]
        #expect(SpeakerTurns.speaker(at: 6, in: spans) == "B")
        #expect(SpeakerTurns.speaker(at: 10, in: spans) == nil)
        let o = SpeakerTurns.overlap(start: 4, end: 6, in: spans)
        #expect(o["A"] == 1 && o["B"] == 1)
        #expect(SpeakerTurns.talkSeconds(spans) == ["A": 5, "B": 4])
    }

    @Test func mergeInterleavesAndJoins() {
        let merged = TranscriptMerger.merge([
            TimedText(speakerKey: "A", start: 5, end: 7, text: "and the rest."),
            TimedText(speakerKey: "me", start: 0, end: 2, text: "Hello everyone."),
            TimedText(speakerKey: "A", start: 3, end: 4.5, text: "Hi, so"),
            TimedText(speakerKey: "me", start: 8, end: 9, text: "  "),
            TimedText(speakerKey: "me", start: 10, end: 11, text: "Thanks."),
        ])
        #expect(merged.map(\.speakerKey) == ["me", "A", "me"])
        #expect(merged[1].text == "Hi, so and the rest.")
        #expect(merged[1].start == 3 && merged[1].end == 7)
    }

    @Test func mergeKeepsLongTurnsReadable() {
        let pieces = (0..<5).map { TimedText(speakerKey: "A", start: Double($0) * 10, end: Double($0) * 10 + 9.5, text: "x") }
        #expect(TranscriptMerger.merge(pieces).count > 1)
    }
}

@Suite struct EchoGateTests {
    /// Speech-like noise bursts with an envelope, deterministic.
    static func bursts(seconds: Double, seed: UInt64) -> [Float] {
        var rng = SplitMix(seed: seed)
        let n = Int(seconds * 16_000)
        return (0..<n).map { i in
            let t = Double(i) / 16_000
            let env = Float(max(0, sin(t * 2 * .pi * (1.3 + Double(seed % 3) * 0.4))))
            return env * Float.random(in: -0.3...0.3, using: &rng)
        }
    }

    @Test func detectsDelayedQuieterCopy() {
        let remote = Self.bursts(seconds: 4, seed: 1)
        // Speaker → room → mic: 30 ms later, attenuated, plus a little noise.
        var rng = SplitMix(seed: 9)
        let delay = 480
        let local = (0..<remote.count).map { i in
            (i >= delay ? remote[i - delay] * 0.2 : 0) + Float.random(in: -0.002...0.002, using: &rng)
        }
        #expect(EchoGate.isEcho(local: local, remote: remote, range: 8_000..<56_000))
    }

    @Test func ownVoiceIsNotEcho() {
        let remote = Self.bursts(seconds: 4, seed: 1)
        let local = Self.bursts(seconds: 4, seed: 2)
        #expect(!EchoGate.isEcho(local: local, remote: remote, range: 8_000..<56_000))
    }

    @Test func silentRemoteIsNeverEcho() {
        let remote = [Float](repeating: 0, count: 64_000)
        let local = Self.bursts(seconds: 4, seed: 3)
        #expect(!EchoGate.isEcho(local: local, remote: remote, range: 0..<64_000))
    }
}

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct NameVotingTests {
    let sarah = UUID(), dev = UUID()

    /// A: 0–30 s, B: 30–60 s, C: 60–75 s.
    var spans: [SpeakerSpan] {
        [SpeakerSpan(speakerKey: "A", start: 0, end: 30), SpeakerSpan(speakerKey: "B", start: 30, end: 60),
         SpeakerSpan(speakerKey: "C", start: 60, end: 75)]
    }

    @Test func savedVoicesWinAndArentReused() {
        let result = NameVoting.assign(.init(spans: spans, voiceMatches: [
            "A": .init(personID: sarah, distance: 0.2),
            "B": .init(personID: sarah, distance: 0.3),   // same person, farther: not assigned
            "C": .init(personID: dev, distance: 0.6),     // above threshold
        ]))
        #expect(result["A"]?.identity == .person(sarah))
        #expect(result["A"]?.source == .voice)
        #expect(result["B"] == nil)
        #expect(result["C"] == nil)
    }

    @Test func highlightVotesWithLag() {
        // The highlight for B's speech lags by ~0.5 s; signals every second.
        var signals: [NameSignal] = []
        for t in stride(from: 0.5, to: 30, by: 1) { signals.append(NameSignal(time: t, name: "Sarah Chen", source: .screen)) }
        for t in stride(from: 30.5, to: 60, by: 1) { signals.append(NameSignal(time: t, name: "Dev Patel", source: .screen)) }
        let result = NameVoting.assign(.init(spans: spans, signals: signals))
        #expect(result["A"]?.identity == .name("Sarah Chen"))
        #expect(result["B"]?.identity == .name("Dev Patel"))
        #expect(result["B"]?.source == .screen)
        #expect(result["C"] == nil)
    }

    @Test func insufficientOrSplitEvidenceIsRejected() {
        // Only 3 seconds of evidence.
        let few = (0..<3).map { NameSignal(time: Double($0) + 1, name: "Sarah", source: .screen) }
        #expect(NameVoting.assign(.init(spans: spans, signals: few))["A"] == nil)
        // A's highlight alternates between two names: share below 0.6.
        let split = (0..<28).map { NameSignal(time: Double($0) + 1, name: $0 % 2 == 0 ? "Sarah" : "Maya", source: .screen) }
        #expect(NameVoting.assign(.init(spans: spans, signals: split))["A"] == nil)
    }

    @Test func captionsAlignToText() {
        let texts = [
            TimedText(speakerKey: "A", start: 2, end: 9, text: "So the new annual plan is live on staging today"),
            TimedText(speakerKey: "B", start: 31, end: 38, text: "Crossed out tested better last time conversion was up eight percent"),
        ]
        var signals: [NameSignal] = []
        for _ in 0..<3 {
            signals.append(NameSignal(time: 8, name: "Sarah Chen", source: .captions,
                                      text: "so the new annual plan is live on staging"))
            signals.append(NameSignal(time: 37, name: "Dev Patel", source: .captions,
                                      text: "crossed out tested better last time, conversion was up eight percent"))
        }
        let result = NameVoting.assign(.init(spans: spans, texts: texts, signals: signals))
        #expect(result["A"]?.identity == .name("Sarah Chen"))
        #expect(result["A"]?.source == .captions)
        #expect(result["B"]?.identity == .name("Dev Patel"))
    }

    @Test func singleCandidateFromInvite() {
        let two = [SpeakerSpan(speakerKey: "A", start: 0, end: 90), SpeakerSpan(speakerKey: "B", start: 90, end: 200)]
        let result = NameVoting.assign(.init(
            spans: two, voiceMatches: ["A": .init(personID: sarah, distance: 0.1)], rosterNames: ["Dev Patel"]))
        #expect(result["B"]?.identity == .name("Dev Patel"))
        #expect(result["B"]?.source == .calendarSingleCandidate)
        // Two candidates left: no guess.
        let none = NameVoting.assign(.init(
            spans: two, voiceMatches: ["A": .init(personID: sarah, distance: 0.1)], rosterNames: ["Dev Patel", "Maya Ross"]))
        #expect(none["B"] == nil)
    }

    @Test func userChoicesAreNeverOverridden() {
        let signals = (0..<29).map { NameSignal(time: Double($0) + 0.5, name: "Sarah Chen", source: .screen) }
        let result = NameVoting.assign(.init(
            spans: spans, voiceMatches: ["A": .init(personID: sarah, distance: 0.1)], signals: signals,
            fixed: ["A": .person(dev)]))
        #expect(result["A"]?.identity == .person(dev))
        #expect(result["A"]?.source == .user)
    }
}

@Suite struct MarkdownExporterTests {
    static func document() -> MeetingDocument {
        let id = UUID()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 10))!
        let sarah = Person(displayName: "Sarah Chen")
        var meeting = Meeting(id: id, title: "Pricing page rollout", startedAt: start,
                              endedAt: start.addingTimeInterval(34 * 60), app: .meet, stage: .done)
        meeting.summary = "Agreed to show the crossed-out price."
        return MeetingDocument(
            meeting: meeting,
            speakers: [
                MeetingSpeaker(meetingID: id, speakerKey: "me", label: "Me", talkSeconds: 10),
                MeetingSpeaker(meetingID: id, speakerKey: "S1", label: "Speaker 2", personID: sarah.id, talkSeconds: 20),
                MeetingSpeaker(meetingID: id, speakerKey: "S2", label: "Speaker 3", talkSeconds: 5),
            ],
            people: [sarah.id: sarah],
            segments: [
                Segment(meetingID: id, speakerKey: "S1", start: 252, end: 260, text: "Is it live on staging?"),
                Segment(meetingID: id, speakerKey: "me", start: 288, end: 295, text: "Ship it by Friday."),
                Segment(meetingID: id, speakerKey: "S2", start: 300, end: 305, text: "Sounds good."),
            ],
            actionItems: [
                ActionItem(meetingID: id, text: "Ship it", ownerPersonID: sarah.id, due: "by Friday", position: 0),
                ActionItem(meetingID: id, text: "Ask legal", ownerSpeakerKey: "me", done: true, position: 1),
            ],
            noteItems: [
                NoteItem(meetingID: id, kind: .decision, text: "Crossed-out price", position: 0),
                NoteItem(meetingID: id, kind: .question, text: "Migrate old plans?", position: 0),
            ],
            marks: [
                Mark(meetingID: id, kind: .bookmark, time: 290),
                Mark(meetingID: id, kind: .privateNote, time: 320, text: "Ask legal first"),
            ])
    }

    @Test func rendersAllSections() {
        let md = MarkdownExporter.render(Self.document())
        #expect(md.hasPrefix("# Pricing page rollout\nFri, Oct 30 2026 · 10:00–10:34 · Google Meet\n"))
        #expect(md.contains("Participants: Sarah Chen, Me, Speaker 3"))
        #expect(md.contains("## Summary\nAgreed to show the crossed-out price."))
        #expect(md.contains("## Decisions\n- Crossed-out price"))
        #expect(md.contains("- [ ] Sarah Chen: Ship it (by Friday)"))
        #expect(md.contains("- [x] Me: Ask legal"))
        #expect(md.contains("## Open questions\n- Migrate old plans?"))
        #expect(md.contains("- 4:50 Bookmark"))
        #expect(md.contains("**Sarah Chen** (4:12): Is it live on staging?"))
        #expect(md.contains("**Speaker 3** (5:00): Sounds good."))
    }

    @Test func privateNotesOnlyWhenAsked() {
        #expect(!MarkdownExporter.render(Self.document()).contains("Ask legal first"))
        #expect(MarkdownExporter.render(Self.document(), includePrivateNotes: true).contains("My note: Ask legal first"))
    }

    @Test func fileNamesAreSafe() {
        var meeting = Self.document().meeting
        meeting.title = "Q4: plan/review?"
        #expect(MarkdownExporter.fileName(for: meeting) == "2026-10-30 Q4  plan review.md")
        #expect(MarkdownExporter.timestamp(3725) == "1:02:05")
    }
}

@Suite struct ReminderTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let meet = ReminderScheduler.Detected(app: .meet, url: "https://meet.google.com/abc-defg-hij", title: "Pricing")

    @Test func promptsOnceThenRepeatsOnceThenSilent() {
        var s = ReminderScheduler()
        #expect(s.meetingStarted(meet, rules: [], now: t0, isRecording: false) == .prompt(meet, isRepeat: false))
        #expect(s.meetingStarted(meet, rules: [], now: t0.addingTimeInterval(5), isRecording: false) == .none)
        #expect(s.tick(now: t0.addingTimeInterval(60), upcoming: [], isRecording: false) == .none)
        #expect(s.tick(now: t0.addingTimeInterval(121), upcoming: [], isRecording: false) == .prompt(meet, isRepeat: true))
        #expect(s.tick(now: t0.addingTimeInterval(400), upcoming: [], isRecording: false) == .none)
        #expect(s.meetingEnded() == .withdraw)
    }

    @Test func answeringStopsReminders() {
        var s = ReminderScheduler()
        _ = s.meetingStarted(meet, rules: [], now: t0, isRecording: false)
        s.answered(now: t0)
        #expect(s.pending == nil)
        #expect(s.tick(now: t0.addingTimeInterval(200), upcoming: [], isRecording: false) == .none)
        #expect(s.meetingEnded() == .none)
    }

    @Test func rulesAutoStart() {
        var s = ReminderScheduler()
        let rule = MeetingRule(meetingURL: "meet.google.com/abc-defg-hij", title: "Pricing")
        #expect(s.meetingStarted(meet, rules: [rule], now: t0, isRecording: false) == .autoStart(meet))
    }

    @Test func noPromptWhileRecordingOrWhenOff() {
        var s = ReminderScheduler()
        #expect(s.meetingStarted(meet, rules: [], now: t0, isRecording: true) == .none)
        var off = ReminderScheduler()
        off.options.remindOnDetect = false
        #expect(off.meetingStarted(meet, rules: [], now: t0, isRecording: false) == .none)
    }

    @Test func headsUpOncePerEventWithLink() {
        var s = ReminderScheduler()
        let soon = ReminderScheduler.CalendarMeeting(eventID: "E1", title: "Standup", start: t0.addingTimeInterval(45),
                                                     url: "https://meet.google.com/abc-defg-hij")
        let noLink = ReminderScheduler.CalendarMeeting(eventID: "E2", title: "Lunch", start: t0.addingTimeInterval(30), url: nil)
        let later = ReminderScheduler.CalendarMeeting(eventID: "E3", title: "Later", start: t0.addingTimeInterval(600),
                                                      url: "https://meet.google.com/abc-defg-hij")
        #expect(s.tick(now: t0, upcoming: [noLink, later, soon], isRecording: false) == .headsUp(title: "Standup"))
        #expect(s.tick(now: t0.addingTimeInterval(10), upcoming: [noLink, later, soon], isRecording: false) == .none)
    }

    @Test func ringKeepsNewestAndWipes() {
        var ring = SampleRing(capacity: 4)
        ring.append([1, 2, 3])
        #expect(ring.snapshot() == [1, 2, 3])
        ring.append([4, 5, 6])
        #expect(ring.snapshot() == [3, 4, 5, 6])
        ring.wipe()
        #expect(ring.count == 0 && ring.isZeroed && ring.snapshot().isEmpty)
    }
}

@Suite struct SpeechRegionTests {
    /// 1 s silence, 2 s speech-like noise, 3 s silence, 20 s speech, 1 s silence.
    static func track() -> [Float] {
        var rng = SplitMix(seed: 5)
        func noise(_ s: Double, _ amp: Float) -> [Float] { (0..<Int(s * 16_000)).map { _ in Float.random(in: -amp...amp, using: &rng) } }
        return noise(1, 0.001) + noise(2, 0.2) + noise(3, 0.001) + noise(20, 0.2) + noise(1, 0.001)
    }

    @Test func findsSpeechAndCapsLength() {
        let regions = SpeechRegions.detect(Self.track())
        #expect(regions.count >= 3)
        guard let first = regions.first else { return }
        #expect(abs(Double(first.lowerBound) / 16_000 - 1) < 0.3)
        #expect(abs(Double(first.upperBound) / 16_000 - 3) < 0.6)
        #expect(regions.allSatisfy { Double($0.count) / 16_000 <= 14.01 })
        let total = regions.dropFirst().reduce(0) { $0 + $1.count }
        #expect(abs(Double(total) / 16_000 - 20) < 1)
    }

    @Test func silenceHasNoRegions() {
        #expect(SpeechRegions.detect([Float](repeating: 0, count: 64_000)).isEmpty)
    }

    @Test func voiceMatchingPicksNearestPerson() {
        let a = UUID(), b = UUID()
        let voices = [Voice(personID: a, embedding: [1, 0, 0], model: "m"), Voice(personID: a, embedding: [0.9, 0.1, 0], model: "m"),
                      Voice(personID: b, embedding: [0, 1, 0], model: "m")]
        let matches = VoiceMatching.bestMatches(clusters: ["S1": [0.95, 0.05, 0], "S2": [0, 0.9, 0.1]], voices: voices)
        #expect(matches["S1"]?.personID == a)
        #expect(matches["S2"]?.personID == b)
        #expect(VoiceMatching.cosineDistance([1, 0], [1, 0]) < 1e-6)
        #expect(VoiceMatching.cosineDistance([1, 0], [0, 1]) == 1)
        #expect(VoiceMatching.cosineDistance([1], [1, 2]) == 2)
    }
}

@Suite struct EchoSuppressionTests {
    @Test func mutesEchoKeepsYourVoice() {
        // Remote talks 0–2 s; you talk 2–4 s; the mic hears the remote at 25 % with a 30 ms delay.
        let remote = EchoGateTests.bursts(seconds: 2, seed: 1) + [Float](repeating: 0, count: 32_000)
        let mine = [Float](repeating: 0, count: 32_000) + EchoGateTests.bursts(seconds: 2, seed: 2)
        var local = mine
        for i in 480..<local.count { local[i] += remote[i - 480] * 0.25 }
        let (cleaned, removed) = EchoGate.suppress(local: local, remote: remote)
        #expect(removed > 0.8)
        #expect(AudioAnalysis.rms(Array(cleaned[0..<32_000])) < AudioAnalysis.rms(Array(local[0..<32_000])) * 0.5)
        #expect(Array(cleaned[37_000..<64_000]) == Array(local[37_000..<64_000]), "your speech was changed")
    }

    @Test func noRemoteMeansNoChange() {
        let local = EchoGateTests.bursts(seconds: 1, seed: 3)
        #expect(EchoGate.suppress(local: local, remote: []).cleaned == local)
    }
}

@Suite struct TimelineAlignerTests {
    @Test func padsLateStartAndGaps() {
        var a = TimelineAligner(startHostSeconds: 100, sampleRate: 1_000)
        #expect(a.place([1, 1, 1], hostSeconds: 101).count == 1_003)   // started 1 s late
        #expect(a.place([2, 2], hostSeconds: 101.003) == [2, 2])        // contiguous
        let gap = a.place([3], hostSeconds: 102.005)                    // ~1 s pause
        #expect(gap.count == 1_001 && gap.last == 3)
        #expect(a.position == 2_006)
    }

    @Test func dropsOverlapWhenAhead() {
        var a = TimelineAligner(startHostSeconds: 0, sampleRate: 1_000)
        _ = a.place([Float](repeating: 1, count: 1_000), hostSeconds: 0)
        let out = a.place([Float](repeating: 2, count: 1_000), hostSeconds: 0.5)  // 500 samples overlap
        #expect(out.count == 500)
        #expect(a.position == 1_500)
    }

    @Test func ignoresJitterAndPadsEnd() {
        var a = TimelineAligner(startHostSeconds: 0, sampleRate: 16_000)
        _ = a.place([Float](repeating: 0, count: 1_600), hostSeconds: 0)
        #expect(a.place([1], hostSeconds: 0.1 + 0.005).count == 1)      // 80 samples late: within tolerance
        #expect(a.padding(toSeconds: 1).count == 16_000 - 1_601)
        #expect(a.padding(toSeconds: 0.5).isEmpty)
    }

    @Test func discardsAudioFromBeforeStart() {
        var a = TimelineAligner(startHostSeconds: 10, sampleRate: 1_000)
        #expect(a.place([1, 1], hostSeconds: 5).isEmpty)
        #expect(a.position == 0)
    }
}

@Suite struct MeetingPreferencesTests {
    @Test func oldSettingsDecodeWithMeetingDefaults() throws {
        let old = #"{"triggerKey":61,"model":"phonon2"}"#
        let settings = try JSONDecoder().decode(MumbleSettings.self, from: Data(old.utf8))
        #expect(settings.meetings == MeetingPreferences())
        #expect(settings.meetings.remindOnDetect && !settings.meetings.catchTheStart && settings.meetings.rememberVoices == nil)
        let partial = #"{"meetings":{"catchTheStart":true}}"#
        let p = try JSONDecoder().decode(MumbleSettings.self, from: Data(partial.utf8))
        #expect(p.meetings.catchTheStart && p.meetings.remindOnDetect)
    }

    @Test func headsUpNeedsCalendar() {
        var p = MeetingPreferences()
        #expect(!p.reminderOptions.headsUp)
        p.useCalendar = true
        #expect(p.reminderOptions.headsUp)
    }
}

@Suite struct IgnoredSpeakerTests {
    @Test func ignoredVoicesAreHiddenFromExport() {
        var doc = MarkdownExporterTests.document()
        let i = doc.speakers.firstIndex { $0.speakerKey == "S2" }!
        doc.speakers[i].label = MeetingSpeaker.ignoredLabel
        let md = MarkdownExporter.render(doc)
        #expect(!md.contains("Sounds good."))
        #expect(!md.contains("Speaker 3"))
        #expect(doc.visibleSegments.count == 2)
    }
}
