# WhiteRecomp iOS

<a href="https://ko-fi.com/joshua27658"><img src="https://ko-fi.com/img/githubbutton_sm.svg" width="340" alt="Support this project on Ko-fi"></a>

**Tips & donations:** https://ko-fi.com/joshua27658

**FINAL FANTASY XIII running on iPhone** — an iOS port of
[WhiteRecomp](https://github.com/ps4star/WhiteRecomp) by **ps4star**, which
recompiles the Steam PC version of the game into native code.

This fork takes the official WhiteRecomp **v0.0.13** sources and builds them
for iOS: same translated game, same runtime, with an iOS entry point, touch
controls, and a small set of patches where iOS differs from macOS.

> Unofficial fan project. Not affiliated with Square Enix or with the
> WhiteRecomp project. **No game data is included or distributed** — you must
> own FINAL FANTASY XIII on Steam and supply your own copy.

## Status — what works

Tested on an iPhone 16 Pro Max (A18 Pro), installed with SideStore.

- ✅ The full game, playable start to finish in principle — title screen,
  gameplay, saves
- ✅ **Cutscenes play straight from the game's own `.wmp` files**, with
  sound — v0.0.13 translates the game's own `bink2w32.dll` alongside the
  exe, so there is **no movie conversion** (no Wine, no 40 GB of MP4s)
- ✅ 60 fps, presented at the panel's native resolution (2868×1320); the
  game renders internally at 1280×720 and is upscaled
- ✅ MSAA 4× and 1024×1024 shadows, full-resolution effects
- ✅ Hair and eyelashes render correctly (upstream's v0.0.12
  alpha-to-coverage fix, with MSAA on)
- ✅ Touch controls: an on-screen gamepad (sticks, buttons) implemented as
  an SDL virtual controller, so the game's own controller code drives it
- ✅ App icon, landscape, full screen

## Requirements

- A **Mac with Xcode** (the build runs there; Apple Silicon used here)
- An **iPhone or iPad on iOS 17+** (USB-C models for wired controllers)
- **SideStore**, AltStore, or LiveContainer to install the unsigned IPA
- **Your own Steam copy of FINAL FANTASY XIII** (Windows version,
  AppID 292120) for the game data
- ~3 GB free on the Mac for the build, plus room on the phone for the game
  folder (~40 GB with movies)

## Building

Everything is driven by three shell scripts. Run them with `sh` (they are
not marked executable), always **from inside this folder**, and always in
the *same* folder — the dependency and object caches live here, and
unzipping a fresh copy elsewhere is the classic way to end up testing a
stale build.

### 1. Get the upstream sources

```sh
sh setup_on_mac.sh
```

Downloads the official WhiteRecomp v0.0.13 macOS launcher from ps4star's
GitHub release, verifies its SHA-256, and extracts the full source bundle
(the launcher carries the game's translated sources inside it) into
`src/bundle/`. Re-running it after an upstream release upgrades the bundle
in place — it swaps the old one out, never merges.

### 2. Fetch the iOS dependencies (once)

```sh
sh ios/fetch_deps.sh
```

Builds or downloads the three things the iOS build links against, into
`ios/deps/` (versions pinned):

- **SDL2.xcframework** (2.32.10) — built from the official SDL source with
  SDL's own `xcFramework-iOS` scheme (there is no iOS binary download)
- **MoltenVK.xcframework** (1.4.1) — Vulkan on Metal, from the official
  MoltenVK-iOS release
- **FFmpeg** (7.1.1) — static libraries for iphoneos-arm64, built from
  source in the same LGPL configuration as upstream's bundled build

### 3. Build the IPA

```sh
sh ios/build_ios.sh
```

Applies the iOS patches to a working copy of the sources (see *How it
works*), compiles the game and runtime for `arm64-apple-ios17.0`, and packs
an **unsigned** `WhiteRecomp.ipa`.

- Re-running is incremental — only changed sources recompile
- `CLEAN=1 sh ios/build_ios.sh` forces a full rebuild
- `JOBS=n` and `OPT=1` are also available as environment knobs

## Installing and adding the game

1. Install `WhiteRecomp.ipa` with **SideStore** (or your usual sideload
   tool).
2. Get your game data: the **Windows** Steam install of FINAL FANTASY
   XIII. On a Mac with no Windows machine, SteamCMD works:

   ```sh
   brew install steamcmd
   steamcmd +@sSteamCmdForcePlatformType windows +login <you> \
       +app_update 292120 validate +quit
   ```

3. Copy the whole **`FINAL FANTASY XIII`** folder into the app's
   **Documents** (Files app or Finder file sharing). The layout must end
   up as `Documents/FINAL FANTASY XIII/white_data/prog/win/bin/ffxiiiimg.exe`.
4. Launch. A log is written to `Documents/ff13.log` — it's the first place
   to look if anything misbehaves.

⚠️ Reinstalling the app gives it a fresh data container: the game folder
(and the log) are wiped, so copy the game in again after a reinstall.
Refreshing the signature in place keeps your data.

## Settings baked into this fork

The desktop launcher passes settings to the game as command-line
arguments; the iOS entry point does the same:

- `-Shadow=1024 -MSAA=4`
- `XRC_MOVIES=bink` — cutscenes from the translated Bink DLL (the default;
  delete the line's effect by choosing the MP4 player upstream-style)
- `XRC_STRETCH=1` — the picture fills the screen
- 60 fps frame limit

Further `XRC_*` options can be put in `WhiteRecomp.cfg` in the app's
Documents, as with the desktop build.

## Known issues

- **Physical controllers are not seen by the app yet.** Pads that work in
  other iOS games (tested: GameSir X5 Lite over USB-C, 8BitDo over
  Bluetooth) currently don't appear to the app at all — Apple's
  GameController framework reports none. Under investigation; the touch
  controls work meanwhile.
- **Don't background the app mid-game.** iOS doesn't allow background GPU
  work, so the Vulkan device is lost (`VK_ERROR_DEVICE_LOST`) and the run
  ends. It also means a device-lost line at the end of a log usually just
  means the app was backgrounded to share the log.
- **Internal resolution is 1280×720.** Raising it with `-Width`/`-Height`
  currently produces a black screen (sound and game logic fine) on both
  the v0.0.9 and v0.0.12+ runtimes; presentation is at native panel
  resolution regardless.
- **Free signing strips the special memory entitlements** (increased
  memory / extended virtual addressing), so the port runs within the
  standard per-app limits.

## How it works

- `tools/extract_bundle.py` unpacks the `FFBUNDL2` source bundle appended
  to the official macOS launcher binary.
- The iOS layer lives in `ios/src/`:
  - `ios_main.m` — a UIScene-based entry point (iOS 26+ requires the
    scene lifecycle). It starts the game's `main()` (renamed `SDL_main`),
    then *adopts* SDL's window onto the app's scene via
    `SDL_GetWindowWMInfo` and raises its Metal layer to the panel's
    native scale.
  - `ios_env.m` — a constructor shim that sets the `XRC_*` paths and
    defaults (game folder in Documents, log file, stretch, Bink movies)
    before the game starts, mirroring what upstream's Android shim does.
  - `xrc_ios_touch.c` — the touch gamepad: the runtime's Android overlay
    design, driven by SDL finger events, presented to the game as an SDL
    **virtual controller** (so real-controller support in the runtime is
    untouched).
- `tools/patch_*.py` make the small, idempotent source edits iOS needs at
  build time: steering upstream's macOS Cocoa window code and its
  log-to-file behaviour away from iOS, opening the touch overlay's guards
  to iOS, and inserting startup markers for debugging.

## Thank you

This port exists because a lot of people's work lined up. Thank you to
**all** of them:

- **ps4star**, for [WhiteRecomp](https://github.com/ps4star/WhiteRecomp)
  itself — the recompilation, the runtime, the launcher — and for the
  rapid-fire releases that kept landing mid-port: the v0.0.12 hair and
  eyelash fix, and v0.0.13 translating the Bink DLL so the cutscenes just
  play. This fork is a thin layer on top of that work.
- **Square Enix**, for FINAL FANTASY XIII.
- The **SDL**, **MoltenVK**, and **FFmpeg** projects — the libraries the
  port stands on.
- The **SideStore** and **LiveContainer** teams, for making it possible to
  run unsigned apps like this on a real phone at all.
- The author of the **Steam Community guide** to FFXIII's graphics
  settings, whose eyelash/hair notes pointed the diagnosis in the right
  direction.
- **Claude** (Anthropic), whose UIScene-lifecycle fix unblocked the app
  launching on current iOS, and **Muse** (Meta), for the long debugging
  sessions that turned a macOS launcher into a phone build.
- And everyone who tested a build, sent a log, and said *"it's black
  screen again"* until it wasn't.

## Support

This is a hobby project, built in spare time. If it brought FFXIII to your
phone and you'd like to say thanks with a coffee, tips and donations are
welcome — never expected:

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/joshua27658)

https://ko-fi.com/joshua27658

## License / disclaimer

The iOS additions in this fork are shared for personal, educational use.
FINAL FANTASY XIII, its assets, and its data are © Square Enix — buy the
game; nothing from it is in this repository. WhiteRecomp's own licensing
applies to the upstream parts.
