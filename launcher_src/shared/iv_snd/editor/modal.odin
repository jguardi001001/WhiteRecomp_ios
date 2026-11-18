package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"
import snd "shared:iv_snd"
import ui "shared:iv_ui"

// ---------------------------------------------------------------------------
// Modal dialogs: one is open at a time and takes all the input.
//
//   prompt    one line of text (numbers, names)
//   picker    a filterable list; also the command palette (Ctrl+P)
//   file      the file dialog for Open, Save and Export
//   confirm   a question with buttons
//   help      the list of keys
//   patch     the sound editor of one zone of an instrument (parameters of its patch)
//   sampler   the editor of the zones of an instrument (recordings or synth sounds on key ranges, root keys, loops)
//   delay     the settings of the echo effect
// ---------------------------------------------------------------------------

Modal_Kind :: enum {
	None,
	Prompt,
	Picker,
	File,
	Confirm,
	Help,
	Patch,
	Delay,
	Sampler,
	Progress,
}

modal_kind: Modal_Kind
ui_blocked: bool // a menu or dialog is open: the rest of the interface sleeps

modal_close :: proc() {
	switch modal_kind {
	case .None:
	case .Prompt:
		delete(prompt.title)
		prompt.title = ""
	case .Picker:
		picker_free()
	case .File:
		file_dlg_free()
	case .Confirm:
		delete(confirm.title)
		delete(confirm.text)
		delete(confirm.buttons)
		confirm.buttons = nil
	case .Help:
	case .Patch:
		patch_drag = false
	case .Delay:
		delay_drag = -1
	case .Sampler:
	case .Progress:
		export_cancel() // (closing the dialog stops the export)
	}
	modal_kind = .None
}

// Updates the open dialog. Returns true if a dialog is open (it used the input).
modal_update :: proc() -> bool {
	switch modal_kind {
	case .None:
		return false
	case .Prompt:
		prompt_update()
	case .Picker:
		picker_update()
	case .File:
		file_dlg_update()
	case .Confirm:
		confirm_update()
	case .Help:
		help_update()
	case .Patch:
		patch_ed_update()
	case .Delay:
		delay_ed_update()
	case .Sampler:
		sampler_ed_update()
	case .Progress:
		progress_update()
	}
	return true
}

modal_draw :: proc() {
	switch modal_kind {
	case .None:
	case .Prompt:
		prompt_draw()
	case .Picker:
		picker_draw()
	case .File:
		file_dlg_draw()
	case .Confirm:
		confirm_draw()
	case .Help:
		help_draw()
	case .Patch:
		patch_ed_draw()
	case .Delay:
		delay_ed_draw()
	case .Sampler:
		sampler_ed_draw()
	case .Progress:
		progress_draw()
	}
}

// ---- helpers ---------------------------------------------------------------------------------

// A dialog box with a title bar; returns the area inside below the title. (main.odin has dimmed the window already.)
modal_box :: proc(r: Rect, title: string) -> Rect {
	return draw_dialog(r, title)
}

centered :: proc(w, h: int) -> Rect {
	w2 := min(w, win_w - 16)
	h2 := min(h, win_h - 16)
	return Rect{(win_w - w2) / 2, max((win_h - h2) / 3, 8), w2, h2}
}

// Splits a text into lines that fit `max_w` pixels (at the spaces).
wrap_text :: proc(s: string, max_w: int, id := Font_Id.Ui) -> []string {
	lines: [dynamic]string
	lines.allocator = context.temp_allocator
	line := ""
	for w in strings.split(s, " ", context.temp_allocator) {
		cand := w if line == "" else strings.concatenate({line, " ", w}, context.temp_allocator)
		if line != "" && text_width(cand, id) > max_w {
			append(&lines, line)
			line = w
		} else {
			line = cand
		}
	}
	append(&lines, line)
	return lines[:]
}

// The end of a long text that fits `max_w` pixels (a path, say), with ".." in front.
tail_fit :: proc(s: string, max_w: int) -> string {
	if text_width(s) <= max_w {
		return s
	}
	for i in 1 ..< len(s) {
		t := strings.concatenate({"...", s[i:]}, context.temp_allocator)
		if text_width(t) <= max_w {
			return t
		}
	}
	return s
}

// "Low_Pass" -> "Low Pass"
pretty :: proc(s: string) -> string {
	t, _ := strings.replace_all(s, "_", " ", context.temp_allocator)
	return t
}

// ---- text input ------------------------------------------------------------------------------

Text_Input :: struct {
	buf:    [256]u8,
	n:      int,
	caret:  int,
	scroll: int,
	fresh:  bool, // the text is selected: the next typed character replaces it
}

ti_set :: proc(t: ^Text_Input, s: string) {
	t.n = min(len(s), len(t.buf) - 1)
	for i in 0 ..< t.n {
		t.buf[i] = s[i]
	}
	t.caret = t.n
	t.scroll = 0
	t.fresh = t.n > 0
}

ti_str :: proc(t: ^Text_Input) -> string {
	return string(t.buf[:t.n])
}

ti_insert :: proc(t: ^Text_Input, s: string) {
	for i in 0 ..< len(s) {
		if t.n >= len(t.buf) - 1 || s[i] < 32 || s[i] > 126 {
			continue
		}
		for j := t.n; j > t.caret; j -= 1 {
			t.buf[j] = t.buf[j - 1]
		}
		t.buf[t.caret] = s[i]
		t.caret += 1
		t.n += 1
	}
}

ti_delete_range :: proc(t: ^Text_Input, from, to: int) {
	if from >= to {
		return
	}
	for i in 0 ..< t.n - to {
		t.buf[from + i] = t.buf[to + i]
	}
	t.n -= to - from
	t.caret = from
}

// Edits the text with the keys of this frame. Returns true if the text changed.
ti_update :: proc(t: ^Text_Input) -> bool {
	before := t.n
	changed := false
	typed := len(in_.chars) > 0 || rep(.Nav_Backspace) || rep(.Nav_Delete) || (in_.ctrl && k1(.V))
	if t.fresh && typed {
		t.n = 0
		t.caret = 0
		t.fresh = false
		changed = true
		if rep(.Nav_Backspace) || rep(.Nav_Delete) {
			return true
		}
	}
	if rep(.Nav_Left) || rep(.Nav_Right) || hit(.Nav_Home) || hit(.Nav_End) {
		t.fresh = false
	}
	for c in in_.chars {
		if c >= 32 && c < 127 {
			tmp := [1]u8{u8(c)}
			ti_insert(t, string(tmp[:]))
			changed = true
		}
	}
	if rep(.Nav_Backspace) && t.caret > 0 {
		if in_.ctrl {
			i := t.caret
			for i > 0 && t.buf[i - 1] == ' ' {
				i -= 1
			}
			for i > 0 && t.buf[i - 1] != ' ' && t.buf[i - 1] != '/' && t.buf[i - 1] != '\\' {
				i -= 1
			}
			ti_delete_range(t, i, t.caret)
		} else {
			ti_delete_range(t, t.caret - 1, t.caret)
		}
		changed = true
	}
	if rep(.Nav_Delete) && t.caret < t.n {
		ti_delete_range(t, t.caret, t.caret + 1)
		changed = true
	}
	if rep(.Nav_Left) {
		t.caret = max(t.caret - 1, 0)
	}
	if rep(.Nav_Right) {
		t.caret = min(t.caret + 1, t.n)
	}
	if hit(.Nav_Home) {
		t.caret = 0
	}
	if hit(.Nav_End) {
		t.caret = t.n
	}
	if in_.ctrl && k1(.U) {
		ti_delete_range(t, 0, t.caret)
		changed = true
	}
	if in_.ctrl && k1(.V) {
		cs := rl.GetClipboardText()
		if cs != nil {
			ti_insert(t, string(cs))
			changed = true
		}
	}
	_ = before
	return changed
}

ti_draw :: proc(t: ^Text_Input, r: Rect, focused: bool) {
	fill_round(r, 4, COL_BG0)
	frame_round(r, 4, COL_ACCENT if focused else COL_LINE2)
	pad := 9
	s := ti_str(t)
	caret_x := text_width(s[:min(t.caret, len(s))])
	off := max(caret_x - (r.w - 2 * pad) + 3, 0) // the text slides left when the caret is at the end of a long one
	saved := clip_to(ui.inset(r, 1))
	tx := r.x + pad - off
	cy := r.y + (r.h - cap_height()) / 2
	selected := t.fresh && t.n > 0
	if focused && selected {
		fill_round(Rect{tx - 2, r.y + 5, text_width(s) + 4, r.h - 10}, 3, with_alpha(COL_ACCENT, 0.5))
	}
	text(tx, cy, s, COL_TEXT)
	if focused && !selected && int(now() * 2) % 2 == 0 {
		fill(Rect{tx + caret_x, r.y + 6, 2, r.h - 12}, COL_TEXT)
	}
	clip_restore(saved)
}

// ---- prompt ------------------------------------------------------------------------------------

Prompt :: struct {
	title: string,
	ti:    Text_Input,
	ok:    proc(text: string),
}

prompt: Prompt

open_prompt :: proc(title, initial: string, ok: proc(text: string)) {
	modal_close()
	prompt.title = strings.clone(title)
	ti_set(&prompt.ti, initial)
	prompt.ok = ok
	modal_kind = .Prompt
}

prompt_rects :: proc() -> (box, field, okb, cancel: Rect) {
	box = centered(min(win_w - 20, 540), DIALOG_TITLE_H + 14 + 34 + 16 + 30 + 14)
	field = Rect{box.x + 14, box.y + DIALOG_TITLE_H + 14, box.w - 28, 34}
	okb = Rect{box.x + box.w - 14 - 2 * 92 - 8, field.y + field.h + 16, 92, 30}
	cancel = Rect{okb.x + 100, okb.y, 92, 30}
	return
}

prompt_update :: proc() {
	_, _, okb, cancel := prompt_rects()
	ti_update(&prompt.ti)
	accept := hit(.Nav_Confirm)
	if in_.pressed[BTN_L] {
		if mouse_in(okb) {
			accept = true
		} else if mouse_in(cancel) {
			modal_close()
			return
		}
	}
	if hit(.Nav_Cancel) {
		modal_close()
		return
	}
	if accept {
		ok := prompt.ok
		text := strings.clone(ti_str(&prompt.ti), context.temp_allocator)
		modal_close()
		if ok != nil {
			ok(text)
		}
	}
}

prompt_draw :: proc() {
	box, field, okb, cancel := prompt_rects()
	modal_box(box, prompt.title)
	ti_draw(&prompt.ti, field, true)
	draw_button(okb, "OK", true)
	draw_button(cancel, "Cancel")
}

// ---- confirm -------------------------------------------------------------------------------------

Confirm :: struct {
	title, text: string,
	buttons:     []string,
	ok:          proc(choice: int),
}

confirm: Confirm

open_confirm :: proc(title, text: string, buttons: []string, ok: proc(choice: int)) {
	modal_close()
	confirm.title = strings.clone(title)
	confirm.text = strings.clone(text)
	confirm.buttons = slice.clone(buttons)
	confirm.ok = ok
	modal_kind = .Confirm
}

confirm_rects :: proc() -> (box: Rect, btns: [4]Rect, lines: []string) {
	w := min(win_w - 20, 500)
	lines = wrap_text(confirm.text, w - 28)
	h := DIALOG_TITLE_H + 16 + len(lines) * 20 + 18 + 30 + 14
	box = centered(w, h)
	x := box.x + box.w - 14
	for i := len(confirm.buttons) - 1; i >= 0; i -= 1 {
		bw := max(text_width(confirm.buttons[i]) + 32, 80)
		x -= bw
		btns[i] = Rect{x, box.y + box.h - 14 - 30, bw, 30}
		x -= 8
	}
	return
}

confirm_update :: proc() {
	_, btns, _ := confirm_rects()
	choice := -1
	if in_.pressed[BTN_L] {
		for i in 0 ..< len(confirm.buttons) {
			if mouse_in(btns[i]) {
				choice = i
			}
		}
	}
	for c in in_.chars {
		lower := c + 32 if c >= 'A' && c <= 'Z' else c // (Y and y both answer "Yes")
		for b, i in confirm.buttons {
			if len(b) > 0 && strings.to_lower(b[:1], context.temp_allocator)[0] == u8(lower) {
				choice = i
			}
		}
		if c >= '1' && c <= '4' && int(c - '1') < len(confirm.buttons) {
			choice = int(c - '1')
		}
	}
	if hit(.Nav_Confirm) {
		choice = 0
	}
	if hit(.Nav_Cancel) {
		choice = len(confirm.buttons) - 1
	}
	if choice >= 0 {
		ok := confirm.ok
		modal_close()
		if ok != nil {
			ok(choice)
		}
	}
}

confirm_draw :: proc() {
	box, btns, lines := confirm_rects()
	inner := modal_box(box, confirm.title)
	y := inner.y + 4
	for l in lines {
		text(inner.x, y, l, COL_TEXT)
		y += 20
	}
	for b, i in confirm.buttons {
		draw_button(btns[i], b, i == 0)
	}
}

// ---- picker and command palette ----------------------------------------------------------------------

Picker_Item :: struct {
	label: string,
	right: string,
	id:    int,
}

Picker :: struct {
	title:    string,
	all:      [dynamic]Picker_Item, // owns the strings
	shown:    [dynamic]int, // indexes into all, best match first
	sel:      int,
	scroll:   int,
	filter:   Text_Input,
	on_pick:  proc(id: int),
	on_move:  proc(id: int),
	is_pal:   bool,
}

picker: Picker

PICKER_ROWS :: 14
PICKER_ROW_H :: 24

