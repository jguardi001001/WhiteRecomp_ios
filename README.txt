WhiteRecomp
===========

Builds a port of FINAL FANTASY XIII on this computer from the sources it carries and your own Steam copy of the game.
It does not contain the game: you need FINAL FANTASY XIII installed from Steam.

What this download contains
  - the launcher program
  - inside it, packed:
      * the translated game code (C source files, generated from the game program, built on this computer)
      * the runtime those sources run on (C source files: memory, threads, files, graphics, sound and movie support)
      * FFmpeg's libraries (libavformat, libavcodec, libswresample, libavutil; LGPL 2.1 or later), which the game is
        linked with to play the movies
      * the movie converter (a 32-bit Windows program: run directly on Windows, under Wine elsewhere)
  - THIRD_PARTY_LICENSES.txt: the licenses of the libraries and fonts in the launcher, and of FFmpeg (with where its
    source is, and how to use your own build of it)

What comes from your computer
  - from your Steam install of FINAL FANTASY XIII: the game program's data (ffxiiiimg.exe, which must be the current
    Steam version), all of the game's files, and its movie decoder (bink2w32.dll, used once to convert the movies)
  - a C compiler, and FFmpeg (the program, with its H.264 encoder) to convert the movies once: the launcher finds them,
    or offers to install them (an install that needs administrator permission asks for it, for that install alone).
    Playing the movies needs no FFmpeg program: the game has FFmpeg's libraries built in

Using it
  1. Start the launcher. It finds the game through Steam (or press "Browse…").
  2. Install what it says is missing.
  3. Options (optional): the compiler, optimization, audio, FPS, graphics driver and cutscene choices.
  4. Build: compiles the game (a few minutes) into WhiteRecomp.exe (Linux: WhiteRecomp) beside the launcher, with
     WhiteRecomp.cfg (where your game and saves are). Start WhiteRecomp.exe to play.
  5. Convert Movies: converts the game's movies to MP4, once (about an hour; it can be stopped and continued).
  6. Discard Movies (optional): frees about 40 GB by cutting the original movie files down once their MP4s exist.
