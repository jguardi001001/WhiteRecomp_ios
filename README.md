# WhiteRecomp

WhiteRecomp builds a native port of **FINAL FANTASY XIII** on your own computer. It uses your own Steam version of the game to do this.

> [!IMPORTANT]
> WhiteRecomp does **not** contain the game or any copyrighted game data or assets. You need a legitimate copy of FINAL FANTASY XIII installed from Steam (the current Steam version).

## Download

Get the launcher for your system from the [Releases page](https://github.com/ps4star/WhiteRecomp/releases):

| System | File |
| --- | --- |
| Windows (64-bit) | `WhiteRecompLauncher_windows.exe` |
| Linux (x86-64) | `WhiteRecompLauncher_linux` (run `chmod +x` on it first; less tested than Windows) |
| Linux (ARM64) | `WhiteRecompLauncher_linux_arm64` (run `chmod +x` on it first; new and least tested: it builds and runs the game on the ARM64 computer itself, which needs Clang or GCC, Vulkan drivers and SDL2) |

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
- **Game options:** **Graphics** and **Memory** are passed to the game when it starts. They take effect the next time you start the game, with no rebuild.

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
  - an **FPS counter** in the top right corner of the game window
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

**Off** stops the background conversion while you play (no Build needed). **Convert Movies** still works, with 1 thread.

### Pipeline Build Threads

How many threads prepare the renderer's graphics pipelines in the background. A new effect or area needs new pipelines the first time it appears, and until one is ready the objects using it are skipped for a frame or two. The default, marked **(Best)**, is half your CPU threads (at most 8). The maximum is your CPU threads minus one (at most 16). Takes effect the next time the game starts, with no Build needed.

### Resolution

The resolution the game renders at, passed to the game as `-Width=W -Height=H`: 854 x 480, 960 x 540, **1280 x 720** (default), 1600 x 900, 1920 x 1080, 2560 x 1440, 3200 x 1800 or 3840 x 2160. Higher is sharper and costs more GPU time; 480 and 540 are for slow GPUs. Takes effect the next time the game starts, with no Build needed.

The game's window opens at this size. You can resize or maximize it, and **F11** switches fullscreen on and off. The picture is scaled to fit the window with its shape kept, so a window of another shape gets black bars.

### Graphics

A preset for shadows and anti-aliasing. Takes effect the next time the game starts.

| Choice | Shadows | Anti-aliasing |
| --- | --- | --- |
| Ultrafast (Worst Quality) | Off | Off |
| Fast | 512 x 512 | 2x FXAA |
| **Fancy (DEFAULT)** | 1024 x 1024, the game's default | 4x FXAA |
| Ultrafancy | 8192 x 8192 | 8x FXAA |
| Custom | As set below | As set below |

**Custom** shows three more options under Graphics:

- **Shadow Resolution:** the size of the shadow maps, passed to the game as `-Shadow=N` exactly as the original launcher does. **Off** draws no shadow maps at all (the fastest); 512 is blurrier and cheaper; 1024 is the game's default; 2048, 4096 and 8192 (the original launcher's maximum) are sharper and costlier.
- **Anti-alias Method:**
  - **FXAA** (default): a cheap smoothing filter on the 3D image, applied before the HUD is drawn so the HUD stays sharp.
  - **MSAA:** the game's own multisampling, passed as `-MSAA=N` like the original launcher. Sharper on fine detail, but costly, especially on integrated GPUs.
- **Anti-alias Quality:** **1x** (off), **2x**, **4x** (default) or **8x**. For FXAA, higher smooths longer edges; for MSAA it's the samples per pixel, and if your GPU can't do the count you pick, the game uses the most it supports.

### Memory

How much memory the game can address.

- **4GB (Recommended)** (default): the address space a 4 GB-patched exe gets.
- **2GB:** what the original, unpatched exe gets.

### Profile-Guided Optimization

- **On** (default): the game is compiled with a profile recorded while playing it, so the compiler optimizes for how the game actually runs: about 6% less CPU time per frame on the game's main thread.
- **Off:** built without the profile.

It needs **Clang**; with GCC it's skipped. On Windows it also needs LLVM's linker (`ld.lld.exe`) next to `clang.exe` (MSYS2: the `mingw-w64-ucrt-x86_64-lld` package); the launcher says so if it's missing. If your Clang is too old to read the profile, the Build says so and goes on without it.

