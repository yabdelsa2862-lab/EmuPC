#!/bin/bash
# Generate build/dxmt-ios/shader-headers/*.h (the airconv helper shaders as
# embedded AIR bitcode) the same way dxmt/src/airconv/meson.build
# does: metal -> .air, then xxd -i. build.sh includes this directory but
# nothing in the repository created it.
set -eu

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
SHADERS="$REPO_ROOT/dxmt/src/airconv/shaders"
OUT="$BUILD_DIR/shader-headers"
mkdir -p "$OUT"

for name in air_msad air_samplepos air_tessellation; do
    xcrun -sdk macosx metal -std=metal3.1 --target=air64-apple-macos14.0 \
        -o "$OUT/$name.air" -c "$SHADERS/$name.metal"
    (cd "$OUT" && xxd -n "$name" -i "$name.air" "$name.h")
    rm "$OUT/$name.air"
    echo "  $name.h"
done
