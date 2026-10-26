# Madeira Dock — implementation handoff, ml2000 (2026-09-25)

## Required-content readiness bound (2026-10-13, local)

Content errors 17/19/20 no longer leave a launch waiting for six hours. A
three-minute deadline is enforced by the polling loop, even if the pending
retry never returns a callback. A running game or an accepted launch is not
aborted by this deadline, and a later non-content refusal retains its own error
classification. Result 48 means required content stayed unavailable, not that a
download was observed; `launch-update-gave-up` records only the retry count.
New callbacks clear a queued retry before deciding whether another is needed.
Valve still authorizes every launch; the host installs nothing and bypasses no
license or executable-preparation checks.

The companion downloader now stages verified shared depots in their owner's
actual install folder and writes the owner's record before marking the consumer
complete. Existing installs need Madeira's Repair to apply that filesystem fix.
The UI reports readiness rather than claiming installation progress and gives
that recovery step. Rebuild both Dock and the app. Phone launch validation is
still outstanding; host tests do not establish third-party launcher compatibility.

## Original launch entry keys (2026-10-05)

LaunchApp uses the validated `MADEIRA_STEAM_HOST_LAUNCH_OPTION` for its initial
request and all retries. It carries the original `config.launch` key, not a
filtered array offset. An absent variable keeps 0 for older launchers; invalid
input fails closed with result 45. A bounded, decoded error-22 detail explicitly
identifying a missing requested entry stops the configuration wait. Reports
contain only numeric launch-option fields; the detail itself is never logged.

Madeira resolves its installed Windows/default entry before native logoff,
excludes DLC-only entries and refetches legacy caches without original keys.
Both app and host must be rebuilt. Authentication, ownership and original game
DRM remain unchanged.

The same C source passed all four ASan/UBSan suites on Linux and macOS, and x64
and i386 builds with warnings as errors. The app's Swift ASan regressions also
passed. A Debug IPA containing this host and the companion Madeira changes was
installed on an M2 iPad with iPadOS 27; the tester confirms that the previously
failing game starts. This establishes startup, not extended gameplay coverage.

## A manager that answers counts as started (2026-09-29)

Device logs of Madeira's one-time-install batch on the upstream tree
(test-all-3/4): `dockhost.exe --start-services` started `services.exe`, the
manager came up within about a second (explorer's COM start connected to it
and it started rpcss), but `__wine_SvcctlStartedEvent`, which this host
created, was never set or opened by anyone (the wineserver's event history:
one create, zero sets), although services.exe had reached the line after its
SetEvent (its process-monitor thread existed). `start_manager` waited the whole
30 s for that event, main.c's 20 s bound fired first, and the batch recorded
`services timeout` with a working manager behind it. Why the event does not
reach this waiter on iOS is not known yet.

`start_manager` now waits in slices of at most `SH_SCM_POLL_MS` (250 ms,
`sh_scm_poll_slice_ms` in validation.c) and calls OpenSCManagerW between them:
an answer returns at once, 1722/1723 keep waiting, another error fails as
before; the event, the process's exit and the 30 s bound end the wait as
before. The CEG path shares `start_manager`, so it no longer waits out the
event either. Windows (manager already running) never reaches this code.
Validation: `tools/check.sh` (3 new assertions), both architectures build with
`-Werror`, privacy scan clean. Not yet run on a device.

## ml2014 — `--start-services` for the one-time-install batch (2026-09-27)

