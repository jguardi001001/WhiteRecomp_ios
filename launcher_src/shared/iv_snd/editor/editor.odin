package main

import "core:fmt"
import "core:slice"
import "core:strings"
import snd "shared:iv_snd"

// ---------------------------------------------------------------------------
// Editor state and the editing operations.
// ---------------------------------------------------------------------------

Grid :: struct {
	label:    string,
	num, den: u32, // ticks = ticks_per_beat * num / den
}

GRIDS := [?]Grid{{"1/1", 4, 1}, {"1/2", 2, 1}, {"1/4", 1, 1}, {"1/8", 1, 2}, {"1/16", 1, 4}, {"1/32", 1, 8}, {"1/8T", 1, 3}, {"1/16T", 1, 6}}

Editor :: struct {
	p:             Project,
	path:          string, // "" while the project has no file
	dirty:         bool,
	rev:           int, // counts changes (playback follows it)
	need_release:  bool, // the next change reaching the sequencer must release sounding notes
	undo, redo:    [dynamic]Project,

	// The view.
	grid_idx:      int,
	beats_per_bar: u32,
	beat_px:       int, // width of a beat in pixels
	row_h:         int, // height of a key row in pixels (logical)
	scroll_tick:   int,
	scroll_key:    int, // the key at the top of the roll
	roll_rows:     int, // rows visible (set when drawing)
	roll_ticks:    int, // ticks visible (set when drawing)

	// The cursor.
	cursor_tick:   u32,
	cursor_key:    int,
	cur_track:     int, // the track the roll shows and edits
	def_vel:       int,
	note_len:      u32, // length of the notes that are inserted (0 = the grid)
	sel_active:    bool, // Shift + a move key is extending a selection: the notes in the rectangle from the anchor to the cursor
	anchor_tick:   u32,
	anchor_key:    int,
	count:         int, // typed number before a command ("4l")
	ghost_tracks:  bool, // show the notes of the other tracks as faint ghosts (off: the roll shows the current track only)
	view:          View_Mode, // what fills the middle of the window: the piano roll or the effect graph of the track's instrument

	// Clipboard.
	clip_notes:    [dynamic]Note,

	// Playback options.
	loop_on:       bool,
	audition_on:   bool,
	follow:        bool,

	// Status line message.
	msg:           [96]u8,
	msg_until:     f64,

	// Tempo map (rebuilt when the project changes).
	tmap:          [dynamic]snd.Tempo_Point,
	tmap_rev:      int,
}

ed: Editor

ed_init :: proc() {
	ed = {}
	ed.p = project_new()
	ed_reset_view()
	ed.loop_on = true
	ed.audition_on = true
	ed.follow = true
	ed.tmap_rev = -1
}

ed_reset_view :: proc() {
	ed.grid_idx = 4
	ed.beats_per_bar = 4
	ed.beat_px = 64
	ed.row_h = ROW_H_DEFAULT
	ed.scroll_tick = 0
	ed.scroll_key = 84
	ed.cursor_tick = 0
	ed.cursor_key = 60
	ed.cur_track = 0
	ed.def_vel = 100
	ed.note_len = 0
	ed.sel_active = false
	ed.count = 0
}

ed_say :: proc(format: string, args: ..any) {
	s := fmt.tprintf(format, ..args)
	n := min(len(s), len(ed.msg) - 1)
	for i in 0 ..< n {
		ed.msg[i] = s[i]
	}
	ed.msg[n] = 0
	ed.msg_until = now() + 4
}

ed_msg_text :: proc() -> string {
	if now() > ed.msg_until {
		return ""
	}
	i := 0
	for i < len(ed.msg) && ed.msg[i] != 0 {
		i += 1
	}
	return string(ed.msg[:i])
}

grid_ticks :: proc() -> u32 {
	g := GRIDS[ed.grid_idx]
	return max(ed.p.tpb * g.num / g.den, 1)
}

bar_ticks :: proc() -> u32 {
	return ed.p.tpb * ed.beats_per_bar
}

// Length given to a note that is inserted.
insert_len :: proc() -> u32 {
	if ed.note_len > 0 {
		return ed.note_len
	}
	return grid_ticks()
}

// ---- undo ---------------------------------------------------------------------------

UNDO_LIMIT :: 100

