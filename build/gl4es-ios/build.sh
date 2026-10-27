#!/bin/zsh
# MABD local: gl4es (desktop OpenGL 2.1 on OpenGL ES, MIT, ../../gl4es) for
# iOS, plus the iOS glue (winios_gl.m: EAGL contexts, IOSurface-backed
# window buffers, Metal present). Output: build/gl4es-ios/out/libgl4es_ios.a,
# merged into libwin32u_unix.a by build/win32u-unix/build.sh.
set -e
HERE=${0:A:h}
ROOT=${HERE:h:h}
OUT=$HERE/out
mkdir -p $OUT
cmake -S $ROOT/gl4es -B $HERE/cmake -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_BUILD_TYPE=Release \
  -DNOX11=ON -DNOEGL=ON -DSTATICLIB=ON -DNO_LOADER=ON -DNO_INIT_CONSTRUCTOR=ON -DDEFAULT_ES=2 \
  -DCMAKE_C_FLAGS="-fvisibility=hidden -Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-function-pointer-types" >$OUT/cmake.log 2>&1 \
  || { tail -20 $OUT/cmake.log; exit 1; }
cmake --build $HERE/cmake --target GL -j 8 >$OUT/build.log 2>&1 || { grep -E "error" $OUT/build.log | head -20; exit 1; }
lib=$(find $HERE/cmake $ROOT/gl4es/lib -name "libGL*.a" 2>/dev/null | head -1)
[[ -n $lib ]] || { echo "no libGL.a found"; exit 1; }
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun -sdk iphoneos clang -arch arm64 -isysroot $SDK -miphoneos-version-min=17.0 -O2 -fobjc-arc -fmodules \
  -DGLES_SILENCE_DEPRECATION -c $HERE/winios_gl.m -o $OUT/winios_gl.o
xcrun -sdk iphoneos clang -arch arm64 -isysroot $SDK -miphoneos-version-min=17.0 -O2 -fvisibility=hidden \
  -I$ROOT/gl4es/include -I$ROOT/gl4es/src -DNOX11 -DNOEGL -DSTATICLIB -DNO_LOADER -DDEFAULT_ES=2 \
  -c $HERE/gl4es_glue.c -o $OUT/gl4es_glue.o
libtool -static -o $OUT/libgl4es_ios.a $lib $OUT/winios_gl.o $OUT/gl4es_glue.o 2>/dev/null
ls -lh $OUT/libgl4es_ios.a
