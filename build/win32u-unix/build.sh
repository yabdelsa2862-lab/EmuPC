#!/bin/bash
# Build Wine's win32u unix side as a static lib for iOS (aarch64).
# Mirrors build/ntdll-unix/build.sh — compiles unpatched upstream .c files
# with iOS clang, per-file overrides go in this dir.
#
# Phase 3D step 1: just get every file compiling. All SONAME_LIB*
# deps (freetype, fontconfig, egl, vulkan) forced undefined for now;
# those code paths fall back to stubs.
set -e

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
WINE_SRC="$REPO_ROOT/wine"
WINE_BUILD="$WINE_SRC/build-macos"
NTDLL_SHIMS="$REPO_ROOT/build/ntdll-unix/shims"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
OBJ_DIR="$BUILD_DIR/obj"
APP_LIB="$REPO_ROOT/app/Madeira/libwin32u_unix.a"

mkdir -p "$OBJ_DIR"

SUCCEEDED=0
FAILED=0
FAILED_FILES=""

FREETYPE_DIR="$REPO_ROOT/build/freetype-ios"

compile_one() {
    local src=$1
    local name=$2
    shift 2
    echo -n "  $name... "

    if xcrun -sdk iphoneos clang \
        -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 \
        -O2 -fPIC -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing \
        -Wno-implicit-function-declaration -Wno-int-conversion \
        -include "$BUILD_DIR/config_ios.h" \
        -include "$REPO_ROOT/build/ntdll-unix/shims/wine_ios_exit.h" \
        -I"$BUILD_DIR" \
        -I"$WINE_BUILD/include" \
        -I"$NTDLL_SHIMS" \
        -I"$WINE_BUILD/dlls/win32u" -I"$WINE_SRC/dlls/win32u" \
        -I"$WINE_BUILD/include" -I"$WINE_SRC/include" \
        -D__WINESRC__ -D_WIN32U_ \
        -D_ACRTIMP= -DWINBASEAPI= \
        -DSYSTEMDLLPATH=\"\" \
        -DWINE_UNIX_LIB -DWINE_IOS=1 \
        -D__wine_unix_lib_init=win32u_unix_lib_init \
        -USONAME_LIBFREETYPE \
        -USONAME_LIBFONTCONFIG \
        -USONAME_LIBEGL \
        -USONAME_LIBVULKAN \
        -USONAME_LIBGNUTLS \
        -UHAVE_FT2BUILD_H \
        "$@" \
        -c "$src" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        echo "OK"
        SUCCEEDED=$((SUCCEEDED + 1))
    else
        echo "FAILED"
        FAILED=$((FAILED + 1))
        FAILED_FILES="$FAILED_FILES $name"
    fi
}

echo "=== Building win32u unix (iOS) ==="

