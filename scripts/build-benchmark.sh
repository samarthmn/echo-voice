#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$ECHO_PROJECT_ROOT"
xcodegen generate --spec project.yml
mkdir -p EchoVoice.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved EchoVoice.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcodebuild -project EchoVoice.xcodeproj -scheme EchoBenchmark -configuration Release -destination 'platform=macOS,arch=arm64' -jobs "${ECHO_BUILD_JOBS:-2}" -derivedDataPath "$ECHO_PROJECT_ROOT/tmp/DerivedData" -clonedSourcePackagesDirPath "$ECHO_PROJECT_ROOT/tmp/swift-build" -packageCachePath "$ECHO_PROJECT_ROOT/tmp/swift-cache" -onlyUsePackageVersionsFromResolvedFile -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- build
mkdir -p "$ECHO_PROJECT_ROOT/dist"
# Dedicated reusable headless runner, separate from the installed meeting app.
ditto "$ECHO_PROJECT_ROOT/tmp/DerivedData/Build/Products/Release/EchoBenchmark.app" "$ECHO_PROJECT_ROOT/dist/EchoBenchmark.app"
python3 scripts/collect-notices.py "$ECHO_PROJECT_ROOT/tmp/swift-build/checkouts" "$ECHO_PROJECT_ROOT/dist/EchoBenchmark.app/Contents/Resources/Notices"
codesign --force --sign - "$ECHO_PROJECT_ROOT/dist/EchoBenchmark.app"
codesign --verify --deep --strict "$ECHO_PROJECT_ROOT/dist/EchoBenchmark.app"
