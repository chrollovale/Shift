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
FRAMEWORKS="$BUNDLE/Contents/Frameworks"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Shift is a macOS app, so it has to be built on a Mac." >&2
    exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    echo "Swift isn't installed. Run:  xcode-select --install   and try again." >&2
    exit 1
fi

# MTP is an optional build feature. Keeping it optional preserves the ADB-only
# build for users who don't have Homebrew's libmtp installed.
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libmtp; then
    export SHIFT_ENABLE_MTP=1
    echo "> MTP support enabled (libmtp found)."

    # Homebrew bottles target the current macOS release. Build the runtime from
    # pinned sources when that deployment target is newer than Shift's minimum.
    LIBMTP_LINK_PATH="$(pkg-config --variable=libdir libmtp)"
    LIBMTP_DYLIB="$(find -L "$LIBMTP_LINK_PATH" -maxdepth 1 -name 'libmtp*.dylib' -print -quit)"
    LIBMTP_MIN_OS="$(vtool -show-build "$LIBMTP_DYLIB" 2>/dev/null | awk '/minos/ { print $2; exit }')"
    NEEDS_MACOS13_RUNTIME=0
    if [ -n "$LIBMTP_MIN_OS" ] && [ "${LIBMTP_MIN_OS%%.*}" -gt 13 ]; then
        NEEDS_MACOS13_RUNTIME=1
    fi
    while IFS= read -r dependency; do
        case "$dependency" in
            /System/Library/*|/usr/lib/*) continue ;;
            /*) candidate="$dependency" ;;
            *) candidate="$(find -L "$(brew --prefix)" -type f -name "$(basename "$dependency")" -print -quit)" ;;
        esac
        if [ ! -f "$candidate" ]; then
            candidate="$(find -L "$(brew --prefix)" -type f -name "$(basename "$dependency")" -print -quit)"
        fi
        [ -f "$candidate" ] || continue
        dependency_min_os="$(vtool -show-build "$candidate" 2>/dev/null | awk '/minos/ { print $2; exit }')"
        if [ -n "$dependency_min_os" ] && [ "${dependency_min_os%%.*}" -gt 13 ]; then
            NEEDS_MACOS13_RUNTIME=1
        fi
    done < <(otool -L "$LIBMTP_DYLIB" | awk 'NR > 1 { print $1 }')

    if [ "$NEEDS_MACOS13_RUNTIME" = "1" ]; then
        MTP_RUNTIME="$PWD/build/mtp-runtime"
        echo "> libmtp targets macOS $LIBMTP_MIN_OS; building a macOS 13 runtime."
        bash Tools/build_mtp_runtime.sh "$MTP_RUNTIME"
        export PKG_CONFIG_PATH="$MTP_RUNTIME/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
        export PKG_CONFIG_LIBDIR="$MTP_RUNTIME/lib/pkgconfig"
        export LIBRARY_PATH="$MTP_RUNTIME/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
        export C_INCLUDE_PATH="$MTP_RUNTIME/include${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
    fi
else
    unset SHIFT_ENABLE_MTP || true
    echo "> MTP support is off. Install libmtp with Homebrew and rebuild to enable it."
fi

# Copy non-system dynamic libraries used by MTP into the app bundle and rewrite
# their install names. The release app can then run without Homebrew installed.
declare -a BUNDLED_MTP_LIBS=("__unprocessed__")
bundle_mtp_library() {
    local dependency="$1"
    local importer="$2"
    local source name destination reference already_bundled

    case "$dependency" in
        /System/Library/*|/usr/lib/*) return 0 ;;
        /*) source="$dependency" ;;
        *)
            name="$(basename "$dependency")"
            source="$(find -L "$(brew --prefix)" -type f -name "$name" -print -quit)"
            ;;
    esac
    if [ ! -f "$source" ]; then
        echo "Couldn't locate MTP runtime library: $dependency" >&2
        return 1
    fi

    name="$(basename "$source")"
    destination="$FRAMEWORKS/$name"
    already_bundled=0
    for bundled in "${BUNDLED_MTP_LIBS[@]}"; do
        if [ "$bundled" = "$name" ]; then already_bundled=1; break; fi
    done
    if [ "$already_bundled" = "0" ]; then
        BUNDLED_MTP_LIBS+=("$name")
        cp -L "$source" "$destination"
        install_name_tool -id "@rpath/$name" "$destination"
        while IFS= read -r nested; do
            [ -z "$nested" ] && continue
            case "$nested" in
                /System/Library/*|/usr/lib/*) continue ;;
            esac
            bundle_mtp_library "$nested" "$destination"
        done < <(otool -L "$destination" | awk 'NR > 1 { print $1 }')
    fi

    if [ "$importer" = "$BUNDLE/Contents/MacOS/$APP" ]; then
        reference="@rpath/$name"
    else
        reference="@loader_path/$name"
    fi
    install_name_tool -change "$dependency" "$reference" "$importer"
}

bundle_mtp_runtime() {
    local dependency app_binary="$BUNDLE/Contents/MacOS/$APP" found=0
    while IFS= read -r dependency; do
        case "$dependency" in
            *libmtp*) found=1; bundle_mtp_library "$dependency" "$app_binary" ;;
        esac
    done < <(otool -L "$BIN" | awk 'NR > 1 { print $1 }')
    if [ "$found" = "1" ]; then
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$app_binary"
        if ! otool -L "$app_binary" | grep -q '@rpath/libmtp'; then
            echo "Couldn't make the bundled libmtp reachable from the app." >&2
            return 1
        fi
        mkdir -p "$BUNDLE/Contents/Resources/ThirdPartyLicenses"
        cp Resources/ThirdPartyLicenses/* "$BUNDLE/Contents/Resources/ThirdPartyLicenses/"
    fi
}

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
if [ "${SHIFT_ENABLE_MTP:-0}" = "1" ]; then
    mkdir -p "$FRAMEWORKS"
    bundle_mtp_runtime
fi
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