Device log 103: Madeira's install batch (`cmd.exe /c call
madeira-dock-installers.cmd & dockhost.exe`) runs before this host, so no
service manager exists while a game's installers run (`\pipe\svcctl`
c0000034 in the log). New CLI mode `dockhost.exe --start-services` (checked
before the probe opt-in; no Steam client loaded, no report file): the first
OpenSCManagerW; only on RPC_S_SERVER_UNAVAILABLE (1722) `start_manager`
(unchanged ml2000 bounded start, event `install-scm-started`). A manager this
call started stays running (Wine system process, ends with the session); the
later host run finds it already running and so never owns or stops it. If it
never answered, the half-started one is terminated. Output: stderr
`[steam-host] ml2014 install-scm=<2 started|1 already|0 off|-1 failed>`
(+ `install-scm-error=<Win32>` on failure) and one stdout line
`services <word>` for the batch's result file; exit 0 always.
`MADEIRA_DOCK_INSTALL_SCM=0`: no-op (`services off`). Pure decisions in
validation.c (`sh_install_scm_should_spawn/outcome/word`), 15 new assertions.
Windows smoke test (native SCM): `services already`, kill switch `services off`,
both architectures; no-argument run unchanged (exit 2 without the opt-in).

Evidence limit: in log 103 every svcctl open comes from pid 0x20
(`explorer.exe /desktop`, the session's first process), not from the
installer's thread. The installer's own failure chain is a missing
`Microsoft.NET\Framework\v2.0.50727\fusion.dll` (LoadLibraryShim E_HANDLE in
its managed-runtime plug-in step) → -9. A service manager alone is not
expected to change that exit; Madeira records such a provided runtime's
failure as done instead of retrying (app side, ml2014).

## Open-sourcing — 2026-09-27

The owner (125hz, sole author) open-sourced Madeira Dock under
GPL-3.0-or-later with the Madeira Converter Exception. The ml1990/ml2000 work
was committed as it stood, then relicensed: SPDX headers on every
source/test/tool file, `COPYING` and `LICENSE-EXCEPTION.md` copied from
Madeira, a `LICENSE` statement, `dock-notices.txt` now carrying the GPL,
exception and LLVM/MinGW runtime notices, `tools/check-privacy.py`
repurposed as a secret/personal-data scan, the cached-login harness
`tools/test-session.ps1` removed, and a generic compiler default in
`tools/check.sh`. No host behaviour changed. Older sections below that
mention private source or a proprietary licence are historical.

## Current change — service manager for Valve's CEG service

The ml1990 device log: ceg-request=1, ceg-server-result=22 (pending), then
ceg-job-result=55 (RemoteCallFailed), host result 49. Around the job Valve's
client opened `\pipe\svcctl` (c0000034, RPC_S_SERVER_UNAVAILABLE 0x6BA), tried
to load its i386 service DLL in the x64 host (c000007b) and retried svcctl.
Valve's client performs CEG work through its own installed client service,
which it demand-starts through the service manager. Madeira's desktop routes
run Wine's services.exe; the Dock route runs only this host, so no manager.

New `src/scm.c`, called in `launch.c` before the CEG request (only with
`MADEIRA_STEAM_HOST_CEG=1`, CEG not disabled, and `MADEIRA_DOCK_CEG_SCM` not
`0`): OpenSCManagerW(SC_MANAGER_CONNECT). Only on RPC_S_SERVER_UNAVAILABLE
(1722) does it start `<system32>\services.exe` (DETACHED_PROCESS, no handle
inheritance, cwd system32), after creating Wine's `__wine_SvcctlStartedEvent`
(include/wine/svcctl.idl SVCCTL_STARTED_EVENT) exactly as wineboot's
start_services_process does; it waits for the event or process exit, then
polls OpenSCManagerW (1722/1723 retry) — all within 30 s. If that event
already existed, another launcher is starting a manager: never a second one.
It then checks registration read-only: OpenServiceW("Steam Client Service",
SERVICE_QUERY_STATUS). Dock never creates, registers, configures or starts a
service; Valve's client demand-starts its own. Failure: ceg-result -4 (manager
unreachable) or -5 (service not registered), host result 49, no launch.

Lifetime: the manager stays for the whole game run (runtime DRM fix-up may
need the service). At host exit (main.c, after Valve's client shutdown, on
every path including errors), only if this host started services.exe: ask the
SCM to stop Steam Client Service (SERVICE_CONTROL_STOP, re-sent each second
while not stop-pending, 15 s bound). If its process outlives the bound, the
process handle opened while the service ran is terminated (only in this
host-started manager's session). Then TerminateProcess our services.exe.
Otherwise no-op. Abrupt host termination skips this cleanup.

Report lines (round **ml2000**): `ceg-scm=1/0` reachable (already running or
started), `ceg-scm-started=1` when this host spawned services.exe,
`ceg-scm-error=<Win32 error>` (open/spawn failure, 1067 manager exited,
1460 30 s timeout, or a non-1060 OpenServiceW error), `ceg-service-registered=0/1`,
at exit `ceg-service-stop=<code>` (0 not running, 1 stopped via SCM, 2 process
ended after bound, -1 failed/manager already gone) and `ceg-scm-stopped=1/0`.
`ceg-result` keeps round ml1990 with new values -4/-5. Pure decisions
(absent/retryable errors, -4/-5 mapping, bounded remaining time, stop outcome)
are in validation.c with 21 new sanitizer assertions. Rollback:
`MADEIRA_DOCK_CEG_SCM=0` (ml1990 behaviour). Static evidence only: Wine
services.exe startup in a Dock session, Valve's service start through it and
real CEG success need a device log. services.exe also autostarts the prefix's
auto-start services/drivers (as on desktop routes); those processes are not
stopped by Dock (Wine system processes end with the session).

### ml2000 follow-up — Valve's own service installer when unregistered

Device log 91 again shows the x64 client trying `Steam\bin\steamservice.dll`
in process (c000007b, i386), so the out-of-process service is the only route.
If the manager is reachable and OpenServiceW reports exactly
ERROR_SERVICE_DOES_NOT_EXIST (1060), Dock runs Valve's own installer the way
Valve's client does when its service is missing. Static inspection of the
January x64 client: the function after the "BOpenSCMgr failed"/"BOpenService
failed" check (RVA `0x96d390`) calls GetModuleFileNameA(NULL), strips the file
name, formats `"%s\bin\SteamService.exe"`, and runs ShellExecuteExA("open",
that file, "/install", directory = Steam folder, SEE_MASK_NOCLOSEPROCESS),
waiting for it. The install-script launcher (`0x6ea510`) likewise runs
`bin\SteamService.exe` relative to the Steam install folder. Dock's own EXE is
not in the Steam folder, so Dock uses the folder of the loaded genuine client
DLL (GetModuleFileNameW of steamclient64.dll) + `\bin\SteamService.exe`.
Only if that file exists: CreateProcessW with `"<path>" /install`, no handle
inheritance, DETACHED_PROCESS, cwd the Steam folder, 60 s bound (a stuck
installer is terminated: fail closed). Then registration is re-checked
read-only. Valve's binary registers Valve's service; Dock writes no service
registry keys and creates no service. On this PC the resulting registration
is `"C:\Program Files (x86)\Common Files\Steam\steamservice.exe" /RunAsService`
(demand start); Valve's installer copies itself there.

New field (round ml2000): `ceg-service-install=<installer exit code>`, -1
timeout (installer ended), -2 file missing, -3 could not start (with
`ceg-scm-error`). It is followed by a second `ceg-service-registered`
(parsers should use the last value). Still unregistered → ceg-result -5.
Kill switch `MADEIRA_DOCK_CEG_SERVICE_INSTALL=0` keeps the fail-fast -5.
Pure decision/report helpers `sh_should_install_service` and
`sh_service_install_report` have 8 more sanitizer assertions (80 total).
Unproven: the i386 installer under WoW64/FEX on iOS, its exit code there, and
whether it needs elevation-only behaviour Wine does not provide. Staged.

## Previous change — custom executable (CEG) preparation before launch

A device log showed a game whose depot executable is flagged CustomExecutable
exit 0x8000DEAD: Valve's client never prepared the per-user binary. Public
Madeira writes the manifest's CheckGuid block, saves depot manifests to
steamapps/depotcache and sets `MADEIRA_STEAM_HOST_CEG=1` for such apps.
When set, `launch.c` (after the install-folder check, before any registry
change or LaunchApp) calls Valve's IClientUser::RequestCustomBinaries
(slot 71, pinned per build; see CLIENT_LAYOUTS.md), pumps callbacks and
waits up to 5 minutes for one success callback 1020025 per started job.
Busy (10) is re-requested every 10 s inside that bound. Any other result,
zero jobs, a failed job, timeout or method mismatch returns **49** and does
not launch. Valve's client and servers produce the binary with the user's
own licence; Dock never alters or bypasses CEG. Rollback: `MADEIRA_DOCK_CEG=0`.

Report lines (round ml1990): `ceg-request-busy=10` (first busy only),
`ceg-request-result=<EResult>`, `ceg-request=<jobs; -1 unset>`,
`ceg-server-result=<EResult>` (changes only), `ceg-job-result=<EResult>`
(failures and first 8), `ceg-finished-jobs=<n>` on failure, `ceg-disabled=1`,
`ceg-unsupported-client=1`, and final `ceg-result`: 1 success, 0 no job
started, >1 Valve EResult of the failing request/job, -1 timeout,
-2 method mismatch, -3 interrupted. Host result 49 = CEG not prepared.
Decoders/progress are in `validation.c` with sanitizer tests. Static RE
only: callback delivery to the global-user pipe and a real CEG download are
unproven until a device log. Built, not staged (owner stages).

## Previous change — wait for Valve's client to prepare content

Public device log 67 (app 220): authenticated, listed, then Valve's LaunchApp
returned EAppUpdateError 17 (content log: "required app 340 not ready") and the
host ended 5 s later (45). Desktop Steam lets its client install/update such
dependencies and then launches; the client had already queued that update.
`launch.c` now keeps pumping callbacks for results 17/19/20 and re-submits
LaunchApp (10 s, 20 s, then 30 s) until Valve reports success, up to 6 hours
(then result 48). Nothing is launched without Valve's own success; every other
refusal fails closed as before. Report lines only on a changed result; new
fields `launch-update-wait/retry/ready` (round ml1970). Rollback:
`MADEIRA_DOCK_CONTENT_WAIT=0`. Classifier/backoff in `validation.c` with
sanitizer tests. Whether the headless client runs the queued download to
completion on iOS is unproven; the next device log's content-log lines show it.
Staged EXE SHA-256 `44f1b0ccbba229cbb9fce4c7b5067bf8975a15e6da522d2e3e52f5b8f5ac862a`.
Public side (not in this repo): the app runs the game's remaining one-time
installs in the Dock session before this host starts; the host is unchanged by that.

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

## Current change — transfer diagnostics

Device log 61 proves the January session ABI checks pass on Wine/FEX/iOS.
It then rejects the native transfer (37), before token submission. The report
does not yet distinguish open, metadata, size, read, parse or close failure.
Public Madeira ml1870 corrects its Z: assumption: a seeded prefix guarantees
C:, while the protected handoff is in native Application Support. The adapter
now uses Wine's explicit Unix namespace, retaining the same protected file.
MADEIRA_DOCK_UNIX_HANDOFF=0 rolls back that public path change.

auth.c now provides numeric operation/error diagnostics without paths, payloads
or account identifiers. Stages: 1 open, 2 info, 3 file type, 4 size query,
5 bounds, 6 read, 7 envelope parsing, 8 close, 9 oversized environment path.
Errors from failed Win32 calls are captured immediately; validation-only
failures have error 0. MADEIRA_DOCK_HANDOFF_DIAGNOSTICS=0 disables logging;
all operations still fail closed. Tags are [steam-host] ml1870
session-handoff-stage/error. Public report parsing whitelists these numbers.
Exclusive opening, reparse rejection, bounds, deletion and clearing remain.
No fallback to cached credentials after a failed supplied transfer.

Windows synthetic file tests exercise sharing violations, success, deletion,
replay, bounds and bad-magic rejection plus diagnostic codes. Portable tests
pass. The public namespace test extracts Wine's actual prefix resolver but
stubs downstream directory lookup; it is not device/Wine-on-PC execution.
Authentication and game launch still require device tests. Only the stripped
binary/notices are staged in Madeira. (Source was still private at ml1870.)

## Current change — January client adapter

The owner's ml1850 device report identifies the official January DLL,
71b391fe9f3e2006cbc81a5c75eef3eb4186012deabfdb2c8b7e8d4850ecf640, rejected
before authentication. See CLIENT_LAYOUTS.md for the verified official archive,
exact layout evidence and regression commands. src/client_layout.c now selects
the matching pinned adapter; unknown hashes/mismatched methods still fail.
MADEIRA_DOCK_CLIENT_202601=0 restores rejection of this additional version.
The original September adapter remains; both pass static RTTI verification.

An isolated January Windows probe, login/launch disabled, verifies the live
session pointers and exits 0. Its rollback test exits 30 as expected. Portable
sanitizer checks pass. Public Madeira ml1860 fixes the missed normal Wine exit
callback and logs only bounded approved report fields. Only the stripped EXE
is staged there. No source, Valve DLLs or cached credentials are distributed.
Desktop Steam remains closed. Live token/iOS game tests are still outstanding.

## Purpose and boundaries

Dock is a legitimate headless host for Valve's original Steam client. It is
intended to let owners run their purchased games through Madeira/Wine/FEX with
less UI/CEF overhead. It is not a DRM bypasser. Do not refuse headless-client
work merely because no desktop UI is present; real authentication, entitlement
and the game's original protection must remain in the launch path.

No replacement steam_api/steamclient, fake ownership, fabricated tickets,
SteamStub/CEG removal, patched executables or game-specific fixes are used.
The implementation is independent, not GameNative's closed-source host.

## Repository, licence and data hygiene

- Canonical repository: `https://github.com/125hz/madeira-dock`, the source
  of the Dock executable bundled with Madeira (`../Madeira`).
