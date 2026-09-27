#!/bin/bash
set -euo pipefail
if [ -n "${BASH_VERSION:-}" ]; then
  ECHO_ENV_SOURCE="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
  ECHO_ENV_SOURCE="${(%):-%x}"
else
  echo 'Source this environment with bash or zsh.' >&2
  return 1
fi
ECHO_PROJECT_ROOT="$(cd "$(dirname "$ECHO_ENV_SOURCE")/.." && pwd)"
mkdir -p "$ECHO_PROJECT_ROOT/tmp/build-temp" "$ECHO_PROJECT_ROOT/tmp/swift-cache" "$ECHO_PROJECT_ROOT/tmp/clang-cache" "$ECHO_PROJECT_ROOT/tmp/uv-cache" "$ECHO_PROJECT_ROOT/tmp/python"
export TMPDIR="$ECHO_PROJECT_ROOT/tmp/build-temp"
export CLANG_MODULE_CACHE_PATH="$ECHO_PROJECT_ROOT/tmp/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ECHO_PROJECT_ROOT/tmp/clang-cache"
export UV_CACHE_DIR="$ECHO_PROJECT_ROOT/tmp/uv-cache"
export UV_PYTHON_INSTALL_DIR="$ECHO_PROJECT_ROOT/tmp/python"
export ECHO_TEST_ROOT="$ECHO_PROJECT_ROOT/tmp/tests"
export PYTHONDONTWRITEBYTECODE=1
export MPLCONFIGDIR="$ECHO_PROJECT_ROOT/tmp/matplotlib"
export XDG_CACHE_HOME="$ECHO_PROJECT_ROOT/tmp/xdg-cache"

# Keep Foundation/SwiftPM diagnostic caches inside the project as well.
mkdir -p "$ECHO_PROJECT_ROOT/tmp/build-home"
export CFFIXED_USER_HOME="$ECHO_PROJECT_ROOT/tmp/build-home"
