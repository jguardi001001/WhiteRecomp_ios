// The launcher's background work: one task at a time (Build, Convert Movies, Discard Old Movies, a dependency's
// install, the dependency check) on its own thread, with a log and a progress value the window shows while it runs.
// Programs it starts are known to the task, so Cancel can kill them.
package launcher

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"

LOG_MAX :: 2000 // lines kept

Task :: struct {
	name:      string,
	mutex:     sync.Mutex,
	log:       [dynamic]string,
	progress:  f32, // 0..1; < 0: no progress to show
	status:    string, // one line under the progress bar
	running:   bool,
	cancel:    bool,
	failed:    bool,
	children:  [dynamic]Child, // programs running for it (Cancel kills them)
	th:        ^thread.Thread,
	work:      proc(t: ^Task),
	user:      rawptr,
}

task: Task // the one task (the window shows it)

// Appends a line to the log. A line that ended with '\r' (a program's progress line) replaces the last one if that
// came from a '\r' too.
log_line :: proc(t: ^Task, line: string, replace := false) {
	sync.mutex_lock(&t.mutex)
	defer sync.mutex_unlock(&t.mutex)
	l := strings.clone(line)
	if replace && len(t.log) > 0 {
		delete(t.log[len(t.log) - 1])
		t.log[len(t.log) - 1] = l
		return
	}
	if len(t.log) >= LOG_MAX {
		delete(t.log[0])
		ordered_remove(&t.log, 0)
	}
	append(&t.log, l)
}
logf :: proc(t: ^Task, f: string, args: ..any) {
	log_line(t, fmt.tprintf(f, ..args))
}
set_status :: proc(t: ^Task, progress: f32, f: string, args: ..any) {
	s := fmt.aprintf(f, ..args)
	sync.mutex_lock(&t.mutex)
	defer sync.mutex_unlock(&t.mutex)
	delete(t.status)
	t.status = s
	t.progress = progress
}
cancelled :: proc(t: ^Task) -> bool {return sync.atomic_load(&t.cancel)}

// Starts a task unless one runs. `work` runs on its own thread; it logs and sets t.failed.
task_start :: proc(name: string, work: proc(t: ^Task), user: rawptr = nil) -> bool {
	t := &task
	if sync.atomic_load(&t.running) {return false}
	if t.th != nil {
		thread.join(t.th)
		thread.destroy(t.th)
		t.th = nil
	}
	sync.mutex_lock(&t.mutex)
	for l in t.log {delete(l)}
	clear(&t.log)
	delete(t.status)
	t.status = ""
	t.progress = -1
	delete(t.name)
	t.name = strings.clone(name) // (its own copy: a caller may pass a name made for one frame)
	t.cancel = false
	t.failed = false
	t.work = work
	t.user = user
	sync.mutex_unlock(&t.mutex)
	sync.atomic_store(&t.running, true)
	t.th = thread.create(proc(th: ^thread.Thread) {
		t := (^Task)(th.data)
		t.work(t)
		if cancelled(t) {
			log_line(t, "Cancelled.")
			t.failed = true
		}
		sync.atomic_store(&t.running, false)
		wake_window() // (the window redraws when the task ends)
	})
	t.th.data = t
	thread.start(t.th)
	return true
}

task_cancel :: proc() {
	t := &task
	if !sync.atomic_load(&t.running) {return}
	sync.atomic_store(&t.cancel, true)
	sync.mutex_lock(&t.mutex)
	defer sync.mutex_unlock(&t.mutex)
	for c in t.children {child_kill(c)}
}

@(private)
task_add_child :: proc(t: ^Task, c: Child) {
	sync.mutex_lock(&t.mutex)
	defer sync.mutex_unlock(&t.mutex)
	append(&t.children, c)
	if t.cancel {child_kill(c)} // (cancelled while it started)
}
@(private)
task_remove_child :: proc(t: ^Task, c: Child) {
	sync.mutex_lock(&t.mutex)
	defer sync.mutex_unlock(&t.mutex)
	for x, i in t.children {
		if x == c {
			unordered_remove(&t.children, i)
			return
		}
	}
}

// Output handling for run(): what a program prints, line by line.
Output_Mode :: enum {
	Log, // every line into the task's log ('\r' progress lines replace each other)
	Quiet, // nothing (only captured)
}

// Runs a program (cmd[0] is its path) and waits. Its stdout and stderr are logged (mode) and, with `capture`, also
// collected. on_line sees every line (e.g. to read progress from it). Returns the exit code; started is false if it
// could not be run at all.
run :: proc(
	t: ^Task,
	cmd: []string,
	dir := "",
	mode := Output_Mode.Log,
	capture: ^strings.Builder = nil,
	on_line: proc(t: ^Task, line: string) = nil,
) -> (
	code: int,
	started: bool,
) {
	c, r, ok := child_start(cmd, dir)
	if !ok {
		if mode == .Log {logf(t, "Could not start %s", cmd[0])}
		return -1, false
	}
	task_add_child(t, c)
	defer task_remove_child(t, c)

	line := make([dynamic]u8, context.temp_allocator)
	buf: [4096]u8
	last_cr := false
	emit :: proc(t: ^Task, s: string, cr: bool, last_cr: ^bool, mode: Output_Mode, capture: ^strings.Builder, on_line: proc(t: ^Task, line: string)) {
		if capture != nil {
			strings.write_string(capture, s)
			strings.write_byte(capture, '\n')
		}
		if on_line != nil {on_line(t, s)}
		if mode == .Log && (len(s) > 0 || !cr) {log_line(t, s, replace = cr && last_cr^)}
		last_cr^ = cr
	}
	for {
		n := child_read(r, buf[:])
		if n <= 0 {break}
		for b in buf[:n] {
			switch b {
			case '\n', '\r':
				emit(t, string(line[:]), b == '\r', &last_cr, mode, capture, on_line)
				clear(&line)
			case:
				append(&line, b)
			}
		}
	}
	if len(line) > 0 {emit(t, string(line[:]), false, &last_cr, mode, capture, on_line)}
	return child_wait(c, r), true
}