picker_free :: proc() {
	for it in picker.all {
		delete(it.label)
		delete(it.right)
	}
	delete(picker.all)
	delete(picker.shown)
	delete(picker.title)
	picker = {}
}

// Opens a list; `items` are copied (the strings in them must be heap strings that are given to the picker).
open_picker :: proc(title: string, items: []Picker_Item, selected: int, on_pick: proc(id: int), on_move: proc(id: int)) {
	modal_close()
	picker.title = strings.clone(title)
	for it in items {
		append(&picker.all, Picker_Item{strings.clone(it.label), strings.clone(it.right), it.id})
	}
	picker.on_pick = on_pick
	picker.on_move = on_move
	picker.filter = {}
	picker_refilter()
	for idx, i in picker.shown {
		if picker.all[idx].id == selected {
			picker.sel = i
		}
	}
	picker_scroll_to_sel()
	modal_kind = .Picker
	picker_moved()
}

// Fuzzy score of `pat` in `s` (both lower case); -1 if it is not a subsequence.
fuzzy_score :: proc(pat, s: string) -> int {
	if len(pat) == 0 {
		return 0
	}
	score := 0
	si := 0
	prev := -2
	for pi in 0 ..< len(pat) {
		if pat[pi] == ' ' {
			continue
		}
		found := -1
		for j := si; j < len(s); j += 1 {
			if s[j] == pat[pi] {
				found = j
				break
			}
		}
		if found < 0 {
			return -1
		}
		if found == prev + 1 {
			score += 8
		}
		if found == 0 || s[found - 1] == ' ' || s[found - 1] == ':' {
			score += 6
		}
		score -= (found - si)
		prev = found
		si = found + 1
	}
	return score + 1000 - len(s)
}

picker_refilter :: proc() {
	clear(&picker.shown)
	pat := strings.to_lower(ti_str(&picker.filter), context.temp_allocator)
	Scored :: struct {
		idx, score: int,
	}
	scored: [dynamic]Scored
	scored.allocator = context.temp_allocator
	for it, i in picker.all {
		hay := strings.to_lower(fmt.tprintf("%s %s", it.label, it.right), context.temp_allocator)
		sc := fuzzy_score(pat, hay)
		if sc >= 0 {
			append(&scored, Scored{i, sc})
		}
	}
	if pat != "" {
		slice.stable_sort_by(scored[:], proc(a, b: Scored) -> bool {return a.score > b.score})
	}
	for s in scored {
		append(&picker.shown, s.idx)
	}
	picker.sel = 0
	picker.scroll = 0
}

picker_scroll_to_sel :: proc() {
	if picker.sel < picker.scroll {
		picker.scroll = picker.sel
	}
	if picker.sel >= picker.scroll + PICKER_ROWS {
		picker.scroll = picker.sel - PICKER_ROWS + 1
	}
	picker.scroll = max(min(picker.scroll, len(picker.shown) - PICKER_ROWS), 0)
}

picker_moved :: proc() {
	if picker.on_move != nil && picker.sel >= 0 && picker.sel < len(picker.shown) {
		picker.on_move(picker.all[picker.shown[picker.sel]].id)
	}
}

picker_rects :: proc() -> (box, field, list: Rect) {
	h := DIALOG_TITLE_H + 12 + 34 + 10 + PICKER_ROWS * PICKER_ROW_H + 14
	box = centered(min(win_w - 16, 720), h)
	field = Rect{box.x + 14, box.y + DIALOG_TITLE_H + 12, box.w - 28, 34}
	list = Rect{box.x + 14, field.y + field.h + 10, box.w - 28, PICKER_ROWS * PICKER_ROW_H}
	return
}

picker_pick :: proc(shown_index: int) {
	if shown_index < 0 || shown_index >= len(picker.shown) {
		return
	}
	id := picker.all[picker.shown[shown_index]].id
	cb := picker.on_pick
	modal_close()
	if cb != nil {
		cb(id)
	}
}

picker_update :: proc() {
	_, _, list := picker_rects()
	if ti_update(&picker.filter) {
		picker_refilter()
		picker_moved()
	}
	old := picker.sel
	n := len(picker.shown)
	if rep(.Nav_Down) || (in_.ctrl && (kp(.J) || kp(.N))) {
		picker.sel = min(picker.sel + 1, n - 1)
	}
	if rep(.Nav_Up) || (in_.ctrl && (kp(.K) || kp(.P))) {
		picker.sel = max(picker.sel - 1, 0)
	}
	if rep(.Nav_Page_Down) {
		picker.sel = min(picker.sel + PICKER_ROWS, n - 1)
	}
	if rep(.Nav_Page_Up) {
		picker.sel = max(picker.sel - PICKER_ROWS, 0)
	}
	if mouse_in(list) {
		if in_.wheel_y != 0 {
			picker.scroll = clamp(picker.scroll - int(in_.wheel_y) * 3, 0, max(n - PICKER_ROWS, 0))
		}
		if in_.pressed[BTN_L] {
			row := (in_.my - list.y) / PICKER_ROW_H + picker.scroll
			if row < n {
				picker.sel = row
				picker_pick(row)
				return
			}
		}
	}
	picker.sel = clamp(picker.sel, 0, max(n - 1, 0))
	if picker.sel != old {
		picker_scroll_to_sel()
		picker_moved()
	}
	if hit(.Nav_Confirm) {
		picker_pick(picker.sel)
		return
	}
	if hit(.Nav_Cancel) {
		modal_close()
	}
}

picker_draw :: proc() {
	box, field, list := picker_rects()
	modal_box(box, picker.title)
	ti_draw(&picker.filter, field, true)
	if len(picker.shown) == 0 {
		text(list.x + 8, list.y + 8, "(nothing matches)", COL_DIM)
		return
	}
	saved := clip_to(list)
	for row in 0 ..< PICKER_ROWS {
		i := row + picker.scroll
		if i >= len(picker.shown) {
			break
		}
		it := picker.all[picker.shown[i]]
		r := Rect{list.x, list.y + row * PICKER_ROW_H, list.w - 10, PICKER_ROW_H}
		sel := i == picker.sel
		draw_row(r, sel, hover(r))
		rw := text_width(it.right)
		text_in(Rect{r.x, r.y, r.w - rw - 18, r.h}, it.label, COL_TEXT, .Ui, .Left, 12)
		text_in(r, it.right, COL_DIM if sel else COL_FAINT, .Ui, .Right, 12)
	}
	clip_restore(saved)
	// Scroll position.
	if len(picker.shown) > PICKER_ROWS {
		th := max(list.h * PICKER_ROWS / len(picker.shown), 18)
		ty := list.y + picker.scroll * (list.h - th) / max(len(picker.shown) - PICKER_ROWS, 1)
		fill_round(Rect{list.x + list.w - 6, ty, 4, th}, 2, COL_BG4)
	}
}

open_palette :: proc() {
	items: [dynamic]Picker_Item
	items.allocator = context.temp_allocator
	for a in Action {
		if a == .None || a == .Palette {
			continue
		}
		append(&items, Picker_Item{COMMANDS[a].name, COMMANDS[a].shortcut, int(a)})
	}
	open_picker("Command palette", items[:], -1, proc(id: int) {run_action(Action(id))}, nil)
	picker.is_pal = true
}

LIB_BASE :: 1000 // picker ids of the library instruments: LIB_BASE + index
IMPORT_ID :: 2000 // picker id of "import a WAV file"
SAMPLER_NEW_ID :: 2001 // picker id of "new empty instrument"
// (the instruments of the song have their index as id)

// The key to test an instrument on: the middle of the keyboard; for an instrument that has no zone there, the key
// of a bass drum, or else the first key it plays.
inst_test_key :: proc(inst: ^snd.Instrument) -> int {
	for k in ([?]int{60, 36}) {
		if snd.instrument_find_zone(inst, k) != nil {
			return k
		}
	}
	if len(inst.zones) > 0 {
		return int(inst.zones[0].key_lo)
	}
	return 60
}

open_instrument_picker :: proc() {
	items: [dynamic]Picker_Item
	items.allocator = context.temp_allocator
	append(&items, Picker_Item{"Import a WAV file as an instrument...", "", IMPORT_ID})
	append(&items, Picker_Item{"New instrument: WAV files and synth sounds on key ranges...", "", SAMPLER_NEW_ID})
	for i in 0 ..< snd.library_count() {
		cat := snd.library_category_name(snd.library_category(i))
		append(&items, Picker_Item{fmt.tprintf("Library: %s - %s", cat, snd.library_name(i)), "samples" if snd.library_has_samples(i) else "synth", LIB_BASE + i})
	}
	for inst, i in ed.p.instruments {
		append(&items, Picker_Item{fmt.tprintf("%02d  %s", i + 1, snd.instrument_name(inst)), snd.instrument_makeup(inst), i})
	}
	title := fmt.tprintf("Instrument for track %d (the numbered ones are in this song)", ed.cur_track + 1)
	open_picker(title, items[:], track_instrument(ed.cur_track), proc(id: int) {
		switch {
		case id == IMPORT_ID:
			run_action(.File_Import_Wav)
		case id == SAMPLER_NEW_ID:
			run_action(.Track_New_Sampler)
		case id >= LIB_BASE:
			ed_set_track_instrument(ed.cur_track, snd.library_instrument(id - LIB_BASE))
			audition(ed.cur_track, inst_test_key(track_inst(ed.cur_track)), ed.def_vel)
		case:
			track_set_instrument(ed.cur_track, id)
			audition(ed.cur_track, inst_test_key(track_inst(ed.cur_track)), ed.def_vel)
		}
	}, proc(id: int) {
		switch {
		case id == IMPORT_ID, id == SAMPLER_NEW_ID:
		case id >= LIB_BASE:
			inst := snd.library_instrument(id - LIB_BASE) // (the sound keeps what it needs of it)
			snd.sfx_play_instrument(&audio, inst, inst_test_key(inst), 0.5, 0.8)
			snd.instrument_destroy(inst)
		case id >= 0 && id < len(ed.p.instruments):
			inst := ed.p.instruments[id]
			snd.sfx_play_instrument(&audio, inst, inst_test_key(inst), 0.3, 0.8)
		}
	})
}

// ---- file dialog -------------------------------------------------------------------------------------

File_Mode :: enum {
	Open,
	Save,
}

File_Entry :: struct {
	name:   string,
	is_dir: bool,
	size:   i64,
}

File_Dlg :: struct {
	mode:       File_Mode,
	title:      string,
	dir:        string,
	entries:    [dynamic]File_Entry,
	sel:        int,
	scroll:     int,
	name:       Text_Input,
	focus_name: bool,
	filters:    [dynamic]string,
	show_all:   bool,
	ok:         proc(path: string),
	err:        string, // shown under the list
	err_buf:    string, // the text of err when it was built (owned)
}

file_dlg: File_Dlg
last_dir: string

FILE_ROWS :: 15
FILE_ROW_H :: 24

file_dlg_free :: proc() {
	for e in file_dlg.entries {
		delete(e.name)
	}
	delete(file_dlg.entries)
	delete(file_dlg.title)
	for f in file_dlg.filters {
		delete(f)
	}
	delete(file_dlg.filters)
	delete(file_dlg.dir)
	delete(file_dlg.err_buf)
	file_dlg = {}
}

path_has_sep :: proc(s: string) -> bool {
	return strings.contains_rune(s, '/') || strings.contains_rune(s, '\\')
}

path_join :: proc(dir, name: string) -> string {
	if dir == "" {
		return strings.clone(name)
	}
	last := dir[len(dir) - 1]
	if last == '/' || last == '\\' {
		return strings.concatenate({dir, name})
	}
	sep := "\\" if strings.contains_rune(dir, '\\') else "/"
	return strings.concatenate({dir, sep, name})
}

path_parent :: proc(p: string) -> string {
	s := p
	for len(s) > 1 && (s[len(s) - 1] == '/' || s[len(s) - 1] == '\\') {
		s = s[:len(s) - 1]
	}
	if len(s) == 2 && s[1] == ':' {
		return ""
	}
	i := len(s) - 1
	for i >= 0 && s[i] != '/' && s[i] != '\\' {
		i -= 1
	}
	if i < 0 {
		return s
	}
	if i == 0 {
		return s[:1]
	}
	if i == 2 && s[1] == ':' {
		return s[:3]
	}
	return s[:i]
}

open_file_dialog :: proc(mode: File_Mode, title: string, filters: []string, default_name: string, ok: proc(path: string)) {
	modal_close()
	dir := strings.clone(last_dir) if last_dir != "" else ""
	if dir == "" {
		if ed.path != "" {
			dir = strings.clone(path_parent(ed.path))
		} else if wd, err := os.get_working_directory(context.allocator); err == nil {
			dir = wd
		} else {
			dir = strings.clone(".")
		}
	}
	file_dlg = {}
	file_dlg.mode = mode
	file_dlg.title = strings.clone(title)
	file_dlg.dir = dir
	for f in filters {
		append(&file_dlg.filters, strings.clone(f))
	}
	file_dlg.ok = ok
	ti_set(&file_dlg.name, default_name)
	file_dlg.focus_name = mode == .Save
	modal_kind = .File
	file_dlg_read()
}

ext_matches :: proc(name: string) -> bool {
	if file_dlg.show_all || len(file_dlg.filters) == 0 {
		return true
	}
	e := strings.to_lower(path_ext(name), context.temp_allocator)
	for f in file_dlg.filters {
		if e == f {
			return true
		}
	}
	return false
}

// Can the folder `p` be listed?
dir_readable :: proc(p: string) -> bool {
	infos, err := os.read_all_directory_by_path(p, context.temp_allocator)
	if err != nil {
		return false
	}
	os.file_info_slice_delete(infos, context.temp_allocator)
	return true
}

