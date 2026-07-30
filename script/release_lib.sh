#!/bin/zsh
# Shared helpers for the Developer ID release pipeline.
# Sourced by release.sh and script/tests/release_lib_test.sh.

readonly ASHTYN_TEAM_ID="JUQMKZZ7TJ"
readonly ASHTYN_BUNDLE_ID="com.kadeem.ashtynmd"
readonly ASHTYN_PRODUCT_NAME="AshtynMD"
readonly ASHTYN_SIGN_IDENTITY_PREFIX="Developer ID Application"

log() {
  print -r -- "==> $*"
}

fail() {
  print -u2 -r -- "error: $*"
  return 1
}

# Marketing version from project.yml (CFBundleShortVersionString).
version_from_project() {
  local project_file="$1"
  [[ -f "$project_file" ]] || {
    fail "project file not found: $project_file"
    return 1
  }
  local version
  version="$(
    sed -n 's/.*CFBundleShortVersionString:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' \
      "$project_file" | head -1
  )"
  version="${version##[[:space:]]##}"
  version="${version%%[[:space:]]##}"
  [[ -n "$version" ]] || {
    fail "could not read CFBundleShortVersionString from $project_file"
    return 1
  }
  print -r -- "$version"
}

# Asserts a `lipo -archs` string covers both shipping architectures.
require_architectures() {
  local archs="$1"
  local missing=()
  [[ "$archs" == *arm64* ]] || missing+=("arm64")
  [[ "$archs" == *x86_64* ]] || missing+=("x86_64")
  if (( ${#missing} > 0 )); then
    print -u2 -r -- "error: binary is missing architecture(s): ${missing[*]} (found: ${archs})"
    return 1
  fi
  return 0
}

# Deletes codesign scratch files left behind by an interrupted signing run.
#
# `codesign` writes the new signature to `<binary>.cstemp` and renames it into
# place. If it is interrupted, killed, or races another codesign process, that
# partial file survives inside the bundle. Every later signing or verification
# pass then walks into it as if it were nested code and fails with errors like
# "invalid or unsupported format for signature" or "main executable failed
# strict validation", naming `<Product>.cstemp` as the offending subcomponent.
# The stale file poisons the bundle indefinitely, so clear it before signing.
purge_signing_temporaries() {
  local target="$1"
  [[ -e "$target" ]] || return 0
  local -a stale
  stale=("${(@f)$(find "$target" -name '*.cstemp' -print 2>/dev/null)}")
  stale=(${stale:#})
  if (( ${#stale} > 0 )); then
    log "removing ${#stale} stale codesign temporary file(s)"
    local item
    for item in "${stale[@]}"; do
      print -r -- "    $item"
      rm -rf -- "$item"
    done
  fi
  return 0
}

# Resolves the Developer ID Application identity SHA-1 from the keychain.
# The hash is used rather than the display name so signing cannot be
# ambiguous when several matching certificates are installed.
resolve_signing_identity() {
  local line
  line="$(
    security find-identity -v -p codesigning 2>/dev/null |
      grep -F "$ASHTYN_SIGN_IDENTITY_PREFIX" | head -1
  )"
  [[ -n "$line" ]] || {
    fail "no '$ASHTYN_SIGN_IDENTITY_PREFIX' identity found in the keychain"
    return 1
  }
  # Line format: `  3) <40-hex-sha1> "Developer ID Application: Name (TEAM)"`.
  local hash
  hash="$(grep -oE '[0-9A-Fa-f]{40}' <<<"$line" | head -1)"
  [[ -n "$hash" ]] || {
    fail "could not parse identity hash from: $line"
    return 1
  }
  print -r -- "$hash"
}

require_tools() {
  local tool
  for tool in xcodegen xcodebuild codesign hdiutil spctl plutil lipo; do
    command -v "$tool" >/dev/null 2>&1 || {
      fail "required tool not found: $tool"
      return 1
    }
  done
  xcrun --find notarytool >/dev/null 2>&1 || {
    fail "notarytool not available in the active Xcode"
    return 1
  }
  xcrun --find stapler >/dev/null 2>&1 || {
    fail "stapler not available in the active Xcode"
    return 1
  }
  return 0
}

# Confirms an exported app is universal, hardened, Developer ID signed, and
# carries the entitlements the app needs at runtime.
verify_signed_app() {
  local app_path="$1"
  [[ -d "$app_path" ]] || {
    fail "app not found: $app_path"
    return 1
  }

  log "verifying signature (deep, strict)"
  codesign --verify --deep --strict --verbose=2 "$app_path" || {
    fail "codesign verification failed"
    return 1
  }

  log "verifying architectures"
  local archs
  archs="$(lipo -archs "$app_path/Contents/MacOS/$ASHTYN_PRODUCT_NAME")" || return 1
  require_architectures "$archs" || return 1
  print -r -- "    $archs"

  local details
  details="$(codesign -dvvv "$app_path" 2>&1)" || {
    fail "could not read signature details"
    return 1
  }

  log "verifying Hardened Runtime"
  grep -Eq 'flags=.*runtime' <<<"$details" || {
    fail "Hardened Runtime flag is not set"
    return 1
  }

  log "verifying signing authority and team"
  grep -Fq "Authority=$ASHTYN_SIGN_IDENTITY_PREFIX" <<<"$details" || {
    fail "app is not signed with a $ASHTYN_SIGN_IDENTITY_PREFIX certificate"
    return 1
  }
  grep -Fq "TeamIdentifier=$ASHTYN_TEAM_ID" <<<"$details" || {
    fail "unexpected team identifier (expected $ASHTYN_TEAM_ID)"
    return 1
  }

  log "verifying entitlements"
  local entitlements
  entitlements="$(codesign -d --entitlements :- --xml "$app_path" 2>/dev/null |
    plutil -convert xml1 -o - - 2>/dev/null)" || {
    fail "could not read entitlements"
    return 1
  }
  local key
  for key in \
    com.apple.security.app-sandbox \
    com.apple.security.files.user-selected.read-write \
    com.apple.security.files.bookmarks.app-scope \
    com.apple.security.network.client; do
    grep -Fq "$key" <<<"$entitlements" || {
      fail "missing entitlement: $key"
      return 1
    }
  done

  return 0
}

# True when a notarytool keychain profile of this name exists.
notary_profile_available() {
  local profile="$1"
  [[ -n "$profile" ]] || return 1
  xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1
}
