package platform

import "base:runtime"
import "core:os"
import "core:strings"
import CF "core:sys/darwin/CoreFoundation"
import CT "core:sys/darwin/CoreText"
import NS "vendor:darwin/AppKit"

// ---------------------------------------------------------------------------
// The macOS part of platform that SDL2 (platform_sdl.odin) does not cover: the file dialogs (NSOpenPanel, NSSavePanel),
// message boxes (NSAlert), the Finder and the system's fonts, through Odin's Objective-C bindings. They run on the main
// thread, with the NSApplication SDL made when the first window was.
//
// Untested without a Mac: written against Apple's documentation and the binding sources only.
// ---------------------------------------------------------------------------

// ---- strings ----

// An autoreleased NSString with a copy of `s`.
@(private = "file")
ns_string :: proc(s: string) -> ^NS.String {
	str := NS.String.alloc()->initWithBytes(raw_data(s), NS.UInteger(len(s)), NS.UTF8StringEncoding)
	return str->autorelease()
}

// A copy of an NSString in `allocator` ("" for nil).
@(private = "file")
odin_string :: proc(str: ^NS.String, allocator: runtime.Allocator) -> string {
	if str == nil {
		return ""
	}
	return strings.clone(str->odinString(), allocator)
}

// The application is there for a panel or an alert: SDL makes it with the first window (sdl_load); without SDL a
// shared application is made here (a program that asks before it opens a window).
@(private = "file")
ensure_app :: proc() -> bool {
	if sdl_load() {
		return true
	}
	return NS.Application.sharedApplication() != nil
}

// ---- the file dialogs (NSOpenPanel, NSSavePanel; modal: they block until they are closed) ----

@(private = "file")
file_url :: proc(path: string, is_dir: bool) -> ^NS.URL {
	return NS.URL.fileURLWithPath_isDirectory(ns_string(path), is_dir)
}

@(private = "file")
open_panel :: proc(title, dir: string, folders: bool, allocator: runtime.Allocator) -> (path: string, ok: bool) {
	if !ensure_app() {
		return "", false
	}
	NS.scoped_autoreleasepool()
	panel := NS.OpenPanel.openPanel()
	panel->setCanChooseDirectories(folders)
	panel->setCanChooseFiles(!folders)
	panel->setAllowsMultipleSelection(false)
	panel->setCanCreateDirectories(folders)
	panel->setMessage(ns_string(title)) // (a panel's title is not shown on current macOS; its message is)
	panel->setTitle(ns_string(title))
	if dir != "" {
		panel->setDirectoryURL(file_url(dir, true))
	}
	if panel->runModal() != NS.ModalResponseOK {
		return "", false
	}
	urls := panel->URLs()
	if urls == nil || urls->count() == 0 {
		return "", false
	}
	url := (^NS.URL)(urls->objectAtIndex(0))
	path = odin_string(url->path(), allocator)
	return path, path != ""
}

// Asks the user for a folder (it blocks until the panel is closed). Returns the folder's full path (the caller owns the
// string), or false if it was cancelled.
pick_folder :: proc(w: ^Window, title: string, allocator := context.allocator) -> (path: string, ok: bool) {
	return open_panel(title, "", true, allocator)
}

// Asks the user where to save a file. `suggested` is the name it starts with ("" for none), `dir` the folder it opens in
// ("" lets macOS choose). The panel asks before replacing a file. Returns the full path, or false if it was cancelled.
pick_save_file :: proc(w: ^Window, title, suggested, dir: string, allocator := context.allocator) -> (path: string, ok: bool) {
	if !ensure_app() {
		return "", false
	}
	NS.scoped_autoreleasepool()
	panel := NS.SavePanel.savePanel()
	panel->setCanCreateDirectories(true)
	panel->setMessage(ns_string(title))
	panel->setTitle(ns_string(title))
	if suggested != "" {
		panel->setNameFieldStringValue(ns_string(suggested))
	}
	if dir != "" {
		panel->setDirectoryURL(file_url(dir, true))
	}
	if panel->runModal() != NS.ModalResponseOK {
		return "", false
	}
	url := panel->URL()
	if url == nil {
		return "", false
	}
	path = odin_string(url->path(), allocator)
	return path, path != ""
}

// Asks the user for a program (any file: macOS programs have no extension of their own, an .app is a folder the panel opens
// as a file only when it is chosen). `dir` is the folder it opens in.
pick_program :: proc(w: ^Window, title, dir: string, allocator := context.allocator) -> (path: string, ok: bool) {
	return open_panel(title, dir, false, allocator)
}

// ---- message boxes (NSAlert, modal) ----

