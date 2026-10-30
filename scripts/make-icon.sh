#!/bin/zsh
# Updates the app icon from a square, full-bleed artwork image (no rounded corners needed).
#
#   scripts/make-icon.sh Design/AppIcon-macOS-source.png
#
# The icon is an Icon Composer document (Mumble/AppIcon.icon). Xcode 26 compiles it into the
# macOS 26 icon, where the system applies the rounded shape (pre-shaped legacy icons get shrunk
# onto a gray tile), and generates the icons for older macOS. This script replaces its artwork
# and renders a preview with Apple's ictool.
set -euo pipefail
cd "$(dirname "$0")/.."
source="$1"
icon=Mumble/AppIcon.icon
ictool="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}/../Applications/Icon Composer.app/Contents/Executables/ictool"

sips -z 1024 1024 "$source" --out "$icon/Assets/artwork.png" >/dev/null
mkdir -p build
"$ictool" "$icon" --export-image --output-file build/AppIcon-preview.png \
  --platform macOS --rendition Default --width 512 --height 512 --scale 2 >/dev/null
echo "Updated $icon from $source; preview: build/AppIcon-preview.png"
