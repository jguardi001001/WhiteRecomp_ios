// Starting programs on Windows: CreateProcessW with CREATE_NO_WINDOW (the launcher is a GUI program: core:os's
// process_start would open a console window for every compiler run), stdout and stderr into one pipe. And elevated
// runs: ShellExecuteExW "runas", the system's own UAC prompt, once per program that needs it.
package launcher

import "core:strings"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32 {
	SetErrorMode :: proc(mode: win.UINT) -> win.UINT ---
}

Child :: distinct win.HANDLE
Child_Pipe :: distinct win.HANDLE

// The command line of cmd, quoted the way CommandLineToArgvW / the C runtime read it.
win_cmdline :: proc(cmd: []string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for a, i in cmd {
		if i > 0 {strings.write_byte(&b, ' ')}
		if len(a) > 0 && !strings.contains_any(a, " \t\"") {
			strings.write_string(&b, a)
			continue
		}
		strings.write_byte(&b, '"')
		slashes := 0
		for c in transmute([]u8)a {
			switch c {
			case '\\':
				slashes += 1
			case '"':
				for _ in 0 ..< slashes * 2 + 1 {strings.write_byte(&b, '\\')}
				slashes = 0
				strings.write_byte(&b, '"')
				continue
			case:
				for _ in 0 ..< slashes {strings.write_byte(&b, '\\')}
				slashes = 0
				strings.write_byte(&b, c)
				continue
			}
		}
		for _ in 0 ..< slashes * 2 {strings.write_byte(&b, '\\')}
		strings.write_byte(&b, '"')
	}
	return strings.to_string(b)
}

// The environment for a child: ours, with the folder of its program first in PATH (a toolchain like MSYS2's gcc runs
// helper programs from other folders that need the DLLs next to gcc.exe: started from outside its shell, they would not
// find them). A double-NUL-terminated UTF-16 block.
@(private = "file")
child_env :: proc(program: string) -> []u16 {
	block := make([dynamic]u16, context.temp_allocator)
	dir := program
	if i := strings.last_index_any(program, `\/`); i >= 0 {dir = program[:i]} else {dir = ""}
	env := win.GetEnvironmentStringsW()
	defer win.FreeEnvironmentStringsW(env)
	p := ([^]u16)(env)
	had_path := false
	for p[0] != 0 {
		n := 0
		for p[n] != 0 {n += 1}
		entry, _ := win.utf16_to_utf8(p[:n], context.temp_allocator)
		if dir != "" && len(entry) > 5 && strings.equal_fold(entry[:5], "PATH=") {
			entry = strings.concatenate({entry[:5], dir, ";", entry[5:]}, context.temp_allocator)
			had_path = true
		}
		w := win.utf8_to_utf16(entry, context.temp_allocator)
		append(&block, ..w)
		append(&block, 0)
		p = p[n + 1:]
	}
	if dir != "" && !had_path {
		append(&block, ..win.utf8_to_utf16(strings.concatenate({"PATH=", dir}, context.temp_allocator), context.temp_allocator))
		append(&block, 0)
	}
	append(&block, 0)
	return block[:]
}

// No "DLL not found" / crash dialogs from the programs the launcher starts (the error mode is inherited): a program
// that cannot start then just fails, with its code in the log (STATUS_DLL_NOT_FOUND: child_failure).
quiet_child_errors :: proc() {
	SetErrorMode(0x0001 | 0x0002 | 0x8000) // SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX
}

// What an exit code means when it is a Windows status (a program that could not run at all).
child_failure :: proc(code: int) -> string {
	switch u32(code) {
	case 0xC0000135: return "a DLL it needs is missing"
	case 0xC0000139: return "a DLL it needs is the wrong version"
	case 0xC000007B: return "it or a DLL it needs is not a 64-bit program"
	case 0xC0000005: return "it crashed"
	}
	return ""
}

