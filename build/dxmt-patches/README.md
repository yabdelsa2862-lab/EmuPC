# Madeira's DXMT patches

Changes to DXMT (the `dxmt` submodule) that live in this repository until
they are in DXMT's own repository. `apply.sh` applies them, in file-name
order, to the `dxmt` working tree before `build/dxmt-ios/build.sh` (the
native Direct3D 9 frontend in `libdxmt_combined.a`),
`build/wine-i386/build.sh` (the 32-bit DLLs) and
`build/windows-runtime/build.sh` (the 64-bit DLLs) build DXMT; it skips a
patch that is already applied, and `apply.sh --revert` takes them out. The
`dxmt` submodule pin does not change.

| Patch | What it fixes |
|---|---|
| `0001-d3d9-index-range-per-draw.patch` | A 32-bit Direct3D 9 indexed draw copies only the index bytes it reads, instead of the whole index buffer before every draw after a lock (Call of Duty: Black Ops drew at 2 to 20 FPS). `env.MADEIRA_D3D9_INDEX_RANGE = 0` goes back to the whole copy. Checked by `tests/host/check-d3d9-index-range.py` |
| `0002-d3d11-mip-clamp-auto-bias.patch` | `d3d11.mipClampAutoBias=N` (1-4, default 1) sets how many top mip levels the automatic clamp (`d3d11.mipClampAuto`) drops. On GPUs that can't sample BC, one level only gets an expanded texture back to its BC size; two levels is 1/16. A failed memory reading after a valid one now counts as no headroom instead of turning the clamp off mid-load. EmuPC issue #2 (6 GB iPad). |
| `0003-d3d11-mip-clamp-auto-small-textures.patch` | Applies on top of 0002. `d3d11.mipClampAutoMinDim=N` (64-4096, default 1024) lowers the size a texture needs before the automatic clamp considers it; textures below 1024 drop one level fewer than large ones (at least one). Under pressure, the log counts the BC textures that could not be shrunk (too small, or a single mip level). EmuPC turns on 512 on 4 GB-limit devices. EmuPC issue #2: ~1400 smaller BC3 textures still held ~1.2 GB. The shipped 64-bit `d3d11.dll` is dxmt `82a2913` plus 0002, 0003, 0004 and 0005 |
| `0004-d3d11-mip-clamp-early-stage.patch` | Applies on top of 0003. `d3d11.mipClampEarlyMinDim=N` (256-16384, default 0 = off): before any memory pressure, BC textures with a side of N or more drop one mip level from the start. EmuPC turns on 1024 on devices with an 8 GB or smaller memory limit. Euro Truck Simulator 2 on an iPhone 16 Pro Max loaded ~1.2 GB of textures at full size in its first minute, before the pressure clamp began, and was killed after 11 minutes |
| `0005-d3d11-half-size-single-level-bc.patch` | Applies on top of 0004. `d3d11.mipClampAutoHalfOneLevel=N` (16-8192, default 0 = off): under memory pressure, a single-level BC texture with a side of N or more that is created with its data is decoded at half width and height into a half-size texture (a quarter of the memory); the D3D description stays full size. Later updates and copies into or out of such a texture are dropped and logged (`[mip-clamp] half one-level`). Only on GPUs without BC support. EmuPC issue #2: Plants vs. Zombies Fusion has ~1300 single-level BC3 sprites (~1.3 GB as RGBA8) that the mip clamp cannot shrink |

A patch must apply on the current `dxmt` pin. When the pin moves, rebase the
patches onto it (or drop a patch the new pin already covers).
