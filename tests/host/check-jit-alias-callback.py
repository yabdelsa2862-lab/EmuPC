#!/usr/bin/env python3
"""Exercise the production PE alias callback, including full-table reentrancy."""
from pathlib import Path
import os
import re
import resource
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "FEX/Source/Windows/ARM64EC/IosJitAlias.cpp").read_text()
native = (root / "build/ntdll-unix/virtual_ios.c").read_text()
capacity = int(re.search(r"#define IOS_JIT_MAX_MAPPINGS (\d+)", native)[1])
layout = source[source.index("struct IosAliasEntry {"):source.index('// extern "C" storage')]
callback = source[source.index("void BTCpu64IosAddAliasMapping("):source.index('}  // extern "C"', source.index("void BTCpu64IosAddAliasMapping("))]

code = r'''
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdio>
LAYOUT
static_assert(sizeof(IosAliasEntry) == 32);
static_assert(offsetof(IosAliasEntry, PeBase) == 0);
static_assert(offsetof(IosAliasEntry, JitBase) == 8);
static_assert(offsetof(IosAliasEntry, Size) == 16);
static_assert(kMaxEntries >= NATIVE_CAPACITY);
static IosAliasEntry g_Entries[kMaxEntries];
static volatile int g_EntryCount;
static constexpr uint64_t kIosSubfloorFloor = 0x100000000ULL;
static unsigned subfloor_calls;
static bool IosSubfloorAdd(uint64_t, uint64_t, uint64_t) {
  ++subfloor_calls;
  return true;
}
// Model PE logging's nested Unix dispatch: it replaces the outstanding frame.
static uint64_t pending_pc = 0xabcdef, pending_sp = 0x123456;
namespace LogMan::Msg {
template<typename... Args> void EFmt(const char*, Args...) {
  pending_pc = 0;
  pending_sp = 0;
}
}
CALLBACK
int main() {
  constexpr uint64_t pe = 0x7100000000ULL, jit = 0x140000000ULL;
  constexpr uint64_t stride = 0x20000, size = 0x10000;
  BTCpu64IosAddAliasMapping(0x20000000, pe, size);
  assert(subfloor_calls == 1 && g_EntryCount == 0);
  for (int i = 0; i < kMaxEntries; ++i) {
    BTCpu64IosAddAliasMapping(pe + i * stride, jit + i * stride, size);
    assert(g_EntryCount == i + 1);
    assert(IosJitTranslate(pe + i * stride + 0x113) == jit + i * stride + 0x113);
    assert(IosJitReverseTranslate(jit + i * stride + 0x113) == pe + i * stride + 0x113);
  }
  assert(IosJitTranslate(pe + size) == pe + size);
  assert(IosJitReverseTranslate(jit + size) == jit + size);
  // Even after filling the table, duplicates and overlap replacement still work.
  BTCpu64IosAddAliasMapping(pe, jit, size);
  assert(g_EntryCount == kMaxEntries);
  constexpr uint64_t replacement = 0x240000000ULL;
  BTCpu64IosAddAliasMapping(pe + 0x8000, replacement, size);
  assert(g_EntryCount == kMaxEntries);
  assert(IosJitTranslate(pe) == pe);
  assert(IosJitTranslate(pe + 0x8010) == replacement + 0x10);
  assert(IosJitReverseTranslate(jit) == jit);
  // Overflow must leave existing mappings AND the pending syscall frame intact.
  const uint64_t extra = pe + kMaxEntries * stride;
  for (int i = 0; i < 10; ++i) {
    BTCpu64IosAddAliasMapping(extra, replacement + stride, size);
    assert(pending_pc == 0xabcdef && pending_sp == 0x123456);
    assert(g_EntryCount == kMaxEntries);
    assert(IosJitTranslate(extra) == extra);
    assert(IosJitTranslate(pe + stride + 0x10) == jit + stride + 0x10);
  }
  puts("JIT alias callback: PASS");
}
'''.replace("LAYOUT", layout).replace("NATIVE_CAPACITY", str(capacity)).replace("CALLBACK", callback)

# A negative control must compile and then detect the unsafe logging path.
unsafe = code.replace("if (count >= kMaxEntries) {", 'if (count >= kMaxEntries) { LogMan::Msg::EFmt("full");', 1)
assert unsafe != code
with tempfile.TemporaryDirectory(prefix="madeira-alias-test-") as directory:
    path = Path(directory)
    for name, text in (("safe", code), ("unsafe", unsafe)):
        cpp = path / f"{name}.cpp"
        exe = path / name
        cpp.write_text(text)
        subprocess.run([os.environ.get("CXX", "clang++"), "-std=c++17", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=address,undefined", "-fno-omit-frame-pointer", str(cpp), "-o", str(exe)], check=True)
        result = subprocess.run([str(exe)], capture_output=True, text=True,
                                preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE, (0, 0)))
        if name == "safe":
            assert result.returncode == 0, result.stdout + result.stderr
            print(result.stdout.strip())
        else:
            assert result.returncode != 0 and "pending_pc" in result.stderr, result.stdout + result.stderr
            print("Unsafe PE logging negative control: detected syscall-frame corruption")
