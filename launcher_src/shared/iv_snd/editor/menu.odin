package main

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import snd "shared:iv_snd"
import ui "shared:iv_ui"

// ---------------------------------------------------------------------------
// Commands. Everything the editor can do is an Action: the menus, the command palette
// (Ctrl+P), the keys and the mouse all end up in run_action.
// ---------------------------------------------------------------------------

Action :: enum {
	None, // separator in menus

	File_New,
	File_Open,
	File_Import_Wav,
	File_Save,
	File_Save_As,
	File_Export_Wav,
	File_Export_Wav_Loops,
	File_Quit,

	Edit_Undo,
	Edit_Redo,
	Edit_Insert,
	Edit_Delete,
	Edit_Yank,
	Edit_Paste,
	Edit_Duplicate,
	Edit_Select_All,
	Edit_Select_Track,
	Edit_Select_None,
	Edit_Quantize,
	Edit_Transpose_Up,
	Edit_Transpose_Down,
	Edit_Octave_Up,
	Edit_Octave_Down,
	Edit_Vel_Up,
	Edit_Vel_Down,
	Edit_Vel_Set,
	Edit_Longer,
	Edit_Shorter,
	Edit_Note_Length,
	Edit_Move_To_Track,

	Track_Add,
	Track_Delete,
	Track_Rename,
	Track_Next,
	Track_Prev,
	Track_Mute,
	Track_Solo,
	Track_Instrument,
	Track_Patch,
	Track_New_Sampler,
	Track_Graph,
	Track_Volume,
	Track_Pan,
	Track_Reverb,
	Track_Delay,
	Delay_Settings,
	Mute_Clear,

	Song_Tempo,
	Song_Rename,
	Song_Beats_Per_Bar,
	Loop_Start,
	Loop_End,
	Loop_Clear,
	Song_End,
	Song_End_Clear,

	Play_Toggle,
	Play_Start,
	Play_Stop,
	Play_Loop_Toggle,
	Audition_Toggle,
	Follow_Toggle,

	View_Zoom_In,
	View_Zoom_Out,
	View_Grid_Next,
	View_Grid_Prev,
	View_Scale_Up,
	View_Scale_Down,
	View_Row_Taller,
	View_Row_Shorter,
	View_Goto_Start,
	View_Goto_End,
	View_Goto_Bar,
	View_Ghost,
	View_Effects,

	Help_Keys,
	Help_About,
	Palette,
}

Command :: struct {
	name:     string, // in the command palette
	label:    string, // in the menus
	shortcut: string,
}

