#!/bin/bash
# Installs or updates Mumble from GitHub Releases. No clone or build needed:
#
#   curl -fsSL https://raw.githubusercontent.com/dahal/mumble/main/scripts/install.sh | bash
#
# Options (environment variables):
#   MUMBLE_VERSION=1.2.0     install a specific version instead of the latest
#   MUMBLE_INSTALL_DIR=...   install somewhere other than /Applications
#   MUMBLE_UNINSTALL=1       remove Mumble (keeps your settings and downloaded models)
#
# What it does: checks this Mac is supported, downloads the release zip, verifies its SHA-256
# checksum and code signature, quits a running Mumble, installs, and opens it. Because the download
# is made by curl rather than a browser, macOS doesn't quarantine it, so there's no
# "Open Anyway" step even for builds that aren't notarized.
set -euo pipefail

REPO="${MUMBLE_REPO:-dahal/mumble}"
VERSION="${MUMBLE_VERSION:-latest}"
INSTALL_DIR="${MUMBLE_INSTALL_DIR:-/Applications}"
APP="$INSTALL_DIR/Mumble.app"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$1" >&2; exit 1; }

quit_running() {
  if pgrep -x Mumble >/dev/null 2>&1; then
    echo "Quitting the running Mumble…"
    osascript -e 'quit app "Mumble"' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Mumble >/dev/null 2>&1 || break; sleep 0.5; done
    pkill -x Mumble >/dev/null 2>&1 || true
  fi
}

if [[ "${MUMBLE_UNINSTALL:-}" == "1" ]]; then
  quit_running
  rm -rf "$APP"
  bold "Mumble removed from $INSTALL_DIR."
  echo "Settings and history: ~/Library/Application Support/Mumble  (delete manually if wanted)"
  echo "Speech models:        ~/Library/Application Support/FluidAudio"
  exit 0
fi

# --- Requirements -------------------------------------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || fail "Mumble is a macOS app."
[[ "$(uname -m)" == "arm64" ]] || fail "Mumble needs a Mac with Apple silicon (M1 or later)."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 15 )) || fail "Mumble needs macOS 15 or later (this Mac has $(sw_vers -productVersion))."

# --- Download and verify ------------------------------------------------------------------
if [[ "$VERSION" == "latest" ]]; then
  base="https://github.com/$REPO/releases/latest/download"
else
  base="https://github.com/$REPO/releases/download/v${VERSION#v}"
fi
zip_url="${MUMBLE_ZIP_URL:-$base/Mumble.zip}"
sums_url="${MUMBLE_SUMS_URL:-$base/SHA256SUMS.txt}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bold "Downloading Mumble ($VERSION)…"
curl -fL --progress-bar "$zip_url" -o "$tmp/Mumble.zip" || fail "Download failed: $zip_url"
curl -fsSL "$sums_url" -o "$tmp/SHA256SUMS.txt" || fail "Could not download checksums: $sums_url"

expected=$(awk '$2 == "Mumble.zip" {print $1}' "$tmp/SHA256SUMS.txt")
actual=$(shasum -a 256 "$tmp/Mumble.zip" | awk '{print $1}')
[[ -n "$expected" && "$expected" == "$actual" ]] || fail "Checksum mismatch; the download may be corrupted. Nothing was installed."
echo "Checksum verified."

ditto -x -k "$tmp/Mumble.zip" "$tmp/unzipped"
[[ -d "$tmp/unzipped/Mumble.app" ]] || fail "The download didn't contain Mumble.app."
codesign --verify --strict --deep "$tmp/unzipped/Mumble.app" 2>/dev/null || fail "Code signature check failed. Nothing was installed."
new_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$tmp/unzipped/Mumble.app/Contents/Info.plist")

# --- Install --------------------------------------------------------------------------------
quit_running
if [[ ! -w "$INSTALL_DIR" ]]; then
  if [[ "$INSTALL_DIR" == "/Applications" ]]; then
    INSTALL_DIR="$HOME/Applications"
    APP="$INSTALL_DIR/Mumble.app"
    echo "/Applications isn't writable; installing to $INSTALL_DIR instead."
  else
    fail "$INSTALL_DIR isn't writable."
  fi
fi
mkdir -p "$INSTALL_DIR"
rm -rf "$APP"
ditto "$tmp/unzipped/Mumble.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

bold "Installed Mumble $new_version to $APP"
if [[ "${MUMBLE_NO_OPEN:-}" != "1" ]]; then
  open "$APP"
  cat <<'EOF'

Mumble is in your menu bar. On first launch:
  1. Allow Microphone access when asked.
  2. Turn on Mumble in System Settings → Privacy & Security → Accessibility.
  3. Wait for the one-time speech model download (~330 MB).
Then hold Right ⌥ Option anywhere, speak, and release.
EOF
fi
