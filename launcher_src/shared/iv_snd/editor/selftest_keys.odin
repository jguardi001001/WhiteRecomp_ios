package main

import "core:fmt"
import input "shared:iv_input"
import snd "shared:iv_snd"

// The editor's keys go through the shared input module: its own table of signals (keymap.odin) is read at every query.
// These feed the module the way input_poll does and look at what the editor does with it.

key_frame :: proc() {
	input.begin_frame(&ictx)
}

key_tap :: proc(k: input.Key, mods: input.Modifiers = {}) {
	if .Ctrl in mods {
		input.set_key_state(&ictx, .Left_Ctrl, {.Down})
	}
	if .Shift in mods {
		input.set_key_state(&ictx, .Left_Shift, {.Down})
	}
	in_.ctrl = .Ctrl in mods
	in_.shift = .Shift in mods
	input.set_key_state(&ictx, k, {.Down, .Pressed})
}

key_release_all :: proc() {
	input.reset_state(&ictx)
	in_.ctrl = false
	in_.shift = false
}

run_key_tests :: proc() {
	keymap_init()
	defer key_release_all()
	ed_init()

	// Plain navigation keys.
	key_frame()
	key_tap(.Enter)
	check(hit(.Nav_Confirm) && !hit(.Nav_Cancel), "keys: Enter confirms")
	key_release_all()
	key_frame()
	key_tap(.Kp_Enter)
	check(hit(.Nav_Confirm), "keys: the number pad's Enter confirms too (two sources of one signal)")
	key_release_all()
	key_frame()
	key_tap(.Down, {.Shift})
	check(rep(.Nav_Down), "keys: an arrow key counts with a modifier held")
	key_release_all()

	// Ctrl+S and Ctrl+Shift+S are different commands; Tab and Shift+Tab too.
	key_frame()
	key_tap(.S, {.Ctrl})
	check(hit(.Cmd_Save) && !hit(.Cmd_Save_As), "keys: Ctrl+S saves")
	key_release_all()
	key_frame()
	key_tap(.S, {.Ctrl, .Shift})
	check(hit(.Cmd_Save_As) && !hit(.Cmd_Save), "keys: Ctrl+Shift+S saves as, and not also saves")
	key_release_all()
	key_frame()
	key_tap(.Tab)
	check(hit(.Cmd_Track_Next) && !hit(.Cmd_Track_Prev), "keys: Tab is the next track")
	key_release_all()
	key_frame()
	key_tap(.Tab, {.Shift})
	check(hit(.Cmd_Track_Prev) && !hit(.Cmd_Track_Next), "keys: Shift+Tab is the previous track")
	key_release_all()

	// The global keys run the actions: Tab moves to the next track of a song that has two.
	demo := demo_song()
	ed_set_project(project_from_song(&demo), "")
	snd.song_destroy(&demo)
	start := ed.cur_track
	count := len(ed.p.tracks)
	check(count >= 2, "keys: the demo has tracks to go through (%d)", count)
	key_frame()
	key_tap(.Tab)
	check(global_keys() == false, "keys: Tab is not a Ctrl command")
	check(ed.cur_track == (start + 1) % count, "keys: Tab went to the next track (%d -> %d)", start, ed.cur_track)
	key_release_all()
	key_frame()
	key_tap(.Z, {.Ctrl})
	check(global_keys() == true, "keys: Ctrl held: the keys of the view stay out of it")
	key_release_all()

	// The player changes a key while the program runs: the table is read live.
	key_frame()
	check(input.rebind(&ictx, .Cmd_Loop_Toggle, input.on_key(.L, {.Ctrl})), "keys: rebinding finds the binding")
	key_tap(.F6)
	check(!hit(.Cmd_Loop_Toggle), "keys: the old key no longer does it")
	key_release_all()
	key_frame()
	key_tap(.L, {.Ctrl})
	check(hit(.Cmd_Loop_Toggle), "keys: the new one does")
	key_release_all()
	who, clash := input.find_conflict(&ictx, input.on_key(.Escape), .Cmd_Save)
	check(clash && who == .Nav_Cancel, "keys: a settings screen can ask what a key is already used for")
	keymap_init() // (defaults back)

	fmt.println("keys: bindings, modifiers, exact chords, rebinding while running checked")
}