// Call before changing the project: remembers the state for undo and marks it modified.
ed_edit :: proc(release := true) {
	if release {
		ed.need_release = true // notes that are sounding may no longer exist
	}
	append(&ed.undo, project_clone(&ed.p))
	if len(ed.undo) > UNDO_LIMIT {
		project_free(&ed.undo[0])
		ordered_remove(&ed.undo, 0)
	}
	for &r in ed.redo {
		project_free(&r)
	}
	clear(&ed.redo)
	ed_changed()
}

// Marks the project as modified (also for changes that were already remembered).
ed_changed :: proc() {
	ed.dirty = true
	ed.rev += 1
	ed.cur_track = clamp(ed.cur_track, 0, len(ed.p.tracks) - 1)
}

ed_undo :: proc() {
	if len(ed.undo) == 0 {
		ed_say("Nothing to undo")
		return
	}
	ed.need_release = true
	append(&ed.redo, ed.p)
	ed.p = pop(&ed.undo)
	ed_changed()
	ed_say("Undo")
}

ed_redo :: proc() {
	if len(ed.redo) == 0 {
		ed_say("Nothing to redo")
		return
	}
	ed.need_release = true
	append(&ed.undo, ed.p)
	ed.p = pop(&ed.redo)
	ed_changed()
	ed_say("Redo")
}

ed_clear_history :: proc() {
	for &u in ed.undo {
		project_free(&u)
	}
	clear(&ed.undo)
	for &r in ed.redo {
		project_free(&r)
	}
	clear(&ed.redo)
}

// Replaces the project (new or loaded) and resets the view.
ed_set_project :: proc(p: Project, path: string) {
	ed_clear_history()
	project_free(&ed.p)
	ed.p = p
	delete(ed.path)
	ed.path = strings.clone(path)
	ed.dirty = false
	ed.rev += 1
	ed_reset_view()
	// Whatever the mouse was doing refers to the old project.
	drag.kind = .None
	clear(&drag.notes)
	fader = {}
	tracks_scroll = 0
	graph_ed_reset()
	// Start on the first note of the song.
	for n in ed.p.notes {
		ed.cur_track = n.track
		ed.cursor_key = int(n.key)
		ed.scroll_key = clamp(int(n.key) + 12, 24, 127)
		break
	}
	if ed.cur_track >= len(ed.p.tracks) {
		ed.cur_track = 0
	}
}

// ---- selection and notes ------------------------------------------------------------

sel_count :: proc() -> int {
	n := 0
	for x in ed.p.notes {
		if x.sel {
			n += 1
		}
	}
	return n
}

sel_clear :: proc() {
	ed.sel_active = false
	for &n in ed.p.notes {
		n.sel = false
	}
}

// Length a note takes up for hit testing (open notes count as one grid step).
note_span :: proc(n: Note) -> u32 {
	return n.len if n.len > 0 else grid_ticks()
}

// The note of the current track at a time and key. -1 if none.
note_at :: proc(tick: u32, key: int) -> int {
	for n, i in ed.p.notes {
		if n.track == ed.cur_track && int(n.key) == key && tick >= n.start && tick < n.start + note_span(n) {
			return i
		}
	}
	return -1
}

// Selects the notes of the current track that touch the rectangle (inclusive ticks and keys).
sel_rect :: proc(t0, t1: u32, k0, k1: int) {
	lo_t := min(t0, t1)
	hi_t := max(t0, t1)
	lo_k := min(k0, k1)
	hi_k := max(k0, k1)
	for &n in ed.p.notes {
		hit := int(n.key) >= lo_k && int(n.key) <= hi_k && n.start <= hi_t && n.start + note_span(n) > lo_t
		if n.track != ed.cur_track {
			hit = false
		}
		n.sel = hit
	}
}

// The notes a command works on: the selected ones, or else the note under the cursor.
targets :: proc() -> []int {
	out: [dynamic]int
	out.allocator = context.temp_allocator
	for n, i in ed.p.notes {
		if n.sel {
			append(&out, i)
		}
	}
	if len(out) == 0 {
		if i := note_at(ed.cursor_tick, ed.cursor_key); i >= 0 {
			append(&out, i)
		}
	}
	return out[:]
}

