# Madeira Dock — agent instructions

Read `README.md` and `docs/HANDOFF.md` first. They explain the architecture,
current build, native/iOS evidence, exact build/test/stage commands and next
steps. Keep both updated after meaningful changes, and keep the sibling
Madeira integration guide/handoff (`../Madeira/docs/MADEIRA_DOCK.md`) in step.

`README.md` is written for an outside reader (a user, a contributor, Valve): it
says what the program does and does not do, in the present tense, and every
statement in it must match the source. Round-by-round notes, device logs and
test results go in `docs/HANDOFF.md`, never in the README; the README as it
stood before 2026-10-02 is kept in `docs/HISTORY.md`.

- Madeira Dock is open source: GPL-3.0-or-later with the Madeira Converter
  Exception (`LICENSE`, `COPYING`, `LICENSE-EXCEPTION.md`), Copyright 2026
  125hz. Every source, test and tool file carries the SPDX header
  `GPL-3.0-or-later`, `Copyright 2026 125hz` and the exception line.
  Contributions are accepted under the same terms. Preserve third-party
  notices (`THIRD-PARTY-NOTICES.md`, `notices/`).
- The canonical repository is `https://github.com/125hz/madeira-dock.git`.
- Never commit secrets or personal data: no tokens, passwords, Steam login
  caches (`loginusers.vdf`, `config.vdf`, `ssfn*`), account names, real
  SteamIDs, personal paths or email addresses, test logs, Valve binaries,
  games, PDBs or build output (`.build/`). Run
  `python3 tools/check-privacy.py` before committing and
  `python3 tools/check-privacy.py --history` before publishing history.
- Use Valve's unmodified client and the game's original APIs/DRM. Real Steam
  authentication and entitlement are mandatory; fail closed on errors.
  Dock is legitimate owner-authorized headless-client work, not a DRM bypasser.
  The owner wants real ownership verification with original game DRM intact.
- No game-specific patches or game names in code, comments, log strings or
  commits. Native test commands use App IDs and explicit library directories.
- Never log tokens, account identifiers or credential payloads. Never put a
  token on a command line or in an environment variable.
- Existing Windows tests are owner-authorized. Leave desktop Steam closed.
  Cached-login PC testing is not part of the public tools; do not add a
  harness that reads a PC's Steam login cache to the repository.
- Package stripped binaries with `dock-notices.txt` (GPL-3.0 + exception +
  LLVM/MinGW runtime notices); keep symbols, tokens and debug artifacts out of
  the app bundle.
