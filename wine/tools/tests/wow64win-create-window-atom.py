#!/usr/bin/env python3
"""Compile the real CreateWindowEx thunk with a synthetic guest base.

LGPL-2.1-or-later. Runs on a 64-bit host with Python 3 and a C compiler;
does not start Wine or replace installed DLLs.
"""
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def function(source, name):
    match = re.search(r"^.*\b" + re.escape(name) + r"\([^;]*?\)\s*\{", source, re.M)
    if not match:
        raise RuntimeError("Function not found: " + name)
    start = source.index("{", match.start())
    depth = 1
    end = start + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[match.start():end]


private = (ROOT / "dlls/wow64win/wow64win_private.h").read_text()
user = (ROOT / "dlls/wow64win/user.c").read_text()
code = r"""
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
typedef uint32_t UINT, ULONG, DWORD, NTSTATUS;
typedef uintptr_t ULONG_PTR;
typedef uint16_t WCHAR;
typedef int BOOL;
typedef void *HANDLE, *HWND, *HMENU, *HINSTANCE;
typedef struct { int unused; } UNICODE_STRING, UNICODE_STRING32;
#define WINAPI
#define LongToHandle(x) ((HANDLE)(intptr_t)(int32_t)(x))
#define HandleToUlong(x) ((ULONG)(uintptr_t)(x))
static uintptr_t base, observed_class;
static uintptr_t wow64win_guest_base(void) { return base; }
static UNICODE_STRING *unicode_str_32to64(UNICODE_STRING *out, const UNICODE_STRING32 *in)
{ return in ? out : NULL; }
static HWND NtUserCreateWindowEx(DWORD ex, UNICODE_STRING *cl, UNICODE_STRING *ver,
    UNICODE_STRING *name, DWORD style, int x, int y, int w, int h, HWND parent,
    HMENU menu, HINSTANCE instance, void *params, DWORD flags, HINSTANCE client,
    const WCHAR *class, BOOL ansi)
{
    observed_class = (uintptr_t)class;
    assert(ansi == 1);
    return (HWND)(uintptr_t)0x1234;
}
"""
for name in ("guest_ptr32", "get_ulong", "get_handle", "get_ptr", "get_str_or_atom"):
    code += function(private, name) + "\n"
code += function(user, "wow64_NtUserCreateWindowEx")
code += r"""
int main(void)
{
    const ULONG values[] = {0, 1, 0x8002, 0xc001, 0xffff, 0x10000, 0x7fff0000, 0xffffffff};
    const uintptr_t bases[] = {0, UINT64_C(0x400000000)};
    unsigned int b, i;
    assert(sizeof(void *) == 8);
    for (b = 0; b < sizeof(bases)/sizeof(bases[0]); ++b)
    {
        base = bases[b];
        for (i = 0; i < sizeof(values)/sizeof(values[0]); ++i)
        {
            UINT args[17] = {0};
            uintptr_t expected = values[i] <= 0xffff ? values[i] : base + values[i];
            args[15] = values[i];
            args[16] = 1;
            assert(wow64_NtUserCreateWindowEx(args) == 0x1234);
            assert(observed_class == expected);
        }
    }
    puts("PASS: CreateWindowEx preserves NULL/atoms and rebases string pointers at zero/nonzero guest bases");
    return 0;
}
"""
with tempfile.TemporaryDirectory(prefix="wow64win-atom-") as directory:
    source = Path(directory) / "test.c"
    binary = Path(directory) / "test"
    source.write_text(code)
    subprocess.run(shlex.split(os.environ.get("CC", "cc")) +
                   ["-std=c99", "-Wall", "-Werror", "-Wno-unused-function",
                    str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
