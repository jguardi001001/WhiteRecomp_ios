// Windows: PATH as it is saved in the registry (the user's, then the system's). A compiler installed, or a PATH
// edited, after the launcher (or the program that started it: Explorer, Steam, a console) was started is not in this
// process's PATH yet -- it is in the registry.
package launcher

import "core:strings"
import win32 "core:sys/windows"

registry_path :: proc() -> string {
	get :: proc(root: win32.HKEY, key: string) -> string {
		k, v := win32.utf8_to_wstring(key), win32.utf8_to_wstring("Path")
		n: win32.DWORD
		// (RRF_RT_REG_SZ alone: a REG_EXPAND_SZ value comes back expanded)
		if win32.RegGetValueW(root, k, v, win32.RRF_RT_REG_SZ, nil, nil, &n) != 0 || n < 2 {return ""}
		buf := make([]u16, n / 2 + 1, context.temp_allocator)
		if win32.RegGetValueW(root, k, v, win32.RRF_RT_REG_SZ, nil, raw_data(buf), &n) != 0 {return ""}
		s, err := win32.wstring_to_utf8(cstring16(raw_data(buf)), -1, context.temp_allocator)
		return s if err == nil else ""
	}
	u := get(win32.HKEY_CURRENT_USER, `Environment`)
	m := get(win32.HKEY_LOCAL_MACHINE, `SYSTEM\CurrentControlSet\Control\Session Manager\Environment`)
	return strings.join({u, m}, ";", context.temp_allocator)
}
