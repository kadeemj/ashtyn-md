#!/bin/zsh
# Builds a signed, notarized, universal Ashtyn MD release and a signed .dmg.
#
# Usage:
#   script/release.sh                     # full pipeline (needs a notary profile)
#   script/release.sh --skip-notarization  # sign + verify + package only
#
# Environment:
#   ASHTYN_NOTARY_PROFILE  notarytool keychain profile name (default: AshtynMD)
#   ASHTYN_OUTPUT_DIR      where the .dmg is written (default: <repo>/build/release)
#
# Create the notary profile once with:
#   xcrun notarytool store-credentials AshtynMD \
#     --apple-id <apple-id> --team-id JUQMKZZ7TJ --password <app-specific-password>
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
source "$SCRIPT_DIR/release_lib.sh"
cd "$REPO_ROOT"

SKIP_NOTARIZATION=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarization) SKIP_NOTARIZATION=1 ;;
    *) fail "unknown argument: $arg"; exit 1 ;;
  esac
done

NOTARY_PROFILE="${ASHTYN_NOTARY_PROFILE:-AshtynMD}"
OUTPUT_DIR="${ASHTYN_OUTPUT_DIR:-$REPO_ROOT/build/release}"

# ---------------------------------------------------------------- preflight

log "preflight"
require_tools
VERSION="$(version_from_project "$REPO_ROOT/project.yml")"
IDENTITY="$(resolve_signing_identity)"
log "version $VERSION, identity $IDENTITY"

if (( SKIP_NOTARIZATION == 0 )); then
  if ! notary_profile_available "$NOTARY_PROFILE"; then
    fail "notarytool profile '$NOTARY_PROFILE' not found or not usable.
    Create it with:
      xcrun notarytool store-credentials $NOTARY_PROFILE \\
        --apple-id <apple-id> --team-id $ASHTYN_TEAM_ID --password <app-specific-password>
    Or run with --skip-notarization to produce a signed (un-notarized) build."
    exit 1
  fi
  log "notary profile '$NOTARY_PROFILE' is usable"
else
  log "skipping notarization by request"
fi

STAGING="$(mktemp -d)"
cleanup() { rm -rf -- "$STAGING"; }
trap cleanup EXIT INT TERM

ARCHIVE_PATH="$STAGING/$ASHTYN_PRODUCT_NAME.xcarchive"
EXPORT_DIR="$STAGING/export"
APP_PATH="$EXPORT_DIR/$ASHTYN_PRODUCT_NAME.app"

# ------------------------------------------------------------------ archive

log "generating project"
xcodegen generate

# An interrupted earlier signing run can leave *.cstemp files inside build
# products; they break every later codesign pass. Clear them first.
purge_signing_temporaries "$REPO_ROOT/build"

log "archiving universal Release build"
xcodebuild \
  -project AshtynMD.xcodeproj \
  -scheme AshtynMD \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  DEVELOPMENT_TEAM="$ASHTYN_TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  archive

purge_signing_temporaries "$ARCHIVE_PATH"

# ------------------------------------------------------------------- export

log "writing ExportOptions.plist"
EXPORT_OPTIONS="$STAGING/ExportOptions.plist"
plutil -create xml1 "$EXPORT_OPTIONS"
plutil -insert method -string developer-id "$EXPORT_OPTIONS"
plutil -insert signingStyle -string manual "$EXPORT_OPTIONS"
plutil -insert teamID -string "$ASHTYN_TEAM_ID" "$EXPORT_OPTIONS"
plutil -insert signingCertificate -string "$ASHTYN_SIGN_IDENTITY_PREFIX" "$EXPORT_OPTIONS"

log "exporting signed app"
# Xcode signs nested code inside-out during export. Never re-sign the exported
# bundle with `codesign --deep`: Apple documents --deep as a diagnostic aid,
# not a distribution signing mode, and re-signing in place is what leaves the
# stale *.cstemp files behind in the first place.
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

purge_signing_temporaries "$APP_PATH"

# ------------------------------------------------------------------- verify

verify_signed_app "$APP_PATH"

# ---------------------------------------------------------------- notarize

if (( SKIP_NOTARIZATION == 0 )); then
  log "submitting app for notarization (this can take several minutes)"
  APP_ZIP="$STAGING/$ASHTYN_PRODUCT_NAME-app.zip"
  ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
  xcrun notarytool submit "$APP_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  log "stapling notarization ticket to the app"
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
fi

# --------------------------------------------------------------------- dmg

log "creating disk image"
mkdir -p "$OUTPUT_DIR"
DMG_NAME="$ASHTYN_PRODUCT_NAME-$VERSION.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
rm -f -- "$DMG_PATH"

DMG_ROOT="$STAGING/dmg"
mkdir -p "$DMG_ROOT"
ditto "$APP_PATH" "$DMG_ROOT/$ASHTYN_PRODUCT_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"

hdiutil create \
  -volname "$ASHTYN_PRODUCT_NAME $VERSION" \
  -srcfolder "$DMG_ROOT" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG_PATH"

log "signing disk image"
# A secure timestamp is mandatory for notarization; never pass --timestamp=none.
codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"

if (( SKIP_NOTARIZATION == 0 )); then
  log "submitting disk image for notarization"
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  log "stapling notarization ticket to the disk image"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"

  log "assessing Gatekeeper acceptance"
  spctl --assess --type open --context context:primary-signature \
    --ignore-cache --verbose=2 "$DMG_PATH"
fi

log "done"
print -r -- "    app: $APP_PATH (staging copy, removed on exit)"
print -r -- "    dmg: $DMG_PATH"
if (( SKIP_NOTARIZATION == 1 )); then
  print -r -- ""
  print -r -- "NOTE: this build is signed but NOT notarized. Gatekeeper will"
  print -r -- "      reject it on other Macs. Re-run without --skip-notarization"
  print -r -- "      once a notary profile is configured."
fi