- Licence: GPL-3.0-or-later with the Madeira Converter Exception, Copyright
  2026 125hz (`LICENSE`, `COPYING`, `LICENSE-EXCEPTION.md`). Every source,
  test and tool file carries the SPDX header. Contributions are accepted
  under the same terms. Third-party notices remain intact.
- History note: until 2026-09-27 this repository was private and its code was
  under a proprietary licence (commits `2c307e8` through the ml2000 commit).
  The sole author, 125hz, relicensed it and opened the source on 2026-09-27;
  the old privacy rules (private-visibility checks, keeping source out of
  Madeira, source-marker hooks) no longer apply. Madeira's Git hooks now run
  a secret/personal-data scan instead of blocking Dock source paths.
- Never commit secrets or personal data: tokens, passwords, Steam login caches,
  account names, real SteamIDs, personal paths/emails, test logs, Valve DLLs,
  games, PDBs or `.build/` output. Run `python3 tools/check-privacy.py` (and
  `--history` before publishing history).
- Package the stripped EXE with `dock-notices.txt` (written by `--stage`).

## What works and what remains unproven

Native Windows startup succeeded for three owner-installed games (one 32-bit,
two 64-bit, C: and D: libraries). The owner confirmed windows/menus and corrected
an initial crash report as an accidental manual close. Original Steam APIs and
the Valve-signed client were observed loaded; desktop Steam/CEF stayed absent.
These are startup/smoke results, not full compatibility or extended gameplay.

