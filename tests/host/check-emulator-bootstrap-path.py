#!/usr/bin/env python3
"""Check the emulator's CRT search before x64 translation is initialized.

Runs production search_dll_file and the bootstrap load_dll call under ASan/UBSan.
File opening and import recursion are modeled: an app-local x64 CRT must remain
available to ordinary loads, but must not shadow the emulator's system CRT.
This is a host regression, not a device/PE loader integration test.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "wine/dlls/ntdll/loader.c").read_text()


def function(signature):
    start = source.index(signature)
    return source[start:source.index("\n}", start) + 2]


bootstrap = function("static void load_arm64ec_module(void)")
call = re.search(r"load_dll\( [^\n]+ \)", bootstrap).group(0)
# The caller's explicit search path must survive the real import-loading chain.
assert "load_native_dll( load_path," in function("static NTSTATUS load_dll( const WCHAR *load_path, const WCHAR *libname, DWORD flags, WINE_MODREF** pwm, BOOL system )\n{")
assert "build_module( load_path," in function("static NTSTATUS load_native_dll(")
assert "fixup_imports( wm, load_path )" in function("static NTSTATUS build_module(")
assert "load_dll( load_path, buffer," in function("static BOOL import_dll(")
assert 'L"\\\\??\\\\C:\\\\windows\\\\sysx64\\\\"' in function("static NTSTATUS find_dll_file(")

code = r'''
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <stdio.h>
typedef wchar_t WCHAR;
typedef const WCHAR *LPCWSTR;
typedef int NTSTATUS, BOOL;
typedef unsigned long ULONG;
typedef void *HANDLE;
typedef struct { WCHAR *Buffer; } UNICODE_STRING;
typedef struct { int kind; } SECTION_IMAGE_INFORMATION;
typedef struct { int unused; } WINE_MODREF;
struct file_id { int unused; };
#define FALSE 0
#define TRUE 1
#define STATUS_SUCCESS 0
#define STATUS_DLL_NOT_FOUND 1
#define STATUS_NO_MEMORY 2
#define STATUS_NOT_SUPPORTED 3
static const WCHAR system_dir[] = L"C:\\windows\\system32";
static const WCHAR default_load_path[] = L"C:\\app;C:\\windows\\system32";
static int missing_system, wrong_system, fail_alloc, local_opens, system_opens;
static void *GetProcessHeap(void) { return NULL; }
static void *RtlAllocateHeap(void *heap, int flags, size_t size)
{ (void)heap; (void)flags; return fail_alloc ? NULL : malloc(size); }
static void RtlFreeHeap(void *heap, int flags, void *ptr)
{ (void)heap; (void)flags; free(ptr); }
static void RtlFreeUnicodeString(UNICODE_STRING *name)
{ free(name->Buffer); name->Buffer = NULL; }
static NTSTATUS RtlDosPathNameToNtPathName_U_WithStatus(const WCHAR *path,
    UNICODE_STRING *name, void *a, void *b)
{ (void)a; (void)b; name->Buffer = wcsdup(path); assert(name->Buffer); return 0; }
static NTSTATUS open_dll_file(UNICODE_STRING *name, WINE_MODREF **wm,
    HANDLE *mapping, SECTION_IMAGE_INFORMATION *info, struct file_id *id)
{
    (void)wm; (void)mapping; (void)id;
    if (!wcsncmp(name->Buffer, L"C:\\app\\", 7))
    { local_opens++; info->kind = 1; return STATUS_SUCCESS; }
    assert(!wcsncmp(name->Buffer, system_dir, wcslen(system_dir)));
    system_opens++;
    if (missing_system) return STATUS_DLL_NOT_FOUND;
    if (wrong_system) return STATUS_NOT_SUPPORTED;
    info->kind = 2;
    return STATUS_SUCCESS;
}
'''
code += function("static NTSTATUS search_dll_file(")
code += r'''
static int selected_crt;
/* Model the root emulator's CRT import and its transitive system dependency.
 * The source assertions above cover propagation through the real loader. */
static NTSTATUS load_dll(const WCHAR *path, const WCHAR *module, int flags,
    WINE_MODREF **wm, BOOL system)
{
    UNICODE_STRING name = {0};
    SECTION_IMAGE_INFORMATION info = {0};
    struct file_id id;
    HANDLE mapping = NULL;
    NTSTATUS status;
    (void)flags; (void)system;
    assert(!wcscmp(module, L"C:\\windows\\system32\\xtajit64.dll"));
    status = search_dll_file(path, L"ucrtbase.dll", &name, wm, &mapping, &info, &id);
    if (status) return status;
    selected_crt = info.kind;
    RtlFreeUnicodeString(&name);
    status = search_dll_file(path, L"kernelbase.dll", &name, wm, &mapping, &info, &id);
    if (!status) RtlFreeUnicodeString(&name);
    return status;
}
static NTSTATUS bootstrap_load(void)
{
    const WCHAR *module = L"C:\\windows\\system32\\xtajit64.dll";
    WINE_MODREF *wm = NULL;
    return BOOTSTRAP_CALL;
}
int main(void)
{
    WINE_MODREF *wm = NULL;
    assert(bootstrap_load() == STATUS_SUCCESS);
    assert(selected_crt == 2 && local_opens == 0 && system_opens == 2);

    /* A missing native CRT cannot fall back to app x64 code before FEX starts. */
    missing_system = 1;
    assert(bootstrap_load() == STATUS_DLL_NOT_FOUND);
    assert(local_opens == 0);
    missing_system = 0;

    /* A mixed-mode system32 leaves the existing sysx64 fallback in charge. */
    wrong_system = 1;
    assert(bootstrap_load() == STATUS_NOT_SUPPORTED);
    assert(local_opens == 0);
    wrong_system = 0;
    fail_alloc = 1;
    assert(bootstrap_load() == STATUS_NO_MEMORY);
    fail_alloc = 0;

    /* No global search-path override: ordinary loads retain app precedence. */
    assert(load_dll(NULL, L"C:\\windows\\system32\\xtajit64.dll", 0, &wm, FALSE) == 0);
    assert(selected_crt == 1 && local_opens == 2);
    puts("PASS: emulator bootstrap excludes app-local CRT; ordinary search unchanged");
}
'''.replace("BOOTSTRAP_CALL", call)

with tempfile.TemporaryDirectory(prefix="madeira-bootstrap-") as tmp:
    test = Path(tmp) / "test.c"
    exe = Path(tmp) / "test"
    test.write_text(code)
    subprocess.run([os.environ.get("CC", "clang"), "-std=c11", "-Wall", "-Wextra",
                    "-Werror", "-fsanitize=address,undefined", str(test), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True,
                   env={**os.environ, "ASAN_OPTIONS": "detect_leaks=0"})
