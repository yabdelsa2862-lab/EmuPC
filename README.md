# RIG

**Your gaming PC, in your pocket.** RIG runs Windows PC games on an iPhone with
no jailbreak. Games run unmodified inside a single iOS app, with a console-style
home screen built for a controller.

RIG is built on [Madeira](https://github.com/willfaust/Madeira) by Will Faust
and its contributors. It keeps Madeira's engine (FEX-Emu, Wine, DXMT and
Madeira's Direct3D 12 runtime) and adds its own interface, stores and quality-of-life features on top.

> [!NOTE]
> RIG is an experimental, personal project. Many games start and some play
> well, but performance and compatibility vary from game to game.

## What RIG adds

### A console home screen
- **Controller-first home** in the style of a games console: a "Jump back in"
  tile, your library as large art tiles, and button hints along the bottom.
- **Guide**: press the **Xbox / Home button** (or View + Menu) for Profile,
  Home, Store, Settings, Wi-Fi controllers and Restart.
- **In-game guide**: the same buttons during a game open Resume, **Quit game**,
  FPS limit, performance overlay and touch controls, all driven by the controller.
- **Optional tab bar** across the top (Home / Store / Settings, switched with LB
  and RB), off by default.
- **Themes**: accent colours, animated backgrounds (waves, orbs, aurora,
  particles, glow) or your own photo, and a startup animation.
- **Profile**: name, a photo or built-in avatar, and a profile page with your
  games, installed size, last played and connected stores. Set up during onboarding.
- Layout that fills the screen edge to edge and keeps clear of the Dynamic Island.

### Stores
- **Steam**, **GOG** and **Epic Games** in one store with filters (all, per
  store, ready to play, offline only, downloading).
- **GOG**: sign in (Google sign-in supported), browse, download and install
  owned games.
- **Epic Games**: sign in (including passkeys through Safari), install owned
  games, and launch them signed in.
- **Store pages** with screenshots you can open full screen (and browse with
  the controller), description, size and requirements.
- **Compatibility estimates** for every game, with precise anti-cheat labels
  (*Might work*, *Offline only*, *Won't run*) so you know before downloading.
- Clear sizes: what a game **downloads** versus how much **space it needs**,
  and a download ETA down to the second.
- Store pages and art cached, so they open instantly the second time.

### Running games
- **Session doctor**: explains crashes after the fact, warns on low memory, and a
  **heat guard** drops games to 30 FPS while the phone is hot.
- **Reopen after a close**: if RIG closes or crashes, a notification brings it
  back. A Shortcuts action, *"Did Rig close by itself?"*, can reopen it
  automatically.
- Per-game **graphics presets**, an Unreal Engine fix, a fast CPU mode and known
  profiles for specific games.
- **Easier game deletion** from the library and details page.
- **Wi-Fi controllers**: other phones on your network join as players 2–4.
- **External display**: the game on a TV while the phone keeps the controls.
- **External drive** support for game installs.
- Better mouse wheel and pointer lock, and controllers that are detected even by
  games that only look for one at startup.

RIG does not bypass DRM or anti-cheat. Games whose anti-cheat blocks
emulation are labelled as such.

## Requirements

- An iPhone on **iOS 26 or later** (developed on an iPhone 16 Pro Max on iOS 27).
- **JIT**, which iOS only allows while a debugger is attached, through
  [StikDebug](https://github.com/StikDebug/StikDebug) or the built-in StikJIT
  helper. See [`docs/JIT.md`](docs/JIT.md).
- An **Apple ID** to sideload or build the app.

## Building

```sh
git clone --recurse-submodules https://github.com/yabdelsa2862-lab/RIG.git
```

Open `app/Madeira.xcodeproj` and build the **Madeira** scheme. The project and
internal names still say Madeira, and the app shows as RIG. The native parts
(Wine unix libraries, ARM64EC modules, FEX, DXMT) are built with the scripts in
[`build/`](build); [`docs/BUILDING.md`](docs/BUILDING.md) walks through all of it.

The `FEX`, `wine`, `dxmt` and `madeira-dock` submodules point at Madeira's
public forks. RIG's own small changes to them are not published yet.

| Path | Contents |
|---|---|
| [`app/`](app) | The iOS app: SwiftUI interface, stores, Wine bridge and resources |
| [`build/`](build) | Build scripts and iOS-side sources, one folder per component |
| [`madeira-d3d12/`](madeira-d3d12) | The native Direct3D 12 runtime |
| [`docs/`](docs) | Documentation (inherited from Madeira) |
| [`tests/`](tests), [`tools/`](tools) | Checks and helper scripts |

## License

RIG is licensed, like Madeira, under **GPL-3.0-or-later** ([`LICENSE`](LICENSE))
with the **Madeira Converter Exception** ([`LICENSE-EXCEPTION.md`](LICENSE-EXCEPTION.md)).
Third-party components keep their own licenses; see
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) and [`LICENSES/`](LICENSES).
Microsoft's Visual C++ runtime is not included.

## Credits

RIG exists because of [Madeira](https://github.com/willfaust/Madeira),
created by **Will Faust** ([@willfaust](https://github.com/willfaust)), and
everyone who contributed to it, including 125hz, Jfishin, JesseLovelace,
danperks, bahacan16, spitefulowl, meshoklv and TheHadesc. Fixes were also taken
from the community forks of [Notbood](https://github.com/Notbood/Madeira) and
[kuscholar](https://github.com/kuscholar/Madeira).

It is built on [Wine](https://www.winehq.org/), [FEX-Emu](https://github.com/FEX-Emu/FEX),
[DXMT](https://github.com/3Shain/DXMT), [rpmalloc](https://github.com/mjansson/rpmalloc),
[StikDebug](https://github.com/StikDebug/StikDebug), [StikJIT](https://github.com/StikDebug/StikJIT)
and [idevice](https://github.com/jkcoxson/idevice). GOG and Epic support follows the
approach of [Legendary](https://github.com/derrod/legendary) and the GOG Galaxy API.

RIG is not affiliated with Microsoft, Xbox, Valve, GOG or Epic Games.