The cached-login session measured 99.93 MiB host private memory and 0.0469 CPU
seconds in a 5.17-second sample. This excludes game/service processes and is
not an iOS memory/performance prediction.

ml1830 adds the native token handoff and an opt-in iOS adapter/onboarding flow.
Portable sanitizer tests and Windows consume/delete/replay tests use synthetic
credentials. A malformed real-host transfer fails before any login or launch.
The existing cached-login authentication/list check still passes. **Live refresh
token authentication and Wine/FEX/iOS gameplay have not yet been tested.**

## How it works

The host locks and hashes the genuine installed x64 steamclient64.dll, loads
it, constructs its client/engine/user interfaces and pumps callbacks. Private
methods require the pinned DLL hash and individually verified RVAs. Unsupported
client builds fail closed; do not guess ABI layouts or disable gates to fix an
update. The original supported DLL SHA-256 (also see the January addition above):
`caba4826aa3501039d095aee1843a6bfb270fb43a3ab4455b2d6733223579fee`
(file version 10.96.30.42, timestamp 1788399258).

Authentication modes:

1. PC test: select the local installed client's cached account metadata and ask
   Valve's client to authenticate its own cached credentials. No credentials
   are extracted into the code, repository or executable.
2. Native app: Madeira obtains its user's Steam refresh token through native
   QR/password login, keeps it in Keychain, pauses downloads and awaits native
   logoff/socket close. A protected single-use file transfers it to Dock. The
   public file protocol is described in README.md. Only its path is in the
   environment. Dock consumes/removes the file before SetLoginToken/LogOn and
   clears its temporary buffers. It never falls back to cached login after a
   failed supplied handoff. Valve may cache this user's session in their prefix.

