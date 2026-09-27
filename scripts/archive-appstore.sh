#!/bin/bash
# Build an App Store archive from the staged, runtime-embedded app.
# Xcode's Product → Archive action skips runtime embedding, notice collection,
# and nested signing. Do not use it for this app.
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$ECHO_PROJECT_ROOT"
: "${ECHO_RUNTIME_BUNDLE:?Set ECHO_RUNTIME_BUNDLE to a verified bundled runtime}"
CONFIGURATION=AppStore ECHO_RUNTIME_BUNDLE="$ECHO_RUNTIME_BUNDLE" ./scripts/build.sh
APP="$ECHO_PROJECT_ROOT/dist/AppStore/Echo Voice.app"
ARCHIVE="$ECHO_PROJECT_ROOT/dist/AppStore/Echo Voice.xcarchive"
STAGE="$ECHO_PROJECT_ROOT/tmp/appstore-archive-stage"
mkdir -p "$ECHO_PROJECT_ROOT/dist/AppStore" "$STAGE"
READINESS="$(python3 scripts/appstore_archive.py --app "$APP" --destination "$ARCHIVE" --stage-root "$STAGE" --profile-name "${ECHO_APPSTORE_PROFILE_NAME:-}")"
printf '%s\n' "$READINESS"
if printf '%s\n' "$READINESS" | head -n 1 | grep -qx 'distribution-checks-passed'; then
  EXPORT_STAGE="$STAGE/export"
  rm -rf "$EXPORT_STAGE"
  mkdir -p "$EXPORT_STAGE"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_STAGE" -exportOptionsPlist "$ECHO_PROJECT_ROOT/dist/AppStore/AppStoreExportOptions.plist"
  EXPORT_DEST="$ECHO_PROJECT_ROOT/dist/AppStore/export"
  PREVIOUS="$STAGE/export-previous"
  rm -rf "$PREVIOUS"
  if [ -d "$EXPORT_DEST" ]; then mv "$EXPORT_DEST" "$PREVIOUS"; fi
  if ! mv "$EXPORT_STAGE" "$EXPORT_DEST"; then
    if [ -d "$PREVIOUS" ]; then mv "$PREVIOUS" "$EXPORT_DEST"; fi
    exit 1
  fi
  rm -rf "$PREVIOUS"
  printf 'readiness: distribution-checks-passed\ndistribution_credentials: distribution-checks-passed\nexport: completed\nredistribution_audit: publication-blocker\n' > "$ECHO_PROJECT_ROOT/dist/AppStore/export-readiness.txt"
  echo "Export completed: $EXPORT_DEST"
else
  echo 'Local inspection archive only. Distribution credentials are unverified and export was not run.'
  echo 'Set ECHO_SIGNING_IDENTITY to Apple Distribution and ECHO_APPSTORE_PROFILE to the installed Mac App Store profile, then rerun, before uploading.'
fi
echo 'Sandbox behavior has not been qualified by this packaging check.'
echo 'Do not upload until the website release is published and the sandbox checks in private-docs/docs/APP_STORE.md have been run.'
