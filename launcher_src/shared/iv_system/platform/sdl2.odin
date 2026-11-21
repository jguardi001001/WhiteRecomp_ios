#+build linux, darwin
package platform

import "core:c"
import "core:dynlib"
import "core:os"
import "core:strings"

// ---------------------------------------------------------------------------
// SDL2, loaded when the first window is made (not linked: a program built against no SDL headers or libraries, and one
// message when SDL2 is not installed). Only what platform_sdl.odin uses; the layouts are SDL2's (stable across 2.0.x).
//
// Where it is looked for: $IV_SDL_LIB, then beside the program and in an .app's Contents/Frameworks (macOS), then the
// system's (libSDL2-2.0.so.0 on Linux; Homebrew and /Library/Frameworks on macOS).
// ---------------------------------------------------------------------------

@(private)
Sdl_Window :: struct {}
@(private)
Sdl_Cursor :: struct {}
@(private)
Sdl_Controller :: struct {}

// SDL_Event: 56 bytes. The fields are read at their offsets (see platform_sdl.odin's poll).
@(private)
Sdl_Event :: struct #raw_union {
	type:  u32,
	bytes: [56]u8,
	ints:  [14]i32,
}

// SDL_SysWMinfo: the version (3 bytes), the subsystem (an int at 4), then the union (at 8; 64 bytes of padding in SDL2)
@(private)
Sdl_Wm_Info :: struct {
	version:   [3]u8,
	_:         u8,
	subsystem: c.int,
	info:      [16]uintptr, // X11: Display*, Window; Wayland: wl_display*, wl_surface*, ...; Cocoa: NSWindow*
}

@(private)
SDL_INIT_VIDEO :: 0x20
@(private)
SDL_INIT_GAMECONTROLLER :: 0x2000
@(private)
SDL_INIT_EVENTS :: 0x4000

@(private)
SDL_WINDOW_FULLSCREEN_DESKTOP :: 0x1001
@(private)
SDL_WINDOW_HIDDEN :: 0x8
@(private)
SDL_WINDOW_BORDERLESS :: 0x10
@(private)
SDL_WINDOW_RESIZABLE :: 0x20
@(private)
SDL_WINDOW_MINIMIZED :: 0x40
@(private)
SDL_WINDOW_MAXIMIZED :: 0x80
@(private)
SDL_WINDOW_INPUT_FOCUS :: 0x200
@(private)
SDL_WINDOW_ALLOW_HIGHDPI :: 0x2000
@(private)
SDL_WINDOW_ALWAYS_ON_TOP :: 0x8000
@(private)
SDL_WINDOW_VULKAN :: 0x10000000
@(private)
SDL_WINDOW_METAL :: 0x20000000

@(private)
SDL_WINDOWPOS_CENTERED :: 0x2FFF0000

@(private)
SDL_SYSWM_X11 :: 2
@(private)
SDL_SYSWM_COCOA :: 4
@(private)
SDL_SYSWM_WAYLAND :: 6

