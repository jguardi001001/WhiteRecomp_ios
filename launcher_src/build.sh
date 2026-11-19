#!/bin/sh
# launcher/build.sh [windows|linux|linux_arm64|all] [odin build flags]   (WSL; default windows; all: windows and linux)
# Builds the launcher: build/WhiteRecompLauncher_windows.exe (Windows), build/WhiteRecompLauncher_linux (Linux x86-64),
# build/WhiteRecompLauncher_linux_arm64 (Linux ARM64: builds and runs the game on the ARM64 machine itself).
#   1. packs what it carries into its bundle.bin (ff bundle): the translated code (build/xrc_gen: run
#      tools/xrc_build.sh first), the runtime (src/runtime), xrc.h, the Vulkan headers (third_party/vulkan), the
#      profile for Profile-Guided Optimization (build/pgo/ff13.profdata: tools/xrc_build.sh XRC_PGO says how), FFmpeg's
#      static libraries for the target with their headers and license (third_party/ffmpeg: the game links them, for
#      the movies) and the movie converter (build/bink2mp4.exe: tools/bink2mp4/build.sh); Windows also the ffmpeg.exe it
#      encodes with (third_party/ffmpeg_exe: a static GPL build, run as its own program). Both also carry what the
#      Cross-Compile tab (cross.odin) builds for Linux ARM64 with: its system files (build/arm64_tools/sysroot_min:
#      tools/arm64_toolchain.sh) and its FFmpeg (third_party/ffmpeg/lib/linux_arm64), as cross/linux_arm64/. Each
#      target has its own bundle (their FFmpeg libraries differ), kept in its staging folder.
#   2. odin build, with the iv_* libraries of shared/ as the `shared` collection. odin.exe cannot build on a
#      \\wsl.localhost path, so the packages are staged under the Windows %TEMP% (like tools/ff/build.sh).
#      Linux: odin.exe cross-compiles an object, linked here by gcc with Odin's stb libraries (built for Linux once:
#      vendor/stb/src/build_stb.sh unix) and libwayland-client. Linux ARM64: the same for -target:linux_arm64, linked
#      by clang with build/arm64_tools (tools/arm64_toolchain.sh: the sysroot has libwayland-client), Odin's stb
#      compiled for ARM64 into the staging folder.
# Env: ODIN (odin.exe), LAUNCHER_NO_BUNDLE=1 keeps the target's existing bundle.bin.
# The launcher's git repo (WhiteRecomp): launcher/publish.sh.
set -u
cd "$(dirname "$0")/.." || exit 1
ODIN=${ODIN:-/mnt/c/Users/psivstar/Documents/git/odin/odin.exe}
ODIN_ROOT=$(dirname "$ODIN")
TARGETS=windows
case "${1:-}" in
windows | linux | linux_arm64) TARGETS=$1; shift ;;
all) TARGETS="windows linux"; shift ;;
esac
M() { wslpath -m "$1"; }
WTEMP=$(cmd.exe /c 'echo %TEMP%' 2>/dev/null | tr -d '\r')

