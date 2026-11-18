#!/bin/sh
# launcher/publish.sh [REPO]               (WSL) the sources into the launcher's git repo
# launcher/publish.sh release TAG [REPO]   (WSL; after launcher/build.sh all) a GitHub release of the launchers
#                                          (REPLACE=1: every earlier release and its tag deleted first)
# The repo (default C:\Users\psivstar\Documents\proj\WhiteRecomp; on GitHub ps4star/WhiteRecomp) holds:
#   README.md                              launcher/release/README.md (GitHub's page)
#   THIRD_PARTY_LICENSES.txt               launcher/release/ (CRLF)
#   launcher_src/                          the launcher's sources: launcher/ (without its bundle.bin) and shared/ (the
#                                          iv_* libraries) as launcher_src/shared/
# The launchers themselves are not in the repo but on its GitHub Releases: `release TAG` makes release TAG at the
# commit pushed last (origin/main: commit and push first) and uploads build/WhiteRecompLauncher_windows.exe and
# build/WhiteRecompLauncher_linux to it, signed in through Windows Git's credential manager (ps4star).
# Each launcher builds the game beside itself (WhiteRecomp(.exe) and WhiteRecomp.cfg: the repo's .gitignore).
# The sources step does not commit: git status / git commit in the repo.
set -eu
cd "$(dirname "$0")/.."
GH_REPO=ps4star/WhiteRecomp
WINGIT="/mnt/c/Program Files/Git/cmd/git.exe"
if [ "${1:-}" = release ]; then
	TAG=${2:?usage: launcher/publish.sh release TAG [REPO]}
	REPO=${3:-/mnt/c/Users/psivstar/Documents/proj/WhiteRecomp}
	for f in build/WhiteRecompLauncher_windows.exe build/WhiteRecompLauncher_linux; do
		[ -f "$f" ] || { echo "publish: $f is missing (launcher/build.sh all)"; exit 1; }
	done
	TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | "$WINGIT" credential fill | sed -n 's/^password=//p')
	[ -n "$TOKEN" ] || { echo "publish: not signed in to GitHub"; exit 1; }
	SHA=$(cd "$REPO" && "$WINGIT" rev-parse origin/main | tr -d '\r')
	if [ "${REPLACE:-0}" = 1 ]; then # REPLACE=1: every earlier release and its tag deleted first
		curl -s -H "Authorization: Bearer $TOKEN" "https://api.github.com/repos/$GH_REPO/releases?per_page=100" |
			sed -n 's/^    "id": \([0-9]*\),$/\1/p; s/^    "tag_name": "\(.*\)",$/T \1/p' | while read -r x y; do
			if [ "$x" = T ]; then
				curl -s -o /dev/null -X DELETE -H "Authorization: Bearer $TOKEN" "https://api.github.com/repos/$GH_REPO/git/refs/tags/$y"
				echo "deleted tag $y"
			else
				curl -s -o /dev/null -X DELETE -H "Authorization: Bearer $TOKEN" "https://api.github.com/repos/$GH_REPO/releases/$x"
				echo "deleted release $x"
			fi
		done
		(cd "$REPO" && "$WINGIT" tag -l | tr -d '\r' | xargs -r "$WINGIT" tag -d > /dev/null)
	fi
	OUT=$(mktemp)
	CODE=$(curl -s -o "$OUT" -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
		"https://api.github.com/repos/$GH_REPO/releases" \
		-d "{\"tag_name\":\"$TAG\",\"target_commitish\":\"$SHA\",\"name\":\"WhiteRecomp $TAG\",\"body\":\"Download the launcher for your system: WhiteRecompLauncher_windows.exe (Windows) or WhiteRecompLauncher_linux (Linux x86-64; chmod +x it). Put it in a folder of its own: Build makes the game beside it. See README.md.\"}")
	[ "$CODE" = 201 ] || { echo "publish: creating release $TAG failed ($CODE):"; cat "$OUT"; rm -f "$OUT"; exit 1; }
	ID=$(sed -n 's/^  "id": \([0-9]*\),$/\1/p' "$OUT" | head -1)
	rm -f "$OUT"
	for f in build/WhiteRecompLauncher_windows.exe build/WhiteRecompLauncher_linux; do
		n=$(basename "$f")
		CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/octet-stream" \
			--data-binary "@$f" "https://uploads.github.com/repos/$GH_REPO/releases/$ID/assets?name=$n")
		[ "$CODE" = 201 ] || { echo "publish: uploading $n failed ($CODE)"; exit 1; }
		echo "uploaded $n"
	done
	echo "https://github.com/$GH_REPO/releases/tag/$TAG"
	exit 0
fi
REPO=${1:-/mnt/c/Users/psivstar/Documents/proj/WhiteRecomp}
mkdir -p "$REPO/launcher_src"
cp launcher/release/README.md "$REPO/README.md"
rm -f "$REPO/README.txt" # (the plain-text one before README.md)
sed 's/\r*$/\r/' launcher/release/THIRD_PARTY_LICENSES.txt > "$REPO/THIRD_PARTY_LICENSES.txt"
rsync -a --delete --exclude bundle.bin --exclude shared --exclude README.md launcher/ "$REPO/launcher_src/"
rsync -a --delete --exclude ols.json shared/ "$REPO/launcher_src/shared/"
cat > "$REPO/launcher_src/README.md" <<'MD'
# WhiteRecomp launcher sources

The launcher (Odin): `*.odin` here, with the `iv_*` libraries of `shared/` as the `shared` collection.

It is built inside the ff13decomp2 project (it lives there as `launcher/`), because what the launcher
carries -- its `bundle.bin`: the translated game code, the runtime, FFmpeg's libraries and the movie
converter -- comes from that project's build:

    sh launcher/build.sh all      # build/WhiteRecompLauncher_windows.exe and build/WhiteRecompLauncher_linux
    sh launcher/publish.sh        # copies these sources into this repo
    sh launcher/publish.sh release vX.Y.Z   # (after committing and pushing) uploads the launchers to a GitHub release

`bundle.bin` is not in this repo (it is made per target by `ff bundle`, and is embedded in the launchers).
The launchers are on the repo's GitHub Releases, not in the repo.
MD
cat > "$REPO/.gitignore" <<'GI'
# what the launcher makes beside itself (Build)
/WhiteRecomp.exe
/WhiteRecomp
/WhiteRecomp.cfg
# what the game writes in the folder it runs from (its Vulkan pipeline cache)
/vk_pipelines.bin
# the launchers: on GitHub Releases (launcher/publish.sh release)
/WhiteRecompLauncher_windows.exe
/WhiteRecompLauncher_linux
# made by build.sh, embedded in the launchers
bundle.bin
*.o
GI
cat > "$REPO/.gitattributes" <<'GA'
*.exe binary
/WhiteRecompLauncher_linux binary
*.ttf binary
*.sh text eol=lf
*.odin text eol=lf
GA
ls -la "$REPO"
