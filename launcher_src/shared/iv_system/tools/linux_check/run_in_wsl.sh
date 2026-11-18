#!/bin/bash
# Runs the Linux (Wayland) tests of iv_system from a Windows machine, with WSL for the compositor.
#
#   bash run_in_wsl.sh platform  iv_system/platform:platform_tests_linux.odin
#   bash run_in_wsl.sh vulkan    iv_system/ren/vulkan:ren_vulkan_test.odin
#   bash run_in_wsl.sh hello     example iv_system/examples/hello -frames 120
#
# Why this way: `odin test` cannot link a Linux test runner when cross-compiling from Windows, but a normal program can be
# compiled to objects (-build-mode:obj) and linked by gcc in WSL. So gen_harness.py makes a small `main` that runs the
# @(test) procedures of the given package files one after the other (counting log errors as failures), and this script
# builds it, links it and runs it against a headless weston (no screen needed, and it works in WSL1, which has no WSLg).
#
# Needed once in the WSL distro (default "Ubuntu", or set WSL_DISTRO):
#   apt-get install gcc libc6-dev libwayland-dev weston        (libvulkan + mesa's lavapipe for the Vulkan tests)
#
# Env: SHARED (the shared folder, Windows style, default: three folders above this file), WORK (scratch folder).
set -e
here="$(cd "$(dirname "$0")" && pwd)"
SHARED="${SHARED:-$(cd "$here/../../.." && (pwd -W 2>/dev/null || pwd))}"
WORK="${WORK:-$TEMP/iv_system_linux_check}"
DISTRO="${WSL_DISTRO:-Ubuntu}"
name="$1"; shift
dir="$WORK/$name"
rm -rf "$dir"; mkdir -p "$dir/src" "$dir/obj"

if [ "$1" = "example" ]; then
    pkg="$2"; shift 2
    odin build "$SHARED/$pkg" -target:linux_amd64 -build-mode:obj -collection:shared="$SHARED" -out:"$dir/obj/h"
    args="$*"
else
    python "$here/gen_harness.py" "$dir/src" "$@"
    odin build "$dir/src" -target:linux_amd64 -build-mode:obj -collection:shared="$SHARED" -debug -out:"$dir/obj/h"
    args=""
fi

# the same folder as WSL sees it: C:/x/y -> /mnt/c/x/y
wslpath() { echo "$1" | sed -E 's#^([A-Za-z]):#/mnt/\L\1#; s#\\#/#g'; }
obj="$(wslpath "$dir/obj")"
MSYS_NO_PATHCONV=1 wsl.exe -d "$DISTRO" -- bash -c '
export XDG_RUNTIME_DIR=/tmp/xdg; mkdir -p $XDG_RUNTIME_DIR; chmod 700 $XDG_RUNTIME_DIR
if ! pgrep -x weston >/dev/null; then
  rm -f $XDG_RUNTIME_DIR/wayland-test*
  (weston --backend=headless --socket=wayland-test --width=1024 --height=768 --idle-time=0 >/tmp/weston.log 2>&1 &)
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -S $XDG_RUNTIME_DIR/wayland-test ] && break; sleep 0.5; done
fi
export WAYLAND_DISPLAY=wayland-test
cd "'"$obj"'" && gcc -no-pie *.o -o h -lwayland-client -lm -ldl -lpthread && ./h '"$args" 2>&1 | tr -d '\0'
