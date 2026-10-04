#!/bin/bash
# Package a Direct-channel DMG from the Direct .app.
# Default output is a local qualification image (*-local.dmg).
# Pass-through: ECHO_RUNTIME_BUNDLE, ECHO_SKIP_BUILD, ECHO_PUBLIC_PACKAGE, ECHO_SIGNING_IDENTITY.
# Xcode "Release" is the development channel — production uses CONFIGURATION=Direct.
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$ECHO_PROJECT_ROOT"
if [ "${1:-}" != "" ]; then
  ECHO_RUNTIME_BUNDLE="$1"
fi
export CONFIGURATION=Direct
if [ "${ECHO_SKIP_BUILD:-0}" != 1 ]; then
  : "${ECHO_RUNTIME_BUNDLE:?Set ECHO_RUNTIME_BUNDLE to a verified bundled runtime, or pass its path as the first argument (or set ECHO_SKIP_BUILD=1)}"
  export ECHO_RUNTIME_BUNDLE
fi
./scripts/package.sh