COMMANDS := #partial [Action]Command {
	.File_New = {"File: New project", "New", "Ctrl+N"},
	.File_Open = {"File: Open...", "Open...", "Ctrl+O"},
	.File_Import_Wav = {"File: Import a WAV file as the track's instrument...", "Import WAV instrument...", ""},
	.File_Save = {"File: Save", "Save", "Ctrl+S"},
	.File_Save_As = {"File: Save as...", "Save as...", "Ctrl+Shift+S"},
	.File_Export_Wav = {"File: Export WAV...", "Export WAV...", "Ctrl+E"},
	.File_Export_Wav_Loops = {"File: Export WAV with loops...", "Export WAV (loops)...", ""},
	.File_Quit = {"File: Quit", "Quit", "Ctrl+Q"},
	.Edit_Undo = {"Edit: Undo", "Undo", "u"},
	.Edit_Redo = {"Edit: Redo", "Redo", "Ctrl+R"},
	.Edit_Insert = {"Edit: Insert note at cursor", "Insert note", "i"},
	.Edit_Delete = {"Edit: Delete notes", "Delete", "x"},
	.Edit_Yank = {"Edit: Copy (yank) notes", "Copy", "y"},
	.Edit_Paste = {"Edit: Paste notes at cursor", "Paste", "p"},
	.Edit_Duplicate = {"Edit: Duplicate notes", "Duplicate", "Ctrl+D"},
	.Edit_Select_All = {"Edit: Select all notes", "Select all", "Ctrl+A"},
	.Edit_Select_Track = {"Edit: Select all notes of the track", "Select track's notes", ""},
	.Edit_Select_None = {"Edit: Select nothing", "Select none", "Esc"},
	.Edit_Quantize = {"Edit: Quantize notes to the grid", "Quantize", "q"},
	.Edit_Transpose_Up = {"Edit: Transpose up a semitone", "Transpose +1", ""},
	.Edit_Transpose_Down = {"Edit: Transpose down a semitone", "Transpose -1", ""},
	.Edit_Octave_Up = {"Edit: Transpose up an octave", "Octave +1", ""},
	.Edit_Octave_Down = {"Edit: Transpose down an octave", "Octave -1", ""},
	.Edit_Vel_Up = {"Edit: Louder (velocity +5%)", "Velocity +5%", "+"},
	.Edit_Vel_Down = {"Edit: Softer (velocity -5%)", "Velocity -5%", "-"},
	.Edit_Vel_Set = {"Edit: Set velocity...", "Set velocity...", ""},
	.Edit_Longer = {"Edit: Make notes longer", "Longer", ">"},
	.Edit_Shorter = {"Edit: Make notes shorter", "Shorter", "<"},
	.Edit_Note_Length = {"Edit: Set the length of new notes...", "New note length...", ""},
	.Edit_Move_To_Track = {"Edit: Move notes to the current track", "Move to track", ""},
	.Track_Add = {"Track: Add a track", "Add track", ""},
	.Track_Delete = {"Track: Delete the current track", "Delete track", ""},
	.Track_Rename = {"Track: Rename the current track...", "Rename track...", ""},
	.Track_Next = {"Track: Next track", "Next track", "Tab"},
	.Track_Prev = {"Track: Previous track", "Previous track", "Shift+Tab"},
	.Track_Mute = {"Track: Mute / unmute the track", "Mute track", "M"},
	.Track_Solo = {"Track: Solo / unsolo the track", "Solo track", "S"},
	.Track_Instrument = {"Track: Choose the instrument...", "Instrument...", "Ctrl+I"},
	.Track_Patch = {"Track: Edit the instrument (its synth sound, or its zones when it has several)...", "Edit instrument...", "Ctrl+T"},
	.Track_New_Sampler = {"Track: New empty instrument (add WAV files and synth sounds on the keys) as the instrument...", "New sampler...", ""},
	.Track_Graph = {"Track: Choose the effects graph of the track (graphs are shared: any number of tracks can use one)...", "Effects graph...", ""},
	.Track_Volume = {"Track: Set volume...", "Volume...", ""},
	.Track_Pan = {"Track: Set pan...", "Pan...", ""},
	.Track_Reverb = {"Track: Set reverb send...", "Reverb send...", ""},
	.Track_Delay = {"Track: Set delay send...", "Delay send...", ""},
	.Delay_Settings = {"Song: Reverb and delay (echo) settings...", "Reverb and delay settings...", ""},
	.Mute_Clear = {"Track: Clear all mute and solo", "Clear mute/solo", ""},
	.Song_Tempo = {"Song: Set tempo at the cursor...", "Tempo...", "t"},
	.Song_Rename = {"Song: Rename the song...", "Rename song...", ""},
	.Song_Beats_Per_Bar = {"Song: Set beats per bar...", "Beats per bar...", ""},
	.Loop_Start = {"Song: Loop starts at the cursor", "Loop start here", ","},
	.Loop_End = {"Song: Loop ends at the cursor", "Loop end here", "."},
	.Loop_Clear = {"Song: Remove the loop", "Remove loop", ""},
	.Song_End = {"Song: The song ends at the cursor", "End here", ""},
	.Song_End_Clear = {"Song: End the song after the last note", "End after last note", ""},
	.Play_Toggle = {"Play: Play / stop from the cursor", "Play / stop", "Space"},
	.Play_Start = {"Play: Play from the start", "Play from start", "F5"},
	.Play_Stop = {"Play: Stop", "Stop", "Esc"},
	.Play_Loop_Toggle = {"Play: Loop playback on / off", "Loop playback", "F6"},
	.Audition_Toggle = {"Play: Sound the notes while editing on / off", "Sound while editing", ""},
	.Follow_Toggle = {"View: Scroll with the play head on / off", "Follow play head", ""},
	.View_Zoom_In = {"View: Zoom in", "Zoom in", "z"},
	.View_Zoom_Out = {"View: Zoom out", "Zoom out", "Z"},
	.View_Grid_Next = {"View: Finer grid", "Finer grid", "]"},
	.View_Grid_Prev = {"View: Coarser grid", "Coarser grid", "["},
	.View_Scale_Up = {"View: Bigger interface", "Bigger interface", "F11"},
	.View_Scale_Down = {"View: Smaller interface", "Smaller interface", "F12"},
	.View_Row_Taller = {"View: Taller key rows", "Taller key rows", "Alt+wheel"},
	.View_Row_Shorter = {"View: Shorter key rows", "Shorter key rows", "Alt+wheel"},
	.View_Goto_Start = {"View: Go to the start", "Go to start", "0"},
	.View_Goto_End = {"View: Go to the end", "Go to end", "$"},
	.View_Goto_Bar = {"View: Go to bar...", "Go to bar...", ""},
	.View_Ghost = {"View: Show the notes of the other tracks as ghosts on / off", "Show other tracks", ""},
	.View_Effects = {"View: Effect graphs (the library of graphs, and the graph of the track) / piano roll", "Effect graphs", "Ctrl+G"},
	.Help_Keys = {"Help: Keys and mouse", "Keys and mouse", "F1"},
	.Help_About = {"Help: About", "About", ""},
	.Palette = {"Command palette", "Command palette", "Ctrl+P"},
}

