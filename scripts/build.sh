#!/bin/zsh
# Builds Mumble.app (Release) into ./build/Mumble.app.
# Needs Xcode 26+ and XcodeGen (brew install xcodegen).
#
# The app is signed with a local self-signed identity kept in .signing/ (created on first run,
# never added to your login keychain). A stable signature means macOS keeps the Microphone and
# Accessibility permissions across rebuilds; ad-hoc signatures change every build and lose them.
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

# --- Stable local signing -------------------------------------------------------------------
keychain="$PWD/.signing/mumble.keychain-db"
if [[ ! -f "$keychain" ]]; then
  mkdir -p .signing
  cat > .signing/cert.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Mumble Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -keyout .signing/key.pem -out .signing/cert.pem \
    -days 3650 -config .signing/cert.cnf 2>/dev/null
  openssl pkcs12 -export -inkey .signing/key.pem -in .signing/cert.pem -out .signing/id.p12 \
    -passout pass:mumble -name "Mumble Local Signing" -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey .signing/key.pem -in .signing/cert.pem -out .signing/id.p12 \
    -passout pass:mumble -name "Mumble Local Signing"
  security create-keychain -p mumble "$keychain"
  security set-keychain-settings "$keychain"
  security unlock-keychain -p mumble "$keychain"
  security import .signing/id.p12 -k "$keychain" -P mumble -T /usr/bin/codesign -A >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k mumble "$keychain" >/dev/null 2>&1 || true
fi
security unlock-keychain -p mumble "$keychain"
identity=$(security find-identity -p codesigning "$keychain" | awk '/Mumble Local Signing/ {print $2; exit}')

# codesign only finds identities in keychains on the user search list; add ours just for this call.
original=(${(f)"$(security list-keychains -d user | tr -d '"' | sed 's/^ *//')"})
security list-keychains -d user -s "${original[@]}" "$keychain"
trap 'security list-keychains -d user -s "${original[@]}"' EXIT
codesign --force --deep --sign "$identity" --identifier dev.mumble.Mumble build/Mumble.app
security list-keychains -d user -s "${original[@]}"
trap - EXIT

codesign --verify --strict build/Mumble.app
echo "Built $(pwd)/build/Mumble.app ($(du -sh build/Mumble.app | cut -f1)), signed: $(codesign -d -r- build/Mumble.app 2>&1 | grep -o 'certificate leaf.*')"