// A folder near `dir` that can be read (an allocated string): its closest readable parent, else the
// working directory, else "" (the list of drives).
dir_fallback :: proc(dir: string) -> string {
	cur := dir
	for _ in 0 ..< 64 {
		parent := path_parent(cur)
		if parent == cur || parent == "" {
			break
		}
		if dir_readable(parent) {
			return strings.clone(parent)
		}
		cur = parent
	}
	if wd, err := os.get_working_directory(context.allocator); err == nil {
		if dir_readable(wd) {
			return wd
		}
		delete(wd)
	}
	return strings.clone("")
}

file_dlg_set_err :: proc(msg: string) {
	delete(file_dlg.err_buf)
	file_dlg.err_buf = strings.clone(msg)
	file_dlg.err = file_dlg.err_buf
}

file_dlg_read :: proc(depth := 0) {
	for e in file_dlg.entries {
		delete(e.name)
	}
	clear(&file_dlg.entries)
	delete(file_dlg.err_buf)
	file_dlg.err_buf = ""
	file_dlg.err = ""
	file_dlg.sel = 0
	file_dlg.scroll = 0
	if file_dlg.dir == "" {
		// The list of drives (Windows).
		for c in 'A' ..= 'Z' {
			p := fmt.tprintf("%c:\\", c)
			if os.exists(p) {
				append(&file_dlg.entries, File_Entry{name = strings.clone(p), is_dir = true})
			}
		}
		if len(file_dlg.entries) == 0 {
			file_dlg.err = "No drives found"
		}
		return
	}
	infos, err := os.read_all_directory_by_path(file_dlg.dir, context.allocator)
	if err != nil {
		// Do not stay stuck in a folder that cannot be read: go to the nearest one that can.
		what := strings.clone(path_base(file_dlg.dir))
		defer delete(what)
		if depth < 3 {
			alt := dir_fallback(file_dlg.dir)
			defer delete(alt)
			if alt != file_dlg.dir {
				file_dlg_cd(alt, depth + 1)
				where_to := alt if alt != "" else "the drive list"
				file_dlg_set_err(fmt.tprintf("Cannot read %s (%v); showing %s", what, err, where_to))
				return
			}
		}
		file_dlg_set_err(fmt.tprintf("Cannot read %s (%v)", what, err))
		append(&file_dlg.entries, File_Entry{name = strings.clone(".."), is_dir = true})
		return
	}
	defer os.file_info_slice_delete(infos, context.allocator)
	append(&file_dlg.entries, File_Entry{name = strings.clone(".."), is_dir = true})
	for fi in infos {
		hidden := len(fi.name) > 0 && fi.name[0] == '.'
		if hidden && !file_dlg.show_all {
			continue
		}
		is_dir := fi.type == .Directory
		if !is_dir && !ext_matches(fi.name) {
			continue
		}
		append(&file_dlg.entries, File_Entry{name = strings.clone(fi.name), is_dir = is_dir, size = fi.size})
	}
	if len(file_dlg.entries) > 1 {
		slice.sort_by(file_dlg.entries[1:], proc(a, b: File_Entry) -> bool {
			if a.is_dir != b.is_dir {
				return a.is_dir
			}
			la := strings.to_lower(a.name, context.temp_allocator)
			lb := strings.to_lower(b.name, context.temp_allocator)
			return la < lb
		})
	}
}

// `dir` may be a piece of the current folder's own string (the parent of it, say), so it is copied
// before the old one is freed.
file_dlg_cd :: proc(dir: string, depth := 0) {
	next := strings.clone(dir)
	delete(file_dlg.dir)
	file_dlg.dir = next
	file_dlg_read(depth)
}

file_dlg_up :: proc() {
	if file_dlg.dir == "" {
		return
	}
	old := strings.clone(path_base(file_dlg.dir)) // (the folder string is replaced by the next line)
	defer delete(old)
	file_dlg_cd(path_parent(file_dlg.dir))
	for e, i in file_dlg.entries {
		if e.name == old {
			file_dlg.sel = i
			file_dlg_scroll()
		}
	}
}

file_dlg_scroll :: proc() {
	if file_dlg.sel < file_dlg.scroll {
		file_dlg.scroll = file_dlg.sel
	}
	if file_dlg.sel >= file_dlg.scroll + FILE_ROWS {
		file_dlg.scroll = file_dlg.sel - FILE_ROWS + 1
	}
	file_dlg.scroll = max(min(file_dlg.scroll, len(file_dlg.entries) - FILE_ROWS), 0)
}

// Chooses the file `path` (asks before overwriting when saving).
file_dlg_finish :: proc(path: string) {
	if file_dlg.mode == .Save && os.exists(path) {
		pending_path = strings.clone(path)
		pending_ok = file_dlg.ok
		file_dlg_remember_dir() // (opening the question closes this dialog)
		open_confirm("Overwrite?", fmt.tprintf("%s exists already. Replace it?", path_base(path)), {"Yes", "No"}, proc(choice: int) {
			if choice == 0 && pending_ok != nil {
				pending_ok(pending_path)
			} else {
				after_save = nil // (a save that was waiting for this file is off)
			}
			delete(pending_path)
			pending_path = ""
		})
		return
	}
	cb := file_dlg.ok
	owned := strings.clone(path)
	defer delete(owned)
	modal_close_keep_dir()
	if cb != nil {
		cb(owned)
	}
}

pending_path: string
pending_ok: proc(path: string)

// Closes the dialog without forgetting the folder it was in.
modal_close_keep_dir :: proc() {
	dir := strings.clone(file_dlg.dir)
	modal_close()
	delete(last_dir)
	last_dir = dir
}

file_dlg_rects :: proc() -> (box, path_r, list, name_r, okb, cancel: Rect) {
	h := DIALOG_TITLE_H + 12 + 30 + 8 + FILE_ROWS * FILE_ROW_H + 12 + 34 + 14 + 30 + 14
	box = centered(min(win_w - 16, 820), h)
	path_r = Rect{box.x + 14, box.y + DIALOG_TITLE_H + 12, box.w - 28, 30}
	list = Rect{box.x + 14, path_r.y + path_r.h + 8, box.w - 28, FILE_ROWS * FILE_ROW_H}
	name_r = Rect{box.x + 14 + 62, list.y + list.h + 12, box.w - 28 - 62, 34}
	okb = Rect{box.x + box.w - 14 - 2 * 100 - 8, name_r.y + name_r.h + 14, 100, 30}
	cancel = Rect{okb.x + 108, okb.y, 100, 30}
	return
}

// Remembers the folder of the dialog for the next one (the dialog itself is about to be replaced).
file_dlg_remember_dir :: proc() {
	dir := strings.clone(file_dlg.dir)
	delete(last_dir)
	last_dir = dir
}

// Escape or Cancel: closes the dialog and forgets that a save was waiting for it (quit after "Save", say).
file_dlg_cancel :: proc() {
	after_save = nil
	modal_close_keep_dir()
}

file_dlg_activate :: proc(i: int) {
	if i < 0 || i >= len(file_dlg.entries) {
		return
	}
	e := file_dlg.entries[i]
	if e.is_dir {
		if e.name == ".." {
			file_dlg_up()
		} else if file_dlg.dir == "" {
			file_dlg_cd(e.name)
		} else {
			p := path_join(file_dlg.dir, e.name)
			file_dlg_cd(p)
			delete(p)
		}
		return
	}
	p := path_join(file_dlg.dir, e.name)
	defer delete(p)
	if file_dlg.mode == .Save {
		ti_set(&file_dlg.name, e.name)
		file_dlg.focus_name = true
	} else {
		file_dlg_finish(p)
	}
}

// Enter in the name field: go to a folder, or choose the file.
file_dlg_accept_name :: proc() {
	name := strings.trim_space(ti_str(&file_dlg.name))
	if name == "" {
		return
	}
	full: string
	absolute := name[0] == '/' || name[0] == '\\' || (len(name) > 1 && name[1] == ':')
	if absolute {
		full = strings.clone(name)
	} else {
		full = path_join(file_dlg.dir, name)
	}
	defer delete(full)
	if os.is_directory(full) {
		file_dlg_cd(full)
		ti_set(&file_dlg.name, "")
		return
	}
	file_dlg_finish(full)
}

file_dlg_update :: proc() {
	_, _, list, name_r, okb, cancel := file_dlg_rects()
	n := len(file_dlg.entries)
	if file_dlg.focus_name {
		ti_update(&file_dlg.name)
		if hit(.Nav_Confirm) {
			file_dlg_accept_name()
			return
		}
		if hit(.Nav_Tab) {
			file_dlg.focus_name = false
		}
		if hit(.Nav_Cancel) {
			if file_dlg.mode == .Open {
				file_dlg.focus_name = false
			} else {
				file_dlg_cancel()
				return
			}
		}
		if rep(.Nav_Down) {
			file_dlg.focus_name = false
		}
	} else {
		for c in in_.chars {
			switch c {
			case 'j':
				file_dlg.sel = min(file_dlg.sel + 1, n - 1)
			case 'k':
				file_dlg.sel = max(file_dlg.sel - 1, 0)
			case 'h':
				file_dlg_up()
			case 'l':
				file_dlg_activate(file_dlg.sel)
			case 'g':
				file_dlg.sel = 0
			case 'G':
				file_dlg.sel = n - 1
			case 'i', '/':
				file_dlg.focus_name = true
			case '.':
				file_dlg.show_all = !file_dlg.show_all
				file_dlg_read()
			}
			if !file_dlg_open() {
				return
			}
		}
		if rep(.Nav_Down) {
			file_dlg.sel = min(file_dlg.sel + 1, n - 1)
		}
		if rep(.Nav_Up) {
			file_dlg.sel = max(file_dlg.sel - 1, 0)
		}
		if rep(.Nav_Page_Down) {
			file_dlg.sel = min(file_dlg.sel + FILE_ROWS, n - 1)
		}
		if rep(.Nav_Page_Up) {
			file_dlg.sel = max(file_dlg.sel - FILE_ROWS, 0)
		}
		if rep(.Nav_Backspace) || rep(.Nav_Left) {
			file_dlg_up()
		}
		if hit(.Nav_Confirm) || hit(.Nav_Right) {
			file_dlg_activate(file_dlg.sel)
			if !file_dlg_open() {
				return
			}
		}
		if hit(.Nav_Tab) {
			file_dlg.focus_name = true
		}
		if hit(.Nav_Cancel) {
			file_dlg_cancel()
			return
		}
	}
	if mouse_in(list) {
		if in_.wheel_y != 0 {
			file_dlg.scroll = clamp(file_dlg.scroll - int(in_.wheel_y) * 3, 0, max(n - FILE_ROWS, 0))
		}
		if in_.pressed[BTN_L] {
			row := (in_.my - list.y) / FILE_ROW_H + file_dlg.scroll
			if row >= 0 && row < n {
				file_dlg.sel = row
				file_dlg.focus_name = false
				if in_.dbl {
					file_dlg_activate(row)
					if !file_dlg_open() {
						return
					}
				} else if !file_dlg.entries[row].is_dir {
					ti_set(&file_dlg.name, file_dlg.entries[row].name)
				}
			}
		}
	}
	if in_.pressed[BTN_L] {
		if mouse_in(name_r) {
			file_dlg.focus_name = true
		}
		if mouse_in(okb) {
			if file_dlg.focus_name || file_dlg.mode == .Save {
				file_dlg_accept_name()
			} else {
				file_dlg_activate(file_dlg.sel)
			}
			return
		}
		if mouse_in(cancel) {
			file_dlg_cancel()
			return
		}
	}
	if file_dlg_open() {
		file_dlg.sel = clamp(file_dlg.sel, 0, max(n - 1, 0))
		file_dlg_scroll()
	}
}

file_dlg_open :: proc() -> bool {
	return modal_kind == .File
}

file_dlg_draw :: proc() {
	box, path_r, list, name_r, okb, cancel := file_dlg_rects()
	modal_box(box, file_dlg.title)
	// The current folder (the end of a long path).
	fill_round(path_r, 4, COL_BG0)
	frame_round(path_r, 4, COL_LINE2)
	shown := file_dlg.dir if file_dlg.dir != "" else "(drives)"
	text_in(path_r, tail_fit(shown, path_r.w - 24), COL_DIM, .Ui, .Left, 10)

	// The list.
	fill(list, COL_BG0)
	saved := clip_to(list)
	n := len(file_dlg.entries)
	for row in 0 ..< FILE_ROWS {
		i := row + file_dlg.scroll
		if i >= n {
			break
		}
		e := file_dlg.entries[i]
		r := Rect{list.x, list.y + row * FILE_ROW_H, list.w - 10, FILE_ROW_H}
		sel := i == file_dlg.sel
		draw_row(r, sel && !file_dlg.focus_name, hover(r))
		if sel && file_dlg.focus_name {
			frame(r, COL_ACCENT_DIM)
		}
		label := e.name
		tx := r.x + 12
		if e.is_dir {
			fill_round(Rect{r.x + 12, r.y + 6, 15, 11}, 2, Color{222, 176, 74, 255})
			fill_round(Rect{r.x + 12, r.y + 4, 7, 4}, 1, Color{222, 176, 74, 255})
			tx = r.x + 34
		} else {
			tx = r.x + 34
		}
		text_in(Rect{tx - 6, r.y, r.w - 120 - (tx - r.x), r.h}, label, COL_TEXT if e.name != ".." else COL_DIM, .Ui, .Left, 6)
		if !e.is_dir {
			sz := fmt.tprintf("%d B" if e.size < 10000 else "%d KB", e.size if e.size < 10000 else e.size / 1024)
			text_in(r, sz, COL_FAINT, .Small, .Right, 12)
		}
	}
	clip_restore(saved)
	if n > FILE_ROWS {
		th := max(list.h * FILE_ROWS / n, 18)
		ty := list.y + file_dlg.scroll * (list.h - th) / max(n - FILE_ROWS, 1)
		fill_round(Rect{list.x + list.w - 6, ty, 4, th}, 2, COL_BG4)
	}
	text_in(Rect{box.x + 14, name_r.y, 62, name_r.h}, "Name", COL_DIM, .Ui, .Left, 0)
	ti_draw(&file_dlg.name, name_r, file_dlg.focus_name)
	draw_button(okb, "Save" if file_dlg.mode == .Save else "Open", true)
	draw_button(cancel, "Cancel")
	if file_dlg.err != "" {
		text_in(Rect{box.x + 14, okb.y, okb.x - box.x - 24, okb.h}, file_dlg.err, COL_MUTE, .Small, .Left, 0)
	} else {
		text_in(Rect{box.x + 14, okb.y, okb.x - box.x - 24, okb.h}, "j/k move   l open   h up   i name   . hidden files", COL_FAINT, .Small, .Left, 0)
	}
}

