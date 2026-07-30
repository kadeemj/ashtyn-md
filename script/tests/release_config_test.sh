#!/bin/zsh
set -euo pipefail

REPO_ROOT="${0:A:h:h:h}"
cd "$REPO_ROOT"

xcodegen generate
SETTINGS="$(xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD \
  -configuration Release -showBuildSettings)"

grep -Fq 'ARCHS = arm64 x86_64' <<<"$SETTINGS"
grep -Fq 'ONLY_ACTIVE_ARCH = NO' <<<"$SETTINGS"
grep -Fq 'ENABLE_HARDENED_RUNTIME = YES' <<<"$SETTINGS"
grep -Fq 'DEVELOPMENT_TEAM = JUQMKZZ7TJ' <<<"$SETTINGS"
grep -Fq 'CODE_SIGN_IDENTITY = Developer ID Application' <<<"$SETTINGS"
grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER = com.kadeem.ashtynmd' <<<"$SETTINGS"