note_add :: proc(start, length: u32, key, track, vel: int) -> int {
	append(&ed.p.notes, Note{start = start, len = length, track = track, key = u8(clamp(key, 0, 127)), vel = u8(clamp(vel, 1, 127))})
	return len(ed.p.notes) - 1
}

// Inserts a note at the cursor (nothing if there already is one on that key and time).
ed_insert_note :: proc() -> bool {
	if i := note_at(ed.cursor_tick, ed.cursor_key); i >= 0 {
		ed_say("There is a note there already")
		return false
	}
	ed_edit(false)
	sel_clear()
	i := note_add(ed.cursor_tick, insert_len(), ed.cursor_key, ed.cur_track, ed.def_vel)
	ed.p.notes[i].sel = false
	return true
}

ed_delete_targets :: proc() {
	t := targets()
	if len(t) == 0 {
		return
	}
	ed_edit()
	// Remove from the back so the indexes stay valid.
	slice.sort(t)
	for i := len(t) - 1; i >= 0; i -= 1 {
		ordered_remove(&ed.p.notes, t[i])
	}
	ed_say("Deleted %d note(s)", len(t))
}

// Moves notes by `dt` ticks and `dk` keys. Nothing moves if one would leave the range.
ed_move_targets :: proc(dt: int, dk: int) -> bool {
	t := targets()
	if len(t) == 0 {
		return false
	}
	for i in t {
		n := ed.p.notes[i]
		if int(n.start) + dt < 0 || int(n.key) + dk < 0 || int(n.key) + dk > 127 {
			return false
		}
	}
	for i in t {
		n := &ed.p.notes[i]
		n.start = u32(int(n.start) + dt)
		n.key = u8(int(n.key) + dk)
	}
	return true
}

ed_resize_targets :: proc(dlen: int) {
	t := targets()
	if len(t) == 0 {
		return
	}
	ed_edit()
	for i in t {
		n := &ed.p.notes[i]
		cur := int(note_span(n^))
		n.len = u32(max(cur + dlen, 1))
	}
}

// How hard a note is played, as a percentage (a note stores it in 127 steps).
vel_text :: proc(v: int) -> string {
	return fmt.tprintf("%d%%", (v * 100 + 63) / 127)
}

// The velocity that is `pct` percent.
vel_from_percent :: proc(pct: int) -> int {
	return clamp((pct * 127 + 50) / 100, 1, 127)
}

VEL_STEP :: 6 // one step of "softer" / "louder": about 5%

ed_velocity_targets :: proc(delta: int) {
	t := targets()
	if len(t) == 0 {
		ed.def_vel = clamp(ed.def_vel + delta, 1, 127)
		ed_say("Velocity %s", vel_text(ed.def_vel))
		return
	}
	ed_edit()
	v := 0
	for i in t {
		n := &ed.p.notes[i]
		n.vel = u8(clamp(int(n.vel) + delta, 1, 127))
		v = int(n.vel)
	}
	ed_say("Velocity %s", vel_text(v))
}

ed_set_velocity :: proc(v: int) {
	t := targets()
	ed.def_vel = clamp(v, 1, 127)
	if len(t) == 0 {
		return
	}
	ed_edit()
	for i in t {
		ed.p.notes[i].vel = u8(ed.def_vel)
	}
}

ed_quantize_targets :: proc() {
	t := targets()
	if len(t) == 0 {
		return
	}
	ed_edit()
	g := grid_ticks()
	for i in t {
		n := &ed.p.notes[i]
		s := (n.start + g / 2) / g * g
		if n.len > 0 {
			e := (n.start + n.len + g / 2) / g * g
			n.len = e - s if e > s else g
		}
		n.start = s
	}
	ed_say("Quantized %d note(s) to %s", len(t), GRIDS[ed.grid_idx].label)
}

// Moves the selected notes (or the one under the cursor) to a track.
ed_assign_targets :: proc(track: int) {
	t := targets()
	if len(t) == 0 || track < 0 || track >= len(ed.p.tracks) {
		return
	}
	ed_edit()
	for i in t {
		ed.p.notes[i].track = track
	}
}

ed_yank :: proc() {
	t := targets()
	clear(&ed.clip_notes)
	for i in t {
		append(&ed.clip_notes, ed.p.notes[i])
	}
	if len(ed.clip_notes) > 0 {
		ed_say("Yanked %d note(s)", len(ed.clip_notes))
	}
}

