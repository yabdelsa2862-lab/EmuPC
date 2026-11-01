#!/bin/bash
# Build the 32-bit OpenGL acceptance test, gl-x86.exe, and copy it into
# app/Madeira/i386-windows/ (no CRT; kernel32/user32/gdi32/opengl32 only).
# Expected log: MADEIRA-GL lines, then MADEIRA-EXIT: gl-x86.exe status=43
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
T="$REPO_ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
cd "$SCRIPT_DIR"
"$T/i686-w64-mingw32-clang" -O2 -nostdlib -ffreestanding -Wl,--entry=_start -Wl,--large-address-aware \
    -o gl-x86.exe gl-x86.c -lkernel32 -luser32 -lgdi32 -lopengl32
"$T/i686-w64-mingw32-objdump" -p gl-x86.exe | grep "DLL Name"
cp gl-x86.exe "$REPO_ROOT/app/Madeira/i386-windows/gl-x86.exe"
rm gl-x86.exe
