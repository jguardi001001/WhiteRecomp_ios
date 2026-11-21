#+build linux, darwin
package launcher

// When the launcher's window cannot be made (Linux, macOS): the reason shown in a dialog of the desktop's own (zenity,
// kdialog, yad, xmessage; macOS osascript), since a launcher started from a file manager has no terminal for it. On
// Linux, when the reason is that SDL2 is not installed (a fresh Xubuntu, for one), the dialog offers to install it with
// the distribution's package manager (pkexec asks for administrator permission) and the window is then tried again.

import "core:fmt"
import "core:strings"
import "shared:iv_system/platform"

// true when SDL2 was installed and the window should be tried again (platform.window_retry already called); with
// offer_install false (the window failed again after that) only the reason
no_window_help :: proc(offer_install := true) -> bool {
	why := platform.window_error
	when ODIN_OS == .Linux {
		if platform.window_sdl_missing && offer_install {
			pm, cmd := linux_install_cmd("sdl2")
			if cmd != nil && find_program("pkexec") != "" {
				msg := fmt.tprintf("WhiteRecomp needs SDL2 for its window, and SDL2 is not installed.\n\nInstall it now with %s? You will be asked for your password.", pm)
				if !ask_dialog(msg, "Install SDL2") {return false}
				args := make([dynamic]string, context.temp_allocator)
				append(&args, find_program("pkexec"))
				append(&args, ..cmd)
				code := run_quiet(args[:])
				if code != 0 {
					error_dialog(fmt.tprintf("Installing SDL2 failed (%s exited with %d).\n\nInstall it yourself, then start WhiteRecomp again:\n  sudo %s", pm, code, sh_quote(cmd)))
					return false
				}
				platform.window_retry()
				return true
			}
			if cmd != nil {
				why = fmt.tprintf("SDL2 is not installed. Install it, then start WhiteRecomp again:\n  sudo %s", sh_quote(cmd))
			}
		}
	}
	error_dialog(fmt.tprintf("WhiteRecomp could not open its window.\n\n%s", why))
	return false
}

// a yes / no question: true for yes (no dialog program: false)
@(private = "file")
ask_dialog :: proc(msg, yes: string) -> bool {
	when ODIN_OS == .Darwin {
		return run_quiet({"/usr/bin/osascript", "-e", applescript_alert(msg, yes)}) == 0
	} else {
		tools := [][]string {
			{"zenity", "--question", "--title=WhiteRecomp", "--no-wrap", strings.concatenate({"--text=", msg}, context.temp_allocator), strings.concatenate({"--ok-label=", yes}, context.temp_allocator), "--cancel-label=Quit"},
			{"kdialog", "--title", "WhiteRecomp", "--yes-label", yes, "--no-label", "Quit", "--yesno", msg},
			{"yad", "--title=WhiteRecomp", strings.concatenate({"--text=", msg}, context.temp_allocator), strings.concatenate({"--button=", yes, ":0"}, context.temp_allocator), "--button=Quit:1"},
			{"xmessage", "-center", "-buttons", strings.concatenate({yes, ":0,Quit:1"}, context.temp_allocator), msg},
		}
		for t in tools {
			if find_program(t[0]) == "" {continue}
			return run_quiet(t) == 0
		}
		return false
	}
}

@(private = "file")
error_dialog :: proc(msg: string) {
	when ODIN_OS == .Darwin {
		run_quiet({"/usr/bin/osascript", "-e", applescript_alert(msg, "")})
	} else {
		tools := [][]string {
			{"zenity", "--error", "--title=WhiteRecomp", "--no-wrap", strings.concatenate({"--text=", msg}, context.temp_allocator)},
			{"kdialog", "--title", "WhiteRecomp", "--error", msg},
			{"yad", "--title=WhiteRecomp", "--image=dialog-error", strings.concatenate({"--text=", msg}, context.temp_allocator), "--button=OK:0"},
			{"xmessage", "-center", msg},
		}
		for t in tools {
			if find_program(t[0]) == "" {continue}
			run_quiet(t)
			return
		}
	}
}

// (macOS) an alert with OK, or with yes and Quit
@(private = "file")
applescript_alert :: proc(msg, yes: string) -> string {
	q, _ := strings.replace_all(msg, `\`, `\\`, context.temp_allocator)
	q, _ = strings.replace_all(q, `"`, `\"`, context.temp_allocator)
	if yes == "" {return strings.concatenate({`display alert "WhiteRecomp" message "`, q, `"`}, context.temp_allocator)}
	return strings.concatenate({`button returned of (display alert "WhiteRecomp" message "`, q, `" buttons {"Quit", "`, yes, `"} default button "`, yes, `" cancel button "Quit")`}, context.temp_allocator)
}

// runs a program (found in PATH) to the end, its output dropped: its exit code (-1 if it could not start)
@(private = "file")
run_quiet :: proc(cmd: []string) -> int {
	args := make([]string, len(cmd), context.temp_allocator)
	copy(args, cmd)
	if p := find_program(args[0]); p != "" {args[0] = p}
	c, r, ok := child_start(args, "")
	if !ok {return -1}
	buf: [4096]u8
	for child_read(r, buf[:]) > 0 {}
	return child_wait(c, r)
}
