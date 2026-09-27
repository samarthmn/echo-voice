#!/bin/bash
set -euo pipefail
ECHO_BENCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ECHO_BENCH_ASSETS="${ECHO_BENCH_ASSETS:-$HOME/Library/Application Support/EchoVoice}"
ECHO_BENCH_PYTHON="$ECHO_BENCH_ASSETS/runtime/venv/bin/python"
if [ ! -x "$ECHO_BENCH_PYTHON" ]; then echo 'Set up the Echo Voice local runtime first.' >&2; exit 1; fi
# --help and ASR-only runs do not require the native notes runner.
ECHO_BENCH_BUILD=true
for arg in "$@"; do case "$arg" in --help|-h|--asr-only|--check|--import-archive) ECHO_BENCH_BUILD=false;; esac; done
if [ "$ECHO_BENCH_BUILD" = true ]; then
  PYTHONDONTWRITEBYTECODE=1 "$ECHO_BENCH_PYTHON" "$ECHO_BENCH_ROOT/scripts/benchmark-meeting.py" --assets "$ECHO_BENCH_ASSETS" "$@" --check
fi
if [ "$ECHO_BENCH_BUILD" = true ] && [ ! -x "$ECHO_BENCH_ROOT/dist/EchoBenchmark.app/Contents/MacOS/EchoBenchmark" ]; then
  "$ECHO_BENCH_ROOT/scripts/build-benchmark.sh"
fi
export PYTHONDONTWRITEBYTECODE=1
exec "$ECHO_BENCH_PYTHON" "$ECHO_BENCH_ROOT/scripts/benchmark-meeting.py" --assets "$ECHO_BENCH_ASSETS" "$@"
