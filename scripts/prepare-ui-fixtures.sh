#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [new-fixture-directory]" >&2
    exit 2
fi
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/musictag-ui-fixtures.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
TARGET="${1:-$ROOT/analysis/tests/ui/manual-$(date +%Y%m%d-%H%M%S)-$(uuidgen)}"
xcrun swiftc -module-cache-path "$BUILD/cache" \
    "$ROOT/Sources/MusicTag/TagEngine.swift" "$ROOT/Sources/MusicTag/MP4Tags.swift" \
    "$ROOT/Tests/Support/UITestFixtures.swift" "$ROOT/scripts/prepare-ui-fixtures.swift" \
    -o "$BUILD/prepare-ui-fixtures"
"$BUILD/prepare-ui-fixtures" "$TARGET"
