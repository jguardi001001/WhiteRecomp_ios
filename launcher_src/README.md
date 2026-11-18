# WhiteRecomp launcher sources

The launcher (Odin): `*.odin` here, with the `iv_*` libraries of `shared/` as the `shared` collection.

It is built inside the ff13decomp2 project (it lives there as `launcher/`), because what the launcher
carries -- its `bundle.bin`: the translated game code, the runtime, FFmpeg's libraries and the movie
converter -- comes from that project's build:

    sh launcher/build.sh all      # build/WhiteRecompLauncher_windows.exe and build/WhiteRecompLauncher_linux
    sh launcher/publish.sh        # copies them, and these sources, into this repo

`bundle.bin` is not in this repo (it is made per target by `ff bundle`, and is embedded in the launchers).
