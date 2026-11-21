#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/musictag-online.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
xcrun swiftc -module-cache-path "$BUILD/cache" \
    "$ROOT/Sources/MusicTag/TagEngine.swift" "$ROOT/Sources/MusicTag/MP4Tags.swift" \
    "$ROOT/Sources/MusicTag/LibraryStore.swift" "$ROOT/Sources/MusicTag/LyricFormatter.swift" "$ROOT/Sources/MusicTag/LookupView.swift" "$ROOT/Sources/MusicTag/OnlineLookup.swift" "$ROOT/Sources/MusicTag/KugouLyrics.swift" \
    "$ROOT/Tests/OnlineLookupTests.swift" -o "$BUILD/OnlineLookupTests"
mkdir -p "$ROOT/analysis/tests"
"$BUILD/OnlineLookupTests" | tee "$ROOT/analysis/tests/online-results.txt"