// The functions, filled in by sdl_load. (The optional ones -- newer than SDL 2.0.10, or not needed -- may stay nil.)
@(private)
Sdl :: struct {
	lib:                       dynlib.Library,
	loaded:                    bool,
	tried:                     bool,
	error:                     string, // why it could not be loaded or started
	Init:                      proc "c" (flags: u32) -> c.int,
	InitSubSystem:             proc "c" (flags: u32) -> c.int,
	GetError:                  proc "c" () -> cstring,
	SetHint:                   proc "c" (name, value: cstring) -> c.int,
	GetVersion:                proc "c" (v: ^[3]u8),
	CreateWindow:              proc "c" (title: cstring, x, y, w, h: c.int, flags: u32) -> ^Sdl_Window,
	DestroyWindow:             proc "c" (w: ^Sdl_Window),
	GetWindowID:               proc "c" (w: ^Sdl_Window) -> u32,
	GetWindowFlags:            proc "c" (w: ^Sdl_Window) -> u32,
	GetWindowSize:             proc "c" (w: ^Sdl_Window, x, y: ^c.int),
	SetWindowSize:             proc "c" (w: ^Sdl_Window, x, y: c.int),
	SetWindowMinimumSize:      proc "c" (w: ^Sdl_Window, x, y: c.int),
	SetWindowTitle:            proc "c" (w: ^Sdl_Window, title: cstring),
	SetWindowFullscreen:       proc "c" (w: ^Sdl_Window, flags: u32) -> c.int,
	SetWindowBordered:         proc "c" (w: ^Sdl_Window, on: b32),
	SetWindowResizable:        proc "c" (w: ^Sdl_Window, on: b32), // (2.0.5)
	SetWindowAlwaysOnTop:      proc "c" (w: ^Sdl_Window, on: b32), // (2.0.16, optional)
	SetWindowHitTest:          proc "c" (w: ^Sdl_Window, callback: rawptr, data: rawptr) -> c.int, // (optional)
	ShowWindow:                proc "c" (w: ^Sdl_Window),
	HideWindow:                proc "c" (w: ^Sdl_Window),
	RaiseWindow:               proc "c" (w: ^Sdl_Window),
	MaximizeWindow:            proc "c" (w: ^Sdl_Window),
	MinimizeWindow:            proc "c" (w: ^Sdl_Window),
	RestoreWindow:             proc "c" (w: ^Sdl_Window),
	GetWindowWMInfo:           proc "c" (w: ^Sdl_Window, info: ^Sdl_Wm_Info) -> b32,
	GetWindowSizeInPixels:     proc "c" (w: ^Sdl_Window, x, y: ^c.int), // (2.26, optional)
	Vulkan_GetDrawableSize:    proc "c" (w: ^Sdl_Window, x, y: ^c.int), // (optional)
	Metal_CreateView:          proc "c" (w: ^Sdl_Window) -> rawptr, // (macOS, 2.0.12)
	Metal_DestroyView:         proc "c" (view: rawptr),
	Metal_GetLayer:            proc "c" (view: rawptr) -> rawptr, // (2.0.14)
	Metal_GetDrawableSize:     proc "c" (w: ^Sdl_Window, x, y: ^c.int), // (2.0.14)
	PollEvent:                 proc "c" (e: ^Sdl_Event) -> c.int,
	WaitEventTimeout:          proc "c" (e: ^Sdl_Event, ms: c.int) -> c.int,
	StartTextInput:            proc "c" (),
	CreateSystemCursor:        proc "c" (id: c.int) -> ^Sdl_Cursor,
	SetCursor:                 proc "c" (cur: ^Sdl_Cursor),
	ShowCursor:                proc "c" (toggle: c.int) -> c.int,
	WarpMouseInWindow:         proc "c" (w: ^Sdl_Window, x, y: c.int),
	GetClipboardText:          proc "c" () -> cstring,
	SetClipboardText:          proc "c" (text: cstring) -> c.int,
	free:                      proc "c" (p: rawptr),
	NumJoysticks:              proc "c" () -> c.int,
	IsGameController:          proc "c" (index: c.int) -> b32,
	GameControllerOpen:        proc "c" (index: c.int) -> ^Sdl_Controller,
	GameControllerClose:       proc "c" (gc: ^Sdl_Controller),
	GameControllerGetAttached: proc "c" (gc: ^Sdl_Controller) -> b32,
	GameControllerGetButton:   proc "c" (gc: ^Sdl_Controller, button: c.int) -> u8,
	GameControllerGetAxis:     proc "c" (gc: ^Sdl_Controller, axis: c.int) -> i16,
	GameControllerUpdate:      proc "c" (),
}

@(private)
sdl: Sdl

