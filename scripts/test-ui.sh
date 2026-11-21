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
cleanup_debug_symbols() {
    local products="$RUN/DerivedData/Build/Products"
    if [ -d "$products" ]; then
        find "$products" -type d -name '*.app' -prune -o \
            -type d -name '*.dSYM' -prune -exec rm -rf -- {} +
    fi
}
trap cleanup_debug_symbols EXIT
echo "UI test artifacts: $RUN"
echo "Requires a macOS desktop session; allow the Xcode test runner to control apps if prompted."
# pipefail preserves xcodebuild's failure status while keeping the complete log.
# Each invocation gets its own build directory, result bundle and test sessions.
# Use DWARF directly so Xcode doesn't seal a dSYM inside the signed test runner.
xcodebuild "$ACTION" \
    -project "$ROOT/MusicTag.xcodeproj" -scheme MusicTag -configuration Debug \
    -destination 'platform=macOS' -parallel-testing-enabled NO \
    -derivedDataPath "$RUN/DerivedData" -resultBundlePath "$RUN/MusicTag.xcresult" \
    DEBUG_INFORMATION_FORMAT=dwarf \
    "$@" 2>&1 | tee "$RUN/xcodebuild.log"
echo "Test app: $RUN/DerivedData/Build/Products/Debug/MusicTag.app"
echo "Open results: open '$RUN/MusicTag.xcresult'"
