#!/bin/bash
# Exercise pressure_fill_loop without mounting, filling, or launching Echo Voice.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ECHO_DISK_PRESSURE_LIBRARY=1
# shellcheck disable=SC1091
source "$ROOT/scripts/disk-pressure.sh"

successes=0
writer() {
  successes=$((successes + 1))
  if [ "$successes" -eq 1 ]; then
    return 0
  fi
  return 2
}
pressure_fill_loop writer
test "$successes" -eq 2

failures=0
failing_writer() {
  failures=$((failures + 1))
  if [ "$failures" -eq 1 ]; then
    return 0
  fi
  return 7
}
set +e
pressure_fill_loop failing_writer
status=$?
set -e
test "$failures" -eq 2
test "$status" -eq 7
echo 'pressure fill loop keeps threshold 2 and other failures'
