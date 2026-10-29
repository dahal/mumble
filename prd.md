# Mumble — Product Requirements Document

| | |
|---|---|
| **Status** | Draft v0.2 (macOS only) |
| **Date** | 2026-10-29 |
| **Platform** | macOS 15+ on Apple silicon (M1 and later) |
| **Core engine** | [FluidAudio](https://github.com/FluidInference/FluidAudio) (CoreML on the Apple Neural Engine) |

---

## 1. Summary

Mumble is a voice-to-text app for the Mac that runs entirely on the device. You hold a key and speak. A Dynamic Island–style pill drops out of the notch, shows that it is listening and displays your words live. When you release the key, polished text appears in whatever app you were using, usually in under 150 ms.

There is no server, no account and no network after the model downloads. The three product pillars, in priority order:

1. **Accurate.** Words, names, numbers and punctuation come out right the first time.
2. **Fast.** The final text lands so quickly that it feels instant.
3. **Lightweight.** Small app, low idle memory, no battery drain, stays out of the way.

## 2. Problem

- **Built-in dictation** (Apple Dictation) is fast, but it is weak on names and jargon, has poor punctuation control, times out, and is inconsistent across apps.
- **Cloud dictation** (Wispr Flow and similar) is accurate but sends audio off-device, needs a network connection and a subscription, and adds round-trip latency.
- **Local Whisper apps** are accurate but heavy (1–3 GB models, GPU-bound) and slow to finish on long clips.
- **Parakeet on the ANE** via FluidAudio is now accurate (~2–3% WER on LibriSpeech), fast (~80–190× real-time on M-series), and power-efficient. Mumble's goal is to be the most polished and accurate way to use it on a Mac.

## 3. Goals and non-goals

### Goals
- G1. Dictate into any text field on macOS with a global hold-to-talk hotkey.
- G2. A notch "island" overlay showing listening state and a live preview of words while speaking.
- G3. A higher-accuracy final pass on release, inserted at the cursor.
- G4. Personal vocabulary (names, products, jargon) that measurably improves recall.
- G5. Fully offline after the first model download. No analytics that contain audio or text.

### Non-goals (v1)
- iOS, iPadOS, Windows, or web. Keep the core in a separate Swift package so iOS stays possible later, but do no iOS work now.
- Intel Macs. The ANE is required.
- Meeting recording, speaker diarization, or long-form transcription of files (possible v2; FluidAudio supports it).
- Cloud sync of history.
- LLM rewriting by default. Available as an opt-in, on-device-only mode (see §8.5).
- Translation.

## 4. Target users
- **Writers and knowledge workers** who type a lot: email, Slack, docs.
- **Developers** dictating prompts to AI tools and coding agents. They need jargon accuracy (`kubectl`, `SwiftUI`, `PostgreSQL`).
- **Privacy-sensitive users** (legal, medical, journalists) who can't send audio to a cloud.
- **Accessibility users**, for example people with RSI or motor impairments.

## 5. Success metrics

| Metric | Target |
|---|---|
| Release-to-text latency (≤15 s utterance, M1) | p50 ≤ 150 ms, p95 ≤ 300 ms |
| Release-to-text latency (≤15 s utterance, M3+) | p50 ≤ 100 ms, p95 ≤ 200 ms |
| Hotkey-to-recording-start (warm) | ≤ 50 ms, no clipped first syllable |
| First live preview word visible | ≤ 600 ms after speech onset |
| WER, internal English dictation eval set | ≤ 4% (beat Apple Dictation on the same set by ≥ 30% relative) |
| Personal-vocabulary term recall | ≥ 95% |
| Memory (model unloaded / loaded) | ≤ 40 MB / ≤ 350 MB, +~130 MB when vocabulary boosting is active |
| CPU while idle | ~0% (no running audio engine, no timers) |
| App download size (excluding models) | ≤ 15 MB |
| Crash-free sessions | ≥ 99.8% |

All targets are budgets to validate in Milestone 0 (§13). FluidAudio's published benchmarks come from an M2 MacBook Air only.

---

## 6. User experience

### 6.1 App shape
- **Menu bar app**, no Dock icon by default.
- **Menu bar menu:** start/stop, the last 5 transcripts (click to copy), model status, settings, quit.
- **Settings window:** a standard SwiftUI window with History, Vocabulary, Replacements and Settings tabs (§6.5).
- **Launch at login:** on by default, via `SMAppService`.

### 6.2 Triggers
- **Hold-to-talk** (default): hold `fn` (configurable: Right ⌥, Right ⌘, or any chord). Release to insert.
- **Toggle mode:** double-tap the hotkey to latch. Tap again or press `Esc` to finish.
- **Cancel:** `Esc` while recording discards the recording without inserting.
- **Re-insert last:** a configurable hotkey, default `⌃⌥V`, re-inserts the last transcript.
- **Accidental taps:** presses shorter than 150 ms are ignored.

### 6.3 Island overlay ("Notch Pill")
- **Placement and focus:**
  - A borderless, non-activating `NSPanel` at `.statusBar` level, anchored to the notch of the screen that holds the focused window.
  - It never steals focus, so the target app stays key. It ignores mouse events except in the error state.
  - On notch-less displays (external monitors, older Macs) it floats at top-center with the same look.
- **States:**
  1. **Idle.** Hidden.
  2. **Listening.** The pill expands out of the notch with a live mic-level waveform, and a red dot if recording is latched.
  3. **Live text.** The pill widens to show the last ~2 lines of the streaming preview. Preview text is dimmed; stable words are full opacity.
  4. **Finishing.** A brief shimmer, shown only if the final pass takes more than 150 ms.
  5. **Inserted.** A check-mark morph, then collapse (≤ 400 ms total).
  6. **Error.** No mic, model missing, secure field, nothing focused. The pill turns amber with a one-line reason. Clicking it opens the fix.
- **Motion:** spring animations matching the iOS Dynamic Island feel. Respects *Reduce Motion* and *Increase Contrast*.
- **Sounds:** optional, subtle start and stop sounds. On by default; the user can turn them off.
- **Prior art:** [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) (FluidVoice uses a fork). We can adopt it or write a ~300-line panel of our own. Decide in M0.

### 6.4 Text insertion
1. **Primary:** save the pasteboard, write the text, post a synthetic `⌘V` with `CGEvent`, then restore the pasteboard after about 300 ms. Needs the **Accessibility** permission.
2. **Fallback:** for apps that block paste, such as some terminals or remote desktops, type with `CGEvent` keyboard events in unicode-string chunks. A per-app override list lets the user force this mode.
3. **Secure input:** if Secure Input is on (`IsSecureEventInputEnabled()`, for example in a password field), do not insert. Show "Secure field — copied to clipboard."
4. **Spacing:** smart leading space and capitalization use the AX API (`kAXSelectedTextRangeAttribute` and the preceding characters) when it is available. If it is not, use plain heuristics.
5. **Never lose text:** the last transcript always stays available through history and the re-insert hotkey, even if insertion fails.

### 6.5 Settings window screens
- **History:** searchable list with copy, re-insert, delete, and audio playback if "keep audio" is on. Off by default.
- **Vocabulary:** add terms with optional aliases, for example `Kubernetes ← "cube and eighties"`. Import names from Contacts on opt-in.
- **Replacements:** deterministic find-and-replace rules applied after ASR, for example "new line" → `\n` or "smiley" → 🙂.
- **Settings:** model tier, hotkey and mode, input device, language, punctuation and formatting toggles, filler-word removal, sounds, history retention, and launch at login.

### 6.6 Onboarding (first run)
1. **Welcome:** a one-screen explanation that everything stays on this Mac.
2. **Microphone permission.**
3. **Accessibility permission:** deep-link to System Settings, then poll `AXIsProcessTrusted()` and continue automatically once it is granted.
4. **Model download:** show the size up front and a progress bar. "Optimizing for your Mac…" covers the first CoreML compile.
5. **Try it:** "Hold `fn` and say something" into a test field, with the result shown.

---

## 7. Architecture

```
mumble/
├── Packages/MumbleCore/            # Swift package, platform-agnostic, no AppKit
│   ├── Audio/                      # capture, resample, ring buffer, VAD gate
│   ├── ASR/                        # FluidAudio wrappers: Engine, Session, ModelStore
│   ├── TextPipeline/               # ITN, vocab, replacements, filler removal, casing
│   ├── Storage/                    # history (SQLite via GRDB), settings
│   └── Telemetry/                  # local-only perf counters (signposts)
├── Mumble/                         # the macOS app target
│   ├── App/                        # menu bar, settings window, onboarding
│   ├── Island/                     # NotchPill NSPanel + SwiftUI views
│   ├── Hotkey/                     # CGEventTap / flagsChanged monitor
│   └── Insertion/                  # pasteboard + CGEvent inserter, AX helpers
└── Eval/                           # WER harness CLI and test corpora
```

- **Language and UI:** Swift 6 with strict concurrency, SwiftUI. AppKit only for the panel, event tap and pasteboard.
- **Dependencies:**
  - **FluidAudio:** pin an exact version. Use package traits to drop `TTS` and `Diarizer` and keep the binary small: `traits: ["NemoTextProcessing"]` for ITN, which adds about 8 MB.
  - **`KeyboardShortcuts`** (sindresorhus) for the hotkey recorder UI. Hold-to-talk on `fn` needs our own `NSEvent` flagsChanged monitor or `CGEventTap`.
  - **GRDB** for history.
  - **Sparkle** for updates.
  - Nothing else unless it earns its place.
- **Concurrency model:**
  - **`AudioCapture`:** an actor wrapping `AVAudioEngine`. The input tap converts to 16 kHz mono Float32 with `AVAudioConverter` on the audio thread and pushes into a lock-free ring buffer. No allocation and no `await` on the render thread.
  - **`TranscriptionEngine`:** an actor that owns the loaded `AsrModels` and its managers. It runs one job at a time, and every job carries a session `UUID` so stale work is discarded (as FluidVoice does).
  - **`DictationSession`:** a `@MainActor @Observable` state machine (`idle → arming → listening → finalizing → inserting → idle | error`) that drives the island and the menu bar.

---

## 8. Speech pipeline

### 8.1 Two-pass design
Mumble uses a cheap pass for live preview and an accurate pass for the final text.

```
mic ─► 16k mono ring buffer ─┬─► [Preview path]  every ~400 ms → partial text → island
                             │
                             └─► [On release]    full buffer → Final model (+vocab) → TextPipeline → insert
```

- **Preview path (option A, default):** re-run the *same* final model on the whole buffer at about 400 ms intervals while the utterance is ≤ 15 s. Above 15 s, switch to incremental chunked decoding: only new audio is encoded and earlier chunks are committed. FluidVoice uses the same approach, with a 15 s threshold (`240_000` samples).
  - **Pro:** a single model in memory, and the preview matches the final.
  - **Con:** repeated ANE work, but at ~80× real-time a 10 s buffer costs about 125 ms per tick.
- **Preview path (option B):** a dedicated streaming model, either *Parakeet EOU 120M* (160/320 ms chunks, ~7.1% WER) or *Nemotron Streaming 0.6B* (560–2240 ms chunks, ~2.0% WER).
  - **Pro:** true streaming, and EOU can auto-stop in toggle mode.
  - **Con:** a second model in memory (with EOU), visible preview-vs-final differences, and more download.
  - Evaluate in M0. Default to A for lightness.
- **Final pass:**
  - Run `AsrManager.transcribe(samples)` on the complete buffer, prefixed with 250 ms of silence. FluidVoice found this helps the first word on short clips.
  - When the vocabulary is non-empty, boost with `customVocabulary:`. Skip the CTC pass entirely when `hasCTCRescoringCandidates` is false.
  - Apply boosting only on the final pass. FluidAudio documents that boosting degrades in streaming mode.
- **Short clips:**
  - FluidVoice reports about 40 ms for final ASR on short audio.
  - Skip near-silent clips of 4 s or less: peak < 0.01 and RMS < 0.002, with no preview words recognized. Treat them as a cancel.
  - Use FluidAudio's Silero VAD (`VadManager`, 256 ms hops) to trim leading and trailing silence before the final pass. This speeds up the pass and avoids hallucinated trailing words.

### 8.2 Model choice

Figures are from FluidAudio's `Documentation/Models.md` and `ASR/benchmarks100.md` (MacBook Air M2), LibriSpeech test-clean WER. Re-measure all of them on our eval set (§10).

| Model | Download | Langs | WER (clean) | Min macOS | Role in Mumble |
|---|---|---|---|---|---|
| **Parakeet Ultra** | ~600 MB (int8 encoder 595 MB) | 25 EU | 2.13% | – | **Default "Max" / multilingual** |
| Parakeet Unified EN 0.6B | ~0.6B, int8/fp16 | EN | 2.15%, punctuation and casing built in | ? | Candidate English default, decided in M0 |
| Phonon-2 | 176–470 MB (321 MB default) | EN | 2.47%, 159× | 15 | **Default "Balanced" English** |
| Parakeet TDT v3 | ~0.6B | 25 EU | 2.6%, ~80× | – | Fallback multilingual |
| Parakeet TDT v2 | ~0.6B | EN | 3.8%, documented as "highest recall" | – | English fallback |
| Parakeet Redux | ~220 MB | 25 EU | EN 2.71% | 15 | "Light" multilingual |
| TDT-CTC-110M | ~110M params | EN | 3.0–3.6%, ~100×+ | – | "Light" English and the cheapest vocab boost (~1 MB CTC head) |

**v1 policy**
- **Settings:** three tiers named **Light / Balanced / Max**, not model names, with the language choice picking English-only or multilingual variants. Advanced users can pick the exact model.
- **Default:** Balanced. Phonon-2 for English; Redux for other languages. Final choice is data-driven from M0, and Ultra or Unified EN may become the default if the latency budget allows.
- **Downloads:** models come from Hugging Face (`FluidInference/*`) on first launch. Downloads are resumable, with SHA-256 verification and a test transcription of a bundled clip before the model is activated. Keep the last working model until the new one passes (FluidVoice's pattern).

### 8.3 Custom vocabulary
- **API:** FluidAudio `CustomVocabularyContext` / `CustomVocabularyTerm` (with aliases), driven by a `CtcKeywordSpotter`.
- **Cost on 0.6B models:**
  - A separate Parakeet CTC 110M encoder: +97.5 MB download, about +130 MB peak memory, and about 26× real-time for that pass.
  - Load it lazily, only when the vocabulary is non-empty.
  - On the 110M model the CTC head is shared, at about 1 MB extra.
- **Limits:**
  - Recommend ≤ 100 terms and warn above 230.
  - Terms must be ≥ 4 characters, configurable.
  - Use the documented tuning: `defaultCbw` ≈ 4.5. For short acronym-style terms, disable spotter rescue to avoid false positives.
- **UX:** an "Add to vocabulary" action on any history item. Select the misheard word and type the correct term.

### 8.4 Text pipeline (deterministic, < 2 ms)
1. **Inverse text normalization:** FluidAudio `TextNormalizer.shared.normalize(result:)`. It converts numbers, currency, dates and emails ("test at gmail dot com" → `test@gmail.com`) and supports EN, DE, ES, FR, HI, JA and ZH. Toggleable.
2. **Spoken commands:** "new line", "new paragraph", "period" and similar, when explicit-punctuation mode is on.
3. **User replacement rules.**
4. **Filler removal** (optional): "um", "uh", stutter repeats.
5. **Context casing and spacing** via AX, using the preceding character.

### 8.5 Optional on-device rewrite (off by default)
- **What it is:** a "Polish" mode using Apple's on-device **Foundation Models** framework (macOS 26+, Apple Intelligence Macs). It does grammar cleanup and handles self-corrections such as "no wait, Tuesday".
- **Constraints:**
  - Strict prompt: "don't add content".
  - Hard timeout of 800 ms. On timeout, insert the raw text.
  - Never the default, because it costs latency and risks changing meaning.

### 8.6 Apple Speech framework (`SpeechAnalyzer`): evaluated, not the primary engine

macOS 26 ships `SpeechAnalyzer` with two modules: `SpeechTranscriber`, a new long-form model, and `DictationTranscriber`, the older on-device dictation model.

**What it offers**
- **Fast:** about 0.10 s for a 2–8 s clip on an M4, against Parakeet v3's 0.13 s. About 64× real-time on an M2 Pro.
- **Live results:** volatile results come back almost as soon as speech occurs, then are finalized.
- **Word timing:** sample-accurate `audioTimeRange` per result.
- **Zero footprint:** the OS downloads and manages the model (`AssetInventory`). It adds nothing to the app's size or memory, because the model runs outside the app's process.

**Why it is not the primary engine**
1. **Less accurate than Parakeet in every independent test we found:**
   - FLEURS English: 6.7% WER, against 4.5% for Parakeet v3 and 3.9% for Whisper large-v3-turbo.
   - Real-voice dictation on a MacBook mic: 15.0% WER, against 13.6% for Parakeet v3.
   - Formatted error rate, where punctuation and casing count: 11.1%, against 8.2% for Parakeet v3.
   
   One blog reports 2.12% on LibriSpeech clean, but that test did not include Parakeet.
2. **No custom vocabulary on `SpeechTranscriber`.** `AnalysisContext.contextualStrings` only biases the older, less accurate `DictationTranscriber`. Custom vocabulary is a core accuracy lever for us (§8.3).
3. **Few languages:** `SpeechTranscriber` covers far fewer languages than Parakeet's 25. The FLEURS benchmark could run only 6 of Parakeet's 25 languages through it.
4. **macOS 26+ only.** Our floor is macOS 15.
5. **No control over the model:** the OS can update it at any time, so accuracy can change under us, which our eval ship gate (§10) cannot catch. We also can't pick model size or tune decoding.

**Where we do use it**
- **Zero-download fallback (macOS 26+):** dictation works on minute one while the Parakeet model downloads and compiles. The island shows a small "Quick mode" badge, and Mumble switches to Parakeet automatically once it is ready.
- **Eval baseline:** run on the same dictation set in every eval run (§10). The product claim "more accurate than Apple" is checked continuously, not assumed.
- **Possible "Light" tier:** zero app memory and zero download, for users who prioritize lightness over accuracy. Decide from M0 data.

Revisit this decision at each WWDC. If Apple's model overtakes Parakeet on our eval set, the `TranscriptionEngine` protocol (§7) lets us swap engines without touching the rest of the app.

---

## 9. Performance and lightness plan

- **Model residency:** load at launch and keep resident while the app runs. That's about 300 MB, acceptable for a dictation tool. A setting can unload it after N idle minutes, with the next dictation paying the reload cost.
- **Warmup:** after load, run one tiny inference so the first real dictation doesn't pay first-run cost.
- **Mic lifecycle:**
  - **Problem:** a running `AVAudioEngine` holds the mic. That shows the orange privacy dot and can degrade Bluetooth headphones to the low-quality headset profile.
  - **Approach:** prepare the engine but don't start it until the hotkey is pressed. Keep it running for about 8 s after a session ends (FluidVoice's standby value) so rapid follow-ups start instantly.
  - **Pre-roll:** capture about 300 ms of pre-roll only while the engine is already running, so the first syllable is never lost.
  - **Experimental:** a direct Core Audio input path for faster cold start, as FluidVoice has. Only if `AVAudioEngine` cold start misses the 50 ms budget.
- **Compile models once:** CoreML caches the compiled model after the first load. Show "Optimizing for your Mac…" once.
- **No work on the main thread** besides UI. All ASR work runs on the engine actor, and previews never queue up: if a tick is still running, skip the next one.
- **Idle cost:** no running audio engine, no polling timers, and the island panel is ordered out (not just hidden) when idle.
- **Binary size:**
  - Disable the FluidAudio `TTS` and `Diarizer` traits.
  - No heavy dependencies.
  - Models are downloaded, not bundled.
- **Instrumentation:** `os_signpost` intervals for capture start, preview tick, final ASR, text pipeline and insertion, visible in Instruments. A hidden "Diagnostics" pane shows the last 50 latencies locally. Nothing is uploaded.

## 10. Accuracy plan

Accuracy is the top pillar, so it needs its own harness from day one.

- **`Eval/` CLI** (`swift run mumble-eval`):
  - Runs every candidate model and configuration over test sets and reports WER, CER, entity recall, punctuation F1, and latency.
  - Runs in CI on the Mac for regression tracking.
- **Test sets:**
  1. LibriSpeech test-clean/other subsets, as a sanity check against FluidAudio's published numbers.
  2. **Mumble dictation set:** 300+ real dictation-style clips that we record. They cover short commands, emails, code and tech jargon, numbers, dates, addresses and names, and include accents and noisy environments (café, AirPods mic, MacBook built-in mic, external USB mic).
  3. **Vocabulary set:** clips containing 50 user-style terms. Measure recall with and without boosting, plus the false-positive rate.
- **Ship gate:** any model or pipeline change must not regress dictation-set WER by more than 0.2 points absolute or entity recall by more than 1 point.
- **Comparison baseline:** Apple `SpeechAnalyzer` (macOS 26) and Apple Dictation on the same set. If Mumble isn't clearly better, we haven't earned the product.

## 11. Privacy and security
- Audio and text never leave the Mac. The only network calls are model downloads from Hugging Face and the Sparkle update check.
- Audio is in memory only and discarded after transcription, unless the user turns on "Keep recordings".
- History is stored locally in Application Support. A retention setting offers 1 day, 7 days, 30 days or forever.
- Pasteboard hygiene: insertion marks its temporary pasteboard item as transient (`org.nspasteboard.TransientType`) so clipboard managers ignore it, and restores the user's previous clipboard.
- No analytics SDK. Crash reports only through opt-in MetricKit.

## 12. Distribution
- **Direct download** as a notarized, hardened-runtime `.dmg`, with auto-updates via Sparkle. This is the only channel for v1, because global event taps and Accessibility-based paste are awkward under the Mac App Store sandbox.
- A Homebrew cask after the beta.
- **Pricing (open question):** free with Light/Balanced, plus a one-time purchase for Max, vocabulary and history? Decide before beta.

## 13. Milestones

| Milestone | Scope | Exit criteria |
|---|---|---|
| **M0 — Spikes (1–2 wk)** | `MumbleCore` + eval CLI. Benchmark the models in §8.2 on M1, M2 and M3/M4 Macs. Prototype the notch panel. Measure `AVAudioEngine` cold start. | Model defaults chosen with data. Latency and memory budgets in §5 confirmed or revised. Preview option A vs B decided. |
| **M1 — Alpha (3 wk)** | Hold-to-talk, notch pill, paste insertion, preview option A, ITN, history, onboarding, menu bar. | Daily-driveable by the team. Release-to-text p50 ≤ 150 ms on M1. |
| **M2 — Accuracy (2 wk)** | Custom vocabulary, replacements, filler removal, VAD trim, AX-aware spacing, dictation eval set. | Beats Apple Dictation by ≥ 30% relative WER on our set. Vocab recall ≥ 95%. |
| **M3 — Beta (2 wk)** | Polish, performance pass, crash hardening, per-app insertion overrides, Sparkle, notarized build. | Metrics in §5 met on the reference Macs. |
| **v1.1** | Optional Foundation Models polish, toggle-mode auto-stop via EOU, iCloud vocabulary sync. | |

## 14. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| ANE contention between two concurrent CoreML models (FluidVoice saw SIGTRAPs with CTC + main manager) | Crashes | Serialize all ANE work through one actor. Never run the preview and the boosted final concurrently. |
| int8 encoder incompatibilities on some chips | Crashes or garbage output | Run the verification transcription before activating any model. Fall back to fp16 or another model. |
| Paste insertion fails in some apps | Text lost | Always keep the last result on the clipboard and in history, with the re-insert hotkey. Typed fallback and per-app overrides. |
| `fn` key is already bound to the emoji picker or system dictation | Hotkey conflicts | Detect it during onboarding and offer to change the system setting, or suggest Right ⌥. |
| Bluetooth headset mic drops to low quality | Accuracy loss | Detect it and show a hint suggesting the built-in mic. Let the user pick the input device in settings. |
| Model download size (~220–600 MB) | Onboarding drop-off | Show the size up front. Balanced tier by default. Resumable downloads. |
| FluidAudio API churn (fast-moving SDK, docs show inconsistent versions) | Breakage on upgrade | Pin the exact version. Wrap it behind our `TranscriptionEngine` protocol. The eval suite gates upgrades. |
| macOS permission changes (Accessibility, Input Monitoring) across OS versions | Hotkey or insertion stops working | Health check on launch, with a clear repair flow in the island error state. |

## 15. Open questions
1. Is preview option A (re-run the final model) or B (dedicated streaming model) better in feel versus memory? Decide in M0.
2. Which model is the default: Phonon-2, Ultra, or Unified EN, which has built-in punctuation and casing?
3. Does `fn` hold-to-talk need `CGEventTap` (and the Input Monitoring permission), or is an `NSEvent` flagsChanged monitor enough?
4. Should we adopt DynamicNotchKit or build our own panel?
5. Business model: free / one-time purchase / subscription?
6. Should Apple `SpeechTranscriber` also be a user-selectable "Light" tier, or only a fallback during download (§8.6)?
7. **Accuracy ceiling:** is there a "Max+" tier worth offering?
   - **LFM3-Audio-2B:** FluidAudio lists 1.32% LibriSpeech-clean WER at about 18× real-time and about 2.5 GB.
   - **Whisper large-v3-turbo:** slightly more accurate on English in some tests, but about 2.9 s per short clip on an M4. That breaks the latency budget.

## 16. References
- FluidAudio — <https://github.com/FluidInference/FluidAudio> (README, `Documentation/Models.md`, `ASR/CustomVocabulary.md`, `ASR/PostProcessing.md`, `ASR/benchmarks100.md`)
- FluidVoice, the reference Mac implementation on FluidAudio — <https://github.com/altic-dev/FluidVoice> (`Sources/Fluid/Services/FluidAudioProvider.swift`, `ASRService.swift`)
- DynamicNotchKit — <https://github.com/MrKai77/DynamicNotchKit>
- Apple, "Bring advanced speech-to-text to your app with SpeechAnalyzer" (WWDC25) — <https://developer.apple.com/videos/play/wwdc2025/277/>
- Apple `DictationTranscriber` docs (contextual strings) — <https://developer.apple.com/documentation/speech/dictationtranscriber>
- Apple Developer Forums, `AnalysisContext` only affecting `DictationTranscriber` — <https://developer.apple.com/forums/thread/811083>
- On-device ASR benchmark, Parakeet vs Whisper vs SpeechTranscriber (FLEURS) — <https://github.com/founden-bot/on-device-asr-benchmark>
- Walkie on-device STT benchmark (real-voice dictation, M4) — <https://trywalkie.com/en/blog/on-device-speech-to-text-benchmark>
