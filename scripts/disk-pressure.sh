#!/bin/bash
# Stop after a successful filler write when write-block returns 2.
# Any other failure is returned unchanged. Status must be read in the else
# branch: a failing if with no else reports 0.
pressure_fill_loop() {
  while true; do
    if "$@"; then
      continue
    else
      status=$?
      if [ "$status" -eq 2 ]; then
        return 0
      fi
      return "$status"
    fi
  done
}

if [ "${ECHO_DISK_PRESSURE_LIBRARY:-}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

# Isolated low-space recording check. Do not run this until you intend to record.
# It refuses to continue when the project volume lacks reserve space, the mount is
# wrong, or no recording chunk exists. Fill stays on the image.
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$ECHO_PROJECT_ROOT"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
ROOT="$ECHO_PROJECT_ROOT/tmp/disk-pressure/$RUN_ID"
APP="$ECHO_PROJECT_ROOT/dist/Direct/Echo Voice.app/Contents/MacOS/Echo Voice"
VOLUME="$(df -P "$ECHO_PROJECT_ROOT" | awk 'NR==2 { print $6 }')"
mkdir -p "$ROOT"
cleanup() {
  if [ -n "${APP_PID:-}" ]; then kill "$APP_PID" 2>/dev/null || true; fi
  if mount | awk -v mount="$ROOT/mnt" '$3 == mount { found=1 } END { exit found ? 0 : 1 }'; then
    hdiutil detach "$ROOT/mnt" || true
  fi
}
trap cleanup EXIT
FREE_KB="$(df -Pk "$VOLUME" | awk 'NR==2 { print $4 }')"
python3 "$ECHO_PROJECT_ROOT/scripts/disk_pressure.py" host-reserve --free-kb "$FREE_KB"
if pgrep -x "Echo Voice" >/dev/null; then
  echo 'Quit Echo Voice before continuing. A running instance ignores ECHO_DATA_ROOT.' >&2
  exit 1
fi
mkdir -p "$ROOT/mnt"
hdiutil create -size 16g -fs APFS -volname EchoPressure "$ROOT/pressure.dmg"
hdiutil attach -nobrowse -mountpoint "$ROOT/mnt" "$ROOT/pressure.dmg"
python3 "$ECHO_PROJECT_ROOT/scripts/disk_pressure.py" mount --mount "$ROOT/mnt" --image "$ROOT/pressure.dmg"
ECHO_DATA_ROOT="$ROOT/mnt/EchoVoice" "$APP" &
APP_PID=$!
LIBRARY="$ROOT/mnt/EchoVoice"
for _ in $(seq 1 600); do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo 'Echo Voice exited before a chunk was saved.' >&2
    exit 1
  fi
  if python3 "$ECHO_PROJECT_ROOT/scripts/disk_pressure.py" chunk --library "$LIBRARY" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
python3 "$ECHO_PROJECT_ROOT/scripts/disk_pressure.py" chunk --library "$LIBRARY" >/dev/null
FILL="$ROOT/mnt/pressure-fill"
mkdir -p "$FILL"
COUNTER="$ROOT/block-counter"
write_one_block() {
  python3 "$ECHO_PROJECT_ROOT/scripts/disk_pressure.py" write-block \
    --mount "$ROOT/mnt" --image "$ROOT/pressure.dmg" --fill "$FILL" --counter "$COUNTER" \
    --app-pid "$APP_PID" \
    --image-free-kb "$(df -Pk "$ROOT/mnt" | awk 'NR==2 { print $4 }')" \
    --host-free-kb "$(df -Pk "$VOLUME" | awk 'NR==2 { print $4 }')"
}
pressure_fill_loop write_one_block
echo 'Fill stopped above the app 1 GB threshold or the host reserve. Wait for the app low-space stop, then confirm earlier chunks remain.'
echo "This run is $ROOT. Cleanup detaches only $ROOT/mnt and you may delete only $ROOT."
wait "$APP_PID" || true