// Pastes the yanked notes with the earliest one at `at`.
ed_paste :: proc(at: u32) {
	if len(ed.clip_notes) == 0 {
		ed_say("Nothing yanked")
		return
	}
	first := ed.clip_notes[0].start
	for n in ed.clip_notes {
		first = min(first, n.start)
	}
	ed_edit(false)
	sel_clear()
	for n in ed.clip_notes {
		c := n
		c.start = at + (n.start - first)
		c.sel = true
		if c.track >= len(ed.p.tracks) {
			c.track = ed.cur_track
		}
		append(&ed.p.notes, c)
	}
	ed_say("Pasted %d note(s)", len(ed.clip_notes))
}

// Copies the selected notes right after the last of them.
ed_duplicate :: proc() {
	t := targets()
	if len(t) == 0 {
		return
	}
	lo := ed.p.notes[t[0]].start
	hi := lo
	for i in t {
		n := ed.p.notes[i]
		lo = min(lo, n.start)
		hi = max(hi, n.start + note_span(n))
	}
	ed_edit(false)
	span := hi - lo
	// Round the span up to whole grid steps so the copy stays on the grid.
	g := grid_ticks()
	span = (span + g - 1) / g * g
	for i in t {
		ed.p.notes[i].sel = false
	}
	for i in t {
		c := ed.p.notes[i]
		c.start += span
		c.sel = true
		append(&ed.p.notes, c)
	}
	ed.cursor_tick += span
	ed_say("Duplicated %d note(s)", len(t))
}

sel_all :: proc(only_cur_track: bool) {
	for &n in ed.p.notes {
		n.sel = !only_cur_track || n.track == ed.cur_track
	}
	ed_say("%d selected", sel_count())
}

// ---- tracks ---------------------------------------------------------------------------------------------

ed_add_track :: proc() {
	ed_edit()
	snd.score_add_track(&ed.p, fmt.tprintf("track %d", len(ed.p.tracks) + 1))
	ed.cur_track = len(ed.p.tracks) - 1
	ed_say("Added track %d", ed.cur_track + 1)
}

// Deletes a track and its notes (the last one stays).
ed_delete_track :: proc(ti: int) {
	if ti < 0 || ti >= len(ed.p.tracks) {
		return
	}
	if len(ed.p.tracks) <= 1 {
		ed_say("The last track cannot be deleted")
		return
	}
	ed_edit()
	snd.score_remove_track(&ed.p, ti)
	project_prune_instruments(&ed.p)
	ed.cur_track = clamp(ed.cur_track, 0, len(ed.p.tracks) - 1)
	ed_say("Track deleted")
}

track_note_count :: proc(ti: int) -> int {
	c := 0
	for n in ed.p.notes {
		if n.track == ti {
			c += 1
		}
	}
	return c
}

// ---- the instrument and the mixer settings of a track ---------------------------------------------------

// The instrument of a track: an index into the project's instruments, or -1 (the default instrument).
track_instrument :: proc(ti: int) -> int {
	if ti < 0 || ti >= len(ed.p.tracks) {
		return -1
	}
	i := ed.p.tracks[ti].inst
	if i < 0 || i >= len(ed.p.instruments) {
		return -1
	}
	return i
}

// The instrument a track plays (the default instrument if the project gives it none). Do not change it:
// ed_inst_for_edit is for that.
track_inst :: proc(ti: int) -> ^snd.Instrument {
	return snd.score_track_instrument(&ed.p, ti)
}

// The track plays instrument number `idx` of the project.
track_set_instrument_raw :: proc(ti, idx: int) {
	if ti >= 0 && ti < len(ed.p.tracks) {
		ed.p.tracks[ti].inst = idx
	}
}

track_set_instrument :: proc(ti, idx: int) {
	ed_edit()
	track_set_instrument_raw(ti, idx)
	project_prune_instruments(&ed.p)
}

// Sets a mixer setting of a track. `snapshot`: remember the old state for undo first (a fader being dragged
// does that once, at the start). Sounding notes are not cut: only a deleted or muted note needs that.
track_set_mix :: proc(ti: int, field: Mix_Field, v: f32, snapshot := true) {
	if ti < 0 || ti >= len(ed.p.tracks) {
		return
	}
	if snapshot {
		ed_edit(false)
	} else {
		ed_changed()
	}
	snd.score_track_set_mix(&ed.p.tracks[ti], field, v)
}

