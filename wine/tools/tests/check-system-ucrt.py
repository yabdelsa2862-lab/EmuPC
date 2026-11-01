#!/usr/bin/env python3
"""Compile the production DLL policy and check UCRT and XInput independently."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "dlls/ntdll/loader.c").read_text()
start = source.index("static BOOL madeira_force_builtin_dll(")
end = source.index("\n}\n", start) + 3
policy = source[start:end]
caller = source[source.index("static NTSTATUS find_dll_file("):]
caller = caller[:caller.index("\n}\n")]
assert caller.index("RtlPathTypeRelative") < caller.index("madeira_force_builtin_dll( libname )")
assert "load_path = system_dir;" in caller

harness = r'''
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
typedef int BOOL;
typedef wchar_t WCHAR;
typedef struct { WCHAR *Buffer; unsigned short Length, MaximumLength; } UNICODE_STRING;
#define TRUE 1
#define FALSE 0
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define wcsicmp wcscasecmp
#define wcsnicmp wcsncasecmp
static void RtlInitUnicodeString(UNICODE_STRING *s, const WCHAR *v) { s->Buffer = (WCHAR *)v; }
static int RtlQueryEnvironmentVariable_U(void *env, UNICODE_STRING *name, UNICODE_STRING *value)
{
    char key[64];
    const char *v;
    (void)env;
    assert(wcstombs(key, name->Buffer, sizeof(key)) < sizeof(key));
    v = getenv(key);
    if (!v) return -1;
    assert((strlen(v) + 1) * sizeof(WCHAR) <= value->MaximumLength);
    mbstowcs(value->Buffer, v, value->MaximumLength / sizeof(WCHAR));
    value->Length = strlen(v) * sizeof(WCHAR);
    return 0;
}
POLICY
int main(void)
{
    const WCHAR *ucrt[] = {L"ucrtbase.dll", L"UCRTBASE.DLL", L"ucrtbase",
        L"api-ms-win-crt-heap-l1-1-0.dll", L"API-MS-WIN-CRT-STDIO-L1-1-0.DLL"};
    const WCHAR *other[] = {L"my-ucrtbase.dll", L"ucrtbase.dll.extra", L"kernel32.dll",
        L"api-ms-win-core-file-l1-1-0.dll", L"C:\\game\\ucrtbase.dll", L""};
    const WCHAR *pads[] = {L"xinput1_1.dll", L"xinput1_2.dll", L"XINPUT1_3.DLL",
        L"xinput1_4.dll", L"xinput9_1_0.dll", L"xinputuap.dll"};
    const char *u = getenv("MADEIRA_NATIVE_UCRT"), *x = getenv("MADEIRA_NATIVE_XINPUT");
    for (unsigned i = 0; i < ARRAY_SIZE(ucrt); ++i)
        assert(madeira_force_builtin_dll(ucrt[i]) == !(u && u[0] == '1'));
    for (unsigned i = 0; i < ARRAY_SIZE(other); ++i) assert(!madeira_force_builtin_dll(other[i]));
    for (unsigned i = 0; i < ARRAY_SIZE(pads); ++i)
        assert(madeira_force_builtin_dll(pads[i]) == !(x && x[0] == '1'));
    return 0;
}
'''.replace("POLICY", policy)

with tempfile.TemporaryDirectory() as directory:
    directory = Path(directory)
    c = directory / "policy.c"
    binary = directory / "policy"
    c.write_text(harness)
    subprocess.run([os.environ.get("CC", "clang"), "-std=c11", "-Wall", "-Wextra", "-Werror",
                    "-fsanitize=address,undefined", str(c), "-o", str(binary)], check=True)
    for ucrt in (None, "0", "1"):
        for xinput in (None, "0", "1"):
            env = dict(os.environ)
            for key, value in (("MADEIRA_NATIVE_UCRT", ucrt), ("MADEIRA_NATIVE_XINPUT", xinput)):
                env.pop(key, None)
                if value is not None:
                    env[key] = value
            subprocess.run([str(binary)], env=env, check=True)
print("PASS: system UCRT names, unrelated names, XInput, and independent rollback switches")
