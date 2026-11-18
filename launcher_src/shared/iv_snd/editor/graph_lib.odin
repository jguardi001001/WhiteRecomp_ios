package main

import "core:fmt"
import "core:strings"
import snd "shared:iv_snd"

// ---------------------------------------------------------------------------
// The library of effect graphs in the editor (the left panel of the graph view), and the choice of a track's graph.
//
// The graphs belong to the project (snd.Score.graphs), not to instruments or tracks: a track only names the graph
// it plays through (Score_Track.graph), so any number of tracks can use the same graph, and a graph can wait in the
// library with nobody using it.
//
//   * click a row: look at (and edit) that graph; double-click: rename
//   * click the circle of a row: the current track plays through that graph (click again: it stops)
//   * New / Copy / Delete under the list
// ---------------------------------------------------------------------------

// ---- operations (every one is a step of undo) ------------------------------------------------------------------------------

graph_new :: proc() {
	ed_edit(false)
	n := snd.score_graph_add(&ed.p)
	graph_ed.sel_graph = n
	graph_ed.sel_node = 0
	graph_ed.sel_wire = {}
	if track_graph_number(ed.cur_track) == 0 {
		ed.p.tracks[ed.cur_track].graph = n
		ed_say("New graph %s: track %d plays through it", snd.fx_graph_name(&ed.p.graphs[n - 1]), ed.cur_track + 1)
	} else {
		ed_say("New graph %s", snd.fx_graph_name(&ed.p.graphs[n - 1]))
	}
	graph_ed_fit()
}

graph_copy :: proc() {
	num := graph_ed.sel_graph
	if num < 1 || num > len(ed.p.graphs) {
		ed_say("Select a graph in the list to copy it")
		return
	}
	ed_edit(false)
	c := snd.score_graph_duplicate(&ed.p, num)
	graph_ed.sel_graph = c
	ed_say("Copied as %s (no track plays through the copy yet)", snd.fx_graph_name(&ed.p.graphs[c - 1]))
}

graph_delete_number: int

graph_do_delete :: proc(num: int) {
	ed_edit(false)
	snd.score_graph_remove(&ed.p, num)
	if graph_ed.sel_graph == num {
		graph_ed.sel_graph = min(num, len(ed.p.graphs))
	} else if graph_ed.sel_graph > num {
		graph_ed.sel_graph -= 1
	}
	graph_ed.sel_node = 0
	graph_ed.sel_wire = {}
	ed_say("Graph deleted")
}

graph_delete :: proc() {
	num := graph_ed.sel_graph
	if num < 1 || num > len(ed.p.graphs) {
		ed_say("Select a graph in the list to delete it")
		return
	}
	users := snd.score_graph_users(&ed.p, num)
	if users == 0 {
		graph_do_delete(num)
		return
	}
	graph_delete_number = num
	text := fmt.tprintf("%d track%s play%s through %s. %s will play without effects.", users, "" if users == 1 else "s", "s" if users == 1 else "", snd.fx_graph_name(&ed.p.graphs[num - 1]), "It" if users == 1 else "They")
	open_confirm("Delete the graph?", text, {"Delete", "Cancel"}, proc(choice: int) {
		if choice == 0 {
			graph_do_delete(graph_delete_number)
		}
	})
}

graph_rename_number: int

graph_rename :: proc() {
	num := graph_ed.sel_graph
	if num < 1 || num > len(ed.p.graphs) {
		ed_say("Select a graph in the list to rename it")
		return
	}
	graph_rename_number = num
	open_prompt("Name of the graph (up to 23 letters)", snd.fx_graph_name(&ed.p.graphs[num - 1]), proc(text: string) {
		name := strings.trim_space(text)
		g := snd.fx_library_get(ed.p.graphs[:], graph_rename_number)
		if name == "" || g == nil {
			return
		}
		if other := snd.fx_library_find(ed.p.graphs[:], name); other != 0 && other != graph_rename_number {
			ed_say("There is a graph called %s already", name)
			return
		}
		ed_edit(false)
		snd.fx_graph_set_name(g, name)
	})
}

// The current track plays through graph `num`, or stops playing through it if it did.
graph_toggle_use :: proc(num: int) {
	if track_graph_number(ed.cur_track) == num {
		track_set_graph(ed.cur_track, 0)
		ed_say("Track %d plays without effects now", ed.cur_track + 1)
	} else {
		track_set_graph(ed.cur_track, num)
		ed_say("Track %d plays through %s", ed.cur_track + 1, snd.fx_graph_name(&ed.p.graphs[num - 1]))
		audition_test_note()
	}
}

// Asks which graph the current track should play through (from the track panel and the Track menu).
GRAPH_NEW_ID :: 3000

