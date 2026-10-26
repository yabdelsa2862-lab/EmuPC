#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
# Cross-compile only. Running Steam on a host requires the owner's authorization.
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$PWD"
madeira="${MADEIRA_ROOT:-$repo/../Madeira}"
toolchain="${LLVM_MINGW_BIN:-$madeira/.xtool/toolchains/llvm-mingw/bin}"
output="${DOCK_OUTPUT:-$repo/.build/windows}"
mkdir -p "$output"
for arch in x86_64 i686; do
    compiler="$toolchain/$arch-w64-mingw32-clang"
    [[ -x "$compiler" ]] || { echo "Missing cross compiler: $compiler" >&2; exit 1; }
    "$compiler" -std=c11 -O2 -Wall -Wextra -Werror -Wno-cast-function-type \
        -static -Wl,--strip-all -o "$output/dockhost-$arch.exe" \
        src/main.c src/probe.c src/session.c src/launch.c src/validation.c src/auth.c src/client_layout.c src/scm.c -ladvapi32
done
echo "Built x86-64 and i386 probes in $output"
# Staging is explicit: experimental probes are not a new default launch route.
if [[ "${1:-}" == --stage ]]; then
    cp "$output/dockhost-x86_64.exe" "$madeira/app/Madeira/arm64ec-windows/dockhost.exe"
    notices="$madeira/app/Madeira/arm64ec-windows/dock-notices.txt"
    # GPL-3.0-or-later with the Madeira Converter Exception, the full licence
    # texts and the LLVM/MinGW-w64 runtime notices for the statically linked
    # runtime. Corresponding source: https://github.com/125hz/madeira-dock
    section() { printf '\n\n==== %s ====\n\n' "$1"; }
    {
        cat LICENSE
        section 'LICENSE-EXCEPTION.md (Madeira Converter Exception)'
        cat LICENSE-EXCEPTION.md
        section 'COPYING (GNU General Public License, version 3)'
        cat COPYING
        section 'MinGW-w64 runtime notice (statically linked runtime)'
        cat notices/MinGW-w64-runtime.txt
        section 'LLVM runtime notice'
        cat notices/LLVM.txt
    } > "$notices"
    echo "Staged stripped x64 Dock executable and GPL-3.0-or-later notices"
fi
