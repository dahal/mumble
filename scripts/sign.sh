#!/bin/zsh
# Signs an app bundle with the hardened runtime and Mumble's entitlements.
#
#   scripts/sign.sh build/Mumble.app
#
# Two modes:
#   DEVELOPER_ID_IDENTITY set   → Apple Developer ID (from a keychain already on the search list),
#                                 with a secure timestamp: ready for notarization.
#   otherwise                   → the stable self-signed "Mumble Local Signing" identity kept in
#                                 .signing/. In CI, set MUMBLE_SIGNING_P12_BASE64 (from
#                                 scripts/export-signing-identity.sh) so every release carries the
#                                 same signature and users keep their Microphone/Accessibility grants
#                                 across updates. Without it a fresh identity is generated.
set -euo pipefail
cd "$(dirname "$0")/.."
app="$1"
entitlements=Mumble/Mumble.entitlements

if [[ -n "${DEVELOPER_ID_IDENTITY:-}" ]]; then
  codesign --force --deep --options runtime --timestamp --entitlements "$entitlements" \
    --sign "$DEVELOPER_ID_IDENTITY" "$app"
  codesign --verify --strict --deep "$app"
  echo "Signed with Developer ID: $DEVELOPER_ID_IDENTITY"
  exit 0
fi

# --- Stable self-signed identity, kept in its own keychain file (never the login keychain) ---
keychain="$PWD/.signing/mumble.keychain-db"
if [[ ! -f "$keychain" ]]; then
  mkdir -p .signing
  if [[ -n "${MUMBLE_SIGNING_P12_BASE64:-}" ]]; then
    echo "$MUMBLE_SIGNING_P12_BASE64" | base64 --decode > .signing/id.p12
  else
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
  fi
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
codesign --force --deep --options runtime --entitlements "$entitlements" \
  --sign "$identity" --identifier dev.mumble.Mumble "$app"
security list-keychains -d user -s "${original[@]}"
trap - EXIT

codesign --verify --strict --deep "$app"
echo "Signed with self-signed identity: $(codesign -d -r- "$app" 2>&1 | grep -o 'certificate leaf.*')"