// ---- help --------------------------------------------------------------------------------------------

HELP_LINES := [?]string {
	"MOVING          h j k l / arrows   left right down up (one grid step / one key)",
	"                H L                one bar left / right   (Ctrl+Left / Right too)",
	"                J K                one octave down / up   (Ctrl+Down / Up, PageDown / PageUp too)",
	"                0  $  w  b         start, end, next note, previous note",
	"                4l  3K  ...        a number first repeats the move",
	"NOTES           i / Enter          insert a note at the cursor",
	"                a                  insert and step forward (typing a melody)",
	"                x / Delete         delete the notes (selected, or under the cursor)",
	"                < >                shorter / longer by one grid step",
	"                - +                softer / louder (velocity, about 5% a step)",
	"                q                  quantize to the grid",
	"                Shift+arrows       select: the notes in the rectangle from where you started",
	"                Alt+arrows         move the selected notes (or the one under the cursor)",
	"                s                  select / unselect the note under the cursor",
	"                y  p  Ctrl+D       copy, paste, duplicate",
	"                u  Ctrl+R          undo, redo",
	"TRACKS          Tab / Shift+Tab    next / previous track (the roll shows one track at a time)",
	"                M  S               mute / solo the track",
	"                Ctrl+I             choose the instrument of the track",
	"                Ctrl+T             edit that instrument: the sound of a synth (z: its zones), or its zones",
	"                Ctrl+I (top rows)  import a WAV file as an instrument (auto-tuned), or make an empty one",
	"                Ctrl+T on zones    a WAV file or synth sound per key range (a, f, s add), root key, loop",
	"EFFECTS         Ctrl+G             the library of effect graphs / back to the piano roll",
	"                Track panel        Fx: picks the graph the track plays through (any tracks can share one); Edit opens it",
	"                graph list         click a graph to edit it, its circle to use it on this track, double-click renames",
	"                in the graph       click a node to select, drag its title to move it, drag from a dot to a dot to wire",
	"                                   Delete removes the selected node or wire, right-click a wire cuts it",
	"                Ctrl+P, \"reverb\"   the reverb and delay (echo) settings of the song",
	"VIEW            [ ]                coarser / finer grid      (Ctrl+P, \"ghost\": show the other tracks faintly)",
	"                z Z                zoom in / out   (Ctrl+wheel also zooms)",
	"                Alt+wheel          taller / shorter key rows",
	"                F11 F12            bigger / smaller interface",
	"PLAYING         Space              play from the cursor / stop",
	"                F5                 play from the start      F6 loop on / off",
	"                , .                loop starts / ends at the cursor",
	"                t                  tempo at the cursor",
	"FILES           Ctrl+O S N E Q     open, save, new, export WAV, quit",
	"                Ctrl+P  or  :      command palette: every command by name",
	"                F10                the menu bar (then h l j k, Enter)",
	"MOUSE           click              move the cursor / select a note",
	"                drag a note        move it (drag its right end to resize)",
	"                drag empty space   select with a rectangle",
	"                double-click       insert a note",
	"                right-click        delete the note",
	"                wheel              scroll (Shift: sideways, Ctrl: zoom)",
	"                middle drag        scroll",
	"                faders             drag; double-click resets; right-click types a number",
	"                click              the ruler sets the position, the piano keys sound a key",
	"                drag in VELOCITY   changes the velocity of the notes",
}

help_scroll: int

open_help :: proc() {
	modal_close()
	help_scroll = 0
	modal_kind = .Help
}

help_rows :: proc() -> int {
	return max((win_h - 16 - DIALOG_TITLE_H - 40) / HELP_ROW_H, 8)
}

help_update :: proc() {
	rows := help_rows()
	maxs := max(len(HELP_LINES) - rows, 0)
	if rep(.Nav_Down) {
		help_scroll += 1
	}
	if rep(.Nav_Up) {
		help_scroll -= 1
	}
	if rep(.Nav_Page_Down) {
		help_scroll += rows
	}
	if rep(.Nav_Page_Up) {
		help_scroll -= rows
	}
	for c in in_.chars {
		if c == 'j' {
			help_scroll += 1
		} else if c == 'k' {
			help_scroll -= 1
		} else if c == 'q' {
			modal_close()
			return
		}
	}
	help_scroll -= int(in_.wheel_y) * 3
	help_scroll = clamp(help_scroll, 0, maxs)
	if hit(.Nav_Cancel) || hit(.Nav_Confirm) || k1(.F1) || (in_.pressed[BTN_L] && !mouse_in(help_box())) {
		modal_close()
	}
}

help_box :: proc() -> Rect {
	rows := min(help_rows(), len(HELP_LINES))
	cw := text_width("M", .Mono)
	widest := 0
	for l in HELP_LINES {
		widest = max(widest, len(l))
	}
	return centered(min(win_w - 16, (widest + 2) * cw + 44), rows * HELP_ROW_H + DIALOG_TITLE_H + 40)
}

help_draw :: proc() {
	box := help_box()
	inner := modal_box(box, "Keys and mouse     (Esc closes, j k scroll)")
	rows := min(help_rows(), len(HELP_LINES))
	cw := text_width("M", .Mono)
	saved := clip_to(inner)
	for i in 0 ..< rows {
		li := i + help_scroll
		if li >= len(HELP_LINES) {
			break
		}
		line := HELP_LINES[li]
		y := inner.y + i * HELP_ROW_H + 2
		// The line is three columns: the part of the program, the keys, what they do.
		sect := strings.trim_space(line[:16])
		keys := strings.trim_space(line[16:35])
		desc := line[35:]
		text(inner.x, y, sect, COL_ACCENT, .Mono)
		text(inner.x + 16 * cw, y, keys, COL_TEXT, .Mono)
		text(inner.x + 35 * cw, y, desc, COL_DIM, .Mono)
		if sect != "" && li > 0 {
			hline(inner.x, inner.x + inner.w - 1, y - 4, Color{255, 255, 255, 14})
		}
	}
	clip_restore(saved)
	if len(HELP_LINES) > rows {
		area := Rect{box.x + box.w - 12, inner.y, 4, rows * HELP_ROW_H}
		th := max(area.h * rows / len(HELP_LINES), 18)
		fill_round(Rect{area.x, area.y + help_scroll * (area.h - th) / max(len(HELP_LINES) - rows, 1), area.w, th}, 2, COL_BG4)
	}
}

// ---- patch editor ------------------------------------------------------------------------------------------
//
// The parameters of the patch of one zone of the instrument of a track. For a zone that plays a synth sound that
// is the sound itself; for a zone that plays a recording it is what shapes the recording (envelope, filter,
// loudness, pan, auto-pan; the oscillator rows do not apply to recordings and are left out).

Row_Kind :: enum {
	Param,
	Wave0,
	Wave1,
	Filter_Mode,
}

Param_Row :: struct {
	kind:      Row_Kind,
	param:     snd.Patch_Param,
	name:      string,
	step:      f32, // added per step, or the factor when `mult`
	lo, hi:    f32,
	mult:      bool,
}

PARAM_ROWS := [?]Param_Row {
	{kind = .Wave0, name = "Oscillator 1 wave"},
	{kind = .Wave1, name = "Oscillator 2 wave"},
	{kind = .Filter_Mode, name = "Filter type"},
	{param = .Volume, name = "Volume", step = 0.02, lo = 0, hi = 2},
	{param = .Pan, name = "Pan", step = 0.1, lo = -1, hi = 1},
	{param = .Osc0_Level, name = "Oscillator 1 level", step = 0.05, lo = 0, hi = 1},
	{param = .Osc1_Level, name = "Oscillator 2 level", step = 0.05, lo = 0, hi = 1},
	{param = .Osc1_Semitones, name = "Oscillator 2 tuning (semitones)", step = 0.5, lo = -48, hi = 48},
	{param = .Pulse_Width, name = "Pulse width", step = 0.05, lo = 0.05, hi = 0.95},
	{param = .Fm_Index, name = "FM amount (0 = off)", step = 0.2, lo = 0, hi = 12},
	{param = .Cutoff, name = "Filter cutoff (Hz)", step = 1.1, lo = 20, hi = 20000, mult = true},
	{param = .Resonance, name = "Filter resonance", step = 0.05, lo = 0, hi = 1},
	{param = .Filter_Env_Amount, name = "Filter envelope (octaves)", step = 0.25, lo = -6, hi = 6},
	{param = .Attack, name = "Attack (s)", step = 1.15, lo = 0.001, hi = 10, mult = true},
	{param = .Decay, name = "Decay (s)", step = 1.15, lo = 0.001, hi = 20, mult = true},
	{param = .Sustain, name = "Sustain level", step = 0.05, lo = 0, hi = 1},
	{param = .Release, name = "Release (s)", step = 1.15, lo = 0.001, hi = 20, mult = true},
	{param = .Vibrato_Rate, name = "Vibrato rate (Hz)", step = 0.25, lo = 0, hi = 15},
	{param = .Vibrato_Depth, name = "Vibrato depth (semitones)", step = 0.05, lo = 0, hi = 2},
	{param = .Pitch_Env_Semitones, name = "Pitch sweep (semitones)", step = 1, lo = -48, hi = 48},
	{param = .Pitch_Env_Time, name = "Pitch sweep time (s)", step = 1.15, lo = 0.001, hi = 5, mult = true},
	{param = .Unison_Voices, name = "Unison copies of oscillator 1", step = 1, lo = 1, hi = f32(snd.UNISON_MAX)},
	{param = .Unison_Detune, name = "Unison detune (semitones)", step = 0.01, lo = 0, hi = 1},
	{param = .Chorus_Depth, name = "Chorus depth", step = 0.02, lo = 0, hi = 1},
	{param = .Chorus_Rate, name = "Chorus rate (Hz)", step = 0.05, lo = 0, hi = 20},
	{param = .Tremolo_Depth, name = "Tremolo depth", step = 0.05, lo = 0, hi = 1},
	{param = .Tremolo_Rate, name = "Tremolo rate (Hz)", step = 0.25, lo = 0, hi = 20},
	{param = .String_Decay, name = "String ring time (s, Pluck wave)", step = 1.15, lo = 0.05, hi = 30, mult = true},
	{param = .String_Brightness, name = "String brightness (Pluck wave)", step = 0.05, lo = 0, hi = 1},
	{param = .Autopan_From, name = "Auto-pan from (-1 left .. 1 right)", step = 0.1, lo = -1, hi = 1},
	{param = .Autopan_To, name = "Auto-pan to (-1 left .. 1 right)", step = 0.1, lo = -1, hi = 1},
	{param = .Autopan_Speed, name = "Auto-pan speed (Hz, 0 = off)", step = 0.05, lo = 0, hi = 20},
	{param = .Drive, name = "Overdrive (0 = clean)", step = 0.05, lo = 0, hi = 1},
}

// True for the rows that only mean something for oscillators (the patch of a zone that plays a recording does
// not show them).
row_is_synth_only :: proc(r: Param_Row) -> bool {
	switch r.kind {
	case .Wave0, .Wave1:
		return true
	case .Filter_Mode:
		return false
	case .Param:
	}
	#partial switch r.param {
	case .Osc0_Level, .Osc1_Level, .Osc1_Semitones, .Pulse_Width, .Fm_Index, .Unison_Voices, .Unison_Detune, .Chorus_Depth, .Chorus_Rate, .String_Decay, .String_Brightness:
		return true
	}
	return false
}

// The rows (indexes into PARAM_ROWS) the editor shows for a zone.
patch_ed_rows :: proc() -> []int {
	rows: [dynamic]int
	rows.allocator = context.temp_allocator
	z := patch_ed_zone()
	recording := z != nil && z.source == .Sample
	for r, i in PARAM_ROWS {
		if recording && row_is_synth_only(r) {
			continue
		}
		append(&rows, i)
	}
	return rows[:]
}

Patch_Ed :: struct {
	track:      int, // the track whose instrument is edited
	zone:    int, // the zone of that instrument whose patch is edited
	sel:     int, // index in patch_ed_rows()
	scroll:  int,
	touched: bool, // the project has been changed (the undo snapshot is made on the first change)
}

patch_ed: Patch_Ed

PATCH_ROWS :: 13
PATCH_ROW_H :: 26
PATCH_NAME_W :: 270
patch_drag: bool // a slider is being dragged

open_patch_editor :: proc(track, zone: int) {
	modal_close()
	patch_ed = Patch_Ed {
		track   = track,
		zone = zone,
	}
	modal_kind = .Patch
}

