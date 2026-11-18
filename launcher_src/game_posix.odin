#+build linux, darwin
package launcher

import "core:os"
import "core:sync"
import "core:thread"

// Starts the built game in its folder (its output: the launcher's); game_running until it ends.
start_game :: proc(exe, dir: string) -> bool {
	p, err := os.process_start({command = {exe}, working_dir = dir})
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
