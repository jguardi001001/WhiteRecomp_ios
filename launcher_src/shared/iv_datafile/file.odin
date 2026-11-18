package iv_datafile

import "core:os"
import "core:strings"

// ---------------------------------------------------------------------------
// Files. A save has to survive the program being stopped half way through writing it: save_file writes the bytes to a file beside the real one and then
// puts it in place, so there is always a whole file (the old one or the new one), never half of a new one.
// ---------------------------------------------------------------------------

// Writes `data` to `path` (the folder is made if it is not there). false if anything went wrong; the file that was there is kept then.
save_file :: proc(path: string, data: []u8) -> bool {
	if dir, ok := parent_dir(path); ok {
		_ = os.make_directory_all(dir)
	}
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if err := os.write_entire_file(tmp, data); err != nil {
		return false
	}
	if os.exists(path) {
		_ = os.remove(path)
	}
	if err := os.rename(tmp, path); err != nil {
		return false
	}
	return true
}

save_text_file :: proc(path: string, text: string) -> bool {
	return save_file(path, transmute([]u8)text)
}

// The bytes of a file (the caller deletes them). A save that was being put in place when the program stopped is found too: if `path` is missing but
// `path.tmp` is there, that is read.
load_file :: proc(path: string, allocator := context.allocator) -> (data: []u8, ok: bool) {
	d, err := os.read_entire_file(path, allocator)
	if err == nil {
		return d, true
	}
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	d, err = os.read_entire_file(tmp, allocator)
	if err == nil {
		return d, true
	}
	return nil, false
}

@(private)
parent_dir :: proc(path: string) -> (dir: string, ok: bool) {
	for i := len(path) - 1; i > 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			return path[:i], true
		}
	}
	return "", false
}
