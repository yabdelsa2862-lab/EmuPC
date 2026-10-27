# EmuPC: PC emulator for iPhone and iPad

**Play Windows PC games on your iPhone or iPad, with no jailbreak.** EmuPC is a
PC emulator for iOS and iPadOS: it runs real Windows games from **Steam**,
**GOG** and **Epic Games** inside a single app, with a console-style home
screen built for a controller.

**[⬇ Download the latest EmuPC IPA](https://github.com/yabdelsa2862-lab/EmuPC/releases/latest)**,
then sideload it and turn on JIT ([how](#faq)).

EmuPC is built on [Madeira](https://github.com/willfaust/Madeira) by Will Faust
and its contributors. It keeps Madeira's engine (the FEX-Emu x86 emulator,
Wine, DXMT and Madeira's Direct3D 12 runtime) and adds its own interface,
stores and quality-of-life features on top.

> [!NOTE]
> EmuPC is an experimental, personal project. Many games start and some play
> well, but performance and compatibility vary from game to game.

> **Tested on an iPhone 16 Pro Max** (8 GB, iOS 27) and an **iPad Air 4**
> (4 GB, iPadOS 27). Other recent iPhones and iPads should work; devices with
> 4 GB of memory get a low-memory profile and run lighter games.

## Screenshots

<p align="center">
  <img src="docs/screenshots/home.jpg" alt="Home: jump back in to your last game" width="49%">
  <img src="docs/screenshots/store.jpg" alt="Store: Steam, GOG and Epic in one place" width="49%">
</p>
<p align="center">
  <img src="docs/screenshots/guide.jpg" alt="The guide, opened with the Xbox button" width="49%">
  <img src="docs/screenshots/download.jpg" alt="A store page while downloading, with the compatibility estimate" width="49%">
</p>
<p align="center">
  <img src="docs/screenshots/touch-library.jpg" alt="The touch library" width="70%">
</p>

### In game

<p align="center">
  <img src="docs/screenshots/quake2.jpg" alt="Quake II PC game running at 72 FPS on an iPhone 16 Pro Max in EmuPC" width="49%">
  <img src="docs/screenshots/quake2-action.jpg" alt="Quake II Windows version played with a controller on iPhone" width="49%">
</p>
<p align="center">
  <img src="docs/screenshots/mecha-chameleon.jpg" alt="Steam game Mecha Chameleon running on iPhone with EmuPC" width="49%">
  <img src="docs/screenshots/launching.jpg" alt="EmuPC starting a GOG game on iPhone" width="49%">
</p>

| | |
|---|---|
| **Home** | Jump back in to your last game, with your library underneath. |
| **Store** | Steam, GOG and Epic Games together, with filters and compatibility badges. |
| **Guide** | The Xbox button opens it from anywhere: profile, store, settings, restart. |
| **Store page** | Download progress, download versus installed size, and whether it will run. |
| **Touch library** | Everything also works by touch when no controller is connected. |

## What EmuPC adds

### A console home screen
- **Controller-first home** in the style of a games console: a "Jump back in"
  tile, your library as large art tiles, and button hints along the bottom.
- **Guide**: press the **Xbox / Home button** (or View + Menu) for Profile,
  Home, Store, Settings, Wi-Fi controllers and Restart.
- **In-game guide**: the same buttons during a game open Resume, **Quit game**,
  FPS limit, performance overlay and touch controls, all driven by the controller.
- **Battery at a glance**: your iPhone or iPad battery and your controller's,
  next to the clock and in the guides.
- **Close EmuPC** from the guide, without reaching for the screen.
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
  owned games. Older GOG releases (first-generation builds) download too, and
  GOG games find their install folder the way they do on Windows.
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
- **OpenGL games**: games that draw with OpenGL (Geometry Dash, Quake II's
  OpenGL renderer and other older or indie titles) run through
  [gl4es](https://github.com/ptitSeb/gl4es) on iOS's OpenGL ES, shown with Metal.
  EmuPC turns it on by itself for those games. Geometry Dash plays at 60 FPS on
  an iPhone 16 Pro Max and runs on an iPad Air 4 (4 GB).
- **Current Steam client**: EmuPC installs Valve's current 64-bit Steam client
  components and updates older installs automatically, so games built with
  newer Steamworks versions start.
- **Session doctor**: explains crashes after the fact, warns on low memory, and a
  **heat guard** drops games to 30 FPS while the phone is hot.
- **Reopen after a close**: if EmuPC closes or crashes, a notification brings it
  back. A Shortcuts action, *"Did EmuPC close by itself?"*, can reopen it
  automatically.
- Per-game **graphics presets**, an Unreal Engine fix, a fast CPU mode and known
  profiles for specific games.
- **Easier game deletion** from the library and details page.
- **Low-memory profile** for 4 GB devices such as the iPad Air 4: a smaller JIT
  pool, a lighter video memory budget, a swap file and 30 FPS for new games,
  switched on by itself (Settings › General).
- **Your music while you play**: game sound mixes with your music instead of
  stopping it, and the guide shows the Apple Music song with play, pause and skip
  on the controller.
- **Wi-Fi controllers**: other phones on your network join as players 2–4.
- **External display**: the game on a TV while the phone keeps the controls.
- **External drive** support for game installs.
- **Button layouts**: a Steam-style editor shows the controller with every button
  around it; pick one and choose what it does, for all games (Settings ›
  Controls) or just one game (its page, LB/RB to switch). The Xbox / Home
  button always opens the guide.
- **Quake II from GOG** sets itself up: EmuPC fetches
  [Yamagi Quake II](https://www.yamagi.org/quake2/) (checksum-pinned), keeps
  GOG's files as backups, and starts it full screen with controller binds.
- Better mouse wheel and pointer lock, and controllers that are detected even by
  games that only look for one at startup.

EmuPC does not bypass DRM or anti-cheat. Games whose anti-cheat blocks
emulation are labelled as such.

## FAQ

**Can I play PC games on my iPhone?**
Yes. EmuPC runs Windows PC games on iPhone and iPad. Games you own on Steam,
GOG or Epic download straight into the app. Older and lighter games run best;
heavy new games may not start or may be slow.

**Does it need a jailbreak?**
No. You sideload the IPA with SideStore, AltStore, Sideloadly or your own Apple
ID, like any other open-source iOS app.

**Why does it need JIT, and how do I turn it on?**
The x86 emulator translates games to ARM as they run, and iOS only allows that
with JIT. Use [StikDebug](https://github.com/StikDebug/StikDebug) with
LocalDevVPN, or EmuPC's built-in helper; see [`docs/JIT.md`](docs/JIT.md).

**Is it on the App Store?**
No. App Store apps can never use JIT, so a PC emulator this fast can't be
released there. EmuPC is free and open source here instead.

**Which devices work?**
Tested on an iPhone 16 Pro Max and an iPad Air 4. Recent iPhones and iPads with
6 GB of memory or more work best; 4 GB devices get a lighter profile.

**Does it work with a controller?**
Yes: Xbox, PlayStation and other MFi controllers, with a console-style home,
an in-game guide, and button remapping for every game. Touch controls and
keyboard and mouse work too.

## Requirements

- An iPhone or iPad on **iOS 26 or later**. EmuPC is tested on an
  **iPhone 16 Pro Max** (iOS 27) and an **iPad Air 4** (iPadOS 27); 4 GB devices
  like the iPad Air 4 get a low-memory profile and run lighter games.
- **JIT**, which iOS only allows while a debugger is attached, through
  [StikDebug](https://github.com/StikDebug/StikDebug) or the built-in StikJIT
  helper. See [`docs/JIT.md`](docs/JIT.md).
- An **Apple ID** to sideload or build the app.

## Building

```sh
git clone https://github.com/yabdelsa2862-lab/EmuPC.git
```

Everything is in this one repository, including EmuPC's versions of Wine, FEX-Emu,
DXMT and the Steam launcher (no submodules to fetch). Open
`app/Madeira.xcodeproj` and build the **Madeira** scheme; the project and
internal names still say Madeira, and the app shows as EmuPC. The native parts
(Wine unix libraries, ARM64EC modules, FEX, DXMT) are built with the scripts in
[`build/`](build), one folder per component.

| Path | Contents |
|---|---|
| [`app/`](app) | The iOS app: SwiftUI interface, stores, Wine bridge and resources |
| [`wine/`](wine), [`FEX/`](FEX), [`dxmt/`](dxmt), [`madeira-dock/`](madeira-dock) | Wine, the x86 translator, the Direct3D-to-Metal layer and the Steam launcher, with EmuPC's changes |
| [`build/`](build) | Build scripts and iOS-side sources, one folder per component |
| [`madeira-d3d12/`](madeira-d3d12) | The native Direct3D 12 runtime |
| [`docs/`](docs) | Documentation (inherited from Madeira) |
| [`tests/`](tests), [`tools/`](tools) | Checks and helper scripts |

## License

EmuPC is licensed, like Madeira, under **GPL-3.0-or-later** ([`LICENSE`](LICENSE))
with the **Madeira Converter Exception** ([`LICENSE-EXCEPTION.md`](LICENSE-EXCEPTION.md)).
Third-party components keep their own licenses; see
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) and [`LICENSES/`](LICENSES).
Microsoft's Visual C++ runtime is not included.

## Thank you, Madeira

EmuPC would not exist without [**Madeira**](https://github.com/willfaust/Madeira).
All the hard parts are Madeira's work: running Windows games on an iPhone at all,
the JIT, Wine and FEX on iOS, Direct3D on Metal and Steam support. Thank you to
**Will Faust** ([@willfaust](https://github.com/willfaust)) for creating it and
sharing it as open source, and to everyone who built it with him, including
125hz, Jfishin, JesseLovelace, danperks, bahacan16, spitefulowl, meshoklv and
TheHadesc.

If you like EmuPC, please ⭐ star [EmuPC](https://github.com/yabdelsa2862-lab/EmuPC) and
[Madeira](https://github.com/willfaust/Madeira) too. It helps both projects a lot.

## Credits

Fixes were also taken from the community forks of
[Notbood](https://github.com/Notbood/Madeira) and
[kuscholar](https://github.com/kuscholar/Madeira).

It is built on [Wine](https://www.winehq.org/), [FEX-Emu](https://github.com/FEX-Emu/FEX),
[DXMT](https://github.com/3Shain/DXMT), [gl4es](https://github.com/ptitSeb/gl4es), [rpmalloc](https://github.com/mjansson/rpmalloc),
[StikDebug](https://github.com/StikDebug/StikDebug), [StikJIT](https://github.com/StikDebug/StikJIT)
and [idevice](https://github.com/jkcoxson/idevice). GOG and Epic support follows the
approach of [Legendary](https://github.com/derrod/legendary) and the GOG Galaxy API.

## Legal

- EmuPC is an independent, non-commercial project. It is not affiliated with,
  endorsed by or sponsored by Microsoft, Xbox, Valve, Steam, GOG, Epic Games,
  Apple, id Software, Bethesda or any game publisher. All product names, logos
  and trademarks belong to their owners and are used only to describe what
  EmuPC works with.
- **No games are included.** EmuPC runs games you own, downloaded from your own
  accounts. It does not bypass DRM, copy protection or anti-cheat, and it does
  not include any Microsoft, Windows or game files (the Visual C++ runtime is
  not included either).
- Screenshots show games running on EmuPC for illustration only. The games and
  their artwork belong to their respective owners.
- For GOG's Quake II, EmuPC downloads [Yamagi Quake II](https://www.yamagi.org/quake2/)
  (GPL-2.0) from its official site on your device; EmuPC does not redistribute it,
  and the game data comes from your own GOG copy.
- EmuPC is provided as is, without warranty (see [`LICENSE`](LICENSE)). The
  source for every release is this repository at the release's tag.
- Questions or a takedown request about anything here? Open an issue and it
  will be dealt with promptly.
