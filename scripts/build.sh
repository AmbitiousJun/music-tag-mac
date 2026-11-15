#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
    "") ARCHS=(arm64) ;;
    --universal) ARCHS=(arm64 x86_64) ;;
    *) echo "Usage: $0 [--universal]" >&2; exit 2 ;;
esac
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/musictag-build.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
APP="$BUILD/MusicTag.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/dist"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
for ARCH in "${ARCHS[@]}"; do
    echo "Building MusicTag for ${ARCH}..."
    xcrun swiftc -Osize -whole-module-optimization -swift-version 5 \
        -sdk "$SDK" -target "$ARCH-apple-macosx13.0" \
        -module-cache-path "$BUILD/cache" \
        "$ROOT"/Sources/MusicTag/*.swift -o "$BUILD/MusicTag-$ARCH"
done
if [ "${#ARCHS[@]}" -gt 1 ]; then
    xcrun lipo -create "$BUILD/MusicTag-arm64" "$BUILD/MusicTag-x86_64" -output "$APP/Contents/MacOS/MusicTag"
else
    cp "$BUILD/MusicTag-arm64" "$APP/Contents/MacOS/MusicTag"
fi
xcrun strip -x "$APP/Contents/MacOS/MusicTag"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
xcrun swiftc -Osize -module-cache-path "$BUILD/cache" "$ROOT/scripts/make-icon.swift" -o "$BUILD/make-icon"
"$BUILD/make-icon" "$BUILD/AppIcon.iconset"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"
# Stage and sign first, so a compilation failure preserves the previous build.
if [ -e "$ROOT/dist/MusicTag.app" ]; then
    mv "$ROOT/dist/MusicTag.app" "$BUILD/previous.app"
fi
mv "$APP" "$ROOT/dist/MusicTag.app"
echo "Built $ROOT/dist/MusicTag.app"
du -sh "$ROOT/dist/MusicTag.app"
