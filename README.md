# WhiteRecomp

WhiteRecomp builds a native port of **FINAL FANTASY XIII** on your own computer. It uses the sources it carries and your own Steam copy of the game.

> [!IMPORTANT]
> WhiteRecomp does **not** contain the game. You need FINAL FANTASY XIII installed from Steam (the current Steam version).

## Download

Get the launcher for your system from the [Releases page](https://github.com/ps4star/WhiteRecomp/releases):

| System | File |
| --- | --- |
| Windows (64-bit) | `WhiteRecompLauncher_windows.exe` |
| Linux (x86-64) | `WhiteRecompLauncher_linux` (run `chmod +x` on it first; less tested than Windows) |

Put the launcher in a folder of its own. **Build** creates the game beside it.

## Quick start

1. **Start the launcher.** It finds the game through Steam. If it doesn't, press **Browse…** and pick the `FINAL FANTASY XIII` folder (the one containing `white_data`).
2. **Install what it says is missing.** Usually that's just a C compiler. The launcher offers to install one, and asks for administrator permission only for an install that needs it.
3. **Options** (optional). See [Options](#options) below.
4. **Build.** This compiles the game, which takes a few minutes. The result is `WhiteRecomp.exe` (Linux: `WhiteRecomp`) beside the launcher, with `WhiteRecomp.cfg` next to it, which records where your game and saves are.
5. **Run** starts the game. You can also start `WhiteRecomp.exe` directly.
6. **Convert Movies** (recommended; Windows only for now). This converts the game's cutscenes to MP4, once. It takes about an hour and can be stopped and resumed.
7. **Discard Movies** (optional). Once the MP4s exist, this frees about 40 GB by cutting the original movie files down.

## Requirements

- **FINAL FANTASY XIII from Steam.** WhiteRecomp reads the game program (`ffxiiiimg.exe`, which must be the current Steam version) and all the game's files from your install. It uses the game's own movie decoder (`bink2w32.dll`) once, to convert the movies.
- **A C compiler.**
  - On Windows: MSYS2's **Clang** (recommended) or GCC. Visual C++ can't build the game.
  - On Linux: `clang` or `gcc`.
  - The launcher lists every compiler it finds and offers to install one if there is none.
- **A GPU with Vulkan 1.3.**
- **Movies:** converting them works on Windows only for now, and the launcher brings the FFmpeg program it needs. Playing converted movies needs no FFmpeg program, because the game has FFmpeg's libraries built in.

## Options

The **Options** tab is saved between sessions.

- **Build options:** most options change how the game is compiled, so they take effect the next time you press **Build**.
- **Game options:** **Shadow Resolution** and **Anti-Aliasing** are passed to the game when it starts. They take effect the next time you start the game, with no rebuild.

### Compiler

The C compiler that builds the game. The launcher finds every GCC and Clang on the system and lists Clang first, marked **(BEST)**. Clang produces a noticeably faster game, about 15% less CPU time per frame than GCC.

### Optimization Level

How hard the compiler optimizes the game. The default is **1**.

| Level | Build time | Game speed |
| --- | --- | --- |
| 0 | Fastest build | Slowest game. Only useful for debugging. |
| **1 (Recommended)** | A few minutes | Fast |
| 2 | Slower build | About the same as 1 |
| 3 | Slowest build | About the same as 1 |

Levels above 1 haven't measured faster than 1.

### Audio

- **On** (default): music, sound effects and voices.
- **Off:** no sound output and no audio processing at all, for example if you want to play your own music. The game's audio engine is replaced by a silent stand-in that only keeps time.

### Debug & Profile Tools

- **Off** (default): the game prints nothing and, on Windows, opens no console window.
- **On:** a console window with logs, plus:
  - a **frame time counter** in the top right corner of the game window
  - stack traces if the game crashes or hangs
  - the profiler and tracing switches (environment variables starting with `XRC_`) for diagnosing problems

  These cost almost nothing while unused.

### FPS

The frame rate cap: **30** or **60** (default). The game's logic runs in 1/60 s steps, so these are the two supported rates.

### Graphics Driver

- **Vulkan (Recommended)**, the default and the only choice on Linux: the port's own renderer.
- **D3D9** (Windows only): Windows' own Direct3D 9. It's currently broken: the game stops at the cutscene after the first fight.

### Cutscenes

FINAL FANTASY XIII's cutscenes are Bink 2 videos, which the port can't play directly. Each one is converted to an MP4 once. **Convert Movies** on the Home tab does them all, and while you play the game also converts missing ones quietly in the background, one at a time.

- **Play if converted** (default): a cutscene plays once its MP4 exists. Until then it's skipped.
- **Auto-skip:** every cutscene is skipped, even converted ones, which is handy for replays and speedruns. Background conversion continues, so the movies are ready if you switch back (followed by a new Build).

### Cutscene Convert Threads

How many CPU threads movie conversion uses, both for **Convert Movies** and for background conversion while you play. The default is **1**, so conversion doesn't slow the game down. Raise it to make **Convert Movies** finish sooner. The maximum is your CPU count minus one.

### Shadow Resolution

The size of the shadow maps, passed to the game as `-Shadow=N` exactly as the original launcher does. Takes effect the next time the game starts.

| Choice | Effect |
| --- | --- |
| Off (no shadows) | Shadow maps aren't drawn at all. Fastest; no shadows anywhere. |
| 512 x 512 | Blurrier shadows, cheaper |
| **1024 x 1024 (DEFAULT)** | The game's default |
| 2048 x 2048 | Sharper shadows |
| 4096 x 4096 | Sharper still, costlier |
| 8192 x 8192 | The original launcher's maximum, for high-end GPUs |

### Anti-Aliasing (MSAA)

Multisample anti-aliasing smooths jagged edges. It's passed to the game as `-MSAA=N`, exactly as the original launcher does, and takes effect the next time the game starts.

| Choice | Effect |
| --- | --- |
| Off | No anti-aliasing. Fastest. |
| 2x | Light smoothing |
| **4x (DEFAULT)** | The game's default |
| 8x | Smoother |
| 16x | Smoothest |

If your GPU can't do the count you pick, the game uses the most it supports. Foliage and other cut-out textures also get smooth edges when MSAA is on.

### Experimental Optimizations

- **Off** (default): only tested optimizations.
- **On:** also enables newer optimizations that are less tested and **may break things**, such as visual glitches, crashes or a softlock.

Turn it off again (and Build) if anything goes wrong. Bug reports from playing with it on are welcome; please say it was on.

## What the download contains

- **The launcher program.** Packed inside it are:
  - **The translated game code:** C source files generated from the game program and compiled on your computer.
  - **The runtime those sources run on:** C sources for memory, threads, files, graphics (Vulkan), sound and movies.
  - **FFmpeg's libraries** (libavformat, libavcodec, libswresample, libavutil; LGPL 2.1 or later), which the game is linked with to play the movies.
  - **On Windows, the movie converter:** a 32-bit Windows program.
  - **On Windows, the FFmpeg program it encodes with** (`ffmpeg.exe`, GPL 3). It's a separate program; see `THIRD_PARTY_LICENSES.txt`.
- **`THIRD_PARTY_LICENSES.txt`:** the licenses of the libraries and fonts in the launcher, and of FFmpeg, with where to get its source and how to use your own build of it.

## Building the launcher

The launcher's sources are in [`launcher_src/`](launcher_src/). It's written in [Odin](https://odin-lang.org/) and is built inside the main decompilation project, because the bundle it carries (the translated code, the runtime and the tools) comes from that project's build. See [`launcher_src/README.md`](launcher_src/README.md).
