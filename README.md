# Mumble

Fast, accurate, fully on-device dictation for the Mac. Hold a key, speak, release: the text appears
wherever your cursor is. Speech recognition runs on the Apple Neural Engine via
[FluidAudio](https://github.com/FluidInference/FluidAudio) (NVIDIA Parakeet-family models).
Audio and text never leave your Mac.

See [prd.md](prd.md) for the product spec.

## Run it

```sh
brew install xcodegen          # once
scripts/build.sh               # → build/Mumble.app
open build/Mumble.app
```

Optionally drag `build/Mumble.app` into `/Applications`.

On first launch Mumble opens its settings window:

1. **Microphone**: click *Grant…*.
2. **Accessibility**: click *Grant…*, then turn Mumble on in System Settings → Privacy & Security →
   Accessibility. This is how Mumble hears the shortcut and pastes text.
3. **Speech model**: downloads once (~330 MB for the default Phonon-2) and is cached in
   `~/Library/Application Support/FluidAudio`.

Then, in any app:

| Action | Result |
|---|---|
| Hold **Right ⌥ Option**, speak, release | Text is inserted at the cursor |
| Double-tap Right ⌥, speak, press it once more | Hands-free (locked) dictation |
| **Esc** while recording | Cancel |
| Menu bar → *Paste last again* | Re-insert the last dictation |

The trigger key can be changed to fn, Right ⌘ or Right ⌃ in settings. If you choose fn, set
System Settings → Keyboard → "Press 🌐 key to" → "Do Nothing" so it doesn't also open the emoji picker.

> **Note on rebuilding:** the app is ad-hoc signed (no Developer ID on this machine). macOS ties the
> Accessibility permission to the exact binary, so after each rebuild remove Mumble from the
> Accessibility list and add it again. A Developer ID signature would fix this.

## Features

- **Notch island**: a Dynamic Island–style pill grows out of the notch, showing the input level, a
  timer and the live transcript. On displays without a notch it floats below the menu bar.
- **Two-pass recognition**: a live preview every ~450 ms, then one final pass on release
  (~30–50 ms for a typical sentence on an M2 Max).
- **Custom vocabulary** with aliases: CTC keyword boosting, plus safeguards that reject any swap
  that drops words or replaces real dictionary words (see `Vocabulary.guardRescore`).
- **Text clean-up**: filler-word removal, "new line" / "new paragraph", user replacement rules,
  cursor-aware spacing and capitalization. Writing numbers as digits is opt-in (experimental).
- **Never loses text**: the clipboard is restored after pasting; secure (password) fields get a
  copy instead of a paste; history is kept locally and can be turned off.
- **Model choice**: Phonon-2 (default), Parakeet Ultra (multilingual, most accurate), TDT v3/v2,
  and a light 110M model.

## Layout

```
Packages/MumbleKit/          Swift package
  Sources/MumbleCore/        pure logic: text pipeline, vocabulary, hotkey gesture, WER, audio analysis
  Sources/MumbleASR/         FluidAudio wrapper (TranscriptionEngine), audio file loading
  Sources/MumbleEval/        mumble-eval CLI
  Tests/                     unit tests + model integration tests
Mumble/                      the macOS app (menu bar, island, hotkey, recorder, inserter, settings)
Eval/make-tts-corpus.sh      builds a synthetic eval set with macOS voices
scripts/build.sh             builds build/Mumble.app
scripts/make-icon.swift      renders the app icon
project.yml                  XcodeGen project definition
```

## Test

```sh
cd Packages/MumbleKit
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test                               # unit tests (fast, no model)
MUMBLE_INTEGRATION=1 swift test          # + real-model tests (downloads the model on first run)
```

Accuracy and speed:

```sh
Eval/make-tts-corpus.sh                                   # or add your own .wav + .txt pairs
swift run -c release mumble-eval ../../Eval/tts           # WER + real-time factor
swift run -c release mumble-eval <dir> --model ultra --vocab "kubectl,Supabase"
```

App-level checks without touching the keyboard:

```sh
build/Mumble.app/Contents/MacOS/Mumble --self-test some.wav     # full pipeline on a file
build/Mumble.app/Contents/MacOS/Mumble --demo-island            # animate the island on screen
build/Mumble.app/Contents/MacOS/Mumble --render-island /tmp/x   # island states → PNGs
```

## Measured (M2 Max, Phonon-2)

| | Result |
|---|---|
| Synthetic dictation set (10 sentences) | 0% WER, ~30 ms per sentence, ~90× real-time |
| Jargon set (names, dev tools) without vocabulary | 23.8% WER |
| Same, with vocabulary | 9.5% WER, and still 0% on the plain set (no false swaps) |
| App bundle | 6.9 MB (models downloaded separately) |

The test sets are synthetic speech from `say`, so treat these as smoke tests. Real recorded dictation
belongs in `Eval/` before claiming accuracy numbers.
