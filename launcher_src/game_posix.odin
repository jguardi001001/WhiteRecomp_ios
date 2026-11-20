#+build linux, darwin
package launcher

import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

// Starts the built game in its folder (its output: the launcher's); game_running until it ends.
start_game :: proc(exe, dir: string) -> bool {
	// (an AppImage opens itself through FUSE; without it, APPIMAGE_EXTRACT_AND_RUN has it unpack itself to /tmp first)
	env: []string
	if strings.has_suffix(exe, ".AppImage") && !os.exists("/dev/fuse") {
		if cur, eerr := os.environ(context.temp_allocator); eerr == nil {
			e := make([dynamic]string, context.temp_allocator)
			append(&e, ..cur)
			append(&e, "APPIMAGE_EXTRACT_AND_RUN=1")
			env = e[:]
		}
	}
	p, err := os.process_start({command = {exe}, working_dir = dir, env = env})
	if err != nil {return false}
	sync.atomic_store(&game_running, true)
	thread.create_and_start_with_poly_data(p, proc(p: os.Process) {
		_, _ = os.process_wait(p)
		sync.atomic_store(&game_running, false)
	}, self_cleanup = true)
	return true
}
registry_steam_path :: proc() -> string {return ""}

// a web page in the player's browser
open_url :: proc(url: string) {
	when ODIN_OS == .Darwin {cmd := []string{"/usr/bin/open", url}} else {cmd := []string{"xdg-open", url}}
	if c, r, ok := child_start(cmd, ""); ok {_ = c; _ = r} // (not waited for)
}
