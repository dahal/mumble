#!/bin/zsh
# Builds Mumble.app (Release) into ./build/Mumble.app.
# Needs Xcode 26+ and XcodeGen (brew install xcodegen).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcodegen generate --quiet
xcodebuild -project Mumble.xcodeproj -scheme Mumble -configuration Release \
  -derivedDataPath build/DerivedData -skipPackagePluginValidation build \
  | grep -E "error:|warning: .*/Mumble/|\*\* BUILD" || true

app=build/DerivedData/Build/Products/Release/Mumble.app
[[ -d "$app" ]] || { echo "Build failed"; exit 1; }
rm -rf build/Mumble.app
ditto "$app" build/Mumble.app
echo "Built $(pwd)/build/Mumble.app ($(du -sh build/Mumble.app | cut -f1))"
