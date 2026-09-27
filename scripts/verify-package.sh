#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
ECHO_DMG="${1:?Pass the disk image to verify}"
ECHO_VERIFY_STAGE="$(mktemp -d "$ECHO_PROJECT_ROOT/tmp/package-check.XXXXXX")"
ECHO_IMAGE_ATTACHED=false
cleanup() {
  if [ "$ECHO_IMAGE_ATTACHED" = true ]; then hdiutil detach "$ECHO_VERIFY_STAGE/mount" >/dev/null; fi
  rm -rf "$ECHO_VERIFY_STAGE"
}
trap cleanup EXIT
mkdir "$ECHO_VERIFY_STAGE/mount" "$ECHO_VERIFY_STAGE/installed"
hdiutil verify "$ECHO_DMG"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$ECHO_VERIFY_STAGE/mount" "$ECHO_DMG" > "$ECHO_VERIFY_STAGE/attach.log"
ECHO_IMAGE_ATTACHED=true
test -L "$ECHO_VERIFY_STAGE/mount/Applications"
test "$(readlink "$ECHO_VERIFY_STAGE/mount/Applications")" = /Applications
test -s "$ECHO_VERIFY_STAGE/mount/Read Me.txt"
ditto "$ECHO_VERIFY_STAGE/mount/Echo Voice.app" "$ECHO_VERIFY_STAGE/installed/Echo Voice.app"
ECHO_INSTALLED="$ECHO_VERIFY_STAGE/installed/Echo Voice.app"
codesign --verify --deep --strict "$ECHO_INSTALLED"
test "$(lipo -archs "$ECHO_INSTALLED/Contents/MacOS/Echo Voice")" = arm64
test "$(plutil -extract LSMinimumSystemVersion raw "$ECHO_INSTALLED/Contents/Info.plist")" = 14.2
ECHO_INSTALLED_SERVICE="$ECHO_INSTALLED/Contents/Resources/service"
ECHO_REQUIRED_SERVICE_FILES=(
  models.json
  pyproject.toml
  uv.lock
  echo_service/__init__.py
  echo_service/__main__.py
  echo_service/adapters.py
  echo_service/aec.py
  echo_service/api.py
  echo_service/audio.py
  echo_service/environment.py
  echo_service/errors.py
  echo_service/installer.py
  echo_service/models.py
  echo_service/paths.py
  echo_service/schema.py
  echo_service/service.py
  echo_service/supervisor.py
  echo_service/worker.py
  echo_service/vocabulary.py
  echo_service/word_timing.py
  echo_service/model_lifecycle.py
  echo_service/community.py
  echo_service/community_setup.py
  community/requirements.lock
)
for ECHO_REQUIRED_SERVICE_FILE in "${ECHO_REQUIRED_SERVICE_FILES[@]}"; do
  test -s "$ECHO_INSTALLED_SERVICE/$ECHO_REQUIRED_SERVICE_FILE"
done
test -z "$(find "$ECHO_INSTALLED_SERVICE" -type d \( -name tests -o -name __pycache__ -o -name .pytest_cache -o -name .mypy_cache -o -name .ruff_cache -o -name .venv \) -print -quit)"
test -z "$(find "$ECHO_INSTALLED_SERVICE" -type f \( -name '*.pyc' -o -name '*.pyo' \) -print -quit)"
ECHO_CHANNEL="$(plutil -extract EchoDistributionChannel raw "$ECHO_INSTALLED/Contents/Info.plist")"
if [ "$ECHO_CHANNEL" = development ]; then
  test -s "$ECHO_INSTALLED/Contents/Resources/bootstrap-runtime.sh"
else
  test ! -e "$ECHO_INSTALLED/Contents/Resources/bootstrap-runtime.sh"
  python3 "$ECHO_PROJECT_ROOT/scripts/bundle-runtime.py" --output "$ECHO_INSTALLED/Contents/Resources/EchoRuntime" --verify
