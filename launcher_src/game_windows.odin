package launcher

import win "core:sys/windows"

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
