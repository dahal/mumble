# Braindump: Meeting notes

> Status: exploration, Oct 30 2026. The buildable version of this lives in
> [`docs/specs/meeting-notes.md`](../specs/meeting-notes.md). This file keeps the thinking behind it.
>
> Design: Paper, file **Mumble**, page **v0-meeting-notes**
> (<https://app.paper.design/file/01M65TS5D8AZS6K2CK9KBQQZ7B/p-1-0>).

## The idea in one paragraph

On a Google Meet, Zoom or Teams call, Mumble records the conversation, transcribes it with **who said what, by
name**, and produces notes: summary, decisions, action items with owners, open questions, and links back to the exact
moment. Everything runs on the Mac, like dictation does today. No meeting bot joins the call, no account, no cloud.

## Why this is mostly integration, not research

FluidAudio (v0.18.0, already a dependency) ships far more than ASR:

| Capability | FluidAudio piece | Notes |
|---|---|---|
| Speech to text | `AsrManager` (Parakeet) | ~90× real-time on Apple silicon, already used by dictation |
| Who spoke when (after the call) | `OfflineDiarizerManager` | pyannote community-1 based, VBx clustering, 17.7% DER on AMI |
| Who spoke when (live) | `SortformerDiarizer`, `LSEENDDiarizer` | Streaming; good for the live island, not the final notes |
| Voice fingerprints | `EmbeddingExtractor`, `CampPlusEmbedder` | Embeddings we can save per person |
| Matching known voices | `SpeakerManager` (`findSpeaker(with:)`) | Seed with saved voices, match new clusters |
| Voice activity | Silero VAD | Skip silence, find pauses |

## Key decisions (and why)

### 1. Record two streams, not one

- **Microphone** is always *you*, so your lines are labeled correctly for free.
- **The meeting app's own audio** is everyone else. macOS 14.4+ Core Audio process taps record one app's output, so
  there's no virtual audio driver and no bot.
- Keeping them apart also stops speaker echo from being transcribed twice.

### 2. The screen doesn't decide who is talking; it votes on names

Diarization splits the remote audio into Speaker A, B, C. Screen signals are only used to **name** those voices.
Across the whole meeting we count co-occurrence:

> Speaker B was talking while Sarah's tile was highlighted 91% of the time → Speaker B = Sarah.

Counting over the whole meeting is what makes it robust: the highlight lags speech by about half a second and people
overlap, but over 30 minutes the pattern is obvious. Once named, the voice is saved, so future meetings don't need
the screen.

Two screen signals, best first:

1. **Live captions** (Meet, Zoom and Teams all have them, and they're shown only to you). They read
   "Sarah Chen: so the annual plan is live…". Mumble already has Accessibility permission and may be able to read
   them without screenshots. Aligning caption words with our transcript gives a direct voice → name link.
   *Unverified per app; needs a spike.* Requires captions to be on.
2. **The speaking highlight.** Every app outlines the active speaker. Capture ~2 frames/s of the meeting window only,
   find the highlighted tile, read its name label with Apple's on-device text recognition, discard the frame.
   Needs Screen Recording permission; breaks during screen sharing and when an app redesigns.

### 3. Participants: use the Mac's Calendar; no Google sign-in, no email

- Google, Office 365/Exchange and iCloud calendars already sync into Apple Calendar for most Mac users.
  **EventKit** gives attendee names, emails, which one is you, and the meeting link, after one standard permission
  prompt. One integration covers Meet, Zoom and Teams.
- Match the event by time overlap, and tighter by comparing the event's meeting link with the URL of the Meet tab.
- **Avoid:** Google Calendar OAuth (a "sensitive" scope that needs Google's verification review; only helps people
  whose calendar isn't synced to the Mac), **reading email** (a "restricted" Gmail scope needing a paid security
  assessment, and a huge trust ask for a privacy product), and Zoom/Teams/Slack APIs (OAuth apps, admin approval).
- The attendee list is a **shortlist of names**, not the identifier. The feature works without it.
- Emails make saved voices durable: `sarah@company.com` matches whether the app shows "Sarah Chen", "Sarah C." or "sarah".

### 4. Naming fallback chain

1. Saved voices (automatic)
2. Captions, if on
3. Speaking highlight, if Screen Recording is allowed
4. Ask: a one-click **Choose name…** picker, shortlisted from the calendar

| Situation | Where names come from |
|---|---|
| Recurring team meeting | Saved voices |
| Scheduled meeting, new people | Calendar shortlist + captions or highlight |
| Ad-hoc call or huddle, no invite | Screen + Choose name… |
| Calendar permission declined | Screen + Choose name… |

### 5. Summaries on the Mac by default

- **Default:** Apple Foundation Models (on-device, macOS 26). Small context (~4k tokens), so summarize in chunks, then
  merge. Guided generation gives typed action items.
- **Option:** a larger local model via MLX (better quality, multi-GB download).
- **Opt-in:** Claude. Only transcript *text* leaves the Mac, never audio, and only when chosen per meeting or globally.

### 6. Forgetting the shortcut shouldn't lose the meeting

Decided defaults (spec §4.1.1):

- **On:** detect the meeting (mic in use by a meeting app or meeting page) and prompt in the island + a notification;
  a 1-minute heads-up for calendar meetings; one second reminder after 2 min, then silence.
- **Opt-in:** *catch the start* (hold the last 2 minutes in memory only until you answer, wiped on Not Now), and
  *always take notes for this meeting* for chosen recurring meetings.

### 7. Store notes in SQLite, with an optional Markdown copy

Meetings are relational (meetings → transcript lines → speakers → people → voices → action items) and need search
across years of meetings. **SQLite via GRDB** (full-text search, migrations, live SwiftUI updates) is the source of
truth; audio stays as separate files. An optional "Also save notes as Markdown" folder (e.g. an Obsidian vault) gives
users plain files they own. Dictation history stays JSON. Details: spec §12.

### 8. It's a mode of Mumble, not a new app

Shares models, menu bar, notch island and window. "Dictation + meetings, 100% local" is a stronger pitch than two apps.

## UI (native, follows the existing app)

Designed from the current SwiftUI code, not a new visual language:

- **Window:** a new **Meetings** row in the existing `NavigationSplitView` sidebar. The list pane mirrors **History**
  (searchable `List`, date sections, caption line). The detail pane is a `.grouped` `Form` like **General**:
  Summary, Action items (checkboxes + owner), Speakers (`PermissionRow`-style with a **Choose name…** picker),
  Transcript (History-style rows). Toolbar: back, Copy as Markdown, delete.
- **Island:** the existing black notch pill with waveform bars, red dot and timer, plus a "Meeting notes" label and the
  current speaker's name in front of the live line.
- **Menu bar:** the existing menu, plus Start/Stop Meeting Notes, Bookmark This Moment, Add Private Note….

## Things that need care

- **Consent and law.** Some US states require all-party consent. Clear recording indicator, plus a one-click "Mumble is
  taking notes" message to paste into the meeting chat. Voice fingerprints are biometric data (e.g. Illinois BIPA):
  local only, opt-in, deletable.
- **Audio storage.** Dictation never stores audio. Meetings must keep it until processing ends. Default: delete after
  processing; option to keep.
- **Echo on laptop speakers.** Without headphones the mic hears other people too. Needs echo handling, plus checking
  "You" segments against your own saved voice.

## Open questions

1. Personal notes only, or shared with the team? Sharing changes export and privacy design.
2. macOS 26 as the minimum for summaries (Apple's model), or keep macOS 15 with summaries unavailable there?
