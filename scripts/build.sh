#!/bin/zsh
# Builds Mumble.app (Release, Apple silicon) into ./build/Mumble.app and signs it.
# Needs Xcode 26+ and XcodeGen (brew install xcodegen).
#
# Environment (all optional):
#   MUMBLE_VERSION   marketing version, e.g. 1.2.0          (default: from project.yml)
#   MUMBLE_BUILD     build number, e.g. CI run number        (default: from project.yml)
#   plus the signing variables documented in scripts/sign.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

overrides=(ARCHS=arm64)
[[ -n "${MUMBLE_VERSION:-}" ]] && overrides+=(MARKETING_VERSION="$MUMBLE_VERSION")
[[ -n "${MUMBLE_BUILD:-}" ]] && overrides+=(CURRENT_PROJECT_VERSION="$MUMBLE_BUILD")

xcodegen generate --quiet
log=build/xcodebuild.log
mkdir -p build
if ! xcodebuild -project Mumble.xcodeproj -scheme Mumble -configuration Release \
  -derivedDataPath build/DerivedData -skipPackagePluginValidation "${overrides[@]}" build > "$log" 2>&1; then
  grep -E "error:" "$log" | sort -u
  echo "Build FAILED (full log: $log)"
  exit 1
fi
grep -E "warning: .*/Mumble/" "$log" | sort -u || true

app=build/DerivedData/Build/Products/Release/Mumble.app
rm -rf build/Mumble.app
ditto "$app" build/Mumble.app

scripts/sign.sh build/Mumble.app
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Mumble.app/Contents/Info.plist)
number=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" build/Mumble.app/Contents/Info.plist)
echo "Built $(pwd)/build/Mumble.app $version ($number), $(du -sh build/Mumble.app | cut -f1)"
