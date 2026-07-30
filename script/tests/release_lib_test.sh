#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR:h}/release_lib.sh"

assert_equal() {
  [[ "$1" == "$2" ]] || {
    print -u2 "expected '$2', got '$1'"
    return 1
  }
}

assert_equal \
  "$(version_from_project "${SCRIPT_DIR:h:h}/project.yml")" \
  "0.1.0"
require_architectures "arm64 x86_64"
require_architectures "x86_64 arm64"
if require_architectures "arm64"; then
  print -u2 "single-architecture input was accepted"
  exit 1
fi
