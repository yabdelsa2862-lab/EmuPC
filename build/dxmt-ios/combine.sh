#!/bin/bash
# Produce app/Madeira/libdxmt_combined.a: the DXMT unix side (libdxmt_unix.a)
# merged with the LLVM 15 archives airconv needs, built for iOS in
# toolchains/llvm-ios-build. build.sh refreshes an existing combined archive
# but nothing in the repository created the first one; this does.
#
# Uses build/dxmt-ios/libdxmt_unix.a if build.sh has produced one, otherwise
# the tracked prebuilt app/libdxmt_unix.a.
set -eu

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
LLVM_LIB="$REPO_ROOT/toolchains/llvm-ios-build/lib"

UNIX_LIB="$BUILD_DIR/libdxmt_unix.a"
[ -f "$UNIX_LIB" ] || UNIX_LIB="$REPO_ROOT/app/libdxmt_unix.a"

# Same list as research/dxmt/src/airconv/meson.build (llvm-config --libs bitwriter passes).
LLVM_LIBS=(
    Passes Target ObjCARCOpts Coroutines ipo Instrumentation Vectorize Linker
    IRReader AsmParser FrontendOpenMP ScalarOpts InstCombine AggressiveInstCombine
    TransformUtils BitWriter Analysis ProfileData Symbolize DebugInfoPDB
    DebugInfoMSF DebugInfoDWARF Object TextAPI MCParser MC DebugInfoCodeView
    BitReader Core Remarks BitstreamReader BinaryFormat Support Demangle
)
INPUTS=("$UNIX_LIB")
for l in "${LLVM_LIBS[@]}"; do
    INPUTS+=("$LLVM_LIB/libLLVM$l.a")
done

xcrun -sdk iphoneos libtool -static -no_warning_for_no_symbols \
    -o "$BUILD_DIR/libdxmt_combined.a" "${INPUTS[@]}"
cp "$BUILD_DIR/libdxmt_combined.a" "$REPO_ROOT/app/Madeira/libdxmt_combined.a"
echo "libdxmt_combined.a from $(basename "$(dirname "$UNIX_LIB")")/$(basename "$UNIX_LIB"):" \
     "$(wc -c < "$REPO_ROOT/app/Madeira/libdxmt_combined.a" | tr -d ' ') bytes"