# All *.c files except main.c (main.c is the PE side entry — lives in win32u.dll).
# dibdrv/*.c compile as their own translation units.
for src in $WINE_SRC/dlls/win32u/*.c $WINE_SRC/dlls/win32u/dibdrv/*.c; do
    name=$(basename "$src" .c)

    # main.c is PE-side (DllMain, syscall PE wrappers) — skip.
    [ "$name" = "main" ] && continue

    # dibdrv file collisions: prefix them so we don't overwrite dc.o/bitblt.o/objects.o
    if [[ "$src" == *"/dibdrv/"* ]]; then
        name="dibdrv_$name"
    fi

    # Per-file iOS overrides (analogous to ntdll-unix's pattern).
    case "$name" in
        class)
            compile_one "$BUILD_DIR/class_ios.c" "class"
            continue
            ;;
        winstation)
            compile_one "$BUILD_DIR/winstation_ios.c" "winstation"
            continue
            ;;
        sysparams)
            compile_one "$BUILD_DIR/sysparams_ios.c" "sysparams"
            continue
            ;;
        defwnd)
            compile_one "$BUILD_DIR/defwnd_ios.c" "defwnd"
            continue
            ;;
        driver)
            compile_one "$BUILD_DIR/driver_ios.c" "driver"
            continue
            ;;
        message)
            compile_one "$BUILD_DIR/message_ios.c" "message"
            continue
            ;;
        d3dkmt)
            # Wraps upstream d3dkmt.c: the opt-in MADEIRA_KMT_ADAPTER adapter
            # (see the header comment in d3dkmt_ios.c).
            compile_one "$BUILD_DIR/d3dkmt_ios.c" "d3dkmt"
            continue
            ;;
        syscall)
            # Wraps upstream syscall.c and adds win32u_zero_bits(), the
            # allocation ceiling of the calling pseudo-process (see the
            # header comment in syscall_ios.c).
            compile_one "$BUILD_DIR/syscall_ios.c" "syscall"
            continue
            ;;
        freetype)
            # Statically-linked freetype (build/freetype-ios). The wrapper
            # re-defines HAVE_FT2BUILD_H itself; config_ios.h's #undefs win
            # for every other TU.
            compile_one "$BUILD_DIR/freetype_ios.c" "freetype" \
                -I"$FREETYPE_DIR/build/include" \
                -I"$REPO_ROOT/research/freetype/include"
            continue
            ;;
    esac

    compile_one "$src" "$name"
done

# MABD local: opengl32's unix side (Wine's OpenGL front end: wgl, contexts,
# the GL thunks), bound by name in build/ntdll-unix/virtual_ios.c when
# MADEIRA_OPENGL=1. Its table names are renamed so they do not collide.
for src in unix_wgl unix_thunks; do
    compile_one "$WINE_SRC/dlls/opengl32/$src.c" "opengl32_$src" \
        -I"$WINE_SRC/dlls/opengl32" -D_OPENGL32_ \
        -D__wine_unix_call_funcs=opengl32_unix_call_funcs \
        -D__wine_unix_call_wow64_funcs=opengl32_unix_call_wow64_funcs
done

echo ""
echo "Results: $SUCCEEDED succeeded, $FAILED failed"
if [ -n "$FAILED_FILES" ]; then
    echo "Failed:$FAILED_FILES"
fi

if [ $FAILED -gt 0 ]; then
    echo ""
    echo "(not linking — errors in $OBJ_DIR/<name>.err)"
    exit 1
fi

echo ""
echo "=== Building libwin32u_unix.a ==="
rm -f "$OBJ_DIR/libwin32u_unix.a"   # ar only adds: start clean (no stale OpenGL stub)
ar rcs "$OBJ_DIR/libwin32u_unix.a" "$OBJ_DIR"/*.o

# Merge the static freetype so the app link needs no project changes.
if [ -f "$FREETYPE_DIR/build/libfreetype.a" ]; then
    libtool -static -o "$OBJ_DIR/libwin32u_unix.a" \
        "$OBJ_DIR/libwin32u_unix.a" "$FREETYPE_DIR/build/libfreetype.a" 2>/dev/null
    echo "merged libfreetype.a"
else
    echo "WARNING: no libfreetype.a — fonts will be disabled"
fi

# MABD local: OpenGL (gl4es + the iOS glue, build/gl4es-ios/build.sh). Without
# it the driver's weak winios_gl_* references stay NULL and OpenGL stays off.
GL4ES_LIB="$REPO_ROOT/build/gl4es-ios/out/libgl4es_ios.a"
if [ -f "$GL4ES_LIB" ]; then
    libtool -static -o "$OBJ_DIR/libwin32u_unix.a" \
        "$OBJ_DIR/libwin32u_unix.a" "$GL4ES_LIB" 2>/dev/null
    echo "merged libgl4es_ios.a"
else
    xcrun -sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2 \
        -c "$REPO_ROOT/build/gl4es-ios/winios_gl_stub.c" -o "$OBJ_DIR/winios_gl_stub.o.part"
    ar rs "$OBJ_DIR/libwin32u_unix.a" "$OBJ_DIR/winios_gl_stub.o.part" 2>/dev/null
    echo "NOTE: no libgl4es_ios.a — OpenGL programs will not run (stub linked)"
fi

echo "Copying to app..."
cp "$OBJ_DIR/libwin32u_unix.a" "$APP_LIB"
echo "libwin32u_unix.a: $(wc -c < "$APP_LIB" | tr -d ' ') bytes"
echo "Done!"
