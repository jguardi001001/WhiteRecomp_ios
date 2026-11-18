package launcher

import "core:sync"
import "core:thread"
import win "core:sys/windows"

// Starts the built game (as a double click would: its own console window), in its folder; game_running until it ends.
start_game :: proc(exe, dir: string) -> bool {
	info := win.SHELLEXECUTEINFOW {
		cbSize      = size_of(win.SHELLEXECUTEINFOW),
		fMask       = win.SEE_MASK_NOCLOSEPROCESS,
		lpVerb      = win.L("open"),
		lpFile      = win.utf8_to_wstring(exe, context.temp_allocator),
		lpDirectory = win.utf8_to_wstring(dir, context.temp_allocator),
		nShow       = win.SW_SHOWNORMAL,
	}
	if !win.ShellExecuteExW(&info) || info.hProcess == nil {return false}
	sync.atomic_store(&game_running, true)
	thread.create_and_start_with_poly_data(info.hProcess, proc(h: win.HANDLE) {
		win.WaitForSingleObject(h, win.INFINITE)
		win.CloseHandle(h)
		sync.atomic_store(&game_running, false)
	}, self_cleanup = true)
	return true
}

// Steam's folder, from the registry (HKCU\Software\Valve\Steam SteamPath)
registry_steam_path :: proc() -> string {
	buf: [1024]u16
	size := win.DWORD(size_of(buf))
	if win.RegGetValueW(win.HKEY_CURRENT_USER, win.L(`Software\Valve\Steam`), win.L("SteamPath"), win.RRF_RT_REG_SZ, nil, &buf, &size) != 0 {return ""}
	s, _ := win.wstring_to_utf8(win.wstring(&buf[0]), -1, context.temp_allocator)
	return s
}

// a web page in the player's browser
open_url :: proc(url: string) {
	win.ShellExecuteW(nil, win.L("open"), win.utf8_to_wstring(url, context.temp_allocator), nil, nil, win.SW_SHOWNORMAL)
}
