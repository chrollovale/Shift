#!/bin/bash
# Builds Shift.app from source.
#
#   ./build.sh              build for this Mac       -> build/Shift.app
#   ./build.sh --run        build, then open it
#   ./build.sh --install    build, then copy it to /Applications
#   ./build.sh --clean      wipe the build cache first
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

# SwiftUI macros (@State, @FocusState, etc.) live inside Xcode.app.
# If xcode-select points at the stand-alone Command Line Tools, the build
# fails with "SwiftUIMacros.StateMacro could not be found".
# Detect this and switch to Xcode for this build if it is installed.
CURRENT_DEV=$(xcode-select -p 2>/dev/null || true)
if [[ "$CURRENT_DEV" == */CommandLineTools* ]] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    echo "> Using Xcode.app (Command Line Tools alone cannot compile SwiftUI macros)."
fi

ARCHS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then
    ARCHS=(--arch arm64 --arch x86_64)
fi

# Optional --clean flag to wipe the build cache before compiling.
if [ "${1:-}" = "--clean" ]; then
    echo "> Cleaning..."
    swift package clean 2>/dev/null || true
    rm -rf .build/out
    shift
fi

echo "> Compiling..."
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/$APP"

echo "> Assembling $BUNDLE..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/Fonts"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
cp Resources/Fonts/*.ttf Resources/Fonts/OFL-Silkscreen.txt "$BUNDLE/Contents/Resources/Fonts/"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

echo "> Signing (ad-hoc, for this Mac only)..."
codesign --force --deep --sign - "$BUNDLE"

echo "Done: $BUNDLE"

case "${1:-}" in
    --run)
        open "$BUNDLE"
        ;;
    --install)
        rm -rf "/Applications/$APP.app"
        cp -R "$BUNDLE" "/Applications/$APP.app"
        echo "Installed to /Applications/$APP.app"
        open "/Applications/$APP.app"
        ;;
esac
