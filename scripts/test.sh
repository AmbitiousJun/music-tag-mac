#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export FFMPEG="${FFMPEG:-$(command -v ffmpeg || true)}"
export FFPROBE="${FFPROBE:-$(command -v ffprobe || true)}"
if [ ! -x "$FFMPEG" ] || [ ! -x "$FFPROBE" ]; then
    echo "Tests need ffmpeg and ffprobe in PATH, or FFMPEG/FFPROBE absolute paths." >&2
    exit 1
fi
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/musictag-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
mkdir -p "$ROOT/analysis/tests"
for TEST in TagEngine MP4; do
    xcrun swiftc -module-cache-path "$BUILD/cache" \
        "$ROOT/Sources/MusicTag/TagEngine.swift" "$ROOT/Sources/MusicTag/MP4Tags.swift" \
        "$ROOT/Tests/${TEST}Tests.swift" -o "$BUILD/${TEST}Tests"
done
xcrun swiftc -module-cache-path "$BUILD/cache" \
    "$ROOT/Sources/MusicTag/TagEngine.swift" "$ROOT/Sources/MusicTag/MP4Tags.swift" \
    "$ROOT/Sources/MusicTag/LibraryStore.swift" "$ROOT/Sources/MusicTag/LyricFormatter.swift" \
    "$ROOT/Sources/MusicTag/OnlineLookup.swift" "$ROOT/Sources/MusicTag/KugouLyrics.swift" \
    "$ROOT/Tests/LibraryStoreTests.swift" -o "$BUILD/LibraryStoreTests"
"$BUILD/TagEngineTests" "$ROOT/analysis/tests" | tee "$ROOT/analysis/tests/tag-engine-results.txt"
"$BUILD/MP4Tests" "$FFMPEG" "$FFPROBE" | tee "$ROOT/analysis/tests/mp4-results.txt"
"$BUILD/LibraryStoreTests" "$ROOT/analysis/tests/roundtrip.mp3" | tee "$ROOT/analysis/tests/library-results.txt"
