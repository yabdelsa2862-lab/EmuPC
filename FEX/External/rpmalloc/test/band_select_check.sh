#!/bin/sh
# band_select_check.sh  -  build check for the 64 GB-regime host-arena slice
#
# Copyright 2026 125hz. Distributed under the same terms as rpmalloc.c in this
# fork (see LICENSE and LICENSE-MADEIRA.md).
#
# ios_fex_band_select() places the FEX host arena. In the constrained 64 GB
# regime the WOW64 build (aarch64, 32-bit guests) may use [48 GB, 60 GB); the
# ARM64EC build (64-bit processes) must keep upstream's [48 GB, 56 GB). The
# choice is compile-time, so this compiles rpmalloc.c exactly as FEX does for
# each CPU module (-DFEX_IOS_HOST) and checks which candidate table landed in
# the object: {0x0c00000000, 0x0dffffffff} or {0x0c00000000, 0x0effffffff}.
#
# Usage: LLVM_MINGW=/path/to/llvm-mingw sh test/band_select_check.sh
set -eu
: "${LLVM_MINGW:?set LLVM_MINGW to the llvm-mingw toolchain root}"
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Little-endian {start, end} pairs as they appear in .rdata.
upstream=000000000c000000ffffffff0d000000
wide=000000000c000000ffffffff0e000000
fail=0

check() {
	target=$1 want=$2 notwant=$3 label=$4
	"$LLVM_MINGW/bin/$target-w64-mingw32-clang" -O2 -DFEX_IOS_HOST -I"$root/rpmalloc" \
		-c "$root/rpmalloc/rpmalloc.c" -o "$tmp/$target.o" 2>/dev/null
	hex=$(od -An -v -tx1 "$tmp/$target.o" | tr -d ' \n')
	if printf '%s' "$hex" | grep -q "$want" && ! printf '%s' "$hex" | grep -q "$notwant"; then
		echo "ok   $target: 64 GB-regime slice is $label"
	else
		echo "FAIL $target: expected the $label slice"
		fail=1
	fi
}

check arm64ec "$upstream" "$wide" "upstream [48 GB, 56 GB)"
check aarch64 "$wide" "$upstream" "WOW64 [48 GB, 60 GB)"
exit $fail
