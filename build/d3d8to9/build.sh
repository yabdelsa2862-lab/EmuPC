#!/bin/zsh
# EmuPC: d3d8to9 (BSD-2-Clause, ../../d3d8to9) as the i386 d3d8.dll.
# Direct3D 8 calls become Direct3D 9 calls, which DXMT's 32-bit D3D9 path
# draws with Metal. Replaces Wine's d3d8.dll, which needs wined3d and so a
# 32-bit OpenGL or Vulkan this port does not have.
set -e
HERE=${0:A:h}
ROOT=${HERE:h:h}
SRC=$ROOT/d3d8to9
T=$ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin
OUT=$HERE/out
mkdir -p $OUT
$T/i686-w64-mingw32-clang++ -std=c++17 -O2 -DD3D8TO9NOLOG -DNDEBUG \
  -Wno-delete-non-virtual-dtor -Wno-unknown-pragmas \
  -shared -static -Wl,--enable-stdcall-fixup -Wl,--large-address-aware \
  -o $OUT/d3d8.dll $SRC/source/*.cpp $SRC/res/d3d8.def -ld3d9 -lgdi32
$T/i686-w64-mingw32-objdump -p $OUT/d3d8.dll | sed -n 's/^\s*DLL Name: //p'
cp $OUT/d3d8.dll $ROOT/app/Madeira/i386-windows/d3d8.dll
ls -l $ROOT/app/Madeira/i386-windows/d3d8.dll