Menu :: struct {
	title: string,
	items: []Action,
}

MENUS := [?]Menu {
	{"File", []Action{.File_New, .File_Open, .File_Import_Wav, .None, .File_Save, .File_Save_As, .None, .File_Export_Wav, .File_Export_Wav_Loops, .None, .File_Quit}},
	{
		"Edit",
		[]Action {
			.Edit_Undo,
			.Edit_Redo,
			.None,
			.Edit_Insert,
			.Edit_Delete,
			.Edit_Yank,
			.Edit_Paste,
			.Edit_Duplicate,
			.None,
			.Edit_Select_All,
			.Edit_Select_Track,
			.Edit_Select_None,
			.None,
			.Edit_Quantize,
			.Edit_Transpose_Up,
			.Edit_Transpose_Down,
			.Edit_Octave_Up,
			.Edit_Octave_Down,
			.Edit_Vel_Up,
			.Edit_Vel_Down,
			.Edit_Vel_Set,
			.Edit_Longer,
			.Edit_Shorter,
			.Edit_Note_Length,
			.None,
			.Edit_Move_To_Track,
		},
	},
	{"Track", []Action{.Track_Add, .Track_Delete, .Track_Rename, .Track_Next, .Track_Prev, .Track_Mute, .Track_Solo, .Mute_Clear, .None, .Track_Instrument, .Track_Patch, .Track_New_Sampler, .None, .Track_Graph, .View_Effects, .None, .Track_Volume, .Track_Pan, .Track_Reverb, .Track_Delay}},
	{"Song", []Action{.Song_Tempo, .Song_Rename, .Song_Beats_Per_Bar, .Delay_Settings, .None, .Loop_Start, .Loop_End, .Loop_Clear, .Song_End, .Song_End_Clear, .None, .Play_Toggle, .Play_Start, .Play_Stop, .Play_Loop_Toggle, .Audition_Toggle}},
	{"View", []Action{.View_Zoom_In, .View_Zoom_Out, .View_Row_Taller, .View_Row_Shorter, .View_Grid_Next, .View_Grid_Prev, .None, .View_Goto_Start, .View_Goto_End, .View_Goto_Bar, .None, .Follow_Toggle, .View_Ghost, .View_Effects, .None, .View_Scale_Up, .View_Scale_Down}},
	{"Help", []Action{.Help_Keys, .Help_About, .Palette}},
}

// Actions that are switches show a check box in the menus.
action_toggle :: proc(a: Action) -> (is_toggle: bool, on: bool) {
	#partial switch a {
	case .Play_Loop_Toggle:
		return true, ed.loop_on
	case .Audition_Toggle:
		return true, ed.audition_on
	case .Follow_Toggle:
		return true, ed.follow
	case .View_Ghost:
		return true, ed.ghost_tracks
	case .View_Effects:
		return true, ed.view == .Graph
	case .Track_Mute:
		return true, ed.p.tracks[ed.cur_track].mute
	case .Track_Solo:
		return true, ed.p.tracks[ed.cur_track].solo
	}
	return false, false
}

