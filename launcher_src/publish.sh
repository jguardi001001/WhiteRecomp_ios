#!/bin/sh
# launcher/publish.sh [REPO]   (WSL; after launcher/build.sh all)
# Copies the launcher into its git repo (default C:\Users\psivstar\Documents\proj\WhiteRecomp), which holds:
#   WhiteRecompLauncher.exe, WhiteRecompLauncher   the Windows and Linux launchers (build/)
#   README.txt, THIRD_PARTY_LICENSES.txt            launcher/release/ (CRLF)
#   launcher_src/                                   the launcher's sources: launcher/ (without its bundle.bin) and
#                                                   shared/ (the iv_* libraries) as launcher_src/shared/
# Each launcher builds the game beside itself (WhiteRecomp(.exe) and WhiteRecomp.cfg: the repo's .gitignore).
# It does not commit: git status / git commit in the repo.
set -eu
cd "$(dirname "$0")/.."
REPO=${1:-/mnt/c/Users/psivstar/Documents/proj/WhiteRecomp}
for f in build/WhiteRecompLauncher.exe build/WhiteRecompLauncher; do
	[ -f "$f" ] || { echo "publish: $f is missing (launcher/build.sh all)"; exit 1; }
done
mkdir -p "$REPO/launcher_src"
cp build/WhiteRecompLauncher.exe build/WhiteRecompLauncher "$REPO/"
for f in README.txt THIRD_PARTY_LICENSES.txt; do sed 's/\r*$/\r/' "launcher/release/$f" > "$REPO/$f"; done
rsync -a --delete --exclude bundle.bin --exclude shared --exclude README.md launcher/ "$REPO/launcher_src/"
rsync -a --delete --exclude ols.json shared/ "$REPO/launcher_src/shared/"
cat > "$REPO/launcher_src/README.md" <<'MD'
# WhiteRecomp launcher sources

The launcher (Odin): `*.odin` here, with the `iv_*` libraries of `shared/` as the `shared` collection.

It is built inside the ff13decomp2 project (it lives there as `launcher/`), because what the launcher
carries -- its `bundle.bin`: the translated game code, the runtime, FFmpeg's libraries and the movie
converter -- comes from that project's build:

    sh launcher/build.sh all      # build/WhiteRecompLauncher.exe and build/WhiteRecompLauncher
    sh launcher/publish.sh        # copies them, and these sources, into this repo

`bundle.bin` is not in this repo (it is made per target by `ff bundle`, and is embedded in the launchers).
MD
cat > "$REPO/.gitignore" <<'GI'
# what the launcher makes beside itself (Build)
/WhiteRecomp.exe
/WhiteRecomp
/WhiteRecomp.cfg
# made by build.sh, embedded in the launchers
bundle.bin
*.o
GI
cat > "$REPO/.gitattributes" <<'GA'
*.exe binary
/WhiteRecompLauncher binary
*.ttf binary
*.sh text eol=lf
*.odin text eol=lf
GA
ls -la "$REPO"
