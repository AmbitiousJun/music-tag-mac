#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "UI tests require full Xcode (not only Command Line Tools). Select it with xcode-select or DEVELOPER_DIR." >&2
    exit 1
fi
ACTION=test
if [ "${1:-}" = "--build-only" ]; then
    ACTION=build-for-testing
    shift
fi
RESULTS="${MUSICTAG_UI_RESULTS_DIR:-$ROOT/analysis/tests/ui}"
mkdir -p "$RESULTS"
RUN="$(mktemp -d "$RESULTS/run-$(date +%Y%m%d-%H%M%S).XXXXXX")"
echo "UI test artifacts: $RUN"
echo "Requires a macOS desktop session; allow the Xcode test runner to control apps if prompted."
# pipefail preserves xcodebuild's failure status while keeping the complete log.
# Each invocation gets its own build directory, result bundle and test sessions.
xcodebuild "$ACTION" \
    -project "$ROOT/MusicTag.xcodeproj" -scheme MusicTag -configuration Debug \
    -destination 'platform=macOS' -parallel-testing-enabled NO \
    -derivedDataPath "$RUN/DerivedData" -resultBundlePath "$RUN/MusicTag.xcresult" \
    "$@" 2>&1 | tee "$RUN/xcodebuild.log"
echo "Test app: $RUN/DerivedData/Build/Products/Debug/MusicTag.app"
echo "Open results: open '$RUN/MusicTag.xcresult'"