// ---- running actions ------------------------------------------------------------------

quit_requested: bool
after_save: proc() // what waits for a save to finish (quit, new or open after "Save" in the unsaved-changes question)
export_loops: int // the number of loop rounds asked for, between the question and the file dialog

// Runs what waited for a save if the save worked; forgets it either way (so that a cancelled or failed save can
// not make the next, unrelated save quit the program).
finish_after_save :: proc(saved: bool) {
	f := after_save
	after_save = nil
	if saved && f != nil {
		f()
	}
}

parse_int_in :: proc(text: string, lo, hi: int) -> (v: int, ok: bool) {
	n, pok := strconv.parse_int(strings.trim_space(text))
	if !pok {
		ed_say("\"%s\" is not a number", text)
		return 0, false
	}
	if n < lo || n > hi {
		ed_say("Use a number from %d to %d", lo, hi)
		return 0, false
	}
	return n, true
}

// Runs `then` right away if there is nothing unsaved, else asks first.
confirm_unsaved :: proc(then: proc()) {
	if !ed.dirty {
		then()
		return
	}
	confirm_then = then
	open_confirm("Unsaved changes", "The project has changes that are not saved.", {"Save", "Discard", "Cancel"}, proc(choice: int) {
		switch choice {
		case 0:
			after_save = confirm_then
			run_action(.File_Save)
		case 1:
			confirm_then()
		}
	})
}

confirm_then: proc()

default_name :: proc(ext: string) -> string {
	stem := name_str(&ed.p.name)
	if ed.path != "" {
		b := path_base(ed.path)
		stem = b[:len(b) - len(path_ext(b))]
	}
	return fmt.tprintf("%s%s", stem, ext)
}

with_ext :: proc(path, ext: string) -> string {
	if strings.to_lower(path_ext(path), context.temp_allocator) == ext {
		return path
	}
	return fmt.tprintf("%s%s", path, ext)
}

cur_trk :: proc() -> ^Trk {
	return &ed.p.tracks[ed.cur_track]
}

