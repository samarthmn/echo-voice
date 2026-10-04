#!/bin/bash
# Build the Direct-channel .app (production release configuration).
# Requires a verified relocatable runtime from build-release-runtime.sh.
# Xcode "Release" is the development channel — production uses CONFIGURATION=Direct.
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$ECHO_PROJECT_ROOT"
if [ "${1:-}" != "" ]; then
  ECHO_RUNTIME_BUNDLE="$1"
fi
: "${ECHO_RUNTIME_BUNDLE:?Set ECHO_RUNTIME_BUNDLE to a verified bundled runtime, or pass its path as the first argument}"
export CONFIGURATION=Direct
export ECHO_RUNTIME_BUNDLE
./scripts/build.sh
printf '%s\n' "$ECHO_PROJECT_ROOT/dist/Direct/Echo Voice.app"
