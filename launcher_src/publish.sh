#!/bin/sh
# launcher/publish.sh [REPO]               (WSL) the sources into the launcher's git repo
# launcher/publish.sh release TAG [REPO]   (WSL; after launcher/build.sh all) a GitHub release of the launchers
#                                          (REPLACE=1: every earlier release and its tag deleted first)
# launcher/publish.sh macos TAG            (WSL) the macOS launcher again for release TAG (after a failed run)
# launcher/publish.sh update TAG [REPO]    (WSL; after launcher/build.sh for all four) release TAG's launchers replaced by
#                                          the ones in build/, its tag moved to the commit pushed last (origin/main),
#                                          and the macOS launcher built again for it
# The repo (default C:\Users\psivstar\Documents\proj\WhiteRecomp; on GitHub ps4star/WhiteRecomp) holds:
#   README.md                              launcher/release/README.md (GitHub's page)
#   THIRD_PARTY_LICENSES.txt               launcher/release/ (CRLF)
#   launcher_src/                          the launcher's sources: launcher/ (without its bundle.bin) and shared/ (the
#                                          iv_* libraries) as launcher_src/shared/
# The launchers themselves are not in the repo but on its GitHub Releases: `release TAG` makes release TAG at the
# commit pushed last (origin/main: commit and push first) and uploads build/WhiteRecompLauncher_windows.exe,
# build/WhiteRecompLauncher_linux and build/WhiteRecompLauncher_linux_arm64 (launcher/build.sh linux_arm64) to it,
# signed in through Windows Git's credential manager (ps4star). With build/bundle_macos.bin (launcher/build.sh macos)
# it also uploads that and starts the repo's "macOS launcher" workflow (.github/workflows/macos-launcher.yml, from
# launcher/release/macos-launcher.yml): GitHub's Mac runner builds WhiteRecompLauncher_macos.zip, adds it to the
# release and deletes bundle_macos.bin from it (a few minutes later: the repo's Actions tab).
# Each launcher builds the game beside itself (WhiteRecomp(.exe) and WhiteRecomp.cfg: the repo's .gitignore).
# The sources step does not commit: git status / git commit in the repo.
set -eu
cd "$(dirname "$0")/.."
GH_REPO=ps4star/WhiteRecomp
WINGIT="/mnt/c/Program Files/Git/cmd/git.exe"
# no_sources REPO: stops if the repo has (tracked, or about to be) any C source or the bundle. The translated game code
# is only ever shipped inside the launcher executables (embedded bundle.bin), never as files
no_sources() {
	bad=$(cd "$1" && { "$WINGIT" ls-files; "$WINGIT" ls-files --others --exclude-standard; } | tr -d '\r' |
		grep -iE '\.(c|h|cc|cpp|hpp|inc)$|(^|/)bundle\.bin$|(^|/)page_[0-9a-f]+\.|(^|/)ffxiiiimg[^/]*\.exe$|(^|/)bink2w32\.dll$|\.wmp$' || true)
	[ -z "$bad" ] || { echo "publish: $1 has source files that must not be published:"; echo "$bad" | head -20; exit 1; }
}
gh_token() {
	TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | "$WINGIT" credential fill | sed -n 's/^password=//p')
	[ -n "$TOKEN" ] || { echo "publish: not signed in to GitHub"; exit 1; }
}
# macos_start TAG RELEASE_ID: build/bundle_macos.bin onto the release, and the macOS workflow started for it
macos_start() {
	[ -f build/bundle_macos.bin ] || { echo "publish: no build/bundle_macos.bin (launcher/build.sh macos): no macOS launcher"; return 0; }
	# (one left on the release by an earlier, failed run: replaced)
	A=$(curl -s -H "Authorization: Bearer $TOKEN" "https://api.github.com/repos/$GH_REPO/releases/$2/assets?per_page=100" |
		tr -d '\n ' | grep -o '"url":"[^"]*/assets/[0-9]*","id":[0-9]*,"node_id":"[^"]*","name":"bundle_macos.bin"' | sed 's/^"url":"\([^"]*\)".*/\1/')
	[ -z "$A" ] || curl -s -o /dev/null -X DELETE -H "Authorization: Bearer $TOKEN" "$A"
	CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/octet-stream" \
		--data-binary @build/bundle_macos.bin "https://uploads.github.com/repos/$GH_REPO/releases/$2/assets?name=bundle_macos.bin")
	[ "$CODE" = 201 ] || { echo "publish: uploading bundle_macos.bin failed ($CODE)"; exit 1; }
	CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
		"https://api.github.com/repos/$GH_REPO/actions/workflows/macos-launcher.yml/dispatches" -d "{\"ref\":\"main\",\"inputs\":{\"tag\":\"$1\"}}")
	[ "$CODE" = 204 ] || { echo "publish: starting the macOS workflow failed ($CODE): is .github/workflows/macos-launcher.yml pushed?"; exit 1; }
	echo "macOS launcher: building on GitHub (https://github.com/$GH_REPO/actions); it adds WhiteRecompLauncher_macos.zip to $1"
}
# asset_url RELEASE_ID NAME: the API URL of the release's asset NAME ("" if it has none)
asset_url() {
	curl -s -H "Authorization: Bearer $TOKEN" "https://api.github.com/repos/$GH_REPO/releases/$1/assets?per_page=100" |
		tr -d '\n ' | grep -o '"url":"[^"]*/assets/[0-9]*","id":[0-9]*,"node_id":"[^"]*","name":"'"$2"'"' | sed 's/^"url":"\([^"]*\)".*/\1/' | head -1
}
if [ "${1:-}" = update ]; then
	TAG=${2:?usage: launcher/publish.sh update TAG [REPO]}
	REPO=${3:-/mnt/c/Users/psivstar/Documents/proj/WhiteRecomp}
	for f in build/WhiteRecompLauncher_windows.exe build/WhiteRecompLauncher_linux build/WhiteRecompLauncher_linux_arm64; do
		[ -f "$f" ] || { echo "publish: $f is missing (launcher/build.sh windows / linux / linux_arm64)"; exit 1; }
	done
	no_sources "$REPO"
	gh_token
	ID=$(curl -s -H "Authorization: Bearer $TOKEN" "https://api.github.com/repos/$GH_REPO/releases/tags/$TAG" | sed -n 's/^  "id": \([0-9]*\),$/\1/p' | head -1)
	[ -n "$ID" ] || { echo "publish: no release $TAG"; exit 1; }
	# the tag to the sources these launchers were built from
	SHA=$(cd "$REPO" && "$WINGIT" rev-parse origin/main | tr -d '\r')
	CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
		"https://api.github.com/repos/$GH_REPO/git/refs/tags/$TAG" -d "{\"sha\":\"$SHA\",\"force\":true}")
	[ "$CODE" = 200 ] || { echo "publish: moving tag $TAG to $SHA failed ($CODE)"; exit 1; }
	echo "tag $TAG -> $SHA"
	# each launcher: the new one uploaded under a temporary name, the old one deleted, the new one renamed (the
	# download is missing only between those two calls)
	for f in build/WhiteRecompLauncher_windows.exe build/WhiteRecompLauncher_linux build/WhiteRecompLauncher_linux_arm64; do
		n=$(basename "$f")
		old=$(asset_url "$ID" "$n.new"); [ -z "$old" ] || curl -s -o /dev/null -X DELETE -H "Authorization: Bearer $TOKEN" "$old"
		OUT=$(mktemp)
		CODE=$(curl -s -o "$OUT" -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/octet-stream" \
			--data-binary "@$f" "https://uploads.github.com/repos/$GH_REPO/releases/$ID/assets?name=$n.new")
		[ "$CODE" = 201 ] || { echo "publish: uploading $n failed ($CODE)"; rm -f "$OUT"; exit 1; }
		new=$(tr -d '\n ' < "$OUT" | grep -o '"url":"[^"]*/assets/[0-9]*"' | head -1 | sed 's/^"url":"\(.*\)"$/\1/')
		rm -f "$OUT"
		old=$(asset_url "$ID" "$n"); [ -z "$old" ] || curl -s -o /dev/null -X DELETE -H "Authorization: Bearer $TOKEN" "$old"
		CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" "$new" -d "{\"name\":\"$n\"}")
		[ "$CODE" = 200 ] || { echo "publish: renaming the new $n failed ($CODE): it is on the release as $n.new"; exit 1; }
		echo "replaced $n"
	done
	macos_start "$TAG" "$ID"
	echo "https://github.com/$GH_REPO/releases/tag/$TAG"
	exit 0
fi
if [ "${1:-}" = macos ]; then
	TAG=${2:?usage: launcher/publish.sh macos TAG}
	gh_token
	ID=$(curl -s -H "Authorization: Bearer $TOKEN" "https://api.github.com/repos/$GH_REPO/releases/tags/$TAG" | sed -n 's/^  "id": \([0-9]*\),$/\1/p' | head -1)
	[ -n "$ID" ] || { echo "publish: no release $TAG"; exit 1; }
	macos_start "$TAG" "$ID"
	exit 0
fi
if [ "${1:-}" = release ]; then
	TAG=${2:?usage: launcher/publish.sh release TAG [REPO]}
	REPO=${3:-/mnt/c/Users/psivstar/Documents/proj/WhiteRecomp}
	for f in build/WhiteRecompLauncher_windows.exe build/WhiteRecompLauncher_linux build/WhiteRecompLauncher_linux_arm64; do
		[ -f "$f" ] || { echo "publish: $f is missing (launcher/build.sh all, launcher/build.sh linux_arm64)"; exit 1; }
	done
	no_sources "$REPO"
	gh_token
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
		-d "{\"tag_name\":\"$TAG\",\"target_commitish\":\"$SHA\",\"name\":\"WhiteRecomp $TAG\",\"body\":\"Download the launcher for your system: WhiteRecompLauncher_windows.exe (Windows) or WhiteRecompLauncher_linux (Linux x86-64) or WhiteRecompLauncher_linux_arm64 (Linux ARM64; chmod +x either) or WhiteRecompLauncher_macos.zip (macOS, Apple silicon or Intel; experimental, not signed: right-click the app and choose Open the first time). Put it in a folder of its own: Build makes the game beside it. See README.md.\"}")
	[ "$CODE" = 201 ] || { echo "publish: creating release $TAG failed ($CODE):"; cat "$OUT"; rm -f "$OUT"; exit 1; }
	ID=$(sed -n 's/^  "id": \([0-9]*\),$/\1/p' "$OUT" | head -1)
	rm -f "$OUT"
	for f in build/WhiteRecompLauncher_windows.exe build/WhiteRecompLauncher_linux build/WhiteRecompLauncher_linux_arm64; do
		n=$(basename "$f")
		CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/octet-stream" \
			--data-binary "@$f" "https://uploads.github.com/repos/$GH_REPO/releases/$ID/assets?name=$n")
		[ "$CODE" = 201 ] || { echo "publish: uploading $n failed ($CODE)"; exit 1; }
		echo "uploaded $n"
	done
	macos_start "$TAG" "$ID"
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
mkdir -p "$REPO/.github/workflows"
cp launcher/release/macos-launcher.yml "$REPO/.github/workflows/macos-launcher.yml"
no_sources "$REPO"
cat > "$REPO/launcher_src/README.md" <<'MD'
# WhiteRecomp launcher sources