run_action :: proc(a: Action) {
	switch a {
	case .None:
	case .File_New:
		confirm_unsaved(proc() {
			play_halt()
			ed_set_project(project_new(), "")
			ed_say("New project")
		})
	case .File_Import_Wav:
		open_file_dialog(.Open, "Import a WAV file as the instrument of the track (a sampler that follows the keys)", {".wav"}, "", proc(path: string) {
			file_import_wav(path)
		})
	case .File_Open:
		confirm_unsaved(proc() {
			open_file_dialog(.Open, "Open", {".psng", ".mid", ".midi"}, "", proc(path: string) {
				play_halt()
				file_load(path)
			})
		})
	case .File_Save:
		if ed.path == "" {
			run_action(.File_Save_As)
		} else {
			finish_after_save(file_save(ed.path))
		}
	case .File_Save_As:
		open_file_dialog(.Save, "Save project", {".psng"}, default_name(".psng"), proc(path: string) {
			finish_after_save(file_save(with_ext(path, ".psng")))
		})
	case .File_Export_Wav:
		export_loops = 0
		open_file_dialog(.Save, "Export WAV", {".wav"}, default_name(".wav"), proc(path: string) {
			export_request(with_ext(path, ".wav"), 0)
		})
	case .File_Export_Wav_Loops:
		open_prompt("Export: how many times is the loop played?", "2", proc(text: string) {
			if n, ok := parse_int_in(text, 1, 64); ok {
				export_loops = n
				open_file_dialog(.Save, "Export WAV", {".wav"}, default_name(".wav"), proc(path: string) {
					export_request(with_ext(path, ".wav"), export_loops)
				})
			}
		})
	case .File_Quit:
		confirm_unsaved(proc() {quit_requested = true})

	case .Edit_Undo:
		ed_undo()
	case .Edit_Redo:
		ed_redo()
	case .Edit_Insert:
		if ed_insert_note() {
			audition(ed.cur_track, ed.cursor_key, ed.def_vel)
		}
	case .Edit_Delete:
		ed_delete_targets()
	case .Edit_Yank:
		ed_yank()
	case .Edit_Paste:
		ed_paste(ed.cursor_tick)
	case .Edit_Duplicate:
		ed_duplicate()
	case .Edit_Select_All:
		sel_all(false)
	case .Edit_Select_Track:
		sel_all(true)
	case .Edit_Select_None:
		sel_clear()
	case .Edit_Quantize:
		ed_quantize_targets()
	case .Edit_Transpose_Up:
		transpose_targets(1)
	case .Edit_Transpose_Down:
		transpose_targets(-1)
	case .Edit_Octave_Up:
		transpose_targets(12)
	case .Edit_Octave_Down:
		transpose_targets(-12)
	case .Edit_Vel_Up:
		ed_velocity_targets(VEL_STEP)
	case .Edit_Vel_Down:
		ed_velocity_targets(-VEL_STEP)
	case .Edit_Vel_Set:
		open_prompt("Velocity in percent (1-100)", fmt.tprintf("%d", (ed.def_vel * 100 + 63) / 127), proc(text: string) {
			if n, ok := parse_int_in(text, 1, 100); ok {
				ed_set_velocity(vel_from_percent(n))
			}
		})
	case .Edit_Longer:
		ed_resize_targets(int(grid_ticks()))
	case .Edit_Shorter:
		ed_resize_targets(-int(grid_ticks()))
	case .Edit_Note_Length:
		open_prompt("Length of new notes in ticks (0 = the grid)", fmt.tprintf("%d", ed.note_len), proc(text: string) {
			if n, ok := parse_int_in(text, 0, 1_000_000); ok {
				ed.note_len = u32(n)
			}
		})
	case .Edit_Move_To_Track:
		ed_assign_targets(ed.cur_track)

	case .Track_Add:
		ed_add_track()
	case .Track_Delete:
		ed_delete_track(ed.cur_track)
	case .Track_Rename:
		open_prompt("Track name", name_str(&cur_trk().name), proc(text: string) {
			ed_edit(false)
			cur_trk().name = name_make(strings.trim_space(text))
		})
	case .Track_Next:
		ed.cur_track = (ed.cur_track + 1) % len(ed.p.tracks)
	case .Track_Prev:
		ed.cur_track = (ed.cur_track + len(ed.p.tracks) - 1) % len(ed.p.tracks)
	case .Track_Mute:
		cur_trk().mute = !cur_trk().mute
		mixer_changed()
	case .Track_Solo:
		cur_trk().solo = !cur_trk().solo
		mixer_changed()
	case .Track_Instrument:
		open_instrument_picker()
	case .Track_Patch:
		inst := track_inst(ed.cur_track)
		if len(inst.zones) == 1 && inst.zones[0].source == .Synth {
			open_patch_editor(ed.cur_track, 0) // one synth sound: its parameters (z goes to the zones)
		} else {
			open_sampler_editor(ed.cur_track)
		}
	case .Track_New_Sampler:
		open_prompt("Name of the new instrument (up to 23 letters)", "sampler", proc(text: string) {
			name := strings.trim_space(text)
			if name == "" {
				name = "sampler"
			}
			ed_set_track_instrument(ed.cur_track, snd.instrument_empty(name))
			open_sampler_editor(ed.cur_track)
		})
	case .Track_Graph:
		open_graph_picker()
	case .Track_Volume:
		open_mix_prompt("Track volume (0-100)", .Volume)
	case .Track_Pan:
		open_mix_prompt("Track pan (-100 left, 0 center, 100 right)", .Pan)
	case .Track_Reverb:
		open_mix_prompt("Track reverb send (0-100)", .Reverb)
	case .Track_Delay:
		open_mix_prompt("Track delay send (0-100, 0 = none)", .Delay)
	case .Delay_Settings:
		open_delay_editor()
	case .Mute_Clear:
		for &t in ed.p.tracks {
			t.mute = false
			t.solo = false
		}
		mixer_changed()

	case .Song_Tempo:
		open_prompt("Tempo in beats per minute, from the cursor on", fmt.tprintf("%.1f", bpm_at(ed.cursor_tick)), proc(text: string) {
			v, ok := strconv.parse_f32(strings.trim_space(text))
			if !ok || v < 10 || v > 400 {
				ed_say("Use a tempo from 10 to 400")
				return
			}
			ed_set_tempo(ed.cursor_tick, v)
		})
	case .Song_Rename:
		open_prompt("Song name", name_str(&ed.p.name), proc(text: string) {
			ed_edit(false)
			ed.p.name = name_make(strings.trim_space(text))
		})
	case .Song_Beats_Per_Bar:
		open_prompt("Beats per bar (1-32)", fmt.tprintf("%d", ed.beats_per_bar), proc(text: string) {
			if n, ok := parse_int_in(text, 1, 32); ok {
				ed.beats_per_bar = u32(n)
			}
		})
	case .Loop_Start:
		ed_edit(false)
		ed.p.loop_start = ed.cursor_tick
		if ed.p.loop_end <= ed.p.loop_start {
			ed.p.loop_end = 0
		}
		ed_say("Loop starts at %s", pos_text(ed.cursor_tick))
	case .Loop_End:
		if ed.cursor_tick <= ed.p.loop_start {
			ed_say("The loop end must be after the loop start")
		} else {
			ed_edit(false)
			ed.p.loop_end = ed.cursor_tick
			ed_say("Loop ends at %s", pos_text(ed.cursor_tick))
		}
	case .Loop_Clear:
		ed_edit(false)
		ed.p.loop_start = 0
		ed.p.loop_end = 0
		ed_say("Loop removed")
	case .Song_End:
		ed_edit(false)
		ed.p.end_tick = ed.cursor_tick
		ed_say("The song ends at %s", pos_text(ed.cursor_tick))
	case .Song_End_Clear:
		ed_edit(false)
		ed.p.end_tick = 0
		ed_say("The song ends after its last note")

	case .Play_Toggle:
		play_toggle(ed.cursor_tick)
	case .Play_Start:
		play_start(0)
	case .Play_Stop:
		play_halt()
	case .Play_Loop_Toggle:
		ed.loop_on = !ed.loop_on
		ed_say("Loop playback %s", "on" if ed.loop_on else "off")
		if play_active {
			p := play_pos()
			play_start(p)
		}
	case .Audition_Toggle:
		ed.audition_on = !ed.audition_on
	case .Follow_Toggle:
		ed.follow = !ed.follow
	case .View_Zoom_In:
		ed.beat_px = min(ed.beat_px * 3 / 2 + 1, 240)
		roll_keep_cursor_visible()
	case .View_Zoom_Out:
		ed.beat_px = max(ed.beat_px * 2 / 3, 6)
		roll_keep_cursor_visible()
	case .View_Grid_Next:
		ed.grid_idx = min(ed.grid_idx + 1, len(GRIDS) - 1)
		ed_say("Grid %s", GRIDS[ed.grid_idx].label)
	case .View_Grid_Prev:
		ed.grid_idx = max(ed.grid_idx - 1, 0)
		ed_say("Grid %s", GRIDS[ed.grid_idx].label)
	case .View_Scale_Up:
		set_ui_scale(ui_scale + 0.25)
	case .View_Scale_Down:
		set_ui_scale(ui_scale - 0.25)
	case .View_Row_Taller:
		ed.row_h = min(ed.row_h + 2, ROW_H_MAX)
	case .View_Row_Shorter:
		ed.row_h = max(ed.row_h - 2, ROW_H_MIN)
	case .View_Goto_Start:
		cursor_goto(0, ed.cursor_key)
	case .View_Goto_End:
		cursor_goto(project_end(&ed.p), ed.cursor_key)
	case .View_Goto_Bar:
		open_prompt("Go to bar", "1", proc(text: string) {
			if n, ok := parse_int_in(text, 1, 100_000); ok {
				cursor_goto(u32(n - 1) * bar_ticks(), ed.cursor_key)
			}
		})
	case .View_Ghost:
		ed.ghost_tracks = !ed.ghost_tracks
		ed_say("%s", "Showing the notes of the other tracks" if ed.ghost_tracks else "Showing the current track only")
	case .View_Effects:
		if ed.view == .Graph {
			ed.view = .Roll
		} else {
			graph_ed_open()
		}

	case .Help_Keys:
		open_help()
	case .Help_About:
		open_confirm("PlanCol sound editor", "Edits PSNG song files for the game's snd library: a piano roll for one instrument track at a time, a library of effect graphs that any tracks can share, a mixer and WAV export. What you hear here is exactly what the game plays.", {"OK"}, proc(choice: int) {})
	case .Palette:
		open_palette()
	}
}

