# Madeira Dock: development history

This is the README as it stood until 2026-10-02, kept unchanged as a record of how the host was
built and tested, round by round ("mlNNNN" are Madeira build rounds). It is not a description of
the current state: for that, read `../README.md`. Later rounds are in `HANDOFF.md`.

---

# Madeira Dock

Madeira Dock is a headless host for Valve's genuine Steam client, used by the
Madeira app to launch a user's own purchased games with real Steam
authentication, entitlement checks and the games' original DRM.

**Licence:** GPL-3.0-or-later with the Madeira Converter Exception;
Copyright 2026 125hz. See `LICENSE`, `COPYING` and `LICENSE-EXCEPTION.md`.

Host ml1870, with authenticated device launch confirmed in the ml1880 notes.
This executable loads the user's
installed, unmodified Valve client. It does not replace Steam APIs or remove
game protection. No Valve binaries are included in this source directory.

## Device confirmation — ml1880 public performance trial

Logs 62/63 from public Madeira ml1870 report authenticated online status and
requested-app subscription membership. The owner confirms the installed
32-bit game runs on iOS through Dock, with roughly 2.9 GB total app memory.
This supersedes earlier unproven-device notes below. It does not prove
clean-prefix setup, all games, revocation handling or all multiplayer APIs.
The Dock host executable is unchanged. Public ml1880 tests a smaller
512 MiB Dock JIT pool (desktop recovery preserved) and avoids guest D3D9
per-call census work during normal gameplay. Gains need device A/B testing.
Read the sibling docs/MADEIRA_DOCK.md for rollback and test instructions.
Original Valve libraries, real authentication, subscription checks and
original game DRM remain mandatory.

## Current operation

The original five-second bootstrap remains available. The opt-in session mode
can now select the existing cached Steam account, ask Valve to authenticate it,
read subscriptions through the authenticated client and submit an installed
game to Valve's own `IClientAppManager::LaunchApp`. It pumps callbacks while
the game runs and restores the process-discovery registry values afterward.

The owner confirmed successful startup for three installed games: one 32-bit
game on C:, one 64-bit Steamworks game on C:, and another on D:. Desktop
`steam.exe` and `steamwebhelper.exe` remained absent. An initially reported
menu crash did not reproduce; the owner confirmed the retry worked and said
they likely closed the first attempt accidentally. This is startup/smoke
validation, not extended gameplay coverage. A host exit of zero records host
lifecycle success. Wine/iOS and live native-token authentication are now confirmed for the
limited device trial described above. The handoff parser and Windows file consumption are tested
with synthetic credentials; those tests do not claim successful authentication.

## Licence, contributions and distribution

Madeira Dock is free software: GPL-3.0-or-later with the Madeira Converter
Exception, Copyright 2026 125hz (`LICENSE`, `COPYING`,
`LICENSE-EXCEPTION.md`). The owner open-sourced the previously private
implementation on 2026-09-27. Contributions are accepted under the same terms;
every source, test and tool file carries the SPDX header. Third-party
references and runtime notices are in `THIRD-PARTY-NOTICES.md` and `notices/`.

Madeira bundles the stripped x64 executable with `dock-notices.txt` (licence
statement, exception, GPL text and LLVM/MinGW runtime notices); this
repository is its corresponding source.

Never commit secrets or personal data: tokens, passwords, Steam login caches
(`loginusers.vdf`, `config.vdf`, `ssfn*`), account names, real SteamIDs,
personal paths or email addresses, test logs, client configuration, Valve
binaries, games, debug symbols or `.build/` output.
`python3 tools/check-privacy.py` scans for these (see Build and checks).

## Native sign-in handoff (ml1830)

The app's QR/password sign-in obtains its user's refresh token from Steam and
stores it in Keychain. The app pauses downloads, disables native reconnection,
awaits Steam logoff/socket close, then writes a one-use transfer in protected
Application Support storage. Only that path enters the guest environment.
The native app's JWT-subject parsing selects an account; it is not trusted as
proof of identity or ownership. The real client must accept the token online.

`MADEIRA_DOCK_AUTH_FILE` selects this route. Missing, locked, malformed or
mismatched handoffs fail; they never fall back to cached PC credentials.
The file is opened exclusively with delete-on-close before any login call.
The host clears its temporary buffers and submits the token to the exact
client's verified SetLoginToken method. Valve's LogOn, authenticated state,
subscription list and original game launch/DRM checks still gate execution.
Valve may maintain its own login cache inside the user's Wine prefix.

Wire version `MDOCK001`: 8 magic bytes; little-endian u64 SteamID, u32 AppID,
u16 account length, u16 token length; account bytes then token bytes, no NULs
or trailing data. Account length 1–64, token length 1–8192. No password or
ownership assertions are present. A transfer is scoped to one requested AppID.