for T in $TARGETS; do
	case $T in
	windows) FFP=windows_amd64; STAGE="$(wslpath "$WTEMP")/ff13_launcher_build"; FFEXE=third_party/ffmpeg_exe/windows_amd64 ;;
	linux) FFP=linux_amd64; STAGE="$(wslpath "$WTEMP")/ff13_launcher_linux"; FFEXE="" ;;
	linux_arm64) FFP=linux_arm64; STAGE="$(wslpath "$WTEMP")/ff13_launcher_linux_arm64"; FFEXE="" ;;
	esac
	mkdir -p "$STAGE/launcher"
	rsync -a --delete --exclude bundle.bin launcher/ "$STAGE/launcher/" || exit 1
	rsync -a --delete shared/ "$STAGE/shared/" || exit 1
	if [ -z "${LAUNCHER_NO_BUNDLE:-}" ] || [ ! -f "$STAGE/launcher/bundle.bin" ]; then
		for f in build/xrc_gen/xrc_table.c build/xrc_gen/match/match_table.c build/bink2mp4.exe third_party/ffmpeg/lib/$FFP/libavcodec.a build/pgo/ff13.profdata \
			build/arm64_tools/sysroot_min/usr/lib/aarch64-linux-gnu/libc.so third_party/ffmpeg/lib/linux_arm64/libavcodec.a; do
			[ -f "$f" ] || { echo "launcher: $f is missing (build it first)"; exit 1; }
		done
		./build/ff.exe bundle --out "$(M "$STAGE/launcher/bundle.bin")" \
			"$(M build/xrc_gen/src)=gen/src" "$(M build/xrc_gen/xrc_table.c)=gen/xrc_table.c" \
			"$(M build/xrc_gen/match)=gen/match" \
			"$(M src/runtime)=runtime" "$(M src/include/xrc.h)=include/xrc.h" \
			"$(M third_party/ffmpeg/include)=ffmpeg/include" "$(M third_party/ffmpeg/lib/$FFP)=ffmpeg/lib" \
			"$(M third_party/ffmpeg/COPYING.LGPLv2.1.txt)=ffmpeg/COPYING.LGPLv2.1.txt" \
			"$(M third_party/ffmpeg/README.md)=ffmpeg/README.md" \
			"$(M third_party/vulkan/include)=vulkan/include" \
			"$(M build/pgo/ff13.profdata)=pgo/ff13.profdata" \
			"$(M build/bink2mp4.exe)=tools/bink2mp4.exe" \
			"$(M build/arm64_tools/sysroot_min)=cross/linux_arm64/sysroot" \
			"$(M third_party/ffmpeg/lib/linux_arm64)=cross/linux_arm64/ffmpeg/lib" \
			${FFEXE:+"$(M $FFEXE/ffmpeg.exe)=tools/ffmpeg.exe" "$(M $FFEXE/LICENSE)=tools/ffmpeg-LICENSE.txt" "$(M $FFEXE/README.txt)=tools/ffmpeg-README.txt"} || exit 1
	fi
	case $T in
	windows)
		(cd "$STAGE" && "$ODIN" build launcher -out:WhiteRecompLauncher_windows.exe -collection:shared=shared -subsystem:windows -o:speed "$@") || exit 1
		cp "$STAGE/WhiteRecompLauncher_windows.exe" build/WhiteRecompLauncher_windows.exe
		ls -la build/WhiteRecompLauncher_windows.exe
		;;
	linux)
		STB="$ODIN_ROOT/vendor/stb/lib"
		[ -f "$STB/stb_truetype.a" ] || { echo "launcher: $STB has no Linux stb libraries (run vendor/stb/src/build_stb.sh unix there)"; exit 1; }
		rm -f "$STAGE/whiterecomp_linux.o"
		(cd "$STAGE" && "$ODIN" build launcher -out:whiterecomp_linux.o -collection:shared=shared -target:linux_amd64 -build-mode:obj -o:speed "$@") || exit 1
		gcc -o build/WhiteRecompLauncher_linux "$STAGE/whiterecomp_linux.o" "$STB/stb_truetype.a" "$STB/stb_rect_pack.a" "$STB/stb_image.a" \
			-l:libwayland-client.so.0 -lm -ldl -lpthread || exit 1
		ls -la build/WhiteRecompLauncher_linux
		;;
	linux_arm64)
		AT=build/arm64_tools
		[ -f "$AT/sysroot/usr/lib/aarch64-linux-gnu/libwayland-client.so.0" ] || { echo "launcher: no ARM64 sysroot with libwayland-client (run tools/arm64_toolchain.sh)"; exit 1; }
		XCC="clang --target=aarch64-linux-gnu --sysroot=$AT/sysroot"; XLD="$XCC --ld-path=$AT/bin/aarch64-linux-gnu-ld"
		STB="$STAGE/stb"
		if [ ! -f "$STB/stb_image.a" ]; then # (Odin's stb, for ARM64: as vendor/stb/src/build_stb.sh unix)
			mkdir -p "$STB"
			for n in stb_truetype stb_rect_pack stb_image; do
				$XCC -c -Os -fPIC "$ODIN_ROOT/vendor/stb/src/$n.c" -o "$STB/$n.o" && llvm-ar-21 rcs "$STB/$n.a" "$STB/$n.o" || exit 1
			done
		fi
		rm -f "$STAGE/whiterecomp_linux_arm64.o"
		(cd "$STAGE" && "$ODIN" build launcher -out:whiterecomp_linux_arm64.o -collection:shared=shared -target:linux_arm64 -build-mode:obj -o:speed "$@") || exit 1
		$XLD -o build/WhiteRecompLauncher_linux_arm64 "$STAGE/whiterecomp_linux_arm64.o" "$STB/stb_truetype.a" "$STB/stb_rect_pack.a" "$STB/stb_image.a" \
			-l:libwayland-client.so.0 -lm -ldl -lpthread || exit 1
		ls -la build/WhiteRecompLauncher_linux_arm64
		;;
	esac
done
