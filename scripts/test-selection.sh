#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/musictag-selection-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT

# Import the actual app views without running the app's @main entry point.
xcrun swiftc -parse-as-library -emit-library -emit-module -enable-testing \
    -module-name MusicTag -module-cache-path "$BUILD/cache" \
    "$ROOT"/Sources/MusicTag/*.swift -o "$BUILD/libMusicTag.dylib"
xcrun swiftc -parse-as-library -module-cache-path "$BUILD/cache" \
    -I "$BUILD" -L "$BUILD" -lMusicTag -Xlinker -rpath -Xlinker "$BUILD" \
    "$ROOT/Tests/SelectionFocusTests.swift" -o "$BUILD/SelectionFocusTests"
"$BUILD/SelectionFocusTests"