// Asks whether to save unsaved changes, with Save / Don't Save / Cancel.
ask_save_changes :: proc(w: ^Window, title, text: string) -> (answer: Save_Answer, ok: bool) {
	if !ensure_app() {
		return .Cancel, false
	}
	NS.scoped_autoreleasepool()
	alert := NS.Alert.alloc()->init()
	defer alert->release()
	alert->setAlertStyle(.Warning)
	alert->setMessageText(ns_string(title))
	alert->setInformativeText(ns_string(text))
	alert->addButtonWithTitle(NS.AT("Save"))
	alert->addButtonWithTitle(NS.AT("Don't Save"))
	cancel := alert->addButtonWithTitle(NS.AT("Cancel"))
	cancel->setKeyEquivalent(NS.AT("\x1b"))
	switch alert->runModal() {
	case NS.AlertFirstButtonReturn:
		return .Save, true
	case NS.AlertSecondButtonReturn:
		return .Discard, true
	}
	return .Cancel, true
}

// A question with Yes and No (a warning). No is the default (Return), as on Windows.
ask_yes_no :: proc(w: ^Window, title, text: string) -> (yes: bool, ok: bool) {
	if !ensure_app() {
		return false, false
	}
	NS.scoped_autoreleasepool()
	alert := NS.Alert.alloc()->init()
	defer alert->release()
	alert->setAlertStyle(.Warning)
	alert->setMessageText(ns_string(title))
	alert->setInformativeText(ns_string(text))
	yes_button := alert->addButtonWithTitle(NS.AT("Yes"))
	no_button := alert->addButtonWithTitle(NS.AT("No"))
	yes_button->setKeyEquivalent(NS.AT(""))
	no_button->setKeyEquivalent(NS.AT("\r"))
	return alert->runModal() == NS.AlertFirstButtonReturn, true
}

// ---- the Finder ----

// Shows `path` in the Finder: a folder is opened; a file's folder is opened with the file selected.
show_in_file_manager :: proc(path: string, is_dir: bool) -> bool {
	NS.scoped_autoreleasepool()
	workspace := NS.Workspace.sharedWorkspace()
	if is_dir {
		return workspace->openURL_(file_url(path, true))
	}
	workspace->activateFileViewerSelectingURLs(NS.Array.arrayWithObject(file_url(path, false)))
	return true
}

// To do: starting a program with a command line (posix_spawn, with the arguments split as a shell would). Not done yet, as on
// Linux.
run_program :: proc(program, args: string) -> bool {
	return false
}

// Moves a file or a folder (with what is in it) to the Trash, where the Finder can put it back from.
move_to_trash :: proc(path: string) -> bool {
	NS.scoped_autoreleasepool()
	return NS.FileManager.defaultManager()->trashItemAtURL_error(NS.URL.fileURLWithPath_(ns_string(path)), nil, nil) // (the URL asks the disk whether it is a folder)
}

// ---- the system's fonts ----
// What is installed is asked of NSFontManager, and a family's bytes are read from the file Core Text says the font is in.

// The installed font families (the caller owns the names and the slice).
list_font_families :: proc(allocator := context.allocator) -> []Font_Family {
	NS.scoped_autoreleasepool()
	manager := NS.FontManager.sharedFontManager()
	families := manager->availableFontFamilies()
	if families == nil {
		return nil
	}
	list := make([dynamic]Font_Family, 0, int(families->count()), allocator)
	for i in 0 ..< families->count() {
		name := (^NS.String)(families->objectAtIndex(i))
		if name == nil {
			continue
		}
		font := manager->fontWithFamily(name, {}, 5, 12) // 5: the regular weight
		append(&list, Font_Family{name = odin_string(name, allocator), monospace = font != nil && font->isFixedPitch()})
	}
	return list[:]
}

// The bytes of a family's regular (or bold) face: the whole font file. A face that lives in a collection (.ttc) comes as the
// whole collection (whose first face is used, which may not be this one). false if the family is not installed or its
// file cannot be read (some system fonts have no file a program may read).
font_data :: proc(family: string, bold := false, allocator := context.allocator) -> (data: []u8, ok: bool) {
	if family == "" {
		return nil, false
	}
	NS.scoped_autoreleasepool()
	traits: NS.FontTraitMask = {.BoldFontMask} if bold else {}
	font := NS.FontManager.sharedFontManager()->fontWithFamily(ns_string(family), traits, 9 if bold else 5, 64)
	if font == nil {
		return nil, false
	}
	// an NSFont is a CTFont (toll-free bridged)
	url := CF.URLRef(CT.FontCopyAttribute(CT.FontRef(rawptr(font)), CT.kFontURLAttribute))
	if url == nil {
		return nil, false
	}
	defer CF.Release(CF.TypeRef(url))
	buf: [1024]u8
	if !CF.URLGetFileSystemRepresentation(url, true, &buf[0], len(buf)) {
		return nil, false
	}
	bytes, err := os.read_entire_file_from_path(string(cstring(&buf[0])), allocator)
	if err != nil {
		return nil, false
	}
	return bytes, true
}
