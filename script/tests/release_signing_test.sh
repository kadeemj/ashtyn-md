#!/bin/zsh
# Regression tests for the signing helpers in release_lib.sh.
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR:h}/release_lib.sh"

FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT INT TERM

# purge_signing_temporaries removes the scratch files an interrupted codesign
# run leaves inside a bundle. A surviving *.cstemp makes every later signing
# or verification pass fail, naming it as a bad subcomponent.
APP="$FIXTURE/Example.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Nested.bundle/Contents"
print -r -- "binary" > "$APP/Contents/MacOS/Example"
print -r -- "partial" > "$APP/Contents/MacOS/Example.cstemp"
print -r -- "partial" > "$APP/Contents/Resources/Nested.bundle/Contents/Nested.cstemp"
print -r -- "keep" > "$APP/Contents/Resources/keep.txt"

purge_signing_temporaries "$APP" >/dev/null

remaining="$(find "$APP" -name '*.cstemp' | wc -l | tr -d ' ')"
[[ "$remaining" == "0" ]] || {
  print -u2 "expected all .cstemp files to be purged, $remaining remain"
  exit 1
}
[[ -f "$APP/Contents/MacOS/Example" ]] || {
  print -u2 "purge removed the main executable"
  exit 1
}
[[ -f "$APP/Contents/Resources/keep.txt" ]] || {
  print -u2 "purge removed an unrelated resource"
  exit 1
}

# Purging is safe on a clean bundle and on a path that does not exist.
purge_signing_temporaries "$APP" >/dev/null
purge_signing_temporaries "$FIXTURE/does-not-exist" >/dev/null

# The signing identity must resolve to a 40-character SHA-1, never to a
# fragment of the `security find-identity` display line.
identity="$(resolve_signing_identity)"
[[ "$identity" =~ ^[0-9A-Fa-f]{40}$ ]] || {
  print -u2 "expected a 40-character identity hash, got '$identity'"
  exit 1
}

print -r -- "release signing tests passed"