// The zone whose patch the editor edits, or nil if the track no longer has it (undo, say).
patch_ed_zone :: proc() -> ^snd.Zone {
	inst := track_inst(patch_ed.track)
	if patch_ed.zone < 0 || patch_ed.zone >= len(inst.zones) {
		return nil
	}
	return &inst.zones[patch_ed.zone]
}

// Before every change: the undo snapshot on the first one, and the instrument itself (a track on the default
// instrument gets a copy of it that belongs to the song). Returns the zone to change.
patch_ed_touch :: proc() -> ^snd.Zone {
	if !patch_ed.touched {
		ed_edit(false)
		patch_ed.touched = true
	}
	inst := ed_inst_for_edit(patch_ed.track)
	ed_changed()
	if patch_ed.zone < 0 || patch_ed.zone >= len(inst.zones) {
		return nil
	}
	return &inst.zones[patch_ed.zone]
}

patch_ed_value_text :: proc(r: Param_Row, p: snd.Patch) -> string {
	switch r.kind {
	case .Wave0:
		return fmt.tprintf("%v", p.osc[0].wave)
	case .Wave1:
		return fmt.tprintf("%v", p.osc[1].wave)
	case .Filter_Mode:
		return fmt.tprintf("%v", p.filter.mode)
	case .Param:
		v := snd.patch_get_param(p, r.param)
		if r.mult || abs(v) >= 100 {
			return fmt.tprintf("%.3f", v)
		}
		return fmt.tprintf("%.2f", v)
	}
	return ""
}

// Changes the selected row by `dir` steps (a big step when `big`).
patch_ed_adjust :: proc(dir: int, big: bool) {
	rows := patch_ed_rows()
	r := PARAM_ROWS[rows[clamp(patch_ed.sel, 0, len(rows) - 1)]]
	z := patch_ed_touch()
	if z == nil {
		return
	}
	p := &z.patch
	switch r.kind {
	case .Wave0:
		w := (int(p.osc[0].wave) + dir + 6) % 6
		p.osc[0].wave = snd.Waveform(w)
	case .Wave1:
		w := (int(p.osc[1].wave) + dir + 5) % 5 // (no Pluck for the second oscillator)
		p.osc[1].wave = snd.Waveform(w)
	case .Filter_Mode:
		m := (int(p.filter.mode) + dir + 4) % 4
		p.filter.mode = snd.Filter_Mode(m)
	case .Param:
		v := snd.patch_get_param(p^, r.param)
		k := f32(dir)
		if big {
			k *= 5
		}
		if r.mult {
			f := r.step
			if big {
				f = f * f * f
			}
			if dir > 0 {
				v = max(v, r.lo) * f
			} else {
				v = v / f
			}
		} else {
			v += r.step * k
		}
		snd.patch_set_param(p, r.param, clamp(v, r.lo, r.hi))
	}
	audition_zone(z, 0.4)
}

patch_ed_rect :: proc() -> Rect {
	return centered(min(win_w - 16, 740), DIALOG_TITLE_H + 12 + 22 + PATCH_ROWS * PATCH_ROW_H + 10 + 22 + 12)
}

// The row `row` (counted from the first one shown) of the list.
patch_row_rect :: proc(box: Rect, row: int) -> Rect {
	return Rect{box.x + 14, box.y + DIALOG_TITLE_H + 12 + 22 + row * PATCH_ROW_H, box.w - 28 - 10, PATCH_ROW_H}
}

// The part of a row right of the name: a slider and the value, or the chips of an enumeration.
patch_ctl_rect :: proc(rr: Rect) -> Rect {
	return Rect{rr.x + PATCH_NAME_W, rr.y, rr.w - PATCH_NAME_W, rr.h}
}

patch_slider_rect :: proc(rr: Rect) -> Rect {
	c := patch_ctl_rect(rr)
	return Rect{c.x + 10, c.y, c.w - 10 - 96, c.h}
}

// The number of choices of an enumeration row (0 for a slider).
patch_row_choices :: proc(r: Param_Row) -> int {
	switch r.kind {
	case .Wave0:
		return 6
	case .Wave1:
		return 5 // (no Pluck for the second oscillator)
	case .Filter_Mode:
		return 4
	case .Param:
	}
	return 0
}

patch_row_choice :: proc(r: Param_Row, p: snd.Patch) -> int {
	#partial switch r.kind {
	case .Wave0:
		return int(p.osc[0].wave)
	case .Wave1:
		return int(p.osc[1].wave)
	case .Filter_Mode:
		return int(p.filter.mode)
	}
	return 0
}

patch_chip_rect :: proc(ctl: Rect, count, idx: int) -> Rect {
	w := (ctl.w - 10) / max(count, 1)
	return Rect{ctl.x + 10 + idx * w, ctl.y + 3, w - 4, ctl.h - 6}
}

// A parameter as a position (0..1) on its slider, and back (the values are rounded to the step of the row).
patch_norm :: proc(r: Param_Row, v: f32) -> f32 {
	if r.mult {
		return math.ln(max(v, r.lo) / r.lo) / math.ln(r.hi / r.lo)
	}
	return (v - r.lo) / (r.hi - r.lo)
}

patch_from_norm :: proc(r: Param_Row, t: f32) -> f32 {
	k := clamp(t, 0, 1)
	v: f32
	if r.mult {
		v = r.lo * math.pow(r.hi / r.lo, k)
	} else {
		v = r.lo + k * (r.hi - r.lo)
		v = r.lo + math.round((v - r.lo) / r.step) * r.step
	}
	return clamp(v, r.lo, r.hi)
}

// Drags the slider of row `r` to the mouse.
patch_ed_drag_to :: proc(r: Param_Row, sl: Rect) {
	zc := patch_ed_zone()
	if zc == nil || r.kind != .Param {
		return
	}
	v := patch_from_norm(r, f32(in_.mx - sl.x) / f32(max(sl.w, 1)))
	if v == snd.patch_get_param(zc.patch, r.param) {
		return
	}
	if z := patch_ed_touch(); z != nil {
		snd.patch_set_param(&z.patch, r.param, v)
	}
}

// Picks choice `idx` of an enumeration row.
patch_ed_set_choice :: proc(r: Param_Row, idx: int) {
	z := patch_ed_touch()
	if z == nil {
		return
	}
	#partial switch r.kind {
	case .Wave0:
		z.patch.osc[0].wave = snd.Waveform(idx)
	case .Wave1:
		z.patch.osc[1].wave = snd.Waveform(idx)
	case .Filter_Mode:
		z.patch.filter.mode = snd.Filter_Mode(idx)
	}
	audition_zone(z, 0.4)
}

patch_ed_update :: proc() {
	rows := patch_ed_rows()
	n := len(rows)
	box := patch_ed_rect()
	if patch_ed_zone() == nil { // the zone is gone (undo, say)
		modal_close()
		return
	}
	for c in in_.chars {
		switch c {
		case 'j':
			patch_ed.sel = min(patch_ed.sel + 1, n - 1)
		case 'k':
			patch_ed.sel = max(patch_ed.sel - 1, 0)
		case 'h':
			patch_ed_adjust(-1, false)
		case 'l':
			patch_ed_adjust(1, false)
		case 'H':
			patch_ed_adjust(-1, true)
		case 'L':
			patch_ed_adjust(1, true)
		case ' ':
			audition_zone(patch_ed_zone(), 0.6)
		case 'n':
			open_instrument_name_prompt(patch_ed.track, false)
			return
		case 'z':
			open_sampler_editor(patch_ed.track, patch_ed.zone)
			return
		case 'q':
			modal_close()
			return
		}
	}
	if rep(.Nav_Down) {
		patch_ed.sel = min(patch_ed.sel + 1, n - 1)
	}
	if rep(.Nav_Up) {
		patch_ed.sel = max(patch_ed.sel - 1, 0)
	}
	if rep(.Nav_Left) {
		patch_ed_adjust(-1, in_.shift)
	}
	if rep(.Nav_Right) {
		patch_ed_adjust(1, in_.shift)
	}

	// The mouse: drag a slider, click a choice; the wheel over a value changes it, anywhere else it scrolls the list.
	if patch_drag {
		if in_.down[BTN_L] {
			cursor_hint(.RESIZE_EW)
			i := clamp(patch_ed.sel, 0, n - 1)
			patch_ed_drag_to(PARAM_ROWS[rows[i]], patch_slider_rect(patch_row_rect(box, i - patch_ed.scroll)))
		} else {
			patch_drag = false
			audition_zone(patch_ed_zone(), 0.4)
		}
	} else {
		over_row := -1
		over_ctl := false
		for row in 0 ..< PATCH_ROWS {
			i := row + patch_ed.scroll
			if i >= n {
				break
			}
			rr := patch_row_rect(box, row)
			if !mouse_in(rr) {
				continue
			}
			over_row = i
			r := PARAM_ROWS[rows[i]]
			over_ctl = mouse_in(patch_ctl_rect(rr))
			if over_ctl {
				cursor_hint(.RESIZE_EW if r.kind == .Param else .POINTING_HAND)
			}
			if in_.pressed[BTN_L] {
				patch_ed.sel = i
				if r.kind == .Param {
					if mouse_in(patch_slider_rect(rr)) {
						patch_drag = true
						patch_ed_drag_to(r, patch_slider_rect(rr))
					}
				} else {
					ctl := patch_ctl_rect(rr)
					cnt := patch_row_choices(r)
					for j in 0 ..< cnt {
						if mouse_in(patch_chip_rect(ctl, cnt, j)) {
							patch_ed_set_choice(r, j)
						}
					}
				}
			}
		}
		if in_.wheel_y != 0 && mouse_in(box) {
			if over_row >= 0 && over_ctl {
				patch_ed.sel = over_row
				patch_ed_adjust(int(in_.wheel_y), in_.shift)
			} else {
				patch_ed.scroll -= int(in_.wheel_y) * 3
			}
		}
		if in_.pressed[BTN_L] && !mouse_in(box) {
			modal_close()
			return
		}
	}
	if hit(.Nav_Cancel) || hit(.Nav_Confirm) {
		modal_close()
		return
	}
	patch_ed.sel = clamp(patch_ed.sel, 0, n - 1)
	patch_ed.scroll = clamp(patch_ed.scroll, 0, max(n - PATCH_ROWS, 0))
	if rep(.Nav_Down) || rep(.Nav_Up) || len(in_.chars) > 0 { // (keep the selected row in view when the keys moved it)
		if patch_ed.sel < patch_ed.scroll {
			patch_ed.scroll = patch_ed.sel
		}
		if patch_ed.sel >= patch_ed.scroll + PATCH_ROWS {
			patch_ed.scroll = patch_ed.sel - PATCH_ROWS + 1
		}
	}
}

// Asks for a new name for the instrument of track `track`, then goes back to the dialog that asked
// (the zone editor if `zones`, else the patch editor).
name_prompt_track: int
name_prompt_zones: bool

open_instrument_name_prompt :: proc(track: int, zones: bool) {
	name_prompt_track = track
	name_prompt_zones = zones
	open_prompt("Name of this instrument (up to 23 letters)", snd.instrument_name(track_inst(track)), proc(text: string) {
		ed_edit(false)
		inst := ed_inst_for_edit(name_prompt_track)
		inst.name = snd.patch_label_make(strings.trim_space(text))
		ed_changed()
		if name_prompt_zones {
			sampler_ed.touched = true
			sampler_ed_reopen()
		} else {
			patch_ed.touched = true
			patch_ed_reopen()
		}
	})
}

// Back to the patch editor after the name prompt (keeps the selection).
patch_ed_reopen :: proc() {
	k := patch_ed
	open_patch_editor(k.track, k.zone)
	patch_ed = k
}

patch_ed_draw :: proc() {
	box := patch_ed_rect()
	inst := track_inst(patch_ed.track)
	z := patch_ed_zone()
	if z == nil {
		return
	}
	zone_text := ""
	if len(inst.zones) > 1 {
		keys := key_label(int(z.key_lo))
		if z.key_hi != z.key_lo {
			keys = fmt.tprintf("%s-%s", key_label(int(z.key_lo)), key_label(int(z.key_hi)))
		}
		zone_text = fmt.tprintf(", zone %d (keys %s)", patch_ed.zone + 1, keys)
	}
	title := fmt.tprintf("Sound of track %d: %s%s", patch_ed.track + 1, snd.instrument_name(inst), zone_text)
	inner := modal_box(box, title)
	p := z.patch
	note := "Stored in the song. n renames the instrument."
	if track_instrument(patch_ed.track) < 0 {
		note = "Default instrument: the first change copies it into the song."
	} else if z.source == .Sample {
		note = "Shapes the recording of this zone. n renames the instrument."
	}
	text(inner.x, inner.y + 2, note, COL_DIM, .Small)

	rows := patch_ed_rows()
	n := len(rows)
	list := Rect{box.x + 14, box.y + DIALOG_TITLE_H + 12 + 22, box.w - 28, PATCH_ROWS * PATCH_ROW_H}
	saved := clip_to(list)
	col := track_color(patch_ed.track)
	for row in 0 ..< PATCH_ROWS {
		i := row + patch_ed.scroll
		if i >= n {
			break
		}
		r := PARAM_ROWS[rows[i]]
		rr := patch_row_rect(box, row)
		sel := i == patch_ed.sel
		draw_row(rr, sel, hover(rr), col)
		text_in(Rect{rr.x, rr.y, PATCH_NAME_W, rr.h}, r.name, COL_TEXT if sel else COL_DIM, .Ui, .Left, 12)
		ctl := patch_ctl_rect(rr)
		if r.kind == .Param {
			v := snd.patch_get_param(p, r.param)
			sl := patch_slider_rect(rr)
			active := sel && patch_drag
			draw_slider(Rect{sl.x + 6, sl.y, sl.w - 12, sl.h}, patch_norm(r, v), col, active || hover(sl), r.lo == -r.hi)
			text_in(Rect{ctl.x + ctl.w - 96, ctl.y, 96, ctl.h}, patch_ed_value_text(r, p), COL_TEXT if sel else COL_DIM, .Mono, .Right, 10)
		} else {
			cnt := patch_row_choices(r)
			cur := patch_row_choice(r, p)
			for j in 0 ..< cnt {
				cr := patch_chip_rect(ctl, cnt, j)
				on := j == cur
				bg := mix(COL_BG2, col, 0.45) if on else (COL_BG3 if hover(cr) else COL_BG2)
				fill_round(cr, 4, bg)
				frame_round(cr, 4, col if on else COL_LINE2)
				name: string
				switch r.kind {
				case .Wave0, .Wave1:
					name = pretty(fmt.tprintf("%v", snd.Waveform(j)))
				case .Filter_Mode:
					name = pretty(fmt.tprintf("%v", snd.Filter_Mode(j)))
				case .Param:
				}
				text_in(cr, name, lighten(col, 0.4) if on else COL_DIM, .Ui, .Center, 2)
			}
		}
	}
	clip_restore(saved)
	if n > PATCH_ROWS {
		th := max(list.h * PATCH_ROWS / n, 18)
		fill_round(Rect{list.x + list.w - 6, list.y + patch_ed.scroll * (list.h - th) / max(n - PATCH_ROWS, 1), 4, th}, 2, COL_BG4)
	}
	text_in(Rect{box.x + 14, box.y + box.h - 12 - 22, box.w - 28, 22}, "Drag a slider or click   j k select   h l change   H L big   Space sound   z zones   Esc done", COL_FAINT, .Small, .Left, 0)
}

