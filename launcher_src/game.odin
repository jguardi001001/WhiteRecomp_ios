// Finding the player's FINAL FANTASY XIII (a Steam install) and checking that its ffxiiiimg.exe is the version the
// bundled code was translated from: the same check the game makes when it starts (src/runtime/xrc_rt.c), a FNV-1a 64
// over the data sections, with the ranges and the hash read from the bundled dispatch table (gen/xrc_table.c).
package launcher

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

GAME_FOLDER :: "FINAL FANTASY XIII"

game_exe :: proc(dir: string) -> string {return pjoin({dir, "white_data", "prog", "win", "bin", "ffxiiiimg.exe"}, context.temp_allocator)}
movie_dir :: proc(dir: string) -> string {return pjoin({dir, "white_data", "movie"}, context.temp_allocator)}

is_game_dir :: proc(dir: string) -> bool {return dir != "" && file_exists(game_exe(dir))}

// Steam's install folders (each with steamapps/)
@(private = "file")
steam_roots :: proc() -> [dynamic]string {
	r := make([dynamic]string, context.temp_allocator)
	home := os.get_env("HOME", context.temp_allocator)
	when ODIN_OS == .Windows {
		if p := steam_path_from_registry(); p != "" {append(&r, p)}
		for env in ([]string{"ProgramFiles(x86)", "ProgramFiles"}) {
			if v := os.get_env(env, context.temp_allocator); v != "" {append(&r, pjoin({v, "Steam"}, context.temp_allocator))}
		}
	} else when ODIN_OS == .Darwin {
		append(&r, pjoin({home, "Library", "Application Support", "Steam"}, context.temp_allocator))
	} else {
		append(&r, pjoin({home, ".steam", "steam"}, context.temp_allocator))
		append(&r, pjoin({home, ".local", "share", "Steam"}, context.temp_allocator))
		append(&r, pjoin({home, ".var", "app", "com.valvesoftware.Steam", ".local", "share", "Steam"}, context.temp_allocator))
	}
	return r
}

// Every Steam library: the roots, and the "path" entries of their steamapps/libraryfolders.vdf.
@(private = "file")
steam_libraries :: proc() -> [dynamic]string {
	libs := make([dynamic]string, context.temp_allocator)
	for root in steam_roots() {
		append(&libs, root)
		d, err := os.read_entire_file(pjoin({root, "steamapps", "libraryfolders.vdf"}, context.temp_allocator), context.temp_allocator)
		if err != nil {continue}
		for line in strings.split_lines(string(d), context.temp_allocator) {
			l := strings.trim_space(line)
			if !strings.has_prefix(l, "\"path\"") {continue}
			v := strings.trim_space(l[6:])
			if len(v) < 2 || v[0] != '"' {continue}
			p, _ := strings.replace_all(v[1:len(v) - 1], `\\`, `\`, context.temp_allocator)
			append(&libs, p)
		}
	}
	return libs
}

find_game :: proc() -> string {
	for lib in steam_libraries() {
		d := pjoin({lib, "steamapps", "common", GAME_FOLDER}, context.temp_allocator)
		if is_game_dir(d) {return strings.clone(d)}
	}
	return ""
}

// Whether exe is the version the bundled code needs. why: what is wrong.
check_game_exe :: proc(exe: string) -> (ok: bool, why: string) {
	table, tok := bundle_read("gen/xrc_table.c", context.temp_allocator)
	if !tok {return false, "the launcher's sources are damaged (no dispatch table)"}
	// const XrcRange xrc_hash_ranges[] = {\n\t{0x...u, N},\n...}; ... xrc_data_hash = 0x...ull;
	t := string(table)
	at := strings.index(t, "xrc_hash_ranges[] = {")
	hat := strings.index(t, "xrc_data_hash = 0x")
	if at < 0 || hat < 0 {return false, "the launcher's sources are damaged (no exe check)"}
	want, _ := strconv.parse_u64_of_base(t[hat + 18:hat + 34], 16)
	Range :: struct {va, n: u32}
	ranges := make([dynamic]Range, context.temp_allocator)
	rest := t[at:]
	rest = rest[:strings.index(rest, "};")]
	for line in strings.split_lines(rest, context.temp_allocator) {
		l := strings.trim_space(line)
		if !strings.has_prefix(l, "{0x") {continue}
		va, _ := strconv.parse_u64_of_base(l[3:11], 16)
		comma := strings.index(l, ",")
		n, _ := strconv.parse_u64(strings.trim(l[comma + 1:], " }"))
		append(&ranges, Range{u32(va), u32(n)})
	}
	d, err := os.read_entire_file(exe, context.temp_allocator)
	if err != nil {return false, "it cannot be read"}
	u32le :: proc(d: []u8, o: int) -> u32 {return u32(d[o]) | u32(d[o + 1]) << 8 | u32(d[o + 2]) << 16 | u32(d[o + 3]) << 24}
	if len(d) < 0x400 || d[0] != 'M' || d[1] != 'Z' {return false, "it is not a Windows program"}
	pe := int(u32le(d, 0x3c))
	nsec := int(u32le(d, pe + 6) & 0xffff)
	base := u32le(d, pe + 24 + 28)
	sh := pe + 24 + int(u32le(d, pe + 20) & 0xffff)
	h: u64 = 0xcbf29ce484222325
	for r in ranges {
		// the file offset of the range's address (a range is the start of a section)
		off := -1
		for i in 0 ..< nsec {
			o := sh + 40 * i
			va := base + u32le(d, o + 12)
			if r.va == va {off = int(u32le(d, o + 20))}
		}
		if off < 0 || off + int(r.n) > len(d) {return false, "it is a different version of the game"}
		for b in d[off:off + int(r.n)] {h = (h ~ u64(b)) * 0x100000001b3}
	}
	if h != want {return false, "it is a different version of the game (this launcher needs the Steam release)"}
	return true, ""
}

@(private = "file")
steam_path_from_registry :: proc() -> string {return registry_steam_path()}