The host requires online/authenticated state, the real client's subscription
list membership and its subscription query, then calls Valve's own asynchronous
LaunchApp. The private subscription query alone returned true even for invalid
IDs in this context, so it MUST NOT authorize a launch by itself. An absent-ID
test failed the list gate; a real non-entitled-account negative remains needed.
App ownership displayed by Madeira or decoded from local metadata is not proof.

The client resolves the actual install folder; it must match the requested
library directory. The host publishes its PID/account in Steam's discovery
keys and pumps callbacks while the game runs. It restores previous registry
values and releases handles at normal exit. Abrupt termination is not yet
crash-recoverable. Keep the same exact client/expected-folder gates.

## Build, test and stage

From this repository on a Windows PC with WSL:

```powershell
wsl -e bash tools/check.sh
wsl -e bash tools/build.sh
wsl -e python3 tools/check-privacy.py
wsl -e python3 tools/check-privacy.py --self-test
./tools/test-invalid-handoff.ps1
wsl -e bash tools/build.sh --stage
```

`tools/check.sh` uses `HOST_CC`, else `clang` from PATH, else the default
swiftly location in `$HOME`. Cached-login testing is not part of the public
tools: the former developer-only `tools/test-session.ps1` (which selected the
PC's cached Steam account from its login cache) was removed when the source
was opened. PC session tests set the host's environment gates manually (see
README "Native Windows test"); never commit account values or reports.