### Link-Time Optimization

- **Off** (default): each source file is optimized on its own. This is the faster Build.
- **On:** the compiler also optimizes across files when it links the game (`-flto`), which can make the game a little faster. The Build takes noticeably longer.

With Clang on Windows, this needs LLVM's linker (`ld.lld.exe`) next to `clang.exe`. In MSYS2 that's the `mingw-w64-ucrt-x86_64-lld` package. If it's missing, the launcher says so and builds without LTO. GCC, and Clang on Linux, need nothing extra.

### Always on

Every Build also uses these, with no option to turn them off:

- **`-march=native`:** the game is compiled for your own CPU's instruction set, since the computer that builds it is the one that plays it. A game built on one computer may not run on an older CPU.
- **Fast math (`-ffast-math -fno-associative-math`):** faster floating-point code. The parts of the translated code that must behave exactly like an x86 CPU (NaN checks, float compares, float-to-integer conversions) are written so fast math can't change them. Reassociation (regrouping sums) stays off, because it breaks the game's own rounding tricks: the title menu disappears. Other results may differ from the original in the last bits.
- **On Linux:** the distributions' hardening defaults (position-independent executables, control-flow protection, stack protector) are turned off. They cost speed and protect nothing here.

### Experimental Optimizations

- **Off** (default): only tested optimizations.
- **On:** also enables newer optimizations that are less tested and **may break things**, such as visual glitches, crashes or a softlock.

Turn it off again (and Build) if anything goes wrong. Bug reports from playing with it on are welcome; please say it was on.

## Cross-Compile

The **Cross-Compile** tab builds the game for another kind of computer than the one the launcher runs on, with the Options tab's options. Today that's **Linux ARM64**: a Raspberry Pi 4 or 5, an ARM laptop, Asahi Linux on an Apple-silicon Mac. It works from the Windows and the Linux launcher.

- **Target:** Linux ARM64 (64-bit ARM, glibc 2.34 or newer: Debian 12, Ubuntu 22.04, Raspberry Pi OS 12 and later).
- **CPU:** **Any ARM64 CPU** (default) runs everywhere; choosing the device's CPU (Raspberry Pi 4, Raspberry Pi 5, Apple M1/M2, ...) is faster there, but that build needs that CPU or a newer one.
- **Needs:** Clang and LLVM's linker (lld). LLVM-MinGW and MSYS2's Clang on Windows come with lld; on Linux install it, e.g. `sudo apt install lld`. Everything for the target (its system headers and libraries, its FFmpeg) is packed in the launcher.
- **Build for Linux ARM64** builds into the folder `WhiteRecomp-linux-arm64` beside the launcher. Copy that folder to the ARM64 computer, put (or link) your `FINAL FANTASY XIII` folder inside it, and run `./WhiteRecomp` there. Its `README.txt` has the steps. That computer needs Vulkan drivers and SDL2 (e.g. `sudo apt install libsdl2-2.0-0 mesa-vulkan-drivers`). Convert the cutscenes on a Windows PC first: they travel with the game folder.

## What the download contains

- **The launcher program.** Packed inside it are:
  - **The translated game code:** C source files generated from the game program and compiled on your computer.
  - **The runtime those sources run on:** C sources for memory, threads, files, graphics (Vulkan), sound and movies.
  - **FFmpeg's libraries** (libavformat, libavcodec, libswresample, libavutil; LGPL 2.1 or later), which the game is linked with to play the movies.
  - **For the Cross-Compile tab:** Linux ARM64's system headers and libraries (from Ubuntu's packages) and FFmpeg's libraries for Linux ARM64.
  - **On Windows, the movie converter:** a 32-bit Windows program.
  - **On Windows, the FFmpeg program it encodes with** (`ffmpeg.exe`, GPL 3). It's a separate program; see `THIRD_PARTY_LICENSES.txt`.
- **`THIRD_PARTY_LICENSES.txt`:** the licenses of the libraries and fonts in the launcher, and of FFmpeg, with where to get its source and how to use your own build of it.

## Building the launcher

The launcher's sources are in [`launcher_src/`](launcher_src/). It's written in [Odin](https://odin-lang.org/) and is built inside the main decompilation project, because the bundle it carries (the translated code, the runtime and the tools) comes from that project's build. See [`launcher_src/README.md`](launcher_src/README.md).