// ---- reverb and delay settings --------------------------------------------------------------------------------
//
// The reverb (a room) and the echo have one set of settings for the whole song. How much of a track goes into
// each is the track's own Reverb and Delay fader.

Delay_Row :: enum {
	Room,
	Damping,
	Time,
	Feedback,
	Tone,
	Ping_Pong,
	Sync,
}

DELAY_ROW_COUNT :: len(Delay_Row)

DELAY_ROW_FIELD := [Delay_Row]snd.Master_Field {
	.Room      = .Room,
	.Damping   = .Damping,
	.Time      = .Delay_Time,
	.Feedback  = .Delay_Feedback,
	.Tone      = .Delay_Tone,
	.Ping_Pong = .Delay_Ping_Pong,
	.Sync      = .Delay_Sync,
}

DELAY_ROW_NAME := [Delay_Row]string {
	.Room      = "Reverb: size of the room",
	.Damping   = "Reverb: damping (higher = duller tail)",
	.Time      = "Echo: time between echoes",
	.Feedback  = "Echo: feedback (how long it repeats)",
	.Tone      = "Echo: tone (higher = each echo duller)",
	.Ping_Pong = "Echo: ping-pong (echoes jump left / right)",
	.Sync      = "Echo: tempo sync (time follows the tempo)",
}

// Names of the tempo-sync values: index = the setting (0 = off), the rest are note lengths.
DELAY_SYNC_NAMES := [snd.DELAY_SYNC_COUNT + 1]string{"off", "1/16", "1/8 triplet", "1/8", "1/8 dotted", "1/4", "1/4 dotted", "1/2", "1/2 dotted", "1 bar"}

delay_sel: int

// A setting of the song's reverb or delay, in steps (snd.score_master_step_range says how many).
master_value :: proc(r: Delay_Row) -> int {
	return snd.score_master_step(&ed.p.master, DELAY_ROW_FIELD[r])
}

// Sets one: `snapshot` makes the undo step (a drag does that once, at the start).
master_set :: proc(r: Delay_Row, v: int, snapshot := true) {
	if snapshot {
		ed_edit(false) // (a setting of the echo does not cut the notes that sound)
	} else {
		ed_changed()
	}
	snd.score_master_set_step(&ed.p.master, DELAY_ROW_FIELD[r], v)
}

delay_row_value :: proc(r: Delay_Row) -> string {
	v := master_value(r)
	switch r {
	case .Room, .Damping, .Tone:
		return fmt.tprintf("%d%%", (v * 100 + 63) / 127)
	case .Time:
		return fmt.tprintf("%d ms", 10 * max(v, 1))
	case .Feedback:
		return fmt.tprintf("%d%%", int(f32(v) / 127 * snd.DELAY_FEEDBACK_MAX * 100 + 0.5))
	case .Ping_Pong:
		return "on" if v >= 1 else "off"
	case .Sync:
		return DELAY_SYNC_NAMES[min(v, snd.DELAY_SYNC_COUNT)]
	}
	return ""
}

delay_ed_adjust :: proc(dir: int, big: bool) {
	r := Delay_Row(delay_sel)
	v := master_value(r)
	lo, hi := snd.score_master_step_range(DELAY_ROW_FIELD[r])
	switch r {
	case .Room, .Damping, .Time, .Feedback, .Tone:
		step := 8 if big else 1
		master_set(r, clamp(v + dir * step, lo, hi))
	case .Ping_Pong:
		master_set(r, 1 if dir > 0 else 0)
	case .Sync:
		master_set(r, clamp(v + dir, lo, hi))
	}
	ed_changed()
}

open_delay_editor :: proc() {
	modal_close()
	modal_kind = .Delay
}

delay_drag: int = -1 // the row whose slider is being dragged
delay_drag_started: bool // the first change of the drag (which made the undo step) has happened

DELAY_ROW_H :: 34

delay_ed_rect :: proc() -> Rect {
	return centered(min(win_w - 16, 680), DIALOG_TITLE_H + 12 + 24 + DELAY_ROW_COUNT * DELAY_ROW_H + 16 + 22 + 10 + 22 + 12)
}

delay_row_rect :: proc(box: Rect, i: int) -> Rect {
	return Rect{box.x + 14, box.y + DIALOG_TITLE_H + 12 + 24 + i * DELAY_ROW_H, box.w - 28, DELAY_ROW_H}
}

delay_slider_rect :: proc(rr: Rect) -> Rect {
	return Rect{rr.x + 300, rr.y, rr.w - 300 - 110, rr.h}
}

delay_ed_drag_to :: proc(i: int, sl: Rect) {
	r := Delay_Row(i)
	lo, hi := snd.score_master_step_range(DELAY_ROW_FIELD[r])
	t := clamp(f32(in_.mx - (sl.x + 6)) / f32(max(sl.w - 12, 1)), 0, 1)
	v := lo + int(t * f32(hi - lo) + 0.5)
	if v != master_value(r) || !(DELAY_ROW_FIELD[r] in ed.p.master.set) {
		master_set(r, v, !delay_drag_started) // (one undo step for the whole drag)
		delay_drag_started = true
	}
}

delay_ed_update :: proc() {
	box := delay_ed_rect()
	for c in in_.chars {
		switch c {
		case 'j':
			delay_sel = min(delay_sel + 1, DELAY_ROW_COUNT - 1)
		case 'k':
			delay_sel = max(delay_sel - 1, 0)
		case 'h':
			delay_ed_adjust(-1, false)
		case 'l':
			delay_ed_adjust(1, false)
		case 'H':
			delay_ed_adjust(-1, true)
		case 'L':
			delay_ed_adjust(1, true)
		case 'q':
			modal_close()
			return
		}
	}
	if rep(.Nav_Down) {
		delay_sel = min(delay_sel + 1, DELAY_ROW_COUNT - 1)
	}
	if rep(.Nav_Up) {
		delay_sel = max(delay_sel - 1, 0)
	}
	if rep(.Nav_Left) {
		delay_ed_adjust(-1, in_.shift)
	}
	if rep(.Nav_Right) {
		delay_ed_adjust(1, in_.shift)
	}
	if delay_drag >= 0 {
		if in_.down[BTN_L] {
			cursor_hint(.RESIZE_EW)
			delay_ed_drag_to(delay_drag, delay_slider_rect(delay_row_rect(box, delay_drag)))
		} else {
			delay_drag = -1
		}
	} else {
		for i in 0 ..< DELAY_ROW_COUNT {
			rr := delay_row_rect(box, i)
			if !mouse_in(rr) {
				continue
			}
			sl := delay_slider_rect(rr)
			if mouse_in(sl) || (Delay_Row(i) == .Ping_Pong && mouse_in(Rect{rr.x + 300, rr.y, rr.w - 300, rr.h})) {
				cursor_hint(.RESIZE_EW if Delay_Row(i) != .Ping_Pong else .POINTING_HAND)
			}
			if in_.wheel_y != 0 {
				delay_sel = i
				delay_ed_adjust(int(in_.wheel_y), in_.shift)
			}
			if in_.pressed[BTN_L] {
				delay_sel = i
				if Delay_Row(i) == .Ping_Pong {
					if mouse_in(Rect{rr.x + 300, rr.y, rr.w - 300, rr.h}) {
						delay_ed_adjust(-1 if master_value(.Ping_Pong) >= 1 else 1, false)
					}
				} else if mouse_in(sl) {
					delay_drag = i
					delay_drag_started = false
					delay_ed_drag_to(i, sl)
				}
			}
		}
		if in_.pressed[BTN_L] && !mouse_in(box) {
			modal_close()
			return
		}
	}
	if hit(.Nav_Cancel) || hit(.Nav_Confirm) {
		modal_close()
		return
	}
}

delay_ed_draw :: proc() {
	box := delay_ed_rect()
	inner := modal_box(box, "Reverb and delay (echo) settings")
	text(inner.x, inner.y + 2, "For the whole song. Tracks send to them with their Reverb and Delay faders.", COL_DIM, .Small)
	synced := master_value(.Sync) != 0
	col := COL_ACCENT
	for r, i in Delay_Row {
		rr := delay_row_rect(box, i)
		sel := i == delay_sel
		draw_row(rr, sel, hover(rr), col)
		dim_row := r == .Time && synced // (the free time is ignored while the tempo sync is on)
		text_in(Rect{rr.x, rr.y, 300, rr.h}, DELAY_ROW_NAME[r], COL_FAINT if dim_row else (COL_TEXT if sel else COL_DIM), .Ui, .Left, 12)
		lo, hi := snd.score_master_step_range(DELAY_ROW_FIELD[r])
		v := master_value(r)
		if r == .Ping_Pong {
			on := v >= 1
			sw := Rect{rr.x + 300 + 10, rr.y + 8, 44, 18}
			fill_round(sw, 9, mix(COL_BG2, col, 0.7) if on else COL_BG0)
			frame_round(sw, 9, col if on else COL_LINE2)
			circle(sw.x + (sw.w - 9 if on else 9), sw.y + 9, 6.5, Color{235, 238, 245, 255} if on else COL_DIM)
		} else {
			sl := delay_slider_rect(rr)
			draw_slider(Rect{sl.x + 6, sl.y, sl.w - 12, sl.h}, f32(v - lo) / f32(hi - lo), COL_FAINT if dim_row else col, (delay_drag == i) || hover(sl))
		}
		text_in(Rect{rr.x + rr.w - 110, rr.y, 110, rr.h}, delay_row_value(r), COL_FAINT if dim_row else (COL_TEXT if sel else COL_DIM), .Mono, .Right, 12)
	}
	// What the echo time really is now.
	secs := snd.delay_resolve_seconds(0.01 * f32(max(master_value(.Time), 1)), master_value(.Sync), bpm_at(ed.cursor_tick))
	text(inner.x, delay_row_rect(box, DELAY_ROW_COUNT).y + 6, fmt.tprintf("Echo every %.0f ms at %.1f BPM", secs * 1000, bpm_at(ed.cursor_tick)), COL_TEXT)
	text_in(Rect{box.x + 14, box.y + box.h - 12 - 22, box.w - 28, 22}, "Drag a slider   j k select   h l change   H L big   Esc done", COL_FAINT, .Small, .Left, 0)
}

// ---- sampler editor -----------------------------------------------------------------------------------------
//
// Every instrument is a list of zones laid out on the keyboard. A zone is a range of keys and where its sound
// comes from: a recording (a WAV file, with its root key and loop) or a synth sound (a patch), plus a few
// settings (see iv_snd/instrument.odin). A drum kit is a row of recordings, an ordinary synth instrument is one synth
// zone over all keys, and the two can be mixed. The editor shows the zones on top and the settings of the
// selected zone below.

Sampler_Field :: enum {
	Key_Lo,
	Key_Hi,
	Source,
	Sample,
	Pitched,
	One_Shot,
	Root,
	Loop,
	Loop_Start,
	Loop_End,
	Tune,
	Volume,
	Pan,
	Group,
}

SAMPLE_ONLY_FIELDS :: bit_set[Sampler_Field]{.Sample, .Pitched, .Root, .Loop, .Loop_Start, .Loop_End}

SAMPLER_FIELD_NAMES := [Sampler_Field]string {
	.Key_Lo     = "First key of the zone",
	.Key_Hi     = "Last key of the zone",
	.Source     = "Sound (h l: recording or synth sound; e edits the synth)",
	.Sample     = "Recording (h l: pick another one of the song)",
	.Pitched    = "Follows the key (off: same sound on every key)",
	.One_Shot   = "Plays to its end (off: stops at note end)",
	.Root       = "Root key (auto = found when needed; R finds it)",
	.Loop       = "Loop while the key is held",
	.Loop_Start = "Loop start (frames)",
	.Loop_End   = "Loop end (frames)",
	.Tune       = "Tuning (semitones)",
	.Volume     = "Volume",
	.Pan        = "Pan (-1 left .. 1 right)",
	.Group      = "Choke group (0 = none; a zone cuts its group)",
}

