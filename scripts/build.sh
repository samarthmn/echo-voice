#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$ECHO_PROJECT_ROOT"
ECHO_OUTPUT="$ECHO_PROJECT_ROOT/dist"
if [ "${CONFIGURATION:-Release}" = Direct ] || [ "${CONFIGURATION:-Release}" = AppStore ]; then
  : "${ECHO_RUNTIME_BUNDLE:?Set ECHO_RUNTIME_BUNDLE to a verified bundled runtime}"
  python3 scripts/bundle-runtime.py --output "$ECHO_RUNTIME_BUNDLE" --verify
  ECHO_OUTPUT="$ECHO_OUTPUT/$CONFIGURATION"
fi
xcrun swift --version >/dev/null
xcrun metal --version >/dev/null || { echo 'Install the Xcode Metal Toolchain component before building.' >&2; exit 1; }
command -v xcodegen >/dev/null || { echo 'Install XcodeGen, then run this script again.' >&2; exit 1; }
xcodegen generate --spec project.yml
mkdir -p EchoVoice.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved EchoVoice.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
# The locked MLX CudaBuild plugin has been reviewed: on macOS it returns no commands.
# Keep resolution locked when allowing the reviewed package build tools in command-line builds.
ECHO_SWIFT_FLAGS='$(inherited)'
xcodebuild -project EchoVoice.xcodeproj -scheme EchoVoice -configuration "${CONFIGURATION:-Release}" -destination 'platform=macOS,arch=arm64' -jobs "${ECHO_BUILD_JOBS:-2}" -derivedDataPath "$ECHO_PROJECT_ROOT/tmp/DerivedData" -clonedSourcePackagesDirPath "$ECHO_PROJECT_ROOT/tmp/swift-build" -packageCachePath "$ECHO_PROJECT_ROOT/tmp/swift-cache" -onlyUsePackageVersionsFromResolvedFile -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- "OTHER_SWIFT_FLAGS=$ECHO_SWIFT_FLAGS -j${ECHO_BUILD_JOBS:-2} -num-threads ${ECHO_BUILD_JOBS:-2}" build
mkdir -p "$ECHO_OUTPUT"
ECHO_APP_STAGE="$(mktemp -d "$ECHO_PROJECT_ROOT/tmp/app-package.XXXXXX")"
trap 'rm -rf "$ECHO_APP_STAGE"' EXIT
ditto "$ECHO_PROJECT_ROOT/tmp/DerivedData/Build/Products/${CONFIGURATION:-Release}/Echo Voice.app" "$ECHO_APP_STAGE/Echo Voice.app"
ECHO_BUNDLED_SERVICE="$ECHO_APP_STAGE/Echo Voice.app/Contents/Resources/service"
test -d "$ECHO_BUNDLED_SERVICE"
# Xcode copies folder resources as a unit, so project-level exclusions are not
# sufficient here. Remove development-only Python content from the staged copy
# before signing; the source tree and the built product remain untouched.
/bin/rm -rf \
  "$ECHO_BUNDLED_SERVICE/tests" \
  "$ECHO_BUNDLED_SERVICE/.pytest_cache" \
  "$ECHO_BUNDLED_SERVICE/.mypy_cache" \
  "$ECHO_BUNDLED_SERVICE/.ruff_cache" \
  "$ECHO_BUNDLED_SERVICE/.venv"
find "$ECHO_BUNDLED_SERVICE" -type d -name __pycache__ -prune -exec /bin/rm -rf {} +
find "$ECHO_BUNDLED_SERVICE" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
python3 scripts/collect-notices.py "$ECHO_PROJECT_ROOT/tmp/swift-build/checkouts" "$ECHO_APP_STAGE/Echo Voice.app/Contents/Resources/Notices"
cp "$ECHO_PROJECT_ROOT/LICENSE" "$ECHO_APP_STAGE/Echo Voice.app/Contents/Resources/Notices/EchoVoice-LICENSE.txt"
if [ "${CONFIGURATION:-Release}" = Direct ] || [ "${CONFIGURATION:-Release}" = AppStore ]; then
  ditto "$ECHO_RUNTIME_BUNDLE" "$ECHO_APP_STAGE/Echo Voice.app/Contents/Resources/EchoRuntime"
  rm -f "$ECHO_APP_STAGE/Echo Voice.app/Contents/Resources/bootstrap-runtime.sh"
  python3 scripts/install-runtime-notices.py "$ECHO_APP_STAGE/Echo Voice.app"
fi
if [ "${CONFIGURATION:-Release}" = AppStore ] && [ -n "${ECHO_APPSTORE_PROFILE:-}" ]; then
  python3 scripts/sign-bundle.py "$ECHO_APP_STAGE/Echo Voice.app" --identity "${ECHO_SIGNING_IDENTITY:--}" --provisioning-profile "$ECHO_APPSTORE_PROFILE"
else
  python3 scripts/sign-bundle.py "$ECHO_APP_STAGE/Echo Voice.app" --identity "${ECHO_SIGNING_IDENTITY:--}"
fi
# Replace the complete verified bundle; merging into a previous build retains
# removed resources and stale debug libraries. Keep that build until verification.
if [ -e "$ECHO_OUTPUT/Echo Voice.app" ]; then
  mv "$ECHO_OUTPUT/Echo Voice.app" "$ECHO_APP_STAGE/previous.app"
fi
if ! mv "$ECHO_APP_STAGE/Echo Voice.app" "$ECHO_OUTPUT/Echo Voice.app"; then
  if [ -e "$ECHO_APP_STAGE/previous.app" ]; then mv "$ECHO_APP_STAGE/previous.app" "$ECHO_OUTPUT/Echo Voice.app"; fi
  exit 1
fi
echo "$ECHO_OUTPUT/Echo Voice.app"