The build uses the sibling Madeira LLVM/MinGW toolchain. Override MADEIRA_ROOT,
LLVM_MINGW_BIN or DOCK_OUTPUT when needed. PE outputs are `.build/windows/`;
session reports are `.build/logs/`. Native C tests use ASan/UBSan. Both PE
architectures build, but authenticated session/launch is x64-only. The x64 host
can serve 32-bit games through their original client libraries.

`--stage` copies only the stripped x64 EXE and combined notices into
`../Madeira/app/Madeira/arm64ec-windows/`. Then use Madeira's normal xtool build
after setting `.xtool/build-round`; preserve the Xcode project and only one
application build at a time. The app's Git hooks scan added lines of commits
and pushes for secrets/personal data (same rules as `tools/check-privacy.py`).

PC tests are owner-authorized. Leave desktop Steam closed; never alter the
installed client/game files or bundle the owner's cached login. If multiple
libraries contain the benchmark AppID, use its C: installation as requested.
Do not put game names in code, comments, log strings or commits.

## iOS integration and next device test

The verified ml1830 app contains a 30,208-byte stripped x64 host, SHA-256
`ddefca17379dda5e274f065913a7215a7f49a504ccb37a657a5257cc8d48804b`.
Its source/build artifacts are excluded from the app. The iOS IPA has 1,389
entries, SHA-256 `bd426d2b3172bf0160050338879d3b8712671af37fbd399509fd4ca49bf59b28`.
The source tree uses Wine 11.4; the bundled prefix template describes Windows
10 Pro build 19045. Dock's static imports resolve against the bundled Wine
export tables, including UCRT API-set mappings/forwarders. This does not prove
runtime behavior or actual Windows 7 compatibility; Valve's genuine client
is still a separate dependency. Do not downgrade the prefix based on a guess.