Sampler_Ed :: struct {
	track:      int, // the track whose instrument is edited
	sel:     int, // selected zone
	field:   int, // selected setting (index into sampler_ed_fields)
	scroll:  int, // first zone shown
	touched: bool, // the undo snapshot has been made
}

sampler_ed: Sampler_Ed

ZONE_ROWS :: 4 // zones shown at a time
ZONE_ROW_H :: 24
FIELD_ROW_H :: 22
HELP_ROW_H :: 19

// Opens the zones of the instrument of track `track`, with zone `zone` selected. A track that plays the default
// instrument gets a copy of it in the song first (it is the song's instrument that is edited).
open_sampler_editor :: proc(track: int, zone := 0) {
	modal_close()
	sampler_ed = Sampler_Ed {
		track  = track,
		sel = zone,
	}
	if track_instrument(track) < 0 {
		ed_edit(false)
		ed_inst_for_edit(track)
		ed_changed()
		sampler_ed.touched = true
	}
	modal_kind = .Sampler
}

// Back to the sampler editor after a dialog (keeps the selection).
sampler_ed_reopen :: proc() {
	k := sampler_ed
	open_sampler_editor(k.track)
	sampler_ed = k
}

// The edited instrument, or nil if the track no longer has one of the song's (undo, say).
sampler_ed_inst :: proc() -> ^snd.Instrument {
	if track_instrument(sampler_ed.track) < 0 {
		return nil
	}
	return track_inst(sampler_ed.track)
}

sampler_ed_zone :: proc() -> ^snd.Zone {
	inst := sampler_ed_inst()
	if inst == nil || len(inst.zones) == 0 {
		return nil
	}
	sampler_ed.sel = clamp(sampler_ed.sel, 0, len(inst.zones) - 1)
	return &inst.zones[sampler_ed.sel]
}

// The settings shown for zone `z` (a zone with a synth sound has no recording, root key or loop).
sampler_ed_fields :: proc(z: ^snd.Zone) -> []Sampler_Field {
	f: [dynamic]Sampler_Field
	f.allocator = context.temp_allocator
	for x in Sampler_Field {
		if z != nil && z.source == .Synth && x in SAMPLE_ONLY_FIELDS {
			continue
		}
		append(&f, x)
	}
	return f[:]
}

// Before a change: one undo snapshot per time the dialog is open.
sampler_ed_begin :: proc() {
	if !sampler_ed.touched {
		ed_edit(false)
		sampler_ed.touched = true
	}
}

// After a change: tell the editor and the player, and look up the recordings of the zones again (a pitched
// zone with no root key gets one now, and keeps it).
sampler_ed_end :: proc() {
	ed_changed()
	ed_resolve()
}

// The key after the last one any zone uses (36, the bass drum of the standard drum kit, for an empty instrument).
sampler_next_key :: proc(inst: ^snd.Instrument) -> int {
	if len(inst.zones) == 0 {
		return 36
	}
	hi := 0
	for z in inst.zones {
		hi = max(hi, int(z.key_hi))
	}
	return min(hi + 1, 127)
}

// Adds a zone on `key` for a recording (the project takes over the caller's share of it).
sampler_ed_add_sample :: proc(inst: ^snd.Instrument, sm: ^snd.Sample, key: int) {
	append(&ed.p.samples, sm)
	z := snd.zone_default()
	z.key_lo = u8(key)
	z.key_hi = u8(key)
	z.sample_id = i32(len(ed.p.samples))
	snd.instrument_add_zone(inst, z)
	sampler_ed.sel = len(inst.zones) - 1
}

// Adds a zone with a synth sound (a basic piano to start with) on all the keys after the last one any zone uses
// (all keys, for an empty instrument).
sampler_ed_add_synth :: proc() {
	inst := sampler_ed_inst()
	if inst == nil {
		return
	}
	if len(inst.zones) >= snd.ZONE_MAX {
		ed_say("An instrument has room for %d zones", snd.ZONE_MAX)
		return
	}
	sampler_ed_begin()
	lo := 0 if len(inst.zones) == 0 else sampler_next_key(inst)
	snd.instrument_add_zone(inst, snd.zone_synth(lo, 127, snd.patch_piano()))
	sampler_ed.sel = len(inst.zones) - 1
	sampler_ed_end()
	ed_say("Added a synth zone on keys %s to %s (e edits its sound)", key_label(lo), key_label(127))
	audition_zone(sampler_ed_zone())
}

wav_stem :: proc(path: string) -> string {
	stem := path_base(path)
	if e := path_ext(path); e != "" {
		stem = stem[:len(stem) - len(e)]
	}
	return stem
}

// One WAV file becomes a zone on the next free key.
sampler_ed_import_one :: proc(path: string) {
	defer sampler_ed_reopen()
	inst := sampler_ed_inst()
	if inst == nil {
		return
	}
	sm, ok := snd.sample_load_wav(path, wav_stem(path))
	if !ok {
		ed_say("Could not read %s as a WAV file (PCM or float, mono or stereo)", path_base(path))
		return
	}
	if len(inst.zones) >= snd.ZONE_MAX {
		snd.sample_release(sm)
		ed_say("An instrument has room for %d zones", snd.ZONE_MAX)
		return
	}
	sampler_ed_begin()
	key := sampler_next_key(inst)
	sampler_ed_add_sample(inst, sm, key)
	sampler_ed_end()
	ed_say("Added %s on key %s (%.2f s)", wav_stem(path), key_label(key), snd.sample_seconds(sm))
	audition_zone(sampler_ed_zone())
}

// Makes the zone play a recording (a zone that had a synth sound gets the patch of a recording zone).
zone_to_sample :: proc(z: ^snd.Zone) {
	if z.source == .Sample {
		return
	}
	z.source = .Sample
	z.patch = snd.sample_zone_patch()
	z.one_shot = true
	z.pitched = false
	z.has_root = false
	z.root_known = false
	z.loop_on = false
	z.loop_start = 0
	z.loop_end = 0
}

// Makes the zone play a synth sound (a basic piano to start with).
zone_to_synth :: proc(z: ^snd.Zone) {
	if z.source == .Synth {
		return
	}
	z.source = .Synth
	z.patch = snd.patch_piano()
	z.one_shot = false
	z.pitched = false
	z.sample_id = 0
	z.sample = nil
	z.has_root = false
	z.root_known = false
	z.loop_on = false
	z.loop_start = 0
	z.loop_end = 0
}

// The selected zone plays a different WAV file.
sampler_ed_replace_one :: proc(path: string) {
	defer sampler_ed_reopen()
	z := sampler_ed_zone()
	if z == nil {
		return
	}
	sm, ok := snd.sample_load_wav(path, wav_stem(path))
	if !ok {
		ed_say("Could not read %s as a WAV file (PCM or float, mono or stereo)", path_base(path))
		return
	}
	sampler_ed_begin()
	zone_to_sample(z)
	append(&ed.p.samples, sm)
	z.sample_id = i32(len(ed.p.samples))
	z.has_root = false // (the root key and the loop belonged to the old recording)
	z.root_known = false
	z.loop_on = false
	z.loop_start = 0
	z.loop_end = 0
	sampler_ed_end()
	ed_say("Zone now plays %s (%.2f s)", wav_stem(path), snd.sample_seconds(sm))
	audition_zone(z)
}

// Every WAV file in the folder of the chosen file becomes a zone, in the order of their names, one key each
// from the next free key on.
sampler_ed_import_folder :: proc(path: string) {
	defer sampler_ed_reopen()
	inst := sampler_ed_inst()
	if inst == nil {
		return
	}
	dir := path_parent(path) if path_has_sep(path) else "."
	infos, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		ed_say("Cannot read the folder (%v)", err)
		return
	}
	defer os.file_info_slice_delete(infos, context.allocator)
	names: [dynamic]string
	names.allocator = context.temp_allocator
	for fi in infos {
		if fi.type != .Directory && strings.to_lower(path_ext(fi.name), context.temp_allocator) == ".wav" {
			append(&names, strings.clone(fi.name, context.temp_allocator))
		}
	}
	slice.sort_by(names[:], proc(a, b: string) -> bool {
		return strings.to_lower(a, context.temp_allocator) < strings.to_lower(b, context.temp_allocator)
	})
	if len(names) == 0 {
		ed_say("No WAV files in that folder")
		return
	}
	sampler_ed_begin()
	first := sampler_next_key(inst)
	key := first
	added := 0
	skipped := 0
	for nm in names {
		if key > 127 || len(inst.zones) >= snd.ZONE_MAX {
			skipped += 1
			continue
		}
		full := path_join(dir, nm)
		sm, ok := snd.sample_load_wav(full, wav_stem(nm))
		delete(full)
		if !ok {
			skipped += 1
			continue
		}
		sampler_ed_add_sample(inst, sm, key)
		key += 1
		added += 1
	}
	sampler_ed_end()
	if added == 0 {
		ed_say("None of the %d WAV files could be added", len(names))
	} else if skipped > 0 {
		ed_say("Added %d recordings on keys %s to %s (%d not added)", added, key_label(first), key_label(key - 1), skipped)
	} else {
		ed_say("Added %d recordings on keys %s to %s", added, key_label(first), key_label(key - 1))
	}
	sampler_ed.sel = max(len(inst.zones) - added, 0)
}

sampler_ed_delete_zone :: proc() {
	inst := sampler_ed_inst()
	if inst == nil || len(inst.zones) == 0 {
		return
	}
	sampler_ed_begin()
	ordered_remove(&inst.zones, clamp(sampler_ed.sel, 0, len(inst.zones) - 1))
	sampler_ed.sel = clamp(sampler_ed.sel, 0, max(len(inst.zones) - 1, 0))
	sampler_ed_end()
}

sampler_ed_value_text :: proc(f: Sampler_Field, z: ^snd.Zone) -> string {
	switch f {
	case .Key_Lo:
		return key_label(int(z.key_lo))
	case .Key_Hi:
		return key_label(int(z.key_hi))
	case .Source:
		return "synth sound" if z.source == .Synth else "recording"
	case .Sample:
		if z.sample != nil {
			return snd.sample_name(z.sample)
		}
		return "(none)"
	case .Pitched:
		return "yes" if z.pitched else "no"
	case .One_Shot:
		return "yes" if z.one_shot else "no"
	case .Root:
		if !z.has_root {
			return "auto"
		}
		k, c := snd.zone_root_note(z)
		return fmt.tprintf("%s %+dc%s", key_label(k), c, "" if z.root_known else " ?")
	case .Loop:
		return "on" if z.loop_on else "off"
	case .Loop_Start:
		return fmt.tprintf("%d", z.loop_start)
	case .Loop_End:
		return fmt.tprintf("%d", z.loop_end)
	case .Tune:
		return fmt.tprintf("%+.2f", z.tune)
	case .Volume:
		return fmt.tprintf("%.2f", z.volume)
	case .Pan:
		return fmt.tprintf("%+.1f", z.pan)
	case .Group:
		if z.group == 0 {
			return "none"
		}
		return fmt.tprintf("%d", z.group)
	}
	return ""
}

// Changes the selected setting of the selected zone by `dir` steps (a big step when `big`).
sampler_ed_adjust :: proc(dir: int, big: bool) {
	z := sampler_ed_zone()
	if z == nil {
		return
	}
	fields := sampler_ed_fields(z)
	sampler_ed.field = clamp(sampler_ed.field, 0, len(fields) - 1)
	field := fields[sampler_ed.field]
	sampler_ed_begin()
	k := f32(dir)
	frames := 0
	if z.sample != nil {
		frames = len(z.sample.data)
	}
	switch field {
	case .Key_Lo:
		z.key_lo = u8(clamp(int(z.key_lo) + dir * (12 if big else 1), 0, 127))
		z.key_hi = max(z.key_hi, z.key_lo)
	case .Key_Hi:
		z.key_hi = u8(clamp(int(z.key_hi) + dir * (12 if big else 1), 0, 127))
		z.key_lo = min(z.key_lo, z.key_hi)
	case .Source:
		if z.source == .Synth {
			zone_to_sample(z)
			if len(ed.p.samples) > 0 {
				z.sample_id = 1
			} else {
				ed_say("This zone is silent until it has a recording (r loads a WAV file)")
			}
		} else {
			zone_to_synth(z)
		}
		sampler_ed.field = clamp(sampler_ed.field, 0, len(sampler_ed_fields(z)) - 1)
	case .Sample:
		if n := len(ed.p.samples); n > 0 {
			z.sample_id = i32(clamp(int(z.sample_id) + dir, 1, n))
			z.has_root = false // (they belonged to the old recording)
			z.root_known = false
			z.loop_on = false
			z.loop_start = 0
			z.loop_end = 0
		}
	case .Pitched:
		z.pitched = !z.pitched
	case .One_Shot:
		z.one_shot = !z.one_shot
	case .Root:
		if z.sample != nil {
			snd.zone_ensure_root(z) // "auto" becomes a real value first, which is then changed
			snd.zone_set_root(z, z.root_key + k * (f32(0.1) if big else f32(1)))
		}
	case .Loop:
		if z.loop_on {
			z.loop_on = false
		} else if z.sample != nil {
			if !snd.zone_find_loop(z) { // no seamless loop: loop the whole recording
				z.loop_on = true
				z.loop_start = 0
				z.loop_end = frames
				ed_say("No seamless loop found (it needs a steady pitch): looping the whole recording")
			}
		}
	case .Loop_Start:
		step := max(frames / 100, 64) if big else 1
		z.loop_start = clamp(z.loop_start + dir * step, 0, max(z.loop_end - 1, 0))
	case .Loop_End:
		step := max(frames / 100, 64) if big else 1
		z.loop_end = clamp(z.loop_end + dir * step, min(z.loop_start + 1, frames), frames)
	case .Tune:
		v := z.tune + k * (f32(1) if big else f32(0.1))
		z.tune = clamp(math.round_f32(v * f32(100)) / f32(100), -48, 48)
	case .Volume:
		v := z.volume + k * (f32(0.25) if big else f32(0.05))
		z.volume = clamp(math.round_f32(v * f32(100)) / f32(100), 0, 4)
	case .Pan:
		v := z.pan + k * (f32(0.5) if big else f32(0.1))
		z.pan = clamp(math.round_f32(v * f32(10)) / f32(10), -1, 1)
	case .Group:
		z.group = u8(clamp(int(z.group) + dir * (4 if big else 1), 0, 255))
	}
	sampler_ed_end()
	audition_zone(z)
}

