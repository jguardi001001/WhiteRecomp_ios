package platform

// ---------------------------------------------------------------------------
// The Linux part of platform that SDL2 (platform_sdl.odin) does not cover: the dialogs, the fonts, the file manager.
// None is done yet -- a program asks some other way (the launcher runs zenity / kdialog, or its own folder browser).
// ---------------------------------------------------------------------------

// Asks the user for a folder. Not done here (that would be the xdg-desktop-portal's FileChooser over D-Bus): always
// "cancelled".
pick_folder :: proc(w: ^Window, title: string, allocator := context.allocator) -> (path: string, ok: bool) {
	return "", false
}

// The installed font families. To do: fontconfig. Until then there are none, and a program falls back to its own fonts.
list_font_families :: proc(allocator := context.allocator) -> []Font_Family {
	return nil
}

// The bytes of a family's regular face. To do with list_font_families: always false here.
font_data :: proc(family: string, bold := false, allocator := context.allocator) -> (data: []u8, ok: bool) {
	return nil, false
}

// Asks the user where to save a file. Not done here, as pick_folder: always "cancelled".
pick_save_file :: proc(w: ^Window, title, suggested, dir: string, allocator := context.allocator) -> (path: string, ok: bool) {
	return "", false
}

// A question with Yes and No. Not done here: `ok` is always false (the caller has to ask some other way).
ask_yes_no :: proc(w: ^Window, title, text: string) -> (yes: bool, ok: bool) {
	return false, false
}

pick_program :: proc(w: ^Window, title, dir: string, allocator := context.allocator) -> (path: string, ok: bool) {
	return "", false
}

show_in_file_manager :: proc(path: string, is_dir: bool) -> bool {
	return false // (not done yet: xdg-open, or org.freedesktop.FileManager1's ShowItems)
}

run_program :: proc(program, args: string) -> bool {
	return false
}

move_to_trash :: proc(path: string) -> bool {
	return false // (not done yet: the freedesktop trash folder)
}

ask_save_changes :: proc(w: ^Window, title, text: string) -> (answer: Save_Answer, ok: bool) {
	return .Cancel, false
}
