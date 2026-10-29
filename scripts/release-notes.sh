#!/bin/zsh
# Prints the install section for a GitHub release's notes.
#   scripts/release-notes.sh <version> <notarized: 0|1> [owner/repo]
set -euo pipefail
version="$1"
notarized="$2"
repo="${3:-dahal/mumble}"

cat <<EOF
## Install

**One line** (recommended; also updates an existing install):

\`\`\`sh
curl -fsSL https://raw.githubusercontent.com/$repo/main/scripts/install.sh | bash
\`\`\`

The script checks your Mac is supported, verifies the download's SHA-256 checksum and code signature,
installs Mumble to /Applications and opens it.

**Or download manually:** open **Mumble-$version.dmg** below and drag Mumble to Applications.
EOF

if [[ "$notarized" != "1" ]]; then
  cat <<'EOF'
This build isn't notarized by Apple, so the first time you open a manually downloaded copy macOS
says it "could not verify Mumble". Go to **System Settings → Privacy & Security**, scroll down and
click **Open Anyway** (once). The one-line installer avoids this step.
EOF
fi

cat <<'EOF'

**Requirements:** a Mac with Apple silicon (M1 or later) running macOS 15 or later.

**First launch:** allow Microphone access, enable Mumble under System Settings → Privacy & Security →
Accessibility, and let the speech model download once (~330 MB). Then hold **Right ⌥ Option**, speak,
and release.

Verify downloads with `shasum -a 256 -c SHA256SUMS.txt`.
EOF
