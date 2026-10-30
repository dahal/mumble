#!/bin/bash
# Tests scripts/next-version.sh against throwaway git repositories.
set -euo pipefail
script="$(cd "$(dirname "$0")" && pwd)/next-version.sh"
failures=0

repo() {
  dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name test
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" config tag.gpgsign false
  echo "$dir"
}
commit() { git -C "$1" commit -q --allow-empty -m "$2" ${3:+-m "$3"}; }
tag() { git -C "$1" tag "$2"; }
expect() {
  local name="$1" want="$2" dir="$3" arg="${4:-}"
  local got
  got=$(cd "$dir" && "$script" $arg 2>/dev/null)
  if [[ "$got" == "$want" ]]; then echo "ok   $name → $got"; else echo "FAIL $name: want $want, got $got"; failures=$((failures + 1)); fi
}

d=$(repo); commit "$d" "initial"
expect "no tags yet starts at 0.0.1" 0.0.1 "$d"

d=$(repo); commit "$d" "init"; tag "$d" v0.1.0; commit "$d" "New app icon (#1)"
expect "non-conventional title → patch" 0.1.1 "$d"

d=$(repo); commit "$d" "init"; tag "$d" v0.1.0; commit "$d" "fix: paste in Terminal (#2)"; commit "$d" "chore: tidy (#3)"
expect "fix + chore → patch" 0.1.1 "$d"

d=$(repo); commit "$d" "init"; tag "$d" v0.1.3; commit "$d" "fix: x"; commit "$d" "feat(audio): Apple Speech fallback (#4)"
expect "feat with scope → minor" 0.2.0 "$d"

d=$(repo); commit "$d" "init"; tag "$d" v1.4.2; commit "$d" "feat!: new settings format (#5)"
expect "breaking after 1.0 → major" 2.0.0 "$d"

d=$(repo); commit "$d" "init"; tag "$d" v1.4.2; commit "$d" "refactor: storage (#6)" "BREAKING CHANGE: history file moved"
expect "BREAKING CHANGE footer → major" 2.0.0 "$d"

d=$(repo); commit "$d" "init"; tag "$d" v0.3.1; commit "$d" "feat!: drop macOS 15 (#7)"
expect "breaking before 1.0 → minor" 0.4.0 "$d"

d=$(repo); commit "$d" "init"; tag "$d" v0.2.0; tag "$d" v0.3.0-beta.1; commit "$d" "fix: y"
expect "pre-release tags ignored" 0.2.1 "$d"

d=$(repo); commit "$d" "init"; tag "$d" v0.9.0; commit "$d" "init2"; tag "$d" v0.10.0; commit "$d" "fix: z"
expect "versions sort numerically (0.10 > 0.9)" 0.10.1 "$d"

d=$(repo); commit "$d" "init"; tag "$d" v0.1.0; commit "$d" "fix: x"
expect "forced minor" 0.2.0 "$d" minor
expect "forced major before 1.0 → minor" 0.2.0 "$d" major

if (( failures > 0 )); then echo "$failures failure(s)"; exit 1; fi
echo "all next-version tests passed"