> **Playing the game? You don't need anything in this folder.** Download the launcher for your system from the
> [Releases page](https://github.com/ps4star/WhiteRecomp/releases) (Linux ARM64, e.g. a Raspberry Pi:
> `WhiteRecompLauncher_linux_arm64`), run it, and press **Build**: that compiles the game on your own computer.
> The scripts here build the launchers themselves, on the maintainer's Windows PC (WSL); they cannot run elsewhere.

The launcher (Odin): `*.odin` here, with the `iv_*` libraries of `shared/` as the `shared` collection.

It is built inside the ff13decomp2 project (it lives there as `launcher/`), because what the launcher
carries -- its `bundle.bin`: the translated game code, the runtime, FFmpeg's libraries and the movie
converter -- comes from that project's build:

    sh launcher/build.sh all      # build/WhiteRecompLauncher_windows.exe and build/WhiteRecompLauncher_linux
    sh launcher/build.sh linux_arm64   # build/WhiteRecompLauncher_linux_arm64
    sh launcher/publish.sh        # copies these sources into this repo
    sh launcher/publish.sh release vX.Y.Z   # (after committing and pushing) uploads the launchers to a GitHub release

`bundle.bin` is not in this repo (it is made per target by `tools/bundle`, and is embedded in the launchers).
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
/WhiteRecompLauncher_linux_arm64
# made by build.sh, embedded in the launchers; never C sources (launcher/publish.sh refuses them)
bundle.bin
*.o
*.c
*.h
# local test builds of the launchers (not published)
/builds/
# the game's own files put here for testing (never published: publish.sh refuses them)
/ffxiiiimg*.exe
bink2w32.dll
*.wmp
GI
cat > "$REPO/.gitattributes" <<'GA'
*.exe binary
/WhiteRecompLauncher_linux binary
/WhiteRecompLauncher_linux_arm64 binary
*.ttf binary
*.sh text eol=lf
*.odin text eol=lf
GA
ls -la "$REPO"