open_graph_picker :: proc() {
	items: [dynamic]Picker_Item
	items.allocator = context.temp_allocator
	append(&items, Picker_Item{"No effects", "", 0})
	for &g, i in ed.p.graphs {
		n := snd.score_graph_users(&ed.p, i + 1)
		right := "unused"
		if n > 0 {
			right = fmt.tprintf("%d track%s", n, "" if n == 1 else "s")
		}
		append(&items, Picker_Item{snd.fx_graph_name(&g), right, i + 1})
	}
	append(&items, Picker_Item{"New graph...", "", GRAPH_NEW_ID})
	title := fmt.tprintf("Effects graph for track %d (graphs are shared: any tracks can use the same one)", ed.cur_track + 1)
	open_picker(title, items[:], track_graph_number(ed.cur_track), proc(id: int) {
		switch {
		case id == GRAPH_NEW_ID:
			graph_ed_open()
			graph_ed.sel_graph = 0 // (the new graph is not a copy of the one the track has)
			graph_new()
		case id >= 0 && id <= len(ed.p.graphs):
			track_set_graph(ed.cur_track, id)
			if id > 0 {
				graph_ed.sel_graph = id
				audition(ed.cur_track, inst_test_key(track_inst(ed.cur_track)), ed.def_vel)
			}
		}
	}, nil)
}

// ---- the panel ------------------------------------------------------------------------------------------------------------------

GRAPH_ROW_H :: 24
PALETTE_ROW_H :: 26

// The left panel: the library of graphs on top (a list and its buttons), the effects you can add below.
Graph_Panel :: struct {
	list_hdr, list:       Rect,
	b_new, b_copy, b_del: Rect,
	fx_hdr:               Rect,
	rows:                 int, // rows of the list
}

graph_panel :: proc(pal: Rect) -> (gp: Graph_Panel) {
	fx_h := 26 + len(GRAPH_PALETTE) * PALETTE_ROW_H + 8
	avail := pal.h - 26 - 36 - fx_h - 56
	gp.rows = clamp(avail / GRAPH_ROW_H, 3, 8)
	gp.list_hdr = Rect{pal.x, pal.y, pal.w - 1, 26}
	gp.list = Rect{pal.x + 4, pal.y + 28, pal.w - 9, gp.rows * GRAPH_ROW_H}
	by := gp.list.y + gp.list.h + 4
	bw := (pal.w - 12 - 8) / 3
	gp.b_new = Rect{pal.x + 6, by, bw, 24}
	gp.b_copy = Rect{pal.x + 6 + bw + 4, by, bw, 24}
	gp.b_del = Rect{pal.x + 6 + 2 * (bw + 4), by, bw, 24}
	gp.fx_hdr = Rect{pal.x, by + 24 + 8, pal.w - 1, 26}
	return
}

palette_row_rect :: proc(pal: Rect, i: int) -> Rect {
	gp := graph_panel(pal)
	return Rect{pal.x + 8, gp.fx_hdr.y + 28 + i * PALETTE_ROW_H, pal.w - 16, PALETTE_ROW_H - 4}
}

graph_row_at :: proc(gp: Graph_Panel, row: int) -> Rect {
	return Rect{gp.list.x, gp.list.y + row * GRAPH_ROW_H, gp.list.w - (8 if len(ed.p.graphs) > gp.rows else 0), GRAPH_ROW_H - 2}
}

// The circle of a row: "the current track plays through this graph".
graph_use_rect :: proc(r: Rect) -> Rect {
	return Rect{r.x, r.y, 28, r.h}
}

graph_panel_mouse :: proc(pal: Rect) {
	gp := graph_panel(pal)
	n := len(ed.p.graphs)
	graph_ed.scroll = clamp(graph_ed.scroll, 0, max(n - gp.rows, 0))
	if graph_ed.last_sel != graph_ed.sel_graph { // (the selection moved by itself: keep it in sight)
		graph_ed.last_sel = graph_ed.sel_graph
		if s := graph_ed.sel_graph - 1; s >= 0 {
			if s < graph_ed.scroll {
				graph_ed.scroll = s
			} else if s >= graph_ed.scroll + gp.rows {
				graph_ed.scroll = s - gp.rows + 1
			}
		}
	}
	pressed := in_.pressed[BTN_L]
	if mouse_in(gp.b_new) || mouse_in(gp.b_copy) || mouse_in(gp.b_del) {
		cursor_hint(.POINTING_HAND)
		if pressed {
			switch {
			case mouse_in(gp.b_new):
				graph_new()
			case mouse_in(gp.b_copy):
				graph_copy()
			case mouse_in(gp.b_del):
				graph_delete()
			}
		}
		return
	}
	if mouse_in(gp.list) {
		if in_.wheel_y != 0 {
			graph_ed.scroll = clamp(graph_ed.scroll - int(in_.wheel_y) * 2, 0, max(n - gp.rows, 0))
		}
		for row in 0 ..< gp.rows {
			i := graph_ed.scroll + row
			if i >= n {
				break
			}
			r := graph_row_at(gp, row)
			if !mouse_in(r) {
				continue
			}
			cursor_hint(.POINTING_HAND)
			if !pressed {
				continue
			}
			switch {
			case mouse_in(graph_use_rect(r)):
				graph_ed.sel_graph = i + 1
				graph_toggle_use(i + 1)
			case graph_ed.sel_graph != i + 1:
				graph_ed.sel_graph = i + 1
				graph_ed.sel_node = 0
				graph_ed.sel_wire = {}
				graph_ed_fit()
			case in_.dbl:
				graph_rename()
			}
		}
		return
	}
	for k, i in GRAPH_PALETTE {
		r := palette_row_rect(pal, i)
		if mouse_in(r) {
			cursor_hint(.POINTING_HAND)
			if pressed {
				graph_add(k)
			}
		}
	}
}

