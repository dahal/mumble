# Spec: Meeting notes

| | |
|---|---|
| Status | Draft v0.1, Oct 30 2026 |
| Background | [`docs/braindump/meeting-notes.md`](../braindump/meeting-notes.md) |
| Design | Paper, file **Mumble**, page **v0-meeting-notes** (<https://app.paper.design/file/01M65TS5D8AZS6K2CK9KBQQZ7B/p-1-0>) |
| Platform | macOS 15+, Apple silicon. Summaries with Apple's model need macOS 26 (§9). |

Items marked **[spike]** must be verified with a prototype before the dependent milestone starts (§16).

---

## 1. Summary

Mumble gains a **Meeting mode**. During a Google Meet, Zoom, Teams or Slack call it records your microphone and the
meeting app's audio, then produces a transcript where every line has a **speaker name**, plus a summary, decisions,
action items with owners and open questions. Everything runs on the Mac. No bot joins the call, no account is needed,
and audio never leaves the device.

## 2. Goals and non-goals

### Goals

1. **Who said what, by name.** ≥ 95% of transcript words attributed to the right person in a typical 3–6 person
   meeting, after the first meeting with that group.
2. **Zero setup for the common case.** Start notes with one action; names appear without typing for recurring
   meetings and for scheduled meetings with captions or the highlight available.
3. **Fast.** Notes ready ≤ 60 s after a 60-minute meeting ends, on M1 or newer (§13).
4. **Private by default.** On-device processing; audio deleted after processing; voice fingerprints opt-in and local.
5. **Native.** Same window, island, menu and settings patterns as dictation.

### Non-goals (v1)

- Joining calls as a bot, or recording calls the user isn't in.
- Cloud sync, team workspaces, sharing links. (Export to Markdown/clipboard only.)
- Video recording or slide capture.
- Reading email, Google Calendar OAuth, or Zoom/Teams/Slack APIs.
- iOS.
- Translating meetings. (Transcription follows the selected speech model's languages; §8.)

## 3. Users and core stories

| # | As a… | I want to… | So that… |
|---|---|---|---|
| S1 | team lead on daily Meets | start notes with one shortcut | I can stay present instead of typing |
| S2 | anyone after a call | read who committed to what | action items have real owners |
| S3 | a person new to a group | name an unknown voice once | the next meeting names them automatically |
| S4 | someone in a meeting | bookmark a moment or dictate a private note | I can find it later |
| S5 | a privacy-conscious user | know nothing left my Mac | I can use it for sensitive calls |
| S6 | anyone | search past meetings | I can find "what did we decide about pricing" |
| S7 | anyone | copy the notes as Markdown | I can paste them into Docs, Notion or Slack |

## 4. User experience

All screens follow the existing SwiftUI patterns (see `Mumble/Settings/SettingsView.swift`, `Mumble/Island/`).
Design reference: the Paper page above.

### 4.1 Starting and stopping

- **Menu bar:** "Start Meeting Notes" (default shortcut ⌥⇧M) toggles to "Stop Meeting Notes · 12:48" while recording.
- **Meetings pane toolbar:** "Start Notes" button.
- **Reminders** so a forgotten shortcut doesn't mean lost notes (§4.1.1).
- **Stop:** the shortcut again, the menu item, or automatically 2 minutes after the meeting app stops using the mic.
- Dictation keeps working during a meeting. Dictated text is still pasted as usual; it is not part of the meeting
  transcript unless it's a private note (§4.4).

### 4.1.1 Reminders: "you forgot to take notes"

| # | Trigger | Default | What the user sees |
|---|---|---|---|
| R1 | **Meeting detected** (§7.1): a meeting app or meeting page starts using the mic | On | Island prompt + notification (below) |
| R2 | **Heads-up:** 1 min before a calendar event that has a meeting link (needs Calendar access) | On when Calendar access is granted | Island hint only (no notification) |
| R3 | **Second reminder:** 2 min after R1 if neither answered nor dismissed | On | Island prompt once more; then silent for this meeting |
| R4 | **Catch the start:** after R1, keep the last 2 min of mic + meeting audio **in memory only** until the user answers | **Off** (opt-in) | Take Notes → included, notes start at the real beginning. Not Now / no answer / meeting ends → wiped. Never written to disk. |
| R5 | **Always take notes for this meeting:** per recurring calendar event (or per meeting link), chosen from the prompt or notification | Off per meeting | Notes start automatically when that meeting is detected; island and menu bar show the red recording state, consent sheet still shown |

Surfaces:

- **Island prompt** (new phase `.suggest`): compact pill expanded to one row. Leading: the meeting app's icon.
  Text: "*Pricing page rollout*" (calendar title) or "Google Meet call" (no event), secondary "Take notes?".
  Trailing: **Take Notes** (white capsule button) and an × to dismiss. Auto-hides after 12 s; doesn't take focus.
  The heads-up (R2) uses the same layout with "in 1 min" and the shortcut hint instead of the × button.
- **Notification** (`UNUserNotificationCenter`, category with actions): title "Take notes for Pricing page rollout?",
  body "Google Meet started using your microphone.", actions **Take Notes**, **Always for This Meeting** (only for
  recurring events / known links), **Not Now**. Removed from Notification Center once answered or when the meeting ends.
- **Menu bar menu** shows "Take Notes for Pricing page rollout" at the top while a detected meeting is unanswered.
- Nothing is ever recorded to disk without a click, except R5 which the user explicitly enabled for that meeting.

Rules are stored in the `meeting_rules` table (calendar series ID or normalized meeting URL, §12.3) and
listed in Settings (§4.6) with a remove button.

### 4.2 Consent prompt

On every start (unless "Don't show again" was ticked): a sheet with
"Let everyone know Mumble is taking notes" and a **Copy Message** button that copies
"Heads up: I'm taking notes with Mumble. Audio stays on my Mac and is deleted after processing." Recording starts
when the sheet is dismissed either way.

### 4.3 Island during a meeting

The existing black pill (`IslandView`), new phase `.meeting`:

- Leading: `WaveformBars` driven by the louder of mic and meeting audio.
- Trailing: "Meeting notes", red dot, elapsed time.
- Second line (when live preview is on): current speaker's name in white, then the last ~12 s of live text at 65%
  white, `lineLimit(2)`, truncating at the head (same as dictation).
- Collapses to the compact pill after 8 s of no change; expands again on speech.
- While dictating during a meeting, the island shows the dictation phases as today, then returns to `.meeting`.

### 4.4 In-meeting actions

| Action | Default shortcut | Result |
|---|---|---|
| Bookmark This Moment | ⌥⇧B | Marks the transcript at now − 5 s. Island flashes "Bookmarked". |
| Add Private Note | hold the dictation key while notes are on, with a setting to choose | The dictated text is stored as a private note at that timestamp, **not pasted**. Visible only in the notes, labeled "My note". |

The private-note behaviour applies only while Meeting mode is recording and only if the setting
"While taking meeting notes, dictation becomes a private note" is on (default **off**, so dictation is unchanged
unless the user opts in).

### 4.5 Window: Meetings pane

New sidebar row **Meetings** (SF Symbol `person.2.wave.2`) between General and Vocabulary.

**List** (mirrors `HistoryPane`): searchable `List` with sections Today / This week / Earlier. Each row:
title (calendar title, or "Meeting with Sarah, Dev" when there's no event), the first line of the summary, and a
caption: time · duration · app · participants. Rows still processing show a `ProgressView` and the current stage
("Transcribing…", "Finding speakers…", "Summarizing…"). Context menu: Copy as Markdown, Delete.
Toolbar: **Start Notes**. Empty state: `ContentUnavailableView` "No meetings yet" with the shortcut.

**Detail** (pushed from the list; `.grouped` `Form` like `GeneralPane`):

1. **Summary**: paragraph, then a caption "Thu, Oct 30 · 10:00 · 34 min · Google Meet · Summarized on this Mac",
   then a row per **Decision**.
2. **Action items**: checkbox, text, owner (trailing, secondary). Checkbox state is saved.
3. **Open questions**: plain rows (section hidden if empty).
4. **Speakers**: one row per voice, `PermissionRow` style.
   - Named: green check, name, caption "Recognized from a saved voice · 11 min" (or "From captions", "From screen",
     "Named by you").
   - Unknown: empty circle, "Speaker 4", caption "New voice · 4 min", trailing **Choose name…** `Picker` with: calendar
     attendees not yet assigned, previously saved people, "New Person…", "Not a person (ignore)".
   - Renaming re-labels every line and action-item owner immediately.
5. **Bookmarks & notes** (hidden if empty).
6. **Transcript**: History-style rows: text, caption "Name · m:ss". Click a row's timestamp to play audio from there
   (only while audio is retained). Search field filters rows.

Toolbar: back, **Copy as Markdown**, delete (trash, confirmation alert).

### 4.6 Settings → General → new "Meetings" section

| Setting | Default |
|---|---|
| Start/stop shortcut | ⌥⇧M |
| Remind me when a meeting starts (R1, R3) | On |
| Heads-up 1 minute before calendar meetings (R2) | On (needs Calendar access) |
| Catch the start: hold the last 2 minutes in memory until I answer (R4) | Off |
| Always take notes for… (R5) | list of meetings with a remove button; empty by default |
| Show the consent message sheet | On |
| Remember voices (saved voice fingerprints) | Off until first "Choose name…", which asks (§11.3) |
| Use calendar to suggest names | Off until enabled; asks Calendar permission |
| Read live captions to identify speakers | On if Accessibility is granted (already required) |
| Read the meeting window to identify speakers | Off; enabling asks Screen Recording permission |
| Keep meeting audio | "Delete after processing" / "Keep 7 days" / "Keep until I delete" |
| Summaries | "On this Mac (Apple Intelligence)" / "Larger local model" / "Claude (sends text only)" / "Off" |
| Saved voices | button **Manage…** → list of people, delete one / delete all |
| Also save notes as Markdown | Off; folder picker when on (§12.6) |

### 4.7 Markdown export format

```markdown
# Pricing page rollout
Thu, Oct 30 2026 · 10:00–10:34 · Google Meet
Participants: Me, Sarah Chen, Dev Patel, Speaker 4

## Summary
…
## Decisions
- Crossed-out monthly price on the annual plan
## Action items
- [ ] Sarah Chen: Ship the crossed-out price behind the flag by Friday
- [x] Me: Ask legal about grandfathering the old plan
## Open questions
- …
## Transcript
**Sarah Chen** (4:12): So the new annual plan is live on staging…
```

Private notes are excluded from export unless "Include my notes" is checked in the copy menu.

## 5. Architecture

```
                 ┌──────────────┐   ┌─────────────────────┐
  Mic ──────────▶│ AudioRecorder│   │ SystemAudioTap      │◀── meeting app audio (process tap)
                 └──────┬───────┘   └─────────┬───────────┘
                        ▼                     ▼
                 ┌─────────────────────────────────────┐
                 │ MeetingRecorder (actor)             │──▶ local.caf, remote.caf (16 kHz mono)
                 │  live: Sortformer + ASR preview     │──▶ island
                 └─────────────────────────────────────┘
  Calendar ─▶ RosterProvider ─┐
  Captions ─▶ CaptionReader ──┼─▶ SignalLog (timestamped name events) ─┐
  Window  ─▶ ScreenSpeaker  ──┘                                       │
                                                                      ▼
  on stop ─▶ MeetingProcessor: ASR(local) + ASR(remote) → Diarize(remote) → Identify → Summarize → MeetingStore
```

### 5.1 Code layout

| Location | New contents | Notes |
|---|---|---|
| `Packages/MumbleKit/Sources/MumbleCore/Meetings/` | `Meeting`, `TranscriptSegment`, `SpeakerCluster`, `Person`, `NameSignal`, `ActionItem` record types (§12.4); `NameVoting`; `CaptionAligner`; `TranscriptMerger`; `SummaryChunker`; `MarkdownExporter`; word-timing packing | Pure Swift, no AppKit, no GRDB. All unit-tested. |
| `Packages/MumbleKit/Sources/MumbleStore/` (new target) | GRDB record conformances, migrations, `MeetingStore` actor, search, Markdown copy writer | Depends on `MumbleCore` + GRDB. Tested against in-memory and temp-file databases. |
| `Packages/MumbleKit/Sources/MumbleASR/` | `MeetingTranscriber` (long-audio ASR with word timings), `MeetingDiarizer` (wraps `OfflineDiarizerManager`), `VoiceLibrary` (wraps `SpeakerManager` + embeddings) | Uses FluidAudio. Integration-tested with `MUMBLE_INTEGRATION=1`. |
| `Packages/MumbleKit/Sources/MumbleSummary/` (new target) | `Summarizer` protocol; `AppleSummarizer`, `MLXSummarizer`, `ClaudeSummarizer` | Apple one behind `#if canImport(FoundationModels)` + availability check. |
| `Mumble/Meetings/` | `MeetingController`, `MeetingRecorder`, `SystemAudioTap`, `MeetingDetector`, `RosterProvider` (EventKit), `CaptionReader` (AX), `ScreenSpeaker` (ScreenCaptureKit + Vision) | App-only, needs permissions. |
| `Mumble/Settings/` | `MeetingsPane`, `MeetingDetailView`, `SpeakerRow`, `VoicesSheet`, settings section | Native SwiftUI. |
| `Mumble/Island/` | `.meeting` phase in `IslandModel` / `IslandView` | |
| `Packages/MumbleKit/Sources/MumbleEval/` | `mumble-eval meeting <dir>`: WDER, DER, naming accuracy, timing | §14 |

`MeetingController` is `@MainActor` and owned next to `DictationController` by `AppDelegate`. The two share the
loaded ASR model (one `AsrManager`); meeting ASR runs at lower task priority so dictation stays at its current latency.

## 6. Audio capture

### 6.1 Local stream (you)

- Reuse `AudioRecorder` (AVCaptureSession, 16 kHz mono float), including the Bluetooth → built-in mic rule.
- A second consumer: dictation and meeting recording must be able to run at the same time. `AudioRecorder` gains a
  fan-out so one capture session feeds both.

### 6.2 Remote stream (everyone else)

- **Core Audio process tap** (macOS 14.4+): `CATapDescription(stereoMixdownOfProcesses:)` + `AudioHardwareCreateProcessTap`,
  attached to a private aggregate device, read with an IO proc, downmixed and resampled to 16 kHz mono.
- **Which processes:** the meeting app's audio often comes from helper processes (e.g. Chrome renders audio in a
  "Google Chrome Helper" process). Enumerate `kAudioHardwarePropertyProcessObjectList`, read each object's bundle ID,
  and tap every process whose bundle ID starts with the meeting app's (`com.google.Chrome`, `us.zoom.xos`,
  `com.microsoft.teams2`, `com.tinyspeck.slackmacgap`, `com.apple.Safari`, `company.thebrowser.Browser`, …).
  Re-enumerate every 5 s; helpers come and go. **[spike S1]**
- **Permission:** "System Audio Recording" (`NSAudioCaptureUsageDescription`). Requested on first meeting start.
- Fallback when the tap fails or permission is denied: record the mic only and warn "Only your microphone is being
  recorded. Other people may be missed if you use headphones."

### 6.3 Echo

With laptop speakers, the mic also hears remote voices.

1. Enable voice processing (echo cancellation) on the mic path while a meeting is recording. **[spike S2]**: confirm
   whether it cancels other apps' output on macOS; if not, rely on step 2.
2. **Echo gate:** for each local speech region, compute the correlation between the local and remote signals over a
   ±300 ms lag window. If correlation > 0.6 and the remote signal is louder, drop that region from the local transcript.
3. If the user has a saved voice, local segments whose embedding doesn't match "me" (cosine distance above threshold)
   are moved to the remote stream for diarization.

### 6.4 Files

Written incrementally as CAF (Float32, 16 kHz mono): `local.caf`, `remote.caf`, a shared clock (`mach_absolute_time`
→ seconds since start) so both align to ±20 ms. One hour ≈ 230 MB per stream uncompressed; after processing, if audio
is kept, re-encode to AAC 32 kbps mono (~15 MB per stream per hour).

## 7. Live pipeline (during the call)

Purpose: the island preview and a crash-safe partial transcript. It is **not** the final transcript.

- Every 2 s: run ASR on the last 12 s of the mixed stream (same windowing as dictation's preview).
- `SortformerDiarizer` on the remote stream for a live "current speaker" index; mapped to names using live signals
  (§10) when available, else "Speaker 2".
- Checkpoint every 60 s: insert finalized live segments into the database (`is_live = 1`, §12.7) so a crash leaves a
  usable transcript.
- CPU budget: ≤ 15% of one performance core on M1 averaged over a minute (§13).

### 7.1 Meeting detection (for auto-suggest)

A meeting is "starting" when **both**:

- the microphone is in use by another process (`kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input,
  and the meeting app is among the processes using input, via the process object's `kAudioProcessPropertyIsRunningInput`), and
- the app is a known meeting app, or a browser whose frontmost tab URL matches `meet.google.com/…`,
  `*.zoom.us/wc/…`, `teams.microsoft.com/…`, `teams.live.com/…`, `app.slack.com/huddle/…`. The URL is read through
  Accessibility (the address bar's `AXValue`), not AppleScript, to avoid an Automation permission prompt. **[spike S3]**

Polled every 3 s, only while Mumble is idle; no polling while a meeting is recording.

When R4 is on, detection also starts a 2-minute in-memory ring buffer for both streams (~15 MB). The buffer is
prepended to the recording on Take Notes and zeroed and freed on Not Now, timeout, or when the meeting app stops using
the mic.

## 8. Final processing (after Stop)

Runs as a background `Task` with progress reported to the list row. Stages:

1. **Transcribe** `local.caf` and `remote.caf` separately with the selected speech model. Long audio is split at
   pauses (existing `AudioAnalysis.splitAtPauses`), ~15 s chunks. Output: words with start/end times.
   Vocabulary boosting and the text pipeline (fillers, spacing) apply as in dictation; spoken commands do not.
2. **Diarize** `remote.caf` with `OfflineDiarizerManager` → segments `(start, end, clusterID)` and one embedding per
   cluster (mean of its span embeddings, from `embedSpans`).
3. **Merge:** assign each remote word to the cluster covering its midpoint; local words to "me". Interleave by time.
   Group consecutive words by the same speaker into `TranscriptSegment`s, splitting at > 1.5 s gaps or sentence ends
   after 30 s.
4. **Identify** speakers (§10).
5. **Summarize** (§9).
6. **Save** and, per setting, delete audio.

Languages: transcription uses the selected speech model, so multilingual meetings need Parakeet v3 / Ultra (25
European languages). Summaries are generated in the meeting's dominant language when the summarizer supports it.

**Failure handling:** each stage writes its output before the next starts; a crash or quit resumes from the last
completed stage on next launch. If any stage fails, the meeting is still listed with whatever exists (transcript
without names, or names without summary) and a **Retry** button.

## 9. Summaries

### 9.1 Output (typed)

```swift
struct MeetingNotes: Codable {
    var title: String?            // only when there's no calendar title
    var summary: String           // 2–4 sentences
    var decisions: [String]
    var actionItems: [ActionItem] // text, ownerPersonID?, due: String?
    var openQuestions: [String]
}
```

Owners must be one of the meeting's identified people; anything else becomes `nil` (shown without owner). The
summarizer gets the transcript with **names**, so "Sarah, can you ship it by Friday" resolves to Sarah.

### 9.2 Providers

| Provider | When | How |
|---|---|---|
| **Apple** (default) | macOS 26 + Apple Intelligence enabled | `FoundationModels` `LanguageModelSession` with guided generation (`@Generable` `MeetingNotes`). Context ~4k tokens, so **map-reduce**: chunk the transcript into ~2,500-token windows at speaker turns, extract partial notes per chunk, then a final merge pass over the partials. |
| **Local (MLX)** | user downloads a model in Settings | A ~8B instruct model (4-bit). Larger context, single pass up to ~90 min meetings. **[spike S6]** to choose the model and measure speed. |
| **Claude** | explicit opt-in, per meeting or always | Sends transcript text with names (never audio) over HTTPS with the user's API key stored in Keychain. Shown as "Summarized with Claude" in the caption. |
| **Off** | user choice or no provider available | Transcript only; summary sections hidden. |

On macOS 15, the Apple provider is unavailable; Settings explains why and offers Local / Claude / Off.

### 9.3 Quality bar

- Every action item cites the transcript segment it came from (we store the segment ID; clicking an action item
  scrolls the transcript there).
- No invented owners or dates; validated after generation (owner must be a participant; dates must appear in the
  source segment text).

## 10. Speaker identification

### 10.1 Model

- `Person`: `id`, `displayName`, `emails: [String]`, `aliases: [String]` (names seen in captions/tiles),
  `isMe`, `voice: VoiceProfile?`.
- `VoiceProfile`: up to 10 embeddings from different meetings, plus their centroid. Stored locally (§11).
- `SpeakerCluster` (per meeting): `clusterID`, `embedding`, `talkSeconds`, `assignedPersonID?`, `assignmentSource`
  (`.voice`, `.captions`, `.screen`, `.user`, `.calendarSingleCandidate`), `confidence`.

### 10.2 Signals

All signals become `NameSignal(time: Double, name: String, source:)` in a `SignalLog`.

| Source | How | Notes |
|---|---|---|
| **Saved voices** | cosine distance between cluster embedding and each `VoiceProfile` centroid via `SpeakerManager.findSpeaker(with:speakerThreshold:)` | Threshold tuned on eval set **[spike S4]**. Not a time signal; applied directly to clusters. |
| **Captions** (`CaptionReader`) | Poll the meeting window's Accessibility tree every 500 ms; find the captions region; emit `(time, speakerName, text)` for new caption lines | Per-app extractors: Chrome/Meet, Zoom, Teams. **[spike S5]** verifies each app exposes captions to AX. |
| **Speaking highlight** (`ScreenSpeaker`) | ScreenCaptureKit stream of the meeting window only (`SCContentFilter(desktopIndependentWindow:)`) at 2 fps; per-app detector finds the highlighted tile; Vision text recognition reads its name label; frame discarded immediately | Opt-in. Skipped while the app is in screen-share layout (no tiles detected). |
| **Participant list** | From the meeting window (people panel / tile labels via AX or OCR) | Names only, no timing. Expands the candidate list for ad-hoc meetings. |
| **Calendar** (`RosterProvider`) | EventKit event overlapping now; attendees' `name`, email (`url` mailto), `isCurrentUser` | Candidate list only. |

### 10.3 Algorithm (`NameVoting`, pure and unit-tested)

1. **Voice match first.** For each cluster, if the best saved voice is within threshold and no other cluster matches
   that person more closely, assign (`source = .voice`). Each person is assigned at most once per meeting.
2. **Captions alignment.** For each caption line, find the transcript window it matches (word-level fuzzy match,
   normalized; reuse the vocabulary similarity utilities) within ±10 s; credit the caption's name to the cluster
   speaking during the matched words. Weight = matched words.
3. **Highlight co-occurrence.** For each highlight event at time *t*, credit its name to the cluster active during
   `[t − 1.0 s, t + 0.3 s]` (the highlight lags speech). Weight = overlap seconds.
4. **Vote.** Build a matrix `votes[cluster][name]`. Solve as a maximum-weight assignment (Hungarian; FluidAudio has
   `HungarianAssignment`) so two clusters can't get the same name. Accept an assignment when
   `share = votes[c][n] / Σ votes[c][*] ≥ 0.6` **and** total evidence ≥ 10 s (captions: ≥ 15 words).
5. **Name resolution.** Map the voted display name to a `Person`: exact email / alias match → calendar attendee by
   fuzzy name ("Sarah C." ↔ "Sarah Chen", first-name match when unique) → saved person by alias → new `Person`
   with that display name.
6. **Single candidate rule.** If exactly one remote cluster remains and exactly one calendar attendee (not me) is
   unassigned and that cluster has ≥ 60 s of speech, assign with `source = .calendarSingleCandidate` and show it as
   a suggestion (dotted check) the user can confirm.
7. Everything else stays "Speaker N" for **Choose name…**.
8. **Learning.** When a cluster is assigned by captions, screen, or the user, and "Remember voices" is on, add its
   embedding to that person's `VoiceProfile` (only for clusters with ≥ 20 s of clean speech).

User corrections always win and are never overwritten by later reprocessing.

### 10.4 Edge cases

| Case | Behaviour |
|---|---|
| Two people in one room on one laptop | Diarization splits them; both appear as remote clusters from one tile. Highlight voting will be split; captions usually name the account owner. Leave the weaker one as "Speaker N". |
| Dial-in phone participant | Tile/caption shows a number; resolve to "Phone ··· 1234" person unless matched by voice. |
| Diarizer over-splits one person | `SpeakerManager.findMergeablePairs` on cluster embeddings before voting; also offer "Merge with…" in the speaker row menu. |
| Screen sharing hides tiles | Highlight detector reports no tiles; captions and voice still work. |
| User is muted the whole time | Local stream has no speech; "You" doesn't appear. |
| Meeting app changes layout/version | Extractors fail closed (no signals), never wrong signals: each detector validates its expected structure first and logs a version mismatch. |

## 11. Privacy, security, consent

### 11.1 Principles

- On-device by default. The only network calls are model downloads (existing) and the opt-in Claude summarizer.
- No analytics. Logs (`AppLog`) never contain transcript text, names, emails or caption text: events and timings only.

### 11.2 Data on disk

```
~/Library/Application Support/Mumble/
  Mumble.sqlite (+ -wal, -shm)    # meetings, transcripts, people, voices, notes, rules (§12)
  Meetings/<meeting-uuid>/
    local.caf | local.m4a         # deleted after processing unless "Keep meeting audio"
    remote.caf | remote.m4a
  history.json                    # dictation history, unchanged
<user-chosen folder>/             # optional Markdown copy (§12.6)
  2026-10-30 Pricing page rollout.md
```

- The database and audio are created with `.completeFileProtection`, as `HistoryStore` does today.
- Audio files are marked `isExcludedFromBackup`; the database is backed up by Time Machine like other app data.
- **Delete meeting** deletes its row (cascading to all its data, §12) and its audio folder, then runs an incremental
  vacuum so deleted text doesn't linger in free pages.
- **Delete all saved voices** deletes every row in `voices`.
- No encryption beyond FileVault and file protection in v1. SQLCipher is a possible later option.

### 11.3 Voice fingerprints (biometric)

- Off until the first time the user names a speaker; then a one-time sheet: "Remember voices so Mumble can name people
  automatically next time? Voice fingerprints stay on this Mac. You can delete them anytime." **Remember** / **Not Now**.
- Embeddings are not reversible to audio, but are treated as sensitive: local only, never exported, never sent to a
  summarizer.

### 11.4 Permissions (asked only when the feature that needs them is first used)

| Permission | Needed for | Asked when |
|---|---|---|
| Microphone | local stream | already granted for dictation |
| Accessibility | captions, meeting URL detection | already granted for dictation |
| System Audio Recording | remote stream | first Start Meeting Notes |
| Calendar (full access) | roster, titles | enabling "Use calendar to suggest names", or from the first Choose name… picker ("Show calendar attendees") |
| Screen Recording | speaking highlight | enabling "Read the meeting window"; note that macOS periodically re-confirms this permission |

Info.plist additions: `NSAudioCaptureUsageDescription`, `NSCalendarsFullAccessUsageDescription`. Screen Recording has
no usage string; Settings explains it before triggering the prompt.

### 11.5 Consent

- Consent sheet (§4.2) on start; red dot in island and menu bar for the whole recording.
- README and the sheet state that the user is responsible for local recording-consent laws.
- Catch the start (R4) holds audio before the user clicks, so it is opt-in, explained in Settings when enabled, memory
  only, and covered by a unit test that the buffer is zeroed on every non-accept path.
- Always take notes (R5) is per meeting, never global, and still shows the consent sheet and recording indicators.

## 12. Storage and data model

### 12.1 Decision

**SQLite via [GRDB.swift](https://github.com/groue/GRDB.swift)** (MIT) is the source of truth for everything except
audio. An optional **Markdown copy** gives users plain files they own (§12.6).

| Option | Verdict |
|---|---|
| **SQLite + GRDB** | ✅ Chosen. FTS5 full-text search, versioned migrations, row-level transactional updates, Swift 6 friendly, `ValueObservation` drives SwiftUI live |
| JSON files (per meeting) | ❌ No cross-meeting search or queries; whole-file rewrites on every edit; slows down after hundreds of meetings (~0.5 MB per 1-hour transcript with word timings) |
| SwiftData / Core Data | ❌ No full-text search; SwiftData migrations are fragile |
| Markdown as the only store | ❌ Word timings, embeddings and speaker assignments don't fit. Kept as an optional copy instead |
| Raw SQLite C API | ❌ Same outcome as GRDB with much more code to maintain |

Dictation history stays in `history.json` (capped, small, already works).

GRDB is the project's second dependency after FluidAudio. Pin the exact version in `Package.resolved` (current major, 7.x).

### 12.2 Database setup

- `DatabasePool` (WAL mode): processing writes in the background while the UI reads.
- `PRAGMA foreign_keys = ON`, `auto_vacuum = INCREMENTAL`.
- All writes go through one `MeetingStore` actor. Reads use GRDB `ValueObservation`, so the list and detail views update
  live as processing stages finish.
- Migrations use GRDB's `DatabaseMigrator`, one named migration per schema change (`"v1"`, `"v2-…"`), never edited
  after release. In debug builds, `eraseDatabaseOnSchemaChange` is on.
- Times are stored as seconds since meeting start (`REAL`) for transcript data, and as Unix seconds for wall-clock dates.

### 12.3 Schema (v1)

```sql
CREATE TABLE meetings (
  id              TEXT PRIMARY KEY,           -- UUID
  title           TEXT NOT NULL,
  started_at      REAL NOT NULL,              -- unix seconds
  ended_at        REAL,
  app             TEXT NOT NULL,              -- meet | zoom | teams | slack | other:<bundle id>
  meeting_url     TEXT,
  calendar_event_id    TEXT,
  calendar_series_id   TEXT,
  stage           TEXT NOT NULL,              -- recording | transcribing | diarizing | identifying | summarizing | done | failed
  failure         TEXT,
  summary         TEXT,
  summary_provider TEXT,                      -- apple | mlx | claude | null
  language        TEXT,
  audio_retained  INTEGER NOT NULL DEFAULT 0,
  audio_expires_at REAL,                      -- for "Keep 7 days"
  markdown_path   TEXT,                       -- last written Markdown copy, if any
  created_at      REAL NOT NULL,
  updated_at      REAL NOT NULL
);
CREATE INDEX meetings_started ON meetings(started_at DESC);

CREATE TABLE people (
  id            TEXT PRIMARY KEY,
  display_name  TEXT NOT NULL,
  is_me         INTEGER NOT NULL DEFAULT 0,
  created_at    REAL NOT NULL
);
CREATE TABLE person_identifiers (             -- emails and names seen in calendars, captions, tiles
  person_id   TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  kind        TEXT NOT NULL,                  -- email | alias
  value       TEXT NOT NULL COLLATE NOCASE,
  PRIMARY KEY (kind, value)
);

CREATE TABLE voices (                         -- biometric: local only, never exported (§11.3)
  id                TEXT PRIMARY KEY,
  person_id         TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  embedding         BLOB NOT NULL,            -- little-endian Float32 array
  dimensions        INTEGER NOT NULL,
  model             TEXT NOT NULL,            -- embedding model id; re-enroll if it changes
  source_meeting_id TEXT REFERENCES meetings(id) ON DELETE SET NULL,
  created_at        REAL NOT NULL
);
CREATE INDEX voices_person ON voices(person_id);

CREATE TABLE meeting_roster (                 -- who was expected or seen (calendar, window)
  meeting_id  TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  email       TEXT,
  is_me       INTEGER NOT NULL DEFAULT 0,
  source      TEXT NOT NULL                   -- calendar | window
);

CREATE TABLE meeting_speakers (               -- diarization clusters and who they are
  meeting_id   TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  speaker_key  TEXT NOT NULL,                 -- "me" or the cluster id
  label        TEXT NOT NULL,                 -- "Speaker 4" until named
  person_id    TEXT REFERENCES people(id) ON DELETE SET NULL,
  source       TEXT,                          -- voice | captions | screen | user | calendarSingleCandidate
  confidence   REAL,
  talk_seconds REAL NOT NULL,
  embedding    BLOB,                          -- cluster centroid; deleted after naming unless voices are remembered
  PRIMARY KEY (meeting_id, speaker_key)
);

CREATE TABLE segments (
  id           INTEGER PRIMARY KEY,           -- rowid, used by FTS
  meeting_id   TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  speaker_key  TEXT NOT NULL,
  start        REAL NOT NULL,
  end          REAL NOT NULL,
  text         TEXT NOT NULL,
  words        BLOB,                          -- per word: start Float32, end Float32, text offset UInt32, length UInt16
  is_live      INTEGER NOT NULL DEFAULT 0     -- live checkpoint rows, replaced by final processing
);
CREATE INDEX segments_meeting ON segments(meeting_id, start);

CREATE VIRTUAL TABLE segments_fts USING fts5(
  text, content='segments', content_rowid='id',
  tokenize='unicode61 remove_diacritics 2'    -- multilingual (25 languages), no English-only stemming
);
-- kept in sync by GRDB (synchronize(withTable: "segments")), which creates the triggers

CREATE TABLE action_items (
  id                TEXT PRIMARY KEY,
  meeting_id        TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  text              TEXT NOT NULL,
  owner_person_id   TEXT REFERENCES people(id) ON DELETE SET NULL,
  due               TEXT,                     -- as said ("by Friday"); never inferred
  done              INTEGER NOT NULL DEFAULT 0,
  source_segment_id INTEGER REFERENCES segments(id) ON DELETE SET NULL,
  position          INTEGER NOT NULL
);
CREATE INDEX action_items_open ON action_items(done, owner_person_id);

CREATE TABLE note_items (                     -- decisions and open questions
  id                TEXT PRIMARY KEY,
  meeting_id        TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  kind              TEXT NOT NULL,            -- decision | question
  text              TEXT NOT NULL,
  source_segment_id INTEGER REFERENCES segments(id) ON DELETE SET NULL,
  position          INTEGER NOT NULL
);

CREATE TABLE marks (                          -- bookmarks and private notes
  id          TEXT PRIMARY KEY,
  meeting_id  TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  kind        TEXT NOT NULL,                  -- bookmark | private_note
  time        REAL NOT NULL,
  text        TEXT
);

CREATE TABLE meeting_rules (                  -- "Always take notes for this meeting" (R5)
  id                 TEXT PRIMARY KEY,
  calendar_series_id TEXT UNIQUE,
  meeting_url        TEXT UNIQUE,             -- normalized
  title              TEXT NOT NULL,
  created_at         REAL NOT NULL,
  CHECK (calendar_series_id IS NOT NULL OR meeting_url IS NOT NULL)
);
```

### 12.4 Swift types

Record types live in `MumbleCore/Meetings` as plain `Codable`, `Sendable` structs (`Meeting`, `Person`, `Voice`,
`MeetingSpeaker`, `Segment`, `ActionItem`, `NoteItem`, `Mark`, `MeetingRule`). `MumbleCore` stays free of GRDB.
The `MumbleStore` target adds GRDB conformances (`FetchableRecord`, `PersistableRecord`) in extensions, plus
`MeetingStore`. `TimedWord` packing and unpacking of the `words` blob is a pure function in `MumbleCore`, unit-tested.

### 12.5 Key queries (must stay fast at 2,000 meetings)

| Feature | Query | Target |
|---|---|---|
| Meetings list | `meetings ORDER BY started_at DESC LIMIT 50` + speaker names | < 10 ms |
| Search all meetings | `segments_fts MATCH ?` joined to meetings, ranked by `bm25`, with `snippet()` | < 50 ms |
| Open action items | `action_items WHERE done = 0` (optionally by owner) | < 10 ms |
| Meetings with a person | `meeting_speakers WHERE person_id = ?` | < 10 ms |
| Rename / merge a person | single transaction updating `meeting_speakers`, `action_items`, `person_identifiers` | < 50 ms |
| Voice matching | load all `voices` (a few hundred rows) into memory once per meeting | < 20 ms |

### 12.6 Markdown copy (optional)

- Setting: **"Also save notes as Markdown"** (off) with a folder picker; the folder is remembered as a security-scoped
  bookmark so access survives relaunches.
- Written after a meeting reaches `done`, and rewritten (debounced 2 s) after edits: renames, checked action items,
  new names. Format is the export format in §4.7. File name: `YYYY-MM-DD <title>.md`, de-duplicated with ` (2)`.
- One-way: the database is the source of truth; edits to the Markdown file are not read back. If the user renamed or
  moved the file, Mumble writes a new one rather than overwriting something else.
- Private notes and voice data are never included. Deleting a meeting asks whether to also delete its Markdown file.

### 12.7 Live checkpoint and recovery

During recording, finalized live segments are inserted with `is_live = 1` every 60 s, so a crash still leaves a
searchable transcript. Final processing deletes the meeting's live rows and inserts the final segments in a single
transaction. On launch, meetings left in a non-final stage resume from that stage (§8).

## 13. Performance targets

| Metric | Target (M1, 60-min meeting, 4 people) |
|---|---|
| Live CPU while recording | ≤ 15% of one P-core average |
| Memory while recording | ≤ 350 MB above idle dictation (~170 MB) |
| Dictation latency while a meeting records | ≤ +30 ms vs. today (50–90 ms) |
| Processing time after stop (transcribe + diarize + identify) | ≤ 60 s |
| Summary (Apple model) | ≤ 45 s |
| Disk while recording | ≤ 500 MB per hour (both streams) |
| Diarization error (DER) on our eval set | ≤ 20% |
| Speaker-attributed words correct, after first meeting | ≥ 95% |

Measured by `mumble-eval meeting` (§14) and logged per meeting in `AppLog` (timings only).

## 14. Testing

### 14.1 Unit (CI, `MumbleCoreTests`)

- `NameVoting`: synthetic signal logs → expected assignments; thresholds; Hungarian uniqueness; lag window; single
  candidate rule; user override precedence.
- `CaptionAligner`: caption text vs. transcript with ASR errors, offsets, overlapping speakers.
- Name resolution: "Sarah C." / "sarah" / email → Person.
- `TranscriptMerger`: interleaving, gap splitting, echo-gated regions.
- `SummaryChunker`: chunk boundaries at speaker turns, token budget.
- Notes validation: invented owner/date rejected.
- `MarkdownExporter`: golden files.
- `MeetingStore` (`MumbleStore` tests, temp-file databases): every migration from an empty database and from each
  previous released schema; round trips; cascade deletes (meeting → all rows; person → voices); FTS stays in sync on
  insert/update/delete; search ranking and snippets; rename/merge person in one transaction; live rows replaced by
  final processing; 2,000-meeting fixture meets the §12.5 query targets.
- Markdown copy: file naming and de-duplication, rewrite on edit, never overwrites a moved or renamed file, never
  contains private notes.

### 14.2 Integration (local, `MUMBLE_INTEGRATION=1`)

- Eval set in `Eval/meetings/` (gitignored audio, checked-in manifests): real recordings of the team's own meetings,
  recorded **with everyone's consent**, plus AMI meeting corpus samples. Each has reference transcript, speaker turns
  and names.
- `mumble-eval meeting <dir>` reports WER, DER, speaker-attributed accuracy, naming accuracy by source, timings.
  CI does not run it (model downloads); results are pasted into PRs that touch the pipeline.

### 14.3 End-to-end (manual checklist + harness)

Extend the existing E2E harness (`Mumble/E2ETest.swift`, which already checks the target app is frontmost before
synthetic input) with a `--e2e-meeting` mode that plays a multi-speaker recording through a browser tab and verifies
the saved meeting. Manual checklist per release: Meet in Chrome, Meet in Safari, Zoom app, Teams app, Slack huddle;
headphones vs. laptop speakers; Bluetooth headset; screen sharing on; captions on/off; dictation during a meeting;
quit during processing → resume.

## 15. Milestones

Each milestone ships behind a "Meeting notes (beta)" toggle in Settings until M3. PR titles use `feat:` so releases
bump the minor version automatically.

| Milestone | Scope | Exit criteria |
|---|---|---|
| **M0 Spikes** (1 wk) | S1–S6 (§16) | Written results appended to this spec; go/no-go per signal |
| **M1 Record & transcribe** | Two-stream capture, process tap, echo gate, Start/Stop, island `.meeting`, Meetings list/detail with "You" / "Others", Markdown export, SQLite storage (GRDB, schema v1, migrations, search), resume after crash | 60-min recording on M1 processes in ≤ 60 s; no dictation regression; E2E Meet in Chrome passes |
| **M2 Speakers** | Offline diarization, Speakers section, Choose name…, People + saved voices (consent sheet), calendar roster, reminders R1–R3 and R5 (island `.suggest`, notification, menu item), catch-the-start R4 | Naming accuracy ≥ 95% on second meeting of eval groups; DER ≤ 20% |
| **M3 Notes** | Apple summarizer (map-reduce, guided generation), decisions/action items/open questions, action item → transcript links, bookmarks, private notes, search across meetings | Human review: no invented owners in 20 eval meetings; summary ≤ 45 s |
| **M4 Auto-naming** | Captions reader (per verified app), speaking-highlight reader (opt-in), participant list, voting | First-meeting naming ≥ 80% with captions on, ≥ 60% with highlight only |
| **M5 Polish** | Local MLX summarizer, Claude opt-in, merge speakers, audio playback from transcript, export options | Beta toggle removed |

## 16. Spikes (do first)

| ID | Question | How to answer | Decides |
|---|---|---|---|
| S1 | Can a process tap reliably capture Meet in Chrome/Safari/Arc, Zoom, Teams, Slack, including helper processes? | Minimal CLI that taps by bundle prefix and writes a WAV during a real call | §6.2 design; supported app list |
| S2 | Does voice processing on the mic cancel other apps' playback on macOS? | Play a meeting through speakers, record with/without voice processing, measure leaked energy | Whether the echo gate alone is enough |
| S3 | Can we read the browser's current tab URL via AX in Chrome, Safari, Arc without Automation permission? | AX tree dump of the address bar per browser | Meeting detection + calendar matching |
| S4 | What voice-match threshold gives < 1% wrong-person matches across meetings? | Embeddings from eval set, sweep threshold | §10.3 step 1 |
| S5 | Which apps expose live captions with speaker names in the AX tree? | AX tree dump with captions on: Meet (Chrome, Safari), Zoom, Teams | Whether captions are M4's primary signal |
| S6 | Which local model gives usable notes, at what speed and size? | Run 3 candidates on 5 transcripts | §9.2 Local provider |

## 17. Risks

| Risk | Mitigation |
|---|---|
| Meeting apps change UI, breaking captions/highlight readers | Signals are optional and fail closed; voices + Choose name… always work; per-app extractor versions logged |
| Process taps miss audio from some app setups | Fallback to mic-only with a clear warning; S1 defines the support matrix |
| Laptop speaker echo labels others as "You" | Voice processing + echo gate + own-voice check (§6.3) |
| Apple's 4k-token model gives shallow summaries | Map-reduce with typed extraction; local/Claude providers |
| Users record without consent | Consent sheet, visible indicators, docs |
| Biometric data concerns | Opt-in, local, deletable, never exported |
| Dictation gets slower during meetings | Shared model with priority; latency budget tested in E2E |

## 18. Open questions

1. Personal notes only, or should a later version share notes with the team (links, Slack posting)? Affects storage
   format and export.
2. Is macOS 26 acceptable for summaries, with macOS 15 users getting transcripts only (unless they choose Local or
   Claude)?
3. Should private notes ever be included in exports by default?
