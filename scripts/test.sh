#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$ECHO_PROJECT_ROOT"
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
# Xcode resolves the separately installed Metal compiler for the MLX resource bundle.
xcodegen generate --spec project.yml
mkdir -p EchoVoice.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved EchoVoice.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
ECHO_SWIFT_FLAGS='$(inherited)'
ECHO_RESULT_PATH="$ECHO_PROJECT_ROOT/tmp/test-result-$(date +%Y%m%d-%H%M%S)-$$.xcresult"
xcodebuild -project EchoVoice.xcodeproj -scheme EchoVoice -configuration Debug -destination 'platform=macOS,arch=arm64' -resultBundlePath "$ECHO_RESULT_PATH" -jobs "${ECHO_BUILD_JOBS:-2}" -derivedDataPath "$ECHO_PROJECT_ROOT/tmp/DerivedData" -clonedSourcePackagesDirPath "$ECHO_PROJECT_ROOT/tmp/swift-build" -packageCachePath "$ECHO_PROJECT_ROOT/tmp/swift-cache" -onlyUsePackageVersionsFromResolvedFile -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- "OTHER_SWIFT_FLAGS=$ECHO_SWIFT_FLAGS -j${ECHO_BUILD_JOBS:-2} -num-threads ${ECHO_BUILD_JOBS:-2}" "ECHO_MODEL_TEST_ROOT=${ECHO_MODEL_TEST_ROOT:-}" "ECHO_RUNTIME_TEST_ROOT=${ECHO_RUNTIME_TEST_ROOT:-}" "ECHO_OLLAMA_TEST_MODEL=${ECHO_OLLAMA_TEST_MODEL:-}" test "$@"
UV_PROJECT_ENVIRONMENT="$ECHO_PROJECT_ROOT/tmp/service-venv" uv run --project service --locked --group test pytest service/tests -q -o cache_dir="$ECHO_PROJECT_ROOT/tmp/pytest-cache" --basetemp="$ECHO_PROJECT_ROOT/tmp/pytest-runs"