graph_draw_palette :: proc(pal: Rect) {
	gp := graph_panel(pal)
	fill(pal, COL_BG1)
	vline(pal.x + pal.w - 1, pal.y, pal.y + pal.h - 1, COL_LINE)

	// ---- the library ----
	n := len(ed.p.graphs)
	section_header(gp.list_hdr, "GRAPHS", fmt.tprintf("%d", n))
	cur_num := track_graph_number(ed.cur_track)
	tcol := track_color(ed.cur_track)
	if n == 0 {
		graph_text_wrapped(Rect{gp.list.x + 8, gp.list.y + 6, gp.list.w - 16, gp.list.h}, "No graphs yet. Add an effect, or press New.", COL_FAINT)
	}
	saved := clip_to(gp.list)
	for row in 0 ..< gp.rows {
		i := graph_ed.scroll + row
		if i >= n {
			break
		}
		g := &ed.p.graphs[i]
		r := graph_row_at(gp, row)
		sel := graph_ed.sel_graph == i + 1
		draw_row(r, sel, hover(r))
		cx, cy := r.x + 14, r.y + r.h / 2
		used := cur_num == i + 1
		circle(cx, cy, 7, Color{0, 0, 0, 110})
		if used {
			circle(cx, cy, 6, tcol)
			circle(cx, cy, 2.5, COL_BG0)
		} else {
			circle(cx, cy, 5.5, COL_BG0)
			circle(cx, cy, 4.5, with_alpha(COL_DIM, 0.7) if hover(graph_use_rect(r)) else COL_BG4)
			circle(cx, cy, 3.2, COL_BG0)
		}
		users := snd.score_graph_users(&ed.p, i + 1)
		right := "-"
		if users > 0 {
			right = fmt.tprintf("x%d", users)
		}
		rw := text_width(right, .Small)
		text_in(Rect{r.x + 28, r.y, r.w - 28 - rw - 8, r.h}, snd.fx_graph_name(g), COL_TEXT if sel else COL_DIM, .Ui, .Left, 2)
		text_in(r, right, COL_DIM if users > 0 else COL_FAINT, .Small, .Right, 8)
	}
	clip_restore(saved)
	if n > gp.rows {
		th := max(gp.list.h * gp.rows / n, 14)
		pos := graph_ed.scroll * (gp.list.h - th) / max(n - gp.rows, 1)
		fill_round(Rect{gp.list.x + gp.list.w - 5, gp.list.y + pos, 4, th}, 2, COL_BG4)
	}
	draw_button(gp.b_new, "New")
	draw_button(gp.b_copy, "Copy")
	draw_button(gp.b_del, "Delete")

	// ---- the effects ----
	section_header(gp.fx_hdr, "ADD EFFECT")
	hint := ""
	for k, i in GRAPH_PALETTE {
		r := palette_row_rect(pal, i)
		h := hover(r)
		col := fx_color(k)
		fill_round(r, 5, COL_BG3 if h else COL_BG2)
		fill_round(Rect{r.x + 8, r.y + 6, 5, r.h - 12}, 2, col)
		text_in(Rect{r.x + 20, r.y, r.w - 20, r.h}, snd.FX_INFO[k].name, COL_TEXT if h else COL_DIM, .Ui, .Left, 2)
		if h {
			hint = snd.FX_INFO[k].blurb
		}
	}
	// What the effect under the mouse does, and how the panel works.
	ty := palette_row_rect(pal, len(GRAPH_PALETTE)).y + 4
	if ty + 40 < pal.y + pal.h {
		if hint != "" {
			graph_text_wrapped(Rect{pal.x + 10, ty, pal.w - 20, 60}, hint, COL_TEXT)
		} else {
			graph_text_wrapped(Rect{pal.x + 10, ty, pal.w - 20, pal.y + pal.h - ty - 4}, "The circle: the track plays through that graph. Click an effect to add it into the selected wire or after the selected node.", COL_FAINT)
		}
	}
}
