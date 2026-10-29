#!/bin/zsh
# Builds a small synthetic eval set with macOS's built-in voices: one .wav + .txt reference per line.
# Real recorded dictation should be added alongside; synthetic speech is only a smoke test.
set -euo pipefail
out="${1:-$(dirname $0)/tts}"
mkdir -p "$out"
i=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  i=$((i+1)); name=$(printf "%02d" $i)
  say -o "$out/$name.wav" --file-format=WAVE --data-format=LEI16@16000 "$line"
  print -r -- "$line" > "$out/$name.txt"
done <<'LINES'
Hey Sam, can you send me the quarterly report before Friday?
I think we should move the meeting to Tuesday afternoon.
Please remind me to call the dentist tomorrow morning.
The deployment failed because the database migration timed out.
Let's grab coffee at nine thirty and go over the roadmap.
Our revenue grew by twelve percent compared to last year.
Can you review my pull request when you get a chance?
I'm running about ten minutes late, sorry about that.
The new design looks great, but the buttons feel a little small.
Book a table for four people at seven o'clock on Saturday.
LINES
echo "Wrote $i clips to $out"