@(private = "file")
sdl_paths :: proc() -> []string {
	paths := make([dynamic]string, context.temp_allocator)
	if env, found := os.lookup_env("IV_SDL_LIB", context.temp_allocator); found && env != "" {
		append(&paths, env)
	}
	exe_dir, err := os.get_executable_directory(context.temp_allocator)
	when ODIN_OS == .Darwin {
		if err == nil {
			append(&paths, strings.concatenate({exe_dir, "/../Frameworks/libSDL2-2.0.0.dylib"}, context.temp_allocator))
			append(&paths, strings.concatenate({exe_dir, "/../Frameworks/SDL2.framework/SDL2"}, context.temp_allocator))
			append(&paths, strings.concatenate({exe_dir, "/libSDL2-2.0.0.dylib"}, context.temp_allocator))
		}
		append(&paths, "libSDL2-2.0.0.dylib", "/opt/homebrew/lib/libSDL2-2.0.0.dylib", "/usr/local/lib/libSDL2-2.0.0.dylib",
			"/Library/Frameworks/SDL2.framework/SDL2", "libSDL2.dylib")
	} else {
		if err == nil {
			append(&paths, strings.concatenate({exe_dir, "/libSDL2-2.0.so.0"}, context.temp_allocator))
		}
		append(&paths, "libSDL2-2.0.so.0", "libSDL2-2.0.so", "libSDL2.so")
	}
	return paths[:]
}

