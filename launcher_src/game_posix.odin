#+build linux, darwin
package launcher

registry_steam_path :: proc() -> string {return ""}

// a web page in the player's browser
open_url :: proc(url: string) {
	when ODIN_OS == .Darwin {cmd := []string{"/usr/bin/open", url}} else {cmd := []string{"xdg-open", url}}
	if c, r, ok := child_start(cmd, ""); ok {_ = c; _ = r} // (not waited for)
}
