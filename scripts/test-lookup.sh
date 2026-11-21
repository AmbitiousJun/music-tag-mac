#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/musictag-lookup.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
xcrun swiftc -module-cache-path "$BUILD/cache" \
    "$ROOT/Sources/MusicTag/TagEngine.swift" "$ROOT/Sources/MusicTag/MP4Tags.swift" \
    "$ROOT/Sources/MusicTag/LibraryStore.swift" "$ROOT/Sources/MusicTag/LyricFormatter.swift" "$ROOT/Sources/MusicTag/OnlineLookup.swift" "$ROOT/Sources/MusicTag/KugouLyrics.swift" \
    "$ROOT/Tests/LookupProviderTests.swift" -o "$BUILD/LookupProviderTests"
xcrun swiftc -module-cache-path "$BUILD/cache" \
    "$ROOT/Sources/MusicTag/LyricFormatter.swift" "$ROOT/Tests/LyricFormatterTests.swift" \
    -o "$BUILD/LyricFormatterTests"
mkdir -p "$ROOT/analysis/tests"
(
    "$BUILD/LookupProviderTests" "$ROOT/Tests/Fixtures"
    "$BUILD/LyricFormatterTests"
) | tee "$ROOT/analysis/tests/lookup-results.txt"