Read `../Madeira/docs/MADEIRA_DOCK.md`. `MADEIRA_DOCK=1` enables the trial, `=0`
restores the desktop route. Default launch option only; custom arguments fail
with an explanation. No failed Dock auth/ownership check falls back to direct
launch. Native account/session code prevents reconnecting while Dock owns the
token. Session end copies only selected numeric host diagnostics into the app
log and clears leftover handoff files.

First device test reuses the user's existing Steam files/prefix. Onboarding
under the switch signs in natively first and still runs Valve's official
installer for files; it asks the user to stop at the updated sign-in screen,
without signing in inside that desktop. Do not advertise fully automatic
component installation or a proven one-login iOS path yet.

Next: validate token submission, online state, subscription-list gate, correct
client discovery, launch and cleanup on the owner's device. Then test a clean
prefix, install only the necessary verified official component packages and
remove the desktop installer step. Also test non-entitled/revoked accounts,
network loss, Steam Guard/token expiry, multiplayer/cloud/achievements, custom
launch options, other client builds and abnormal-exit recovery. Preserve genuine
DRM throughout; do not substitute emulated licensing for a missing client API.

## Device integration update — ml1850

Log 59 from Madeira ml1840 confirms the x64 Dock EXE ran on Wine/FEX/iOS,
then crashed during LoadLibraryExW before authentication. The public runtime
kept a dead bcrypt executable mapping when coml2 reused its PE base and size.
Madeira ml1850 retires image translations on unmap, adds independent host-exit
reporting and repairs startup log controls. See sibling Madeira HANDOFF.md
for precise evidence/tests. Dock implementation and binary are unchanged;
live native-token authentication and device game launch remain unproven.
Use Documents/madeira.cfg: env.MADEIRA_DOCK = 1. Legacy env-file instructions
are superseded by canonical config (legacy files are now safely imported).

ml1860 stripped host SHA-256:
`61976bb68737c9e39f1acd387b22c7aece406f34784352bb0307bf21a1b0f3fa`,
30,208 bytes, staged into and verified inside Madeira IPA ml1860 · 09-24 21:30.
The IPA contains no Valve libraries, Dock source, symbols or cached logins.
Public IPA SHA-256: `78a10b3ce35fc5da9aee957f8e3ce0f5c6ce493fc3b8811daa7c3b73176373ca`.
No source push in this round; device authentication and launch tests pending.
Full-host malformed synthetic transfer also rejected before login with stage=5/error=0, removed the file, and did not take the cached-login path. The isolated official runtime emitted missing-helper warnings; no game was launched.

ml1870 verified artifact: `ml1870 · 09-24 21:46`, `xtool/Madeira.ipa`,
166,307,354 bytes / 1,389 entries. SHA-256:
`defe7ed39691534563d027ae813054eb709e5a30169ad6aef22680aa1df3a124`.
Stripped x64 Dock is 30,720 bytes, SHA-256:
`26bc7b1ace2846191f67d7673219e7bae132be5b0ec0db84d5e9795c65b45044`.
CRC, all 1,271 Windows resources, new app/host diagnostic strings, resource
seals and source/login/Valve-DLL exclusions pass. Only Madeira, Dock EXE,
Info.plist and CodeResources changed from ml1860; no entries removed.
Dock imports resolve against bundled Wine exports. Existing unrelated compiler
warnings remain. No commit/push performed. Device verification is outstanding.
