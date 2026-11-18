#!/bin/sh
# launcher/release.sh   -> dist/ff13-launcher-<platform>-<arch>.(zip | tar.gz)
# Makes the release of the launcher for the system it runs on:
#   WSL (Windows)  build/WhiteRecompLauncher.exe (launcher/build.sh: packs launcher/bundle.bin with ff bundle first)
#                  -> dist/ff13-launcher-windows-x64.zip
#   Linux          odin build (needs launcher/bundle.bin, made on Windows, and Odin's stb libraries built:
#                  vendor/stb/src/build_stb.sh) -> dist/ff13-launcher-linux-x64.tar.gz
#   macOS          odin build for arm64 and amd64, joined with lipo; "WhiteRecomp.app" with Info.plist and MoltenVK
#                  (the launcher draws with Vulkan); signed with the hardened runtime, notarized and stapled
#                  -> dist/ff13-launcher-macos.zip
# Every release holds the launcher (its packed bundle: the translated C sources, the runtime's C sources and the
# Windows movie converter), README.txt and THIRD_PARTY_LICENSES.txt (launcher/release/).
# Env: ODIN (the compiler). macOS: MOLTENVK (path of libMoltenVK.dylib; default from $VULKAN_SDK), MOLTENVK_LICENSE
# (its LICENSE file), MACOS_SIGN_ID ("Developer ID Application: ..."; unset: not signed), NOTARY_PROFILE (a
# `xcrun notarytool store-credentials` profile; unset: not notarized).
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD
REL=launcher/release
mkdir -p dist

case "$(uname -s)" in
Linux)
	if grep -qi microsoft /proc/version 2>/dev/null && [ -z "${RELEASE_NATIVE_LINUX:-}" ]; then
		# WSL: the Windows release (RELEASE_NATIVE_LINUX=1 makes the Linux one here instead)
		sh launcher/build.sh
		D=dist/ff13-launcher-windows-x64
		rm -rf "$D" "$D.zip"
		mkdir -p "$D"
		cp build/WhiteRecompLauncher.exe "$D/"
		cp $REL/README.txt $REL/THIRD_PARTY_LICENSES.txt "$D/"
		sed -i 's/$/\r/' "$D/README.txt" "$D/THIRD_PARTY_LICENSES.txt"
		WD=$(wslpath -w "$ROOT/dist")
		powershell.exe -NoProfile -Command "Compress-Archive -Force -Path '$WD\\ff13-launcher-windows-x64\\*' -DestinationPath '$WD\\ff13-launcher-windows-x64.zip'"
		ls -la "$D.zip"
		exit 0
	fi
	ODIN=${ODIN:-odin}
	[ -f launcher/bundle.bin ] || { echo "launcher/bundle.bin is missing: make it on Windows (launcher/build.sh)"; exit 1; }
	D=dist/ff13-launcher-linux-x64
	rm -rf "$D"
	mkdir -p "$D"
	"$ODIN" build launcher -collection:shared=shared -o:speed -out:"$D/ff13-launcher"
	cp $REL/README.txt $REL/THIRD_PARTY_LICENSES.txt "$D/"
	tar -C dist -czf "$D.tar.gz" ff13-launcher-linux-x64
	ls -la "$D.tar.gz"
	;;
Darwin)
	ODIN=${ODIN:-odin}
	[ -f launcher/bundle.bin ] || { echo "launcher/bundle.bin is missing: make it on Windows (launcher/build.sh)"; exit 1; }
	MVK=${MOLTENVK:-${VULKAN_SDK:-/usr/local}/lib/libMoltenVK.dylib}
	[ -f "$MVK" ] || { echo "MoltenVK not found ($MVK): install the Vulkan SDK or set MOLTENVK"; exit 1; }
	MVK_LICENSE=${MOLTENVK_LICENSE:-${VULKAN_SDK:-/usr/local}/share/doc/MoltenVK/LICENSE}
	[ -f "$MVK_LICENSE" ] || { echo "MoltenVK's LICENSE not found ($MVK_LICENSE): set MOLTENVK_LICENSE"; exit 1; }
	APP="dist/WhiteRecomp.app"
	rm -rf "$APP" dist/ff13-launcher-macos.zip
	mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
	# one program for both kinds of Mac (the game it builds is x86-64 either way: Rosetta 2 on Apple silicon)
	"$ODIN" build launcher -collection:shared=shared -o:speed -target:darwin_arm64 -out:dist/ff13-launcher-arm64
	"$ODIN" build launcher -collection:shared=shared -o:speed -target:darwin_amd64 -out:dist/ff13-launcher-amd64
	lipo -create -output "$APP/Contents/MacOS/ff13-launcher" dist/ff13-launcher-arm64 dist/ff13-launcher-amd64
	rm -f dist/ff13-launcher-arm64 dist/ff13-launcher-amd64
	cp "$MVK" "$APP/Contents/Frameworks/libMoltenVK.dylib"
	cp $REL/Info.plist "$APP/Contents/Info.plist"
	cp $REL/README.txt "$APP/Contents/Resources/"
	{ cat $REL/THIRD_PARTY_LICENSES.txt
	  printf '\n\n--------------------------------------------------------------------------------------------------------------------\n'
	  printf '5. MoltenVK (https://github.com/KhronosGroup/MoltenVK)\n'
	  printf -- '--------------------------------------------------------------------------------------------------------------------\n\n'
	  cat "$MVK_LICENSE"; } > "$APP/Contents/Resources/THIRD_PARTY_LICENSES.txt"
	if [ -n "${MACOS_SIGN_ID:-}" ]; then
		codesign --force --timestamp --options runtime --sign "$MACOS_SIGN_ID" "$APP/Contents/Frameworks/libMoltenVK.dylib"
		codesign --force --timestamp --options runtime --sign "$MACOS_SIGN_ID" "$APP"
		codesign --verify --strict --verbose=2 "$APP"
	else
		echo "MACOS_SIGN_ID not set: the app is not signed (Gatekeeper will block it on other Macs)"
	fi
	ditto -c -k --keepParent "$APP" dist/ff13-launcher-macos.zip
	if [ -n "${MACOS_SIGN_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
		xcrun notarytool submit dist/ff13-launcher-macos.zip --keychain-profile "$NOTARY_PROFILE" --wait
		xcrun stapler staple "$APP"
		rm -f dist/ff13-launcher-macos.zip
		ditto -c -k --keepParent "$APP" dist/ff13-launcher-macos.zip # (again, with the ticket stapled)
	else
		echo "NOTARY_PROFILE not set: not notarized"
	fi
	cp $REL/README.txt $REL/THIRD_PARTY_LICENSES.txt dist/ 2>/dev/null || true
	ls -la dist/ff13-launcher-macos.zip
	;;
*)
	echo "release.sh: run it on Windows (WSL), Linux or macOS"
	exit 1
	;;
esac