transpose_targets :: proc(d: int) {
	t := targets()
	if len(t) == 0 {
		return
	}
	for i in t {
		k := int(ed.p.notes[i].key) + d
		if k < 0 || k > 127 {
			ed_say("Out of range")
			return
		}
	}
	ed_edit()
	for i in t {
		ed.p.notes[i].key = u8(int(ed.p.notes[i].key) + d)
	}
	ed.cursor_key = clamp(ed.cursor_key + d, 0, 127)
	audition(ed.cur_track, ed.cursor_key, ed.def_vel)
}

mixer_changed :: proc() {
	ed.need_release = true
	ed_changed()
}

// Asks for a mixer setting of the current track as a whole number of percent (pan: -100 .. 100).
open_mix_prompt :: proc(title: string, field: Mix_Field) {
	mix_field_asked = field
	v := track_mix(ed.cur_track, field)
	open_prompt(title, fmt.tprintf("%d", int(math.round_f32(v * 100))), proc(text: string) {
		lo := -100 if mix_field_asked == .Pan else 0
		if n, ok := parse_int_in(text, lo, 100); ok {
			track_set_mix(ed.cur_track, mix_field_asked, f32(n) / 100)
		}
	})
}

mix_field_asked: Mix_Field

export_request :: proc(path: string, loops: int) {
	export_begin(path, loops)
}