The iOS trial is off until `MADEIRA_DOCK=1` is set in madeira-env.txt. It still
uses Valve's official installer to prepare client files, requires the pinned
client version, and supports the default launch option without custom args.
One native sign-in is intended to replace the desktop sign-in. Removing the
installer and clean-prefix support remain future work; the existing-prefix
authenticated device launch is confirmed above. `MADEIRA_DOCK=0` restores the existing desktop launch route.

**Private ABI support is limited to one independently inspected client build:**

- x64 SHA-256: `caba4826aa3501039d095aee1843a6bfb270fb43a3ab4455b2d6733223579fee`
- File version: 10.96.30.42; PE timestamp: 1788399258.
- The installed DLL's Authenticode signature was verified as Valve Corp.
- The host checks the SHA-256 and the selected method RVAs before private calls.
- Client updates require a new verified adapter. Unsupported files fail closed.

This is an internal experiment, not a supported Valve embedding SDK. Do not
ship the pinned Windows adapter as a universal solution to private ABI drift.

## Native Windows test

Exit desktop Steam normally first. The owner's earlier native Windows results
below came from a developer-only harness that selected the PC's cached Steam
account. **Cached-login testing is not part of the public tools**: that
harness was removed when the source was opened, and no script in this
repository reads a PC's Steam login cache. The host's cached-login mode is
still reachable by setting the gates below plus `MADEIRA_STEAM_HOST_ACCOUNT`,
`MADEIRA_STEAM_HOST_STEAMID` and `MADEIRA_STEAM_HOST_APPID` in the process
environment yourself; never commit those values. The public test is
`tools/test-invalid-handoff.ps1` (synthetic, fails before login).