track_mix :: proc(ti: int, field: Mix_Field) -> f32 {
	if ti < 0 || ti >= len(ed.p.tracks) {
		return 0
	}
	return snd.score_track_mix(&ed.p.tracks[ti], field)
}

// The label of a key on the key column of a track whose zones name the keys: the name of the recording its
// zone plays.
zone_key_label :: proc(inst: ^snd.Instrument, key: int) -> string {
	if z := snd.instrument_find_zone(inst, key); z != nil && z.source == .Sample && z.sample != nil {
		return snd.sample_name(z.sample)
	}
	return ""
}

// The instrument whose zones name the keys of the roll for track `ti` (a kit: some zones play a recording
// that sounds the same on all their keys), or nil: an instrument whose zones all follow the keys like a melodic
// instrument.
track_key_labels :: proc(ti: int) -> ^snd.Instrument {
	inst := track_inst(ti)
	for z in inst.zones {
		if z.source == .Sample && !z.pitched {
			return inst
		}
	}
	return nil
}

track_label :: proc(ti: int) -> string {
	return snd.instrument_name(track_inst(ti))
}

// ---- effect graphs: the library belongs to the project, tracks name the graph they play through ----

empty_graph: snd.Fx_Graph

// The graph track `ti` plays through, or an empty one (for counting nodes and the like).
track_graph_or_empty :: proc(ti: int) -> ^snd.Fx_Graph {
	if g := snd.score_track_graph(&ed.p, ti); g != nil {
		return g
	}
	return &empty_graph
}

// The number of the graph track `ti` plays through in the project's library (0 = none).
track_graph_number :: proc(ti: int) -> int {
	if ti < 0 || ti >= len(ed.p.tracks) {
		return 0
	}
	if snd.score_track_graph(&ed.p, ti) == nil {
		return 0
	}
	return ed.p.tracks[ti].graph
}

// Makes track `ti` play through graph `number` of the library (0 = none). Several tracks can use the same graph.
track_set_graph :: proc(ti, number: int) {
	if ti < 0 || ti >= len(ed.p.tracks) {
		return
	}
	ed_edit(false) // (the notes that sound are not cut)
	ed.p.tracks[ti].graph = number if number >= 1 && number <= len(ed.p.graphs) else 0
}

// How many notes each track has, counted in ONE pass over the notes once per frame (the single lookups above scan
// every note, which adds up when the side panel asks for every track every frame).
track_counts: [dynamic]int

info_update :: proc() {
	resize(&track_counts, len(ed.p.tracks))
	for &c in track_counts {
		c = 0
	}
	for n in ed.p.notes {
		if n.track >= 0 && n.track < len(track_counts) {
			track_counts[n.track] += 1
		}
	}
}

// Gives the project an instrument (it owns it from now on) and returns its index. The recordings its zones
// point to are added to the project too, once each.
ed_adopt_instrument :: proc(inst: ^snd.Instrument) -> int {
	for &z in inst.zones {
		if z.source != .Sample || z.sample == nil {
			continue
		}
		idx := -1
		for sm, i in ed.p.samples {
			if sm == z.sample {
				idx = i
				break
			}
		}
		if idx < 0 {
			snd.sample_retain(z.sample)
			append(&ed.p.samples, z.sample)
			idx = len(ed.p.samples) - 1
		}
		z.sample_id = i32(idx + 1)
	}
	append(&ed.p.instruments, inst)
	snd.instruments_resolve(ed.p.instruments[len(ed.p.instruments) - 1:], ed.p.samples[:])
	return len(ed.p.instruments) - 1
}

// Re-reads the recordings of the zones (after a tool changed zones or the project's recordings).
ed_resolve :: proc() {
	snd.instruments_resolve(ed.p.instruments[:], ed.p.samples[:])
}

