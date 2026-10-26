#!/bin/bash
# Build the base libwineserver.a that build.sh patches in place.
#
# build.sh expects obj/libwineserver.a (or app/Madeira/libwineserver.a) to
# already exist and only swaps the iOS-patched objects into it; the original
# base archive was never committed. This compiles every wine/server/*.c with
# the same flags build.sh uses, so a clean checkout can run build.sh after it.
set -e

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
WINE_SRC="$REPO_ROOT/wine"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
SHIMS_DIR="$REPO_ROOT/build/ntdll-unix/shims"
OBJ_DIR="$BUILD_DIR/obj/base"
rm -rf "$OBJ_DIR" && mkdir -p "$OBJ_DIR"

CC_FLAGS=(
    -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2
    -I"$WINE_SRC/include" -I"$WINE_SRC/include/wine"
    -I"$WINE_SRC/build-macos/include"
    -I"$BUILD_DIR" -I"$WINE_SRC/server"
    -I"$SHIMS_DIR"
    -I"$BUILD_DIR/../madsync" -DHAVE_LINUX_NTSYNC_H=1
    -include "$BUILD_DIR/config_ios.h"
    -include stdarg.h
    -include "$BUILD_DIR/unicode_fix.h"
    -include "$BUILD_DIR/wineserver_ios_kill.h"
    -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\"
    -D__WINESRC__ -DWINE_IOS=1
    -Dmain=wineserver_main
    -Wno-implicit-function-declaration
)

FAILED=""
for src in "$WINE_SRC"/server/*.c; do
    name=$(basename "$src" .c)
    if ! xcrun -sdk iphoneos clang "${CC_FLAGS[@]}" -c "$src" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        FAILED="$FAILED $name"
    fi
done
[ -n "$FAILED" ] && echo "base objects that failed (build.sh replaces some of them):$FAILED"

rm -f "$BUILD_DIR/obj/libwineserver.a"
ar rcs "$BUILD_DIR/obj/libwineserver.a" "$OBJ_DIR"/*.o
echo "Base archive: $BUILD_DIR/obj/libwineserver.a ($(ls "$OBJ_DIR"/*.o | wc -l | tr -d ' ') objects)"