// ---- the menu bar -------------------------------------------------------------------------

menu_open: int = -1
menu_sel: int

MENU_H :: 26
ITEM_H :: 26
SEP_H :: 9
MENU_GUTTER :: 28 // the column of check marks in a menu

menu_title_rect :: proc(i: int) -> Rect {
	x := 6
	for j in 0 ..< i {
		x += text_width(MENUS[j].title) + 24
	}
	return Rect{x, 0, text_width(MENUS[i].title) + 24, MENU_H}
}

menu_item_label :: proc(a: Action) -> string {
	return COMMANDS[a].label
}

menu_drop_rect :: proc(i: int) -> Rect {
	w := 0
	h := 8
	for a in MENUS[i].items {
		if a == .None {
			h += SEP_H
			continue
		}
		w = max(w, ui.text_size(text_measure, menu_item_label(a)).w + 36 + ui.text_size(text_measure, COMMANDS[a].shortcut).w)
		h += ITEM_H
	}
	t := menu_title_rect(i)
	return Rect{t.x, MENU_H - 1, max(w + MENU_GUTTER + 18, 190), h}
}

menu_item_rect :: proc(i, item: int) -> Rect {
	d := menu_drop_rect(i)
	y := d.y + 4
	for a, j in MENUS[i].items {
		h := SEP_H if a == .None else ITEM_H
		if j == item {
			return Rect{d.x + 4, y, d.w - 8, h}
		}
		y += h
	}
	return {}
}

menu_close :: proc() {
	menu_open = -1
}

menu_step :: proc(dir: int) {
	items := MENUS[menu_open].items
	n := len(items)
	for _ in 0 ..< n {
		menu_sel = (menu_sel + dir + n) % n
		if items[menu_sel] != .None {
			break
		}
	}
}

menu_pick :: proc() {
	a := MENUS[menu_open].items[menu_sel]
	menu_close()
	run_action(a)
}