For a launch, `MADEIRA_STEAM_HOST_EXPECTED_INSTALL` names the game's
installation directory (from the chosen library's `steamapps` manifest); the
host requires the real client's resolved installation directory to match it
exactly. This avoids accidentally testing a second/old installation. There are no game-specific paths or fixes
in the host. The host does not read credential tokens, print account
identifiers, modify game executables or call APIs that invalidate cached
credentials.

The host uses the standard installed Steam service and supporting client files.
Its memory figure therefore does not include all system-wide Steam components.
During one authenticated game session, a 5.17-second sample measured 99.93 MiB
host private memory and 0.0469 seconds of host CPU time. These are native Windows
measurements, not predictions of Wine/FEX memory use or device frame rate.
Close the game normally to end the session. Desktop Steam remains closed.
The report is `.build/logs/session.txt`; copy it before the next test.

Current EXE: `.build/windows/dockhost-x86_64.exe`.
Double-clicking does nothing useful because the master opt-in defaults off.
The 32-bit EXE supports the bootstrap only; session/launch requires the x64 host.

## Gates and observations

- `MADEIRA_STEAM_HOST_PROBE=1`: master opt-in.
- `MADEIRA_STEAM_HOST_BOOTSTRAP=1`: original five-second export/bootstrap test.
- `MADEIRA_STEAM_HOST_SESSION=1`: version-gated private interface test.
- `MADEIRA_STEAM_HOST_LOGIN=1`: genuine cached authentication.
- `MADEIRA_STEAM_HOST_LAUNCH=1`: launch only after authentication and entitlement.
- Account, App ID, expected installation (`MADEIRA_STEAM_HOST_EXPECTED_INSTALL`)
  and report path (`MADEIRA_STEAM_HOST_LOG`) come from the launcher's environment
  (Madeira's adapter on device; set manually for a PC test).
- No fallback launches a game after failed authentication or entitlement.
- `dockhost.exe --start-services` (ml2014): no Steam client is loaded. Makes
  Wine's service manager reachable for Madeira's one-time-install batch
  (starts `services.exe` only when none answers, same bounded start as the
  CEG path; a manager that answers counts as started even if its started
  event never arrives), leaves it running for the session, prints one stdout line
  `services started|already|failed|off` and exits 0.
  `MADEIRA_DOCK_INSTALL_SCM=0` makes it a no-op (`services off`).

Authentication requires `Steam_BLoggedOn`, `IClientUser::BLoggedOn` and
`BConnected`. The requested App ID must also appear in the client-provided
subscription list and pass its subscription query. The standalone private
`BIsSubscribedApp` query returned true for invalid IDs in this host context;
its semantics remain unresolved and it is deliberately not sufficient to
authorize launch. An absent App ID was rejected by the list gate. That test
does not substitute for a future real-game test using a non-entitled account.
The game's original DRM and Valve's own launch checks remain in place.

`LaunchApp` returns an asynchronous result. This exact DLL emits callback
1270027 with **524** bytes, not the 528 bytes suggested by padded reference
structs. The first trial started a child but rejected the result length;
the corrected trial retained the host until game exit. Result validation now
has a regression test, and a rejected result no longer immediately abandons a
game that is already running.

The host temporarily publishes its real PID and authenticated account ID in
Steam's discovery keys. Normal exit restores the original values. Abrupt host
termination is not yet crash-recoverable. Do not run a second Steam session
concurrently. The native control handler allows cleanup on Ctrl+C/Ctrl+Break,
but terminating the host while playing necessarily removes its client service.

Known native diagnostics include failed overlay/injection-helper setup and
socket binding warnings. No patch disables those checks. The helper warning
did not prevent the first 32-bit game from reaching a visible window. Overlay,
cloud, achievements, multiplayer, CEG (ml1990 requests it; ml2000 starts Wine's service manager for it; see HANDOFF), connection-loss recovery,
refunded/revoked licences and full gameplay remain separate validation work.

## Build and checks

```powershell
wsl -e bash tools/check.sh
wsl -e bash tools/build.sh
```

The native ASan/UBSan tests cover bootstrap cleanup, malformed callbacks,
callback fairness/time bounds, subscription-list bounds and exact launch-result
decoding. They do not emulate a successful Steam server response.

`tools/build.sh --stage` copies the stripped x64 EXE into Madeira's resource
directory and writes `dock-notices.txt` there: the GPL-3.0-or-later statement,
the Madeira Converter Exception, the GPL-3.0 text and the LLVM/MinGW-w64
runtime notices. The app routes games to Dock only with its explicit trial
switch enabled.

```sh
python3 tools/check-privacy.py              # tracked files
python3 tools/check-privacy.py --history    # all reachable blobs and commit messages
python3 tools/check-privacy.py --self-test  # rule fixtures
```

The secret/personal-data scan fails on personal user paths, email addresses,
JWT-like tokens, private keys and common API tokens, real-looking SteamIDs
other than the synthetic test IDs, and Steam login-cache files/content.
Madeira's `.githooks/pre-commit` and `pre-push` apply the same rules to added
lines.

## References and provenance

The C implementation is independent; no reference library was vendored.
Signatures and architecture were checked against
[OpenSteamworks](https://github.com/OpenSteamClient/OpenSteamworks/tree/d0abbe85f4b8314607836e1c588bb48813f642a4),
and selected methods were confirmed by RTTI/IPC strings and call signatures in
the exact installed DLL. The reference generated headers are not treated as
current binary layouts. Public shutdown slot 23 was checked against
[Valve's SteamClient021 header](https://github.com/ValveSoftware/Proton/blob/proton_10.0/lsteamclient/steamworks_sdk_162/isteamclient.h).

[Valve's API overview](https://partner.steamgames.com/doc/sdk/api) and
[DRM documentation](https://partner.steamgames.com/doc/features/drm) describe the
game-facing client requirements. GameNative's closed-source steamhost binaries
were not reused; see its
[third-party notices](https://github.com/utkarshdalal/GameNative/blob/master/THIRD_PARTY_NOTICES).

## Device integration update — ml1870

Log 61 passes the January adapter on-device, then rejects the native credential
transfer before Steam login. Madeira fixes its assumption that Z: exists by
using Wine's Unix namespace for the same protected Application Support file.
Dock adds numeric operation/error diagnostics; see docs/HANDOFF.md for codes.
MADEIRA_DOCK_HANDOFF_DIAGNOSTICS=0 disables these extra logs. No paths, account
identifiers or token data are logged. Consumption, cleanup and real Valve
authentication/ownership checks are unchanged. Device login remains unproven.

## Previous device integration update — ml1860

Log 60 confirms client loading works after ml1850. Its normal return 30 was
the exact-client gate: the device has the official January DLL rather than the
previous PC build. Dock now selects one of two exact, independently inspected
layouts. See [CLIENT_LAYOUTS.md](docs/CLIENT_LAYOUTS.md) for provenance, ABI
checks and limits. MADEIRA_DOCK_CLIENT_202601=0 disables the January adapter.
The compatibility probe passes with login disabled; device token authentication
and game launch remain unproven. Original authentication/ownership gates remain.
Public Madeira ml1860 fixes normal-exit notification and safely includes bounded
report fields in its exported log. Source stays here; only the stripped EXE
and notices are staged into Madeira. No cached login or Valve DLL is bundled.

## Previous device integration update — ml1850

Log 59 from Madeira ml1840 confirms the x64 Dock EXE ran on Wine/FEX/iOS,
then crashed during LoadLibraryExW before authentication. The public runtime
kept a dead bcrypt executable mapping when coml2 reused its PE base and size.
Madeira ml1850 retires image translations on unmap, adds independent host-exit
reporting and repairs startup log controls. See sibling Madeira HANDOFF.md
for precise evidence/tests. Dock implementation and binary are unchanged;
live native-token authentication and device game launch remain unproven.
Use Documents/madeira.cfg: env.MADEIRA_DOCK = 1. Legacy env-file instructions
are superseded by canonical config (legacy files are now safely imported).