// Works out the root key of the selected zone from its recording again, and keeps the result.
sampler_ed_detect_root :: proc() {
	z := sampler_ed_zone()
	if z == nil || z.sample == nil {
		return
	}
	sampler_ed_begin()
	z.has_root = false
	snd.zone_ensure_root(z)
	sampler_ed_end()
	k, c := snd.zone_root_note(z)
	if z.root_known {
		ed_say("Root key found: %s %+dc", key_label(k), c)
	} else {
		ed_say("No clear pitch in this recording: root key set to %s (change it with h l)", key_label(k))
	}
	audition_zone(z)
}

sampler_ed_layout :: proc() -> (box: Rect, list_y, field_y: int) {
	h := DIALOG_TITLE_H + 12 + 20 + ZONE_ROWS * ZONE_ROW_H + 12 + len(Sampler_Field) * FIELD_ROW_H + 10 + 3 * 16 + 12
	box = centered(min(win_w - 16, 820), h)
	list_y = box.y + DIALOG_TITLE_H + 12 + 20
	field_y = list_y + ZONE_ROWS * ZONE_ROW_H + 12
	return
}

// The box that shows the value of a setting, with an arrow at each end that changes it.
sampler_pill_rect :: proc(box: Rect, field_y, row: int) -> Rect {
	return Rect{box.x + box.w - 14 - 10 - 230, field_y + row * FIELD_ROW_H + 1, 230, FIELD_ROW_H - 2}
}

sampler_ed_update :: proc() {
	inst := sampler_ed_inst()
	if inst == nil { // the instrument is gone (undo, say)
		modal_close()
		return
	}
	box, list_y, field_y := sampler_ed_layout()
	nz := len(inst.zones)
	nf := len(sampler_ed_fields(sampler_ed_zone()))
	for c in in_.chars {
		switch c {
		case 'j':
			sampler_ed.sel = min(sampler_ed.sel + 1, max(nz - 1, 0))
		case 'k':
			sampler_ed.sel = max(sampler_ed.sel - 1, 0)
		case 'h':
			sampler_ed_adjust(-1, false)
		case 'l':
			sampler_ed_adjust(1, false)
		case 'H':
			sampler_ed_adjust(-1, true)
		case 'L':
			sampler_ed_adjust(1, true)
		case ' ':
			audition_zone(sampler_ed_zone())
		case 'a':
			open_file_dialog(.Open, "Add a WAV file to the instrument (on the next free key)", {".wav"}, "", sampler_ed_import_one)
			return
		case 'f':
			open_file_dialog(.Open, "Add every WAV file of the folder of the file you choose", {".wav"}, "", sampler_ed_import_folder)
			return
		case 's':
			sampler_ed_add_synth()
			return
		case 'r':
			if sampler_ed_zone() != nil {
				open_file_dialog(.Open, "Replace the sound of the zone with a recording", {".wav"}, "", sampler_ed_replace_one)
				return
			}
		case 'R':
			sampler_ed_detect_root()
		case 'd':
			sampler_ed_delete_zone()
		case 'n':
			open_instrument_name_prompt(sampler_ed.track, true)
			return
		case 'e':
			if sampler_ed_zone() != nil {
				open_patch_editor(sampler_ed.track, sampler_ed.sel)
				return
			}
		case 'q':
			modal_close()
			return
		}
	}
	if rep(.Nav_Down) {
		sampler_ed.sel = min(sampler_ed.sel + 1, max(nz - 1, 0))
	}
	if rep(.Nav_Up) {
		sampler_ed.sel = max(sampler_ed.sel - 1, 0)
	}
	if rep(.Nav_Delete) {
		sampler_ed_delete_zone()
	}
	if hit(.Nav_Tab) {
		sampler_ed.field = (sampler_ed.field + (nf - 1 if in_.shift else 1)) % max(nf, 1)
	}
	if rep(.Nav_Left) {
		sampler_ed_adjust(-1, in_.shift)
	}
	if rep(.Nav_Right) {
		sampler_ed_adjust(1, in_.shift)
	}
	if in_.wheel_y != 0 && mouse_in(box) {
		sampler_ed.sel = clamp(sampler_ed.sel - int(in_.wheel_y), 0, max(nz - 1, 0))
	}
	if in_.pressed[BTN_L] && mouse_in(box) {
		row := (in_.my - list_y) / ZONE_ROW_H
		if in_.my >= list_y && row >= 0 && row < ZONE_ROWS && row + sampler_ed.scroll < nz {
			sampler_ed.sel = row + sampler_ed.scroll
		}
		nf = len(sampler_ed_fields(sampler_ed_zone()))
		frow := (in_.my - field_y) / FIELD_ROW_H
		if in_.my >= field_y && frow >= 0 && frow < nf {
			sampler_ed.field = frow
			// The arrows at the two ends of the value change it.
			pill := sampler_pill_rect(box, field_y, frow)
			if mouse_in(pill) {
				if in_.mx < pill.x + 28 {
					sampler_ed_adjust(-1, false)
				} else if in_.mx >= pill.x + pill.w - 28 {
					sampler_ed_adjust(1, false)
				}
			}
		}
	}
	if in_.pressed[BTN_L] && !mouse_in(box) {
		modal_close()
		return
	}
	if hit(.Nav_Cancel) || hit(.Nav_Confirm) {
		modal_close()
		return
	}
	nz = len(inst.zones)
	sampler_ed.sel = clamp(sampler_ed.sel, 0, max(nz - 1, 0))
	nf = len(sampler_ed_fields(sampler_ed_zone()))
	sampler_ed.field = clamp(sampler_ed.field, 0, max(nf - 1, 0))
	sampler_ed.scroll = clamp(sampler_ed.scroll, 0, max(nz - ZONE_ROWS, 0))
	if sampler_ed.sel < sampler_ed.scroll {
		sampler_ed.scroll = sampler_ed.sel
	}
	if sampler_ed.sel >= sampler_ed.scroll + ZONE_ROWS {
		sampler_ed.scroll = sampler_ed.sel - ZONE_ROWS + 1
	}
}

sampler_ed_draw :: proc() {
	inst := sampler_ed_inst()
	box, list_y, field_y := sampler_ed_layout()
	title := fmt.tprintf("Zones of track %d: %s", sampler_ed.track + 1, snd.instrument_name(track_inst(sampler_ed.track)))
	inner := modal_box(box, title)
	if inst == nil {
		return
	}
	col := track_color(sampler_ed.track)
	nz := len(inst.zones)
	if nz == 0 {
		text(inner.x, inner.y + 2, "No zones yet: a adds a WAV file, f a folder of them, s a synth sound.", COL_DIM, .Small)
	} else {
		text(inner.x, inner.y + 2, fmt.tprintf("Zone %d of %d. The first zone that holds a key plays it; other keys stay silent.", sampler_ed.sel + 1, nz), COL_DIM, .Small)
	}
	for row in 0 ..< ZONE_ROWS {
		i := row + sampler_ed.scroll
		if i >= nz {
			break
		}
		z := inst.zones[i]
		rr := Rect{box.x + 14, list_y + row * ZONE_ROW_H, box.w - 28 - 10, ZONE_ROW_H}
		sel := i == sampler_ed.sel
		draw_row(rr, sel, hover(rr), col)
		keys := key_label(int(z.key_lo))
		if z.key_hi != z.key_lo {
			keys = fmt.tprintf("%s-%s", key_label(int(z.key_lo)), key_label(int(z.key_hi)))
		}
		nm := "(none)"
		first := "P" if z.pitched else "-"
		if z.source == .Synth {
			nm = fmt.tprintf("synth: %v", z.patch.osc[0].wave)
			first = "S"
		} else if z.sample != nil {
			nm = snd.sample_name(z.sample)
		}
		flags := fmt.tprintf("%s%s%s%s", first, "O" if z.one_shot else "-", "L" if z.loop_on else "-", fmt.tprintf("g%d", z.group) if z.group > 0 else "")
		text_in(Rect{rr.x, rr.y, 118, rr.h}, keys, COL_TEXT if sel else COL_DIM, .Mono, .Left, 12)
		text_in(Rect{rr.x + 118, rr.y, rr.w - 118 - 100, rr.h}, nm, COL_TEXT if sel else COL_DIM, .Ui, .Left, 0)
		text_in(rr, flags, COL_FAINT, .Mono, .Right, 12)
	}
	hline(box.x + 14, box.x + box.w - 15, field_y - 6, COL_LINE2)
	if z := sampler_ed_zone(); z != nil {
		for f, row in sampler_ed_fields(z) {
			rr := Rect{box.x + 14, field_y + row * FIELD_ROW_H, box.w - 28 - 10, FIELD_ROW_H}
			sel := row == sampler_ed.field
			draw_row(rr, sel, hover(rr), col)
			text_in(Rect{rr.x, rr.y, rr.w - 250, rr.h}, SAMPLER_FIELD_NAMES[f], COL_TEXT if sel else COL_DIM, .Ui, .Left, 12)
			pill := sampler_pill_rect(box, field_y, row)
			fill_round(pill, 4, COL_BG0)
			frame_round(pill, 4, col if sel else COL_LINE2)
			l := Rect{pill.x, pill.y, 28, pill.h}
			r := Rect{pill.x + pill.w - 28, pill.y, 28, pill.h}
			icon_chevron(l.x + 14, l.y + l.h / 2, 9, -1, COL_TEXT if hover(l) else COL_FAINT)
			icon_chevron(r.x + 14, r.y + r.h / 2, 9, 1, COL_TEXT if hover(r) else COL_FAINT)
			text_in(Rect{pill.x + 26, pill.y, pill.w - 52, pill.h}, sampler_ed_value_text(f, z), COL_TEXT, .Mono, .Center, 2)
		}
	}
	hy := box.y + box.h - 12 - 3 * 16
	text_in(Rect{box.x + 14, hy, box.w - 28, 16}, "j k zone   Tab setting   h l change   H L big   Space play   Esc done", COL_FAINT, .Small, .Left, 0)
	text_in(Rect{box.x + 14, hy + 16, box.w - 28, 16}, "a add WAV   f add folder   s add synth zone   r replace with WAV   d delete zone", COL_FAINT, .Small, .Left, 0)
	text_in(Rect{box.x + 14, hy + 32, box.w - 28, 16}, "e edit the sound of the zone   R find root key   n rename the instrument", COL_FAINT, .Small, .Left, 0)
}

// ---- export progress -----------------------------------------------------------------------------------------
//
// While a WAV file is rendered (see export_step in fileio.odin) this dialog shows how far it is. Esc or Cancel stops.

open_progress :: proc() {
	modal_close()
	modal_kind = .Progress
}

progress_rects :: proc() -> (box, bar, cancel: Rect) {
	box = centered(min(win_w - 20, 480), DIALOG_TITLE_H + 16 + 18 + 14 + 16 + 20 + 14 + 30 + 14)
	bar = Rect{box.x + 14, box.y + DIALOG_TITLE_H + 16 + 18 + 14, box.w - 28, 16}
	cancel = Rect{box.x + box.w - 14 - 96, bar.y + bar.h + 20 + 14, 96, 30}
	return
}

progress_update :: proc() {
	_, _, cancel := progress_rects()
	if hit(.Nav_Cancel) || (in_.pressed[BTN_L] && mouse_in(cancel)) {
		modal_close() // (this stops the export)
	}
}

progress_draw :: proc() {
	box, bar, cancel := progress_rects()
	inner := modal_box(box, "Exporting WAV")
	job := &export_job
	text_in(Rect{inner.x, inner.y, inner.w, 18}, path_base(job.path), COL_TEXT, .Ui, .Left, 0)
	fill_round(bar, 8, COL_BG0)
	frame_round(bar, 8, COL_LINE2)
	pr := export_progress()
	if pr > 0 {
		fill_round(Rect{bar.x + 1, bar.y + 1, max(int(f32(bar.w - 2) * pr), 8), bar.h - 2}, 7, COL_ACCENT)
	}
	elapsed := now() - job.started
	info := fmt.tprintf("%d%%   %s of %s   %.1f s", int(pr * 100), time_text(f64(job.done) / EXPORT_RATE), time_text(f64(job.frames) / EXPORT_RATE), elapsed)
	text(bar.x, bar.y + bar.h + 14, info, COL_DIM, .Ui)
	// A program built without optimization renders several times slower (odin run does that).
	if !build_is_optimized() {
		text_in(Rect{box.x + 14, cancel.y, cancel.x - box.x - 24, cancel.h}, "This build is not optimized, so rendering is slow. Use build.bat.", COL_MUTE, .Small, .Left, 0)
	}
	draw_button(cancel, "Cancel")
}

build_is_optimized :: proc() -> bool {
	return ODIN_OPTIMIZATION_MODE == .Speed || ODIN_OPTIMIZATION_MODE == .Aggressive
}

