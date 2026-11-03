#!/bin/bash
# Builds Shift.app from source.
#
#   ./build.sh              build for this Mac       -> build/Shift.app
#   ./build.sh --run        build, then open it
#   ./build.sh --install    build, then copy it to /Applications
#   UNIVERSAL=1 ./build.sh  Apple Silicon + Intel (needs full Xcode)
#
# Needs Xcode or the Command Line Tools:  xcode-select --install

set -euo pipefail
cd "$(dirname "$0")"

APP="Shift"
OUT="build"
BUNDLE="$OUT/$APP.app"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Shift is a macOS app, so it has to be built on a Mac." >&2
    exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    echo "Swift isn't installed. Run:  xcode-select --install   and try again." >&2
    exit 1
fi

ARCHS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then
    ARCHS=(--arch arm64 --arch x86_64)
fi

echo "▸ Compiling…"
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/$APP"

echo "▸ Assembling $BUNDLE…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/Fonts"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
cp Resources/Fonts/*.ttf Resources/Fonts/OFL-Silkscreen.txt "$BUNDLE/Contents/Resources/Fonts/"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

echo "▸ Signing (ad-hoc, for this Mac only)…"
codesign --force --deep --sign - "$BUNDLE"

echo "✓ Built $BUNDLE"

case "${1:-}" in
    --run)
        open "$BUNDLE"
        ;;
    --install)
        rm -rf "/Applications/$APP.app"
        cp -R "$BUNDLE" "/Applications/$APP.app"
        echo "✓ Installed to /Applications/$APP.app"
        open "/Applications/$APP.app"
        ;;
esac
