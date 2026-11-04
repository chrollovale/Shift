#!/bin/bash
# Build libusb and libmtp for Shift's macOS 13 deployment target.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${1:-$ROOT/build/mtp-runtime}"
SOURCE="$ROOT/build/mtp-source"
DOWNLOADS="$SOURCE/downloads"
LIBUSB_VERSION="1.0.30"
LIBMTP_VERSION="1.1.23"
JOBS="$(sysctl -n hw.ncpu)"

mkdir -p "$DOWNLOADS" "$PREFIX"

if [ -f "$PREFIX/.shift-mtp-runtime-macos13" ] \
    && [ -f "$PREFIX/lib/libmtp.9.dylib" ] \
    && [ -f "$PREFIX/lib/libusb-1.0.0.dylib" ]; then
    echo "Reusing the macOS 13 MTP runtime in $PREFIX"
    exit 0
fi

LIBUSB_ARCHIVE="$DOWNLOADS/libusb-$LIBUSB_VERSION.tar.bz2"
LIBMTP_ARCHIVE="$DOWNLOADS/libmtp-$LIBMTP_VERSION.tar.gz"

if [ ! -f "$LIBUSB_ARCHIVE" ]; then
    curl -fL --retry 3 "https://github.com/libusb/libusb/releases/download/v$LIBUSB_VERSION/libusb-$LIBUSB_VERSION.tar.bz2" -o "$LIBUSB_ARCHIVE"
fi
if [ ! -f "$LIBMTP_ARCHIVE" ]; then
    curl -fL --retry 3 "https://downloads.sourceforge.net/project/libmtp/libmtp/$LIBMTP_VERSION/libmtp-$LIBMTP_VERSION.tar.gz" -o "$LIBMTP_ARCHIVE"
fi

echo "fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf  $LIBUSB_ARCHIVE" | shasum -a 256 -c -
echo "74a2b6e8cb4a0304e95b995496ea3ac644c29371649b892b856e22f12a0bdeed  $LIBMTP_ARCHIVE" | shasum -a 256 -c -

LIBUSB_SOURCE="$SOURCE/libusb-$LIBUSB_VERSION"
LIBMTP_SOURCE="$SOURCE/libmtp-$LIBMTP_VERSION"
mkdir -p "$LIBUSB_SOURCE" "$LIBMTP_SOURCE"
tar -xjf "$LIBUSB_ARCHIVE" --strip-components=1 -C "$LIBUSB_SOURCE"
tar -xzf "$LIBMTP_ARCHIVE" --strip-components=1 -C "$LIBMTP_SOURCE"

export MACOSX_DEPLOYMENT_TARGET="13.0"
export CFLAGS="-O2 -mmacosx-version-min=13.0"
export LDFLAGS="-mmacosx-version-min=13.0"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

echo "> Building libusb $LIBUSB_VERSION for macOS 13..."
(
    cd "$LIBUSB_SOURCE"
    ac_cv_func_pipe2=no ./configure --prefix="$PREFIX" --disable-dependency-tracking --disable-static
    make clean
    make -j"$JOBS"
    make install
)

echo "> Building libmtp $LIBMTP_VERSION for macOS 13..."
(
    cd "$LIBMTP_SOURCE"
    CPPFLAGS="-I$PREFIX/include" \
    LDFLAGS="-L$PREFIX/lib -mmacosx-version-min=13.0" \
    PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
    PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
        ./configure --prefix="$PREFIX" --disable-mtpz --disable-silent-rules --with-udev="$PREFIX/lib/udev"
    make clean
    make -j"$JOBS"
    make install
)

LIBUSB_DYLIB="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$PREFIX/lib/libusb-1.0.0.dylib")"
LIBMTP_DYLIB="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]) if os.path.exists(sys.argv[1]) else "")' "$PREFIX/lib/libmtp.9.dylib")"
if [ -z "$LIBMTP_DYLIB" ]; then
    LIBMTP_DYLIB="$(find "$PREFIX/lib" -maxdepth 1 -name 'libmtp*.dylib' -type f -print -quit)"
fi

install_name_tool -id "$LIBUSB_DYLIB" "$LIBUSB_DYLIB"
install_name_tool -id "$LIBMTP_DYLIB" "$LIBMTP_DYLIB"
while IFS= read -r dependency; do
    case "$dependency" in
        *libusb*) install_name_tool -change "$dependency" "$LIBUSB_DYLIB" "$LIBMTP_DYLIB" ;;
    esac
done < <(otool -L "$LIBMTP_DYLIB" | awk 'NR > 1 { print $1 }')

touch "$PREFIX/.shift-mtp-runtime-macos13"
echo "MTP runtime built in $PREFIX"
