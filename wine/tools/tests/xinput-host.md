# Host XInput regression test

This standalone test includes the real XInput implementation and supplies a
synthetic host-query import. It runs on Windows without Wine, an iOS device or
a physical controller. It does not install or replace any DLL.

From this repository, with llvm-mingw on PATH and Wine's generated headers in
`build/include` (adjust that path for your configured build):

```sh
x86_64-w64-mingw32-clang -O2 -D__WINESRC__ -Iinclude -Ibuild/include \
  tools/tests/xinput-host.c -lhid -lsetupapi -ladvapi32 -luser32 \
  -o xinput-host-test.exe
```

Run `xinput-host-test.exe` on Windows. The test checks state/capability mapping,
Guide-button filtering, keystroke edges, XInputEnable (and a disable taken as
stale while the caller owns the foreground window, ml2115), vibration forwarding
(including XInputEnable and process detach), invalid arguments,
unknown and published (NtUserGamepadOp_Battery) battery reporting, and per-user audio/disconnect results. It does not
exercise the HID fallback or prove device compatibility.

The iOS `ios_gamepad_query` implementation is supplied by Madeira. The paired
Madeira change must be built together with this Wine change, including the
win32u and XInput PE DLLs; updating only the app does not update those DLLs.

## Host pads in Windows.Gaming.Input

`wgi-host-pads.c` does the same for `dlls/windows.gaming.input/provider.c`
(Madeira ml2171): each connected host slot is listed as a Gamepad provider,
read in the XUSB layout `gamepad.c` expects, and its rumble/buzz reach the
slot's motors. Build it like the XInput test (x86_64 only; the generated
`provider.h`/`async_private.h` are in the configured build's
`dlls/windows.gaming.input`):

```sh
x86_64-w64-mingw32-clang -O2 -D__WINESRC__ -Iinclude -Ibuild/include \
  -Ibuild/dlls/windows.gaming.input -Idlls/windows.gaming.input \
  tools/tests/wgi-host-pads.c -ldinput8 -lhid -lruntimeobject \
  -o wgi-host-pads-test.exe
```

Run `wgi-host-pads-test.exe`, then `MADEIRA_XINPUT_WGI=0` with the argument
`off` (the kill switch lists no host pads).
