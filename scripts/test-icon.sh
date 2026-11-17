#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/musictag-icon-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
xcrun swiftc -Osize -module-cache-path "$BUILD/cache" \
    "$ROOT/scripts/make-icon.swift" -o "$BUILD/make-icon"
xcrun swiftc -Osize -module-cache-path "$BUILD/cache" \
    "$ROOT/Tests/IconTests.swift" -o "$BUILD/IconTests"
"$BUILD/make-icon" "$BUILD/AppIcon.iconset"
# Exercise the system ICNS decoder, including the small representations that
# NSImage.isValid can accept even when their decoded pixels are corrupt.
/usr/bin/iconutil --convert iconset --output "$BUILD/decoded.iconset" "$BUILD/AppIcon.icns"
"$BUILD/IconTests" "$BUILD/AppIcon.iconset" "$BUILD/decoded.iconset"
