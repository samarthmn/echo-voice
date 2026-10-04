#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$ECHO_PROJECT_ROOT"
xcodegen generate --spec project.yml
mkdir -p EchoVoice.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved EchoVoice.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcodebuild -project EchoVoice.xcodeproj -scheme EchoVoiceUI -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -jobs "${ECHO_BUILD_JOBS:-2}" \
  -derivedDataPath "$ECHO_PROJECT_ROOT/tmp/DerivedData" \
  -clonedSourcePackagesDirPath "$ECHO_PROJECT_ROOT/tmp/swift-build" \
  -packageCachePath "$ECHO_PROJECT_ROOT/tmp/swift-cache" \
  -onlyUsePackageVersionsFromResolvedFile -skipPackagePluginValidation \
  -resultBundlePath "$ECHO_PROJECT_ROOT/tmp/ui-result-$(date +%Y%m%d-%H%M%S)-$$.xcresult" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- test "$@"