// Loads SDL2 and starts its video (and, when it can, its game controllers). Once; false (and sdl.error) if it cannot.
@(private)
sdl_load :: proc(app_id := "") -> bool {
	if sdl.tried {
		return sdl.loaded
	}
	sdl.tried = true
	found := false
	for path in sdl_paths() {
		if lib, ok := dynlib.load_library(path); ok {
			sdl.lib = lib
			found = true
			break
		}
	}
	if !found {
		when ODIN_OS == .Darwin {
			sdl.error = "SDL2 was not found (it comes in WhiteRecomp.app's Contents/Frameworks; or: brew install sdl2)"
		} else {
			sdl.error = "SDL2 was not found: install it (Debian/Ubuntu: sudo apt install libsdl2-2.0-0; Fedora: sudo dnf install SDL2; Arch: sudo pacman -S sdl2)"
		}
		return false
	}
	missing := ""
	sym :: proc(p: rawptr, name: string, missing: ^string, required := true) {
		addr, ok := dynlib.symbol_address(sdl.lib, name)
		(^rawptr)(p)^ = ok ? addr : nil
		if !ok && required && missing^ == "" {
			missing^ = name
		}
	}
	sym(&sdl.Init, "SDL_Init", &missing)
	sym(&sdl.InitSubSystem, "SDL_InitSubSystem", &missing)
	sym(&sdl.GetError, "SDL_GetError", &missing)
	sym(&sdl.SetHint, "SDL_SetHint", &missing)
	sym(&sdl.GetVersion, "SDL_GetVersion", &missing)
	sym(&sdl.CreateWindow, "SDL_CreateWindow", &missing)
	sym(&sdl.DestroyWindow, "SDL_DestroyWindow", &missing)
	sym(&sdl.GetWindowID, "SDL_GetWindowID", &missing)
	sym(&sdl.GetWindowFlags, "SDL_GetWindowFlags", &missing)
	sym(&sdl.GetWindowSize, "SDL_GetWindowSize", &missing)
	sym(&sdl.SetWindowSize, "SDL_SetWindowSize", &missing)
	sym(&sdl.SetWindowMinimumSize, "SDL_SetWindowMinimumSize", &missing)
	sym(&sdl.SetWindowTitle, "SDL_SetWindowTitle", &missing)
	sym(&sdl.SetWindowFullscreen, "SDL_SetWindowFullscreen", &missing)
	sym(&sdl.SetWindowBordered, "SDL_SetWindowBordered", &missing)
	sym(&sdl.SetWindowResizable, "SDL_SetWindowResizable", &missing, false)
	sym(&sdl.SetWindowAlwaysOnTop, "SDL_SetWindowAlwaysOnTop", &missing, false)
	sym(&sdl.SetWindowHitTest, "SDL_SetWindowHitTest", &missing, false)
	sym(&sdl.ShowWindow, "SDL_ShowWindow", &missing)
	sym(&sdl.HideWindow, "SDL_HideWindow", &missing)
	sym(&sdl.RaiseWindow, "SDL_RaiseWindow", &missing)
	sym(&sdl.MaximizeWindow, "SDL_MaximizeWindow", &missing)
	sym(&sdl.MinimizeWindow, "SDL_MinimizeWindow", &missing)
	sym(&sdl.RestoreWindow, "SDL_RestoreWindow", &missing)
	sym(&sdl.GetWindowWMInfo, "SDL_GetWindowWMInfo", &missing)
	sym(&sdl.GetWindowSizeInPixels, "SDL_GetWindowSizeInPixels", &missing, false)
	sym(&sdl.Vulkan_GetDrawableSize, "SDL_Vulkan_GetDrawableSize", &missing, false)
	when ODIN_OS == .Darwin {
		sym(&sdl.Metal_CreateView, "SDL_Metal_CreateView", &missing)
		sym(&sdl.Metal_DestroyView, "SDL_Metal_DestroyView", &missing)
		sym(&sdl.Metal_GetLayer, "SDL_Metal_GetLayer", &missing)
		sym(&sdl.Metal_GetDrawableSize, "SDL_Metal_GetDrawableSize", &missing, false)
	}
	sym(&sdl.PollEvent, "SDL_PollEvent", &missing)
	sym(&sdl.WaitEventTimeout, "SDL_WaitEventTimeout", &missing)
	sym(&sdl.StartTextInput, "SDL_StartTextInput", &missing)
	sym(&sdl.CreateSystemCursor, "SDL_CreateSystemCursor", &missing)
	sym(&sdl.SetCursor, "SDL_SetCursor", &missing)
	sym(&sdl.ShowCursor, "SDL_ShowCursor", &missing)
	sym(&sdl.WarpMouseInWindow, "SDL_WarpMouseInWindow", &missing)
	sym(&sdl.GetClipboardText, "SDL_GetClipboardText", &missing)
	sym(&sdl.SetClipboardText, "SDL_SetClipboardText", &missing)
	sym(&sdl.free, "SDL_free", &missing)
	sym(&sdl.NumJoysticks, "SDL_NumJoysticks", &missing)
	sym(&sdl.IsGameController, "SDL_IsGameController", &missing)
	sym(&sdl.GameControllerOpen, "SDL_GameControllerOpen", &missing)
	sym(&sdl.GameControllerClose, "SDL_GameControllerClose", &missing)
	sym(&sdl.GameControllerGetAttached, "SDL_GameControllerGetAttached", &missing)
	sym(&sdl.GameControllerGetButton, "SDL_GameControllerGetButton", &missing)
	sym(&sdl.GameControllerGetAxis, "SDL_GameControllerGetAxis", &missing)
	sym(&sdl.GameControllerUpdate, "SDL_GameControllerUpdate", &missing)
	if missing != "" {
		sdl.error = strings.concatenate({"the SDL2 found is too old (it has no ", missing, "): SDL 2.0.14 or newer is needed"})
		return false
	}
	// before SDL_Init: the program's name on the desktop (Window_Desc.app_id: its .desktop file)
	if app_id != "" {
		id := strings.clone_to_cstring(app_id, context.temp_allocator)
		sdl.SetHint("SDL_VIDEO_X11_WMCLASS", id)
		sdl.SetHint("SDL_VIDEO_WAYLAND_WMCLASS", id)
	}
	sdl.SetHint("SDL_NO_SIGNAL_HANDLERS", "1") // (Ctrl+C and SIGTERM stay the program's)
	sdl.SetHint("SDL_MOUSE_FOCUS_CLICKTHROUGH", "1") // (macOS: the click that activates the window is a click, as on Windows)
	sdl.SetHint("SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS", "0")
	if sdl.Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) != 0 {
		sdl.error = strings.concatenate({"SDL could not start its video: ", string(sdl.GetError())})
		return false
	}
	sdl.InitSubSystem(SDL_INIT_GAMECONTROLLER) // (no pads without it: not an error)
	sdl.loaded = true
	return true
}