child_start :: proc(cmd: []string, dir: string) -> (c: Child, r: Child_Pipe, ok: bool) {
	sa := win.SECURITY_ATTRIBUTES{nLength = size_of(win.SECURITY_ATTRIBUTES), bInheritHandle = true}
	rd, wr: win.HANDLE
	if !win.CreatePipe(&rd, &wr, &sa, 0) {return}
	win.SetHandleInformation(rd, win.HANDLE_FLAG_INHERIT, 0)
	nul := win.CreateFileW(win.L("NUL"), win.GENERIC_READ, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, &sa, win.OPEN_EXISTING, 0, nil)
	si := win.STARTUPINFOW {
		cb         = size_of(win.STARTUPINFOW),
		dwFlags    = win.STARTF_USESTDHANDLES,
		hStdInput  = nul,
		hStdOutput = wr,
		hStdError  = wr,
	}
	pi: win.PROCESS_INFORMATION
	line := win.utf8_to_wstring(win_cmdline(cmd), context.temp_allocator)
	wdir := win.utf8_to_wstring(dir, context.temp_allocator) if dir != "" else nil
	env := child_env(cmd[0])
	made := win.CreateProcessW(nil, line, nil, nil, true, win.CREATE_NO_WINDOW | win.CREATE_UNICODE_ENVIRONMENT, raw_data(env), wdir, &si, &pi)
	win.CloseHandle(wr) // (the child has its copy: the pipe ends when it exits)
	if nul != win.INVALID_HANDLE_VALUE {win.CloseHandle(nul)}
	if !made {
		win.CloseHandle(rd)
		return
	}
	win.CloseHandle(pi.hThread)
	return Child(pi.hProcess), Child_Pipe(rd), true
}

// Bytes from the child's output; 0 when it has closed it (exited).
child_read :: proc(r: Child_Pipe, buf: []u8) -> int {
	n: win.DWORD
	if !win.ReadFile(win.HANDLE(r), raw_data(buf), win.DWORD(len(buf)), &n, nil) {return 0}
	return int(n)
}

child_wait :: proc(c: Child, r: Child_Pipe) -> int {
	win.CloseHandle(win.HANDLE(r))
	win.WaitForSingleObject(win.HANDLE(c), win.INFINITE)
	code: win.DWORD
	win.GetExitCodeProcess(win.HANDLE(c), &code)
	win.CloseHandle(win.HANDLE(c))
	return int(code)
}

child_kill :: proc(c: Child) {
	win.TerminateProcess(win.HANDLE(c), 1)
}

// Runs cmd as administrator: Windows asks the user (UAC) for this one program. Its output cannot be read (an elevated
// process cannot write to our pipe), only its exit code. started is false if the user said no.
run_elevated :: proc(t: ^Task, cmd: []string) -> (code: int, started: bool) {
	logf(t, "Asking for administrator permission to run: %s", win_cmdline(cmd))
	info := win.SHELLEXECUTEINFOW {
		cbSize       = size_of(win.SHELLEXECUTEINFOW),
		fMask        = win.SEE_MASK_NOCLOSEPROCESS | win.SEE_MASK_NOASYNC,
		lpVerb       = win.L("runas"),
		lpFile       = win.utf8_to_wstring(cmd[0], context.temp_allocator),
		lpParameters = win.utf8_to_wstring(win_cmdline(cmd[1:]), context.temp_allocator),
		nShow        = win.SW_SHOWNORMAL,
	}
	if !win.ShellExecuteExW(&info) || info.hProcess == nil {
		log_line(t, "Administrator permission was not given.")
		return -1, false
	}
	c := Child(info.hProcess)
	task_add_child(t, c)
	defer task_remove_child(t, c)
	win.WaitForSingleObject(info.hProcess, win.INFINITE)
	ec: win.DWORD
	win.GetExitCodeProcess(info.hProcess, &ec)
	win.CloseHandle(info.hProcess)
	return int(ec), true
}
