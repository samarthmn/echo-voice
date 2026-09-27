#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
[ "${CONFIGURATION:-Release}" != AppStore ] || { echo 'App Store delivery uses a signed archive, not a DMG.' >&2; exit 1; }
if [ "${ECHO_SKIP_BUILD:-0}" != 1 ]; then "$ECHO_PROJECT_ROOT/scripts/build.sh"; fi
ECHO_OUTPUT="$ECHO_PROJECT_ROOT/dist"
[ "${CONFIGURATION:-Release}" != Direct ] || ECHO_OUTPUT="$ECHO_OUTPUT/Direct"
ECHO_APP="$ECHO_OUTPUT/Echo Voice.app"
codesign --verify --deep --strict "$ECHO_APP"
ECHO_VERSION="$(plutil -extract CFBundleShortVersionString raw "$ECHO_APP/Contents/Info.plist")"
ECHO_SUFFIX=-local
if [ "${ECHO_PUBLIC_PACKAGE:-0}" = 1 ]; then
  [ "${CONFIGURATION:-Release}" = Direct ] || { echo 'A public package requires the Direct configuration.' >&2; exit 1; }
  codesign -dv "$ECHO_APP" 2>&1 | grep -q 'Authority=Developer ID Application:' || {
    echo 'A public package requires Developer ID Application signing.' >&2; exit 1;
  }
  python3 "$ECHO_PROJECT_ROOT/scripts/audit-runtime-notices.py" --app "$ECHO_APP" --strict --summary
  xcrun stapler validate "$ECHO_APP"
  spctl --assess --type execute "$ECHO_APP"
  # The image itself still needs signing, notarization and stapling.
  ECHO_SUFFIX=-notary-pending
fi
ECHO_IMAGE="Echo-Voice-$ECHO_VERSION-arm64$ECHO_SUFFIX.dmg"
ECHO_STAGE="$(mktemp -d "$ECHO_PROJECT_ROOT/tmp/dmg-stage.XXXXXX")"
trap 'rm -rf "$ECHO_STAGE"' EXIT
mkdir "$ECHO_STAGE/payload"
ditto "$ECHO_APP" "$ECHO_STAGE/payload/Echo Voice.app"
cp "$ECHO_PROJECT_ROOT/docs/QUICK_START.txt" "$ECHO_STAGE/payload/Read Me.txt"
if [ "$ECHO_SUFFIX" = -local ]; then printf 'LOCAL QUALIFICATION BUILD\nThis image is not a production public download.\n' > "$ECHO_STAGE/payload/Build Status.txt"; fi
ln -s /Applications "$ECHO_STAGE/payload/Applications"
hdiutil create -volname 'Echo Voice' -srcfolder "$ECHO_STAGE/payload" -format UDZO "$ECHO_STAGE/$ECHO_IMAGE"
hdiutil verify "$ECHO_STAGE/$ECHO_IMAGE"
mv -f "$ECHO_STAGE/$ECHO_IMAGE" "$ECHO_OUTPUT/$ECHO_IMAGE"
(cd "$ECHO_OUTPUT" && shasum -a 256 "$ECHO_IMAGE" > "$ECHO_IMAGE.sha256")
printf '%s\n' "$ECHO_OUTPUT/$ECHO_IMAGE"
