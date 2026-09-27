#!/bin/bash
# Clean, locked executable dependency provisioning happens on the release builder.
set -euo pipefail
source "$(dirname "$0")/environment.sh"
ECHO_RELEASE_ROOT="${1:?Choose a NEW build directory inside the project tmp folder}"
case "$ECHO_RELEASE_ROOT" in "$ECHO_PROJECT_ROOT/tmp/"*) ;; *) echo 'Release scratch must be inside project tmp/.' >&2; exit 1;; esac
[ ! -e "$ECHO_RELEASE_ROOT" ] || { echo 'Use an empty build directory.' >&2; exit 1; }
mkdir -p "$ECHO_RELEASE_ROOT"
"$ECHO_PROJECT_ROOT/scripts/bootstrap-runtime.sh" "$ECHO_RELEASE_ROOT/input" "$ECHO_PROJECT_ROOT/service"
ECHO_DATA_ROOT="$ECHO_RELEASE_ROOT/input" "$ECHO_RELEASE_ROOT/input/runtime/venv/bin/python" -B -c 'import os; from pathlib import Path; from echo_service.community_setup import install_runtime; install_runtime(Path(os.environ["ECHO_DATA_ROOT"]), lambda **progress: print(progress))'
python3 "$ECHO_PROJECT_ROOT/scripts/bundle-runtime.py" --runtime-root "$ECHO_RELEASE_ROOT/input/runtime" --output "$ECHO_RELEASE_ROOT/bundle"
printf '%s\n' "$ECHO_RELEASE_ROOT/bundle"
