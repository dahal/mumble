#!/bin/zsh
# Prints the self-signed signing identity (.signing/id.p12) as base64, for the GitHub secret
# MUMBLE_SIGNING_P12_BASE64. With it, CI releases are signed with the same identity as your local
# builds, so users (and you) keep Microphone/Accessibility permissions across updates.
#
#   scripts/export-signing-identity.sh | gh secret set MUMBLE_SIGNING_P12_BASE64
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .signing/id.p12 ]] || { echo "No identity yet; run scripts/build.sh once to create it." >&2; exit 1; }
base64 -i .signing/id.p12
