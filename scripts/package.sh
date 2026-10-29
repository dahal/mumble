#!/bin/zsh
# Packages build/Mumble.app for distribution into build/dist/:
#
#   Mumble-<version>.dmg   drag-to-Applications disk image
#   Mumble-<version>.zip   zipped app (what the install script downloads)
#   Mumble.zip             same zip under a fixed name, for .../releases/latest/download/Mumble.zip
#   SHA256SUMS.txt         checksums of all of the above
#
# Notarizes and staples when App Store Connect API credentials are set:
#   NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY_PATH (path to the .p8 key)
# Notarization requires the app to be signed with a Developer ID (see scripts/sign.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

app=build/Mumble.app
[[ -d "$app" ]] || { echo "Run scripts/build.sh first"; exit 1; }
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
dist=build/dist
rm -rf "$dist" && mkdir -p "$dist"

notarize() {
  xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" --wait --timeout 30m
}

if [[ -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" && -n "${NOTARY_KEY_PATH:-}" ]]; then
  echo "Notarizing the app…"
  ditto -c -k --keepParent "$app" "$dist/notarize.zip"
  notarize "$dist/notarize.zip"
  rm "$dist/notarize.zip"
  xcrun stapler staple "$app"
  notarized=1
else
  echo "No notary credentials: packaging without notarization."
  notarized=0
fi

ditto -c -k --keepParent "$app" "$dist/Mumble-$version.zip"
cp "$dist/Mumble-$version.zip" "$dist/Mumble.zip"

staging=$(mktemp -d)
ditto "$app" "$staging/Mumble.app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "Mumble $version" -srcfolder "$staging" -ov -format UDZO "$dist/Mumble-$version.dmg"
rm -rf "$staging"
if [[ $notarized == 1 ]]; then
  notarize "$dist/Mumble-$version.dmg"
  xcrun stapler staple "$dist/Mumble-$version.dmg"
fi

(cd "$dist" && shasum -a 256 Mumble-$version.dmg Mumble-$version.zip Mumble.zip > SHA256SUMS.txt)
echo "notarized=$notarized" > build/package-info
echo "Packaged Mumble $version (notarized: $notarized):"
ls -lh "$dist" | awk 'NR > 1 {print "  " $5 "  " $9}'