// Handles the mouse and keys for the menu bar. Returns true if it used the input.
menu_update :: proc() -> bool {
	bar := Rect{0, 0, win_w, MENU_H}
	// Titles.
	if menu_open < 0 {
		if mouse_in(bar) {
			cursor_hint(.POINTING_HAND)
		}
		if in_.pressed[BTN_L] && mouse_in(bar) {
			for i in 0 ..< len(MENUS) {
				if mouse_in(menu_title_rect(i)) {
					menu_open = i
					menu_sel = -1
					return true
				}
			}
			return true
		}
		if hit(.Menu_Toggle) {
			menu_open = 0
			menu_sel = -1
			menu_step(1)
			return true
		}
		return false
	}

	// A menu is open: it takes all input.
	if mouse_in(bar) {
		for i in 0 ..< len(MENUS) {
			if mouse_in(menu_title_rect(i)) && (i != menu_open) && (in_.dmx != 0 || in_.pressed[BTN_L]) {
				menu_open = i
				menu_sel = -1
			}
		}
	}
	drop := menu_drop_rect(menu_open)
	if mouse_in(drop) && (in_.dmx != 0 || in_.dmy != 0 || in_.pressed[BTN_L]) {
		for a, j in MENUS[menu_open].items {
			if a != .None && mouse_in(menu_item_rect(menu_open, j)) {
				menu_sel = j
			}
		}
	}
	if in_.pressed[BTN_L] {
		if mouse_in(drop) {
			if menu_sel >= 0 && mouse_in(menu_item_rect(menu_open, menu_sel)) {
				menu_pick()
			}
		} else if !mouse_in(bar) {
			menu_close()
		} else {
			// Click on the title of the open menu closes it.
			if mouse_in(menu_title_rect(menu_open)) {
				menu_close()
			}
		}
		return true
	}
	if hit(.Nav_Cancel) || hit(.Menu_Toggle) {
		menu_close()
		return true
	}
	if rep(.Nav_Down) {
		menu_step(1)
	}
	if rep(.Nav_Up) {
		menu_step(-1)
	}
	if rep(.Nav_Left) {
		menu_open = (menu_open + len(MENUS) - 1) % len(MENUS)
		menu_sel = -1
		menu_step(1)
	}
	if rep(.Nav_Right) {
		menu_open = (menu_open + 1) % len(MENUS)
		menu_sel = -1
		menu_step(1)
	}
	for c in in_.chars {
		switch c {
		case 'j':
			menu_step(1)
		case 'k':
			menu_step(-1)
		case 'h':
			menu_open = (menu_open + len(MENUS) - 1) % len(MENUS)
			menu_sel = -1
			menu_step(1)
		case 'l':
			menu_open = (menu_open + 1) % len(MENUS)
			menu_sel = -1
			menu_step(1)
		}
	}
	if menu_open >= 0 && (hit(.Nav_Confirm)) && menu_sel >= 0 {
		menu_pick()
	}
	return true
}

menu_draw_bar :: proc() {
	bar := Rect{0, 0, win_w, MENU_H}
	fill(bar, COL_BG1)
	hline(0, win_w - 1, MENU_H - 1, COL_LINE)
	for i in 0 ..< len(MENUS) {
		r := menu_title_rect(i)
		inner := Rect{r.x + 2, r.y + 3, r.w - 4, r.h - 6}
		if i == menu_open {
			fill_round(inner, 4, COL_ACCENT_DIM)
		} else if modal_kind == .None && menu_open < 0 && mouse_in(r) {
			fill_round(inner, 4, COL_BG3)
		}
		text_in(r, MENUS[i].title, COL_TEXT, .Ui, .Center, 0)
	}
	// Right side: the name of the song and a mark when it has unsaved changes.
	title := name_str(&ed.p.name)
	pad := 24 if ed.dirty else 14
	tw := text_width(title) + 2 * pad + 4
	text_in(Rect{win_w - tw, 0, tw, MENU_H}, title, COL_DIM, .Ui, .Right, pad)
	if ed.dirty {
		circle(win_w - 17, MENU_H / 2, 3.5, COL_PLAY)
	}
}

menu_draw_drop :: proc() {
	if menu_open < 0 {
		return
	}
	d := menu_drop_rect(menu_open)
	shadow(d, 6, 14)
	fill_round(d, 6, COL_BG2)
	frame_round(d, 6, COL_LINE2)
	for a, j in MENUS[menu_open].items {
		r := menu_item_rect(menu_open, j)
		if a == .None {
			hline(r.x + 6, r.x + r.w - 7, r.y + SEP_H / 2, COL_LINE2)
			continue
		}
		sel := j == menu_sel
		if sel {
			fill_round(r, 4, COL_ACCENT)
		}
		tc := Color{255, 255, 255, 255} if sel else COL_TEXT
		if is_t, on := action_toggle(a); is_t && on {
			icon_check(r.x + 14, r.y + r.h / 2, 10, tc)
		}
		text_in(Rect{r.x + MENU_GUTTER - 4, r.y, r.w, r.h}, menu_item_label(a), tc, .Ui, .Left, 0)
		text_in(r, COMMANDS[a].shortcut, Color{220, 232, 255, 255} if sel else COL_DIM, .Ui, .Right, 12)
	}
}