fi
test -s "$ECHO_INSTALLED/Contents/Resources/EchoVoice.icns"
ECHO_IMAGE_NAME="$(basename "$ECHO_DMG")"
case "$ECHO_IMAGE_NAME" in
  *-local.dmg)
    ECHO_PACKAGE_STATE=local
    grep -Fxq 'LOCAL QUALIFICATION BUILD' "$ECHO_VERIFY_STAGE/mount/Build Status.txt"
    ;;
  *-notary-pending.dmg)
    ECHO_PACKAGE_STATE=notary-pending
    test "$ECHO_CHANNEL" = direct
    test ! -e "$ECHO_VERIFY_STAGE/mount/Build Status.txt"
    codesign -dv "$ECHO_INSTALLED" 2>&1 | grep -q 'Authority=Developer ID Application:'
    xcrun stapler validate "$ECHO_INSTALLED"
    spctl --assess --type execute "$ECHO_INSTALLED"
    ;;
  *)
    ECHO_PACKAGE_STATE=public
    ECHO_VERSION="$(plutil -extract CFBundleShortVersionString raw "$ECHO_INSTALLED/Contents/Info.plist")"
    test "$ECHO_IMAGE_NAME" = "Echo-Voice-$ECHO_VERSION-arm64.dmg"
    test "$ECHO_CHANNEL" = direct
    test ! -e "$ECHO_VERIFY_STAGE/mount/Build Status.txt"
    codesign -dv "$ECHO_INSTALLED" 2>&1 | grep -q 'Authority=Developer ID Application:'
    xcrun stapler validate "$ECHO_DMG"
    xcrun stapler validate "$ECHO_INSTALLED"
    spctl --assess --type execute "$ECHO_INSTALLED"
    test -s "$ECHO_DMG.sha256"
    (cd "$(dirname "$ECHO_DMG")" && shasum -a 256 -c "$ECHO_IMAGE_NAME.sha256")
    ;;
esac
if [ "$ECHO_PACKAGE_STATE" = public ]; then
  python3 "$ECHO_PROJECT_ROOT/scripts/audit-runtime-notices.py" --app "$ECHO_INSTALLED" --strict --summary
fi
python3 - "$ECHO_DMG" "$ECHO_INSTALLED" "$ECHO_PROJECT_ROOT/Package.resolved" "$ECHO_PROJECT_ROOT/dist/package-verification.json" "$ECHO_PACKAGE_STATE" <<'PY'
from datetime import datetime, timezone
from hashlib import sha256
import json
from pathlib import Path
import sys

image, app, package_lock, output = map(Path, sys.argv[1:5])
package_state = sys.argv[5]
def digest(path):
    value = sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()

notices = app / 'Contents/Resources/Notices'
if not (notices / 'EchoVoice-LICENSE.txt').is_file():
    raise SystemExit('Missing original application license.')
if not (notices / 'README.md').is_file():
    raise SystemExit('Missing packaged third-party notice index.')
pins = json.loads(package_lock.read_text())['pins']
for pin in pins:
    identity = pin['identity']
    notice_directory = notices / identity
    source = notice_directory / 'SOURCE.txt'
    expected_source = (
        f"{pin['location']}\n"
        f"Revision: {pin['state']['revision']}\n"
        f"Version: {pin['state'].get('version', 'revision pin')}\n"
    )
    if not source.is_file() or source.read_text() != expected_source:
        raise SystemExit(f'Missing or stale packaged source notice for {identity}.')
    license_files = [
        path for path in notice_directory.rglob('*')
        if path.is_file()
        and path.name.lower().startswith(('license', 'licence', 'copying', 'notice'))
    ]
    if not license_files:
        raise SystemExit(f'Missing packaged license notice for {identity}.')

result = {
    'verified_at': datetime.now(timezone.utc).isoformat(),
    'disk_image': image.name,
    'disk_image_sha256': digest(image),
    'disk_image_bytes': image.stat().st_size,
    'release_state': package_state,
    'executable_sha256': digest(app / 'Contents/MacOS/Echo Voice'),
    'architecture': 'arm64',
    'minimum_macos': '14.2',
    'image_checksum': 'passed',
    'copied_application_signature': 'passed',
    'setup_resources_and_notices': 'present',
    'locked_dependency_notice_count': len(pins),
    'runtime_development_files': 'absent',
    'fresh_directory_copy': 'passed',
    'application_launch': 'not_performed',
    'recording_or_inference': 'not_performed',
}
output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
PY
