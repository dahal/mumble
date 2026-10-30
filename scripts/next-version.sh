#!/bin/bash
# Prints the next release version (no leading "v") based on the commits since the latest release tag.
#
#   scripts/next-version.sh            # auto: decided from commit messages
#   scripts/next-version.sh minor      # force patch | minor | major
#
# Auto rules (Conventional Commits; with squash merges each PR title is one commit subject):
#   "type!: ..." or "BREAKING CHANGE" in a message   → major
#   "feat: ..." / "feat(scope): ..."                  → minor
#   anything else                                     → patch
# Before 1.0.0 a breaking change bumps the minor version instead (SemVer: 0.x may change freely).
# The decision is explained on stderr; only the version goes to stdout.
set -euo pipefail

bump="${1:-auto}"
case "$bump" in auto|patch|minor|major) ;; *) echo "usage: $0 [auto|patch|minor|major]" >&2; exit 2 ;; esac

# Latest stable release tag (pre-releases like v1.2.0-beta.1 are ignored).
latest=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | grep -vE -- '-' | head -1 || true)
if [[ -z "$latest" ]]; then
  latest="v0.0.0"
  range="HEAD"
else
  range="$latest..HEAD"
fi

version="${latest#v}"
IFS=. read -r major minor patch <<< "$version"

if [[ "$bump" == "auto" ]]; then
  log=$(git log --format='%s%n%b' "$range")
  if grep -qE '^[a-z]+(\([^)]*\))?!:|BREAKING CHANGE' <<< "$log"; then
    bump=major
  elif grep -qE '^feat(\([^)]*\))?:' <<< "$log"; then
    bump=minor
  else
    bump=patch
  fi
  echo "Since $latest: $(git rev-list --count "$range") commit(s) → $bump bump" >&2
fi

if [[ "$bump" == "major" && "$major" == "0" ]]; then
  echo "Breaking change before 1.0.0 → minor bump" >&2
  bump=minor
fi

case "$bump" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
esac
echo "$major.$minor.$patch"
