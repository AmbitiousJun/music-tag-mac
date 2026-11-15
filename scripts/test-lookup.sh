#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/musictag-lookup.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
xcrun swiftc -module-cache-path "$BUILD/cache" \
    "$ROOT/Sources/MusicTag/TagEngine.swift" "$ROOT/Sources/MusicTag/MP4Tags.swift" \
    "$ROOT/Sources/MusicTag/LibraryStore.swift" "$ROOT/Sources/MusicTag/OnlineLookup.swift" \
    "$ROOT/Tests/LookupProviderTests.swift" -o "$BUILD/LookupProviderTests"
mkdir -p "$ROOT/analysis/tests"
"$BUILD/LookupProviderTests" "$ROOT/Tests/Fixtures" | tee "$ROOT/analysis/tests/lookup-results.txt"
