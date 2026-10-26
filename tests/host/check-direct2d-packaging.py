#!/usr/bin/env python3
"""Check Direct2D's packaged PE imports, not on-device rendering or launch.

Accepts an optional DLL-farm path to also check the built app's resources.
Uses the same llvm-mingw toolchain as build/wine-pe/build-modules.sh.
"""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
READOBJ = ROOT / "toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/llvm-readobj"
FARM = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "app/Madeira/arm64ec-windows"
MODULES = ("d2d1.dll", "d3d10_1.dll")


def inspect(path, *options):
    assert path.is_file(), f"Missing packaged DLL: {path}"
    return subprocess.check_output([str(READOBJ), *options, str(path)], text=True)


def check(farm):
    files = {p.name.lower(): p for p in farm.iterdir() if p.is_file()}
    exports = {}
    checked = 0
    for module in MODULES:
        text = inspect(farm / module, "--file-headers", "--coff-imports", "--coff-exports")
        assert "Machine: IMAGE_FILE_MACHINE_ARM64EC" in text, f"{module}: wrong architecture"
        required_export = "D2D1CreateFactory" if module == "d2d1.dll" else "D3D10CreateDevice1"
        assert re.search(rf"^  Name: {required_export}$", text, re.M), f"{module}: missing factory"
        blocks = re.findall(r"^(?:Delay)?Import \{\n(.*?)^\}", text, re.M | re.S)
        assert blocks, f"{module}: no imports inspected"
        dependencies = set()
        for block in blocks:
            dependency = re.search(r"^  Name: (.+)$", block, re.M).group(1).lower()
            dependencies.add(dependency)
            assert dependency in files, f"{module}: missing dependency {dependency}"
            if dependency not in exports:
                data = inspect(files[dependency], "--coff-exports")
                exports[dependency] = set(re.findall(r"^  Name: (.+)$", data, re.M))
            symbols = re.findall(r"^\s+Symbol: (.*?) \(\d+\)$", block, re.M)
            assert symbols, f"{module}: no named imports inspected for {dependency}"
            for symbol in symbols:
                assert symbol in exports[dependency], f"{module}: {dependency} lacks {symbol}"
                checked += 1
        if module == "d2d1.dll":
            assert {"d3d10_1.dll", "dwrite.dll", "xmllite.dll", "ole32.dll"} <= dependencies
        else:
            assert {"d3d10core.dll", "dxgi.dll"} <= dependencies
    return checked


if __name__ == "__main__":
    try:
        count = check(FARM)
    except (AssertionError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"FAIL: {error}")
    print(f"PASS: Direct2D/D3D10.1 packaged; {count} immediate/delay imports exported by bundled DLLs")