// Makes `inst` the instrument of track `ti` (the project takes it over, or, for an instrument without
// recordings that the project has already, shares that one) and drops the instruments no track
// plays any more.
ed_set_track_instrument :: proc(ti: int, inst: ^snd.Instrument, snapshot := true) {
	if snapshot {
		ed_edit(false)
	}
	idx := -1
	if !snd.instrument_has_samples(inst) {
		for x, i in ed.p.instruments { // the same instrument is already in the project: share it
			if instruments_same_synth(x, inst) {
				idx = i
				break
			}
		}
	}
	if idx >= 0 {
		snd.instrument_destroy(inst)
	} else {
		idx = ed_adopt_instrument(inst)
	}
	track_set_instrument_raw(ti, idx)
	project_prune_instruments(&ed.p)
}

// Whether two instruments without recordings are the same: the same name and the same zones.
instruments_same_synth :: proc(a, b: ^snd.Instrument) -> bool {
	if len(a.zones) == 0 || snd.instrument_has_samples(a) || snd.instrument_has_samples(b) || a.name != b.name || len(a.zones) != len(b.zones) {
		return false
	}
	for i in 0 ..< len(a.zones) {
		if a.zones[i] != b.zones[i] {
			return false
		}
	}
	return true
}

// The instrument of track `ti` for changing it: one that belongs to the project. A track on the default
// instrument gets a copy of it first. Call ed_edit before.
ed_inst_for_edit :: proc(ti: int) -> ^snd.Instrument {
	if i := track_instrument(ti); i >= 0 {
		return ed.p.instruments[i]
	}
	inst := snd.instrument_clone(snd.default_instrument())
	idx := ed_adopt_instrument(inst)
	track_set_instrument_raw(ti, idx)
	return inst
}

// ---- tempo ----------------------------------------------------------------------------

tmap_update :: proc() {
	if ed.tmap_rev == ed.rev {
		return
	}
	ed.tmap_rev = ed.rev
	changes: [dynamic]snd.Score_Tempo
	changes.allocator = context.temp_allocator
	for t in ed.p.tempo {
		append(&changes, snd.Score_Tempo{t.tick, max(t.us, 1)})
	}
	slice.stable_sort_by(changes[:], proc(a, b: snd.Score_Tempo) -> bool {return a.tick < b.tick})
	clear(&ed.tmap)
	append(&ed.tmap, snd.Tempo_Point{tick = 0, us = snd.DEFAULT_TEMPO_US})
	for c in changes {
		last := &ed.tmap[len(ed.tmap) - 1]
		if c.tick == last.tick {
			last.us = c.us
		} else {
			append(&ed.tmap, snd.Tempo_Point{tick = c.tick, us = c.us})
		}
	}
	tpb := f64(max(ed.p.tpb, 1))
	for i in 1 ..< len(ed.tmap) {
		prev := ed.tmap[i - 1]
		ed.tmap[i].seconds = prev.seconds + f64(ed.tmap[i].tick - prev.tick) * f64(prev.us) / 1e6 / tpb
	}
}

tick_to_seconds :: proc(tick: u32) -> f64 {
	tmap_update()
	i := 0
	for i + 1 < len(ed.tmap) && ed.tmap[i + 1].tick <= tick {
		i += 1
	}
	m := ed.tmap[i]
	return m.seconds + f64(tick - m.tick) * f64(m.us) / 1e6 / f64(max(ed.p.tpb, 1))
}

// Beats per minute in force at a tick.
bpm_at :: proc(tick: u32) -> f32 {
	tmap_update()
	i := 0
	for i + 1 < len(ed.tmap) && ed.tmap[i + 1].tick <= tick {
		i += 1
	}
	return snd.tempo_to_bpm(ed.tmap[i].us)
}

// Puts a tempo change at `tick` (replacing the one that is there).
ed_set_tempo :: proc(tick: u32, bpm: f32) {
	ed_edit()
	snd.score_set_tempo(&ed.p, tick, bpm)
}

// ---- position text ---------------------------------------------------------------------------

// "003:2:120": bar, beat, ticks.
pos_text :: proc(tick: u32) -> string {
	bt := bar_ticks()
	bar := tick / bt + 1
	beat := (tick % bt) / ed.p.tpb + 1
	rest := tick % ed.p.tpb
	return fmt.tprintf("%03d:%d:%03d", bar, beat, rest)
}

time_text :: proc(seconds: f64) -> string {
	s := max(seconds, 0)
	m := int(s) / 60
	return fmt.tprintf("%d:%04.1f", m, s - f64(m * 60))
}
