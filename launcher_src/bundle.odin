// The sources the launcher carries: launcher/bundle.bin, made by `ff bundle` (tools/ff/bundle.odin has the format),
// embedded at compile time. What is in it: the translated code (gen/src/page_*.c, gen/xrc_table.c), the runtime
// (runtime/), its header (include/xrc.h) and the movie converter (tools/bink2mp4.exe). Nothing of the game itself:
// its data comes from the player's own ffxiiiimg.exe and install.
package launcher

import "core:compress/deflate"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"

BUNDLE: []u8 = #load("bundle.bin")

Bundle_Entry :: struct {
	path:         string,
	flags:        u32,
	size, packed: u64,
	offset:       u64,
}
bundle_entries: [dynamic]Bundle_Entry

@(private = "file")
le :: proc(b: []u8, o: int, n: int) -> u64 {
	v: u64
	for i in 0 ..< n {v |= u64(b[o + i]) << (8 * uint(i))}
	return v
}

bundle_open :: proc() -> bool {
	b := BUNDLE
	if len(b) < 12 || string(b[:8]) != "FFBUNDL1" {return false}
	n := int(le(b, 8, 4))
	o := 12
	for _ in 0 ..< n {
		pl := int(le(b, o, 2))
		e := Bundle_Entry{path = string(b[o + 2:o + 2 + pl])}
		o += 2 + pl
		e.flags = u32(le(b, o, 4))
		e.size = le(b, o + 4, 8)
		e.packed = le(b, o + 12, 8)
		e.offset = le(b, o + 20, 8)
		o += 28
		append(&bundle_entries, e)
	}
	return true
}

// One file of the bundle, unpacked (in the allocator).
bundle_read :: proc(path: string, allocator := context.allocator) -> (data: []u8, ok: bool) {
	for e in bundle_entries {
		if e.path != path {continue}
		out := make([dynamic]u8, 0, int(e.size), allocator)
		src := BUNDLE[e.offset:e.offset + e.packed]
		if deflate.inflate_raw(&out, src, int(e.size), allocator = allocator) != nil || u64(len(out)) != e.size {return nil, false}
		return out[:], true
	}
	return nil, false
}

// Unpacks every file whose path starts with one of prefixes into dir (keeping its path), on every core. A file that
// is already there with the same contents is left alone (its time stays, so an incremental build keeps its object).
// Returns the number written, or -1 on an error.
bundle_extract :: proc(t: ^Task, dir: string, prefixes: []string) -> int {
	Job :: struct {
		t:        ^Task,
		dir:      string,
		list:     []Bundle_Entry,
		next:     int,
		done:     int,
		written:  int,
		failed:   bool,
		mutex:    sync.Mutex,
		err_path: string,
	}
	sel := make([dynamic]Bundle_Entry, context.temp_allocator)
	for e in bundle_entries {
		for p in prefixes {if strings.has_prefix(e.path, p) {append(&sel, e); break}}
	}
	job := Job{t = t, dir = dir, list = sel[:]}
	worker :: proc(th: ^thread.Thread) {
		j := (^Job)(th.data)
		for !cancelled(j.t) {
			k := sync.atomic_add(&j.next, 1)
			if k >= len(j.list) {return}
			e := j.list[k]
			data, ok := bundle_read(e.path)
			dst := pjoin({j.dir, e.path})
			if ok {
				old, rerr := os.read_entire_file(dst, context.allocator)
				same := rerr == nil && len(old) == len(data) && string(old) == string(data)
				delete(old)
				if !same {
					_ = os.make_directory_all(filepath.dir(dst))
					ok = os.write_entire_file(dst, data) == nil
					when ODIN_OS != .Windows {
						if ok && e.flags & 1 != 0 {_ = os.chmod(dst, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})}
					}
					if ok {sync.atomic_add(&j.written, 1)}
				}
				delete(data)
			}
			if !ok {
				sync.mutex_lock(&j.mutex)
				j.failed = true
				j.err_path = e.path
				sync.mutex_unlock(&j.mutex)
			}
			d := sync.atomic_add(&j.done, 1) + 1
			set_status(j.t, f32(d) / f32(len(j.list)) * 0.1, "Unpacking the sources: %d of %d", d, len(j.list))
			free_all(context.temp_allocator)
		}
	}
	threads := make([dynamic]^thread.Thread, context.temp_allocator)
	for _ in 0 ..< max(1, os.get_processor_core_count()) {
		th := thread.create(worker)
		th.data = &job
		th.init_context = context
		thread.start(th)
		append(&threads, th)
	}
	for th in threads {thread.join(th); thread.destroy(th)}
	if job.failed {
		logf(t, "Could not unpack %s into %s", job.err_path, dir)
		return -1
	}
	return job.written
}
