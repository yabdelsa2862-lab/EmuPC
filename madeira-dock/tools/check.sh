#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
set -euo pipefail
cd "$(dirname "$0")/.."
# HOST_CC selects the compiler; otherwise clang from PATH, then the default
# swiftly install location (not on PATH for non-login shells such as `wsl -e`).
compiler="${HOST_CC:-$(command -v clang || true)}"
if [[ -z "$compiler" && -x "$HOME/.local/share/swiftly/bin/clang" ]]; then
    compiler="$HOME/.local/share/swiftly/bin/clang"
fi
[[ -n "$compiler" ]] || { echo "No clang found; set HOST_CC to a clang with ASan/UBSan" >&2; exit 1; }
output=.build/tests
mkdir -p "$output"
for test in probe validation auth client_layout; do
    "$compiler" -std=c11 -g -O1 -Wall -Wextra -Werror -fsanitize=address,undefined \
        -Isrc "src/$test.c" "tests/test-$test.c" -o "$output/test-$test"
    "$output/test-$test"
done
