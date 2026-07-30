#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
cd "$REPO_ROOT"

xcodegen generate
xcodebuild \
  -project AshtynMD.xcodeproj \
  -scheme AshtynMD \
  -configuration Debug \
  ASHTYN_PERFORMANCE_TESTS=1 \
  test -only-testing:AshtynMDTests/PerformanceGateTests
