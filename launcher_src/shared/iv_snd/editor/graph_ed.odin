package main

import "core:fmt"
import "core:math"
import snd "shared:iv_snd"
import ui "shared:iv_ui"

// ---------------------------------------------------------------------------
// The effect graph editor: a view that replaces the piano roll (Ctrl+G, or the "Effects graph" button). The graphs are
// a LIBRARY of the project, separate from the instruments and the tracks: make as many as you like, and make any
// number of tracks play through the same one (a track names its graph; changing the graph changes them all, and each
// track still gets its own echoes and tails). The graph itself, with what its nodes do, is the library's
// (iv_snd/graph.odin, iv_snd/score.odin); this file draws it and turns the mouse and keys into edits of it.
//
//   * The list on the left is the library: click a graph to look at it, click its circle to make the current track
//     play through it (or stop), double-click to rename; New, Copy and Delete are under the list.
//   * The Input node is the sound of the track; the Output node is what is heard. Wire them up through
//     effect nodes: drag from the dot on the right of a node to the dot on the left of another.
//   * Every effect node shows its parameters as sliders; drag them, double-click to reset one.
//   * Click an effect in the list on the left to add it (into the selected wire, or after the selected node,
//     or in front of the Output).
//   * Every change is one step of undo, and is heard at once when the song is playing.
// ---------------------------------------------------------------------------

View_Mode :: enum {
	Roll,
	Graph,
}

NODE_W :: 204
NODE_IO_W :: 120
NODE_IO_H :: 46
NODE_HEAD :: 28
NODE_ROW :: 25
NODE_PAD :: 9
PORT_R :: 6
PALETTE_W :: 190
TOOLBAR_H :: 38
GRAPH_GAP_X :: 70 // between columns when the nodes are arranged
GRAPH_GAP_Y :: 26

GRAPH_PALETTE := [?]snd.Fx_Kind{.Gain, .Filter, .Delay, .Reverb, .Chorus, .Distortion, .Crusher, .Tremolo, .Compressor}

Graph_Drag :: enum {
	None,
	Node, // moving a node by its title
	Wire, // a wire being pulled out of an output (the other end follows the mouse)
	Pickup, // pressed on an input that has a wire: pulling now takes the wire off
	Slider, // a parameter slider
	Pan, // the canvas
}

Graph_Ed :: struct {
	pan:       [2]int, // the world position at the top-left of the canvas
	sel_node:  u16, // 0 = none
	sel_wire:  snd.Fx_Edge, // from == 0: none
	drag:      Graph_Drag,
	drag_id:   u16, // the node being moved, or the node a wire comes from, or the node whose slider is dragged
	drag_to:   u16, // Pickup: the node the wire was going into
	grab:      [2]int, // Node: where inside the node it was grabbed; Pickup: where the mouse was pressed
	param:     int, // Slider: the parameter
	changed:   bool, // the undo step of this drag has been made
	cascade:   int, // the next new node is put a little lower than the last
	sel_graph: int, // the graph of the library that is shown (its number, 1 = the first; 0 = none)
	last_sel:  int, // (the one the list was last scrolled to)
	shown_trk: int, // the track the view last followed (when the track changes, the view shows its graph)
	scroll:    int, // the first graph shown in the list
}

graph_ed: Graph_Ed
graph_virtual: snd.Fx_Graph // what is shown when no graph is selected (nothing is stored until something is changed)

graph_ed_reset :: proc() {
	graph_ed = {}
	graph_ed.shown_trk = -1
	ed.view = .Roll
}

// Opens the view on the graph the current track plays through.
graph_ed_open :: proc() {
	ed.view = .Graph
	graph_ed.drag = .None
	graph_ed.shown_trk = -1 // (graph_shown follows the track)
	graph_shown()
	graph_ed_fit()
}

// ---- the graph that is shown, and edits of it ----------------------------------------------------------------

// The graph that is shown: the selected one of the library (a plain Input -> Output one when none is selected). The
// view follows the current track: when the track changes, it shows the graph that track plays through, if it has one.
graph_shown :: proc() -> ^snd.Fx_Graph {
	if graph_ed.shown_trk != ed.cur_track {
		graph_ed.shown_trk = ed.cur_track
		if n := track_graph_number(ed.cur_track); n > 0 {
			graph_ed.sel_graph = n
		}
	}
	if graph_ed.sel_graph > len(ed.p.graphs) { // (an undo took it away)
		graph_ed.sel_graph = 0
	}
	if g := snd.fx_library_get(ed.p.graphs[:], graph_ed.sel_graph); g != nil {
		return g
	}
	if len(graph_virtual.nodes) == 0 {
		graph_virtual = snd.fx_graph_default()
	}
	return &graph_virtual
}

// Starts an edit of the graph: one step of undo (unless `same_step`, the later changes of a drag) and the graph that
// belongs to the project. With no graph selected, the first edit makes one (and the current track plays through it,
// unless it has a graph already).
graph_edit :: proc(same_step := false) -> ^snd.Fx_Graph {
	graph_shown()
	if same_step {
		ed_changed()
	} else {
		ed_edit(false) // (a change of the effects does not cut the notes that sound)
	}
	if snd.fx_library_get(ed.p.graphs[:], graph_ed.sel_graph) == nil {
		n := snd.score_graph_add(&ed.p)
		graph_ed.sel_graph = n
		if track_graph_number(ed.cur_track) == 0 {
			ed.p.tracks[ed.cur_track].graph = n
			ed_say("Made the graph %s for track %d", snd.fx_graph_name(&ed.p.graphs[n - 1]), ed.cur_track + 1)
		}
	}
	return snd.fx_library_get(ed.p.graphs[:], graph_ed.sel_graph)
}

// How many tracks play through the shown graph, and whether the current track is one of them.
graph_users :: proc() -> (n: int, mine: bool) {
	num := graph_ed.sel_graph
	if num < 1 || num > len(ed.p.graphs) {
		return 0, false
	}
	return snd.score_graph_users(&ed.p, num), track_graph_number(ed.cur_track) == num
}

// ---- geometry ------------------------------------------------------------------------------------------------------

graph_areas :: proc() -> (toolbar, palette, canvas: Rect) {
	a := lay.roll
	toolbar = Rect{a.x, a.y, a.w, TOOLBAR_H}
	palette = Rect{a.x, a.y + TOOLBAR_H, PALETTE_W, a.h - TOOLBAR_H}
	canvas = Rect{a.x + PALETTE_W, a.y + TOOLBAR_H, a.w - PALETTE_W, a.h - TOOLBAR_H}
	return
}

graph_node_size :: proc(n: ^snd.Fx_Node) -> (w, h: int) {
	if !snd.fx_kind_is_effect(n.kind) {
		return NODE_IO_W, NODE_IO_H
	}
	return NODE_W, NODE_HEAD + len(snd.FX_INFO[n.kind].params) * NODE_ROW + NODE_PAD
}

// The node's rectangle on the screen.
graph_node_rect :: proc(n: ^snd.Fx_Node) -> Rect {
	_, _, cv := graph_areas()
	w, h := graph_node_size(n)
	return Rect{cv.x + int(n.x) - graph_ed.pan[0], cv.y + int(n.y) - graph_ed.pan[1], w, h}
}

graph_port_y :: proc(n: ^snd.Fx_Node, r: Rect) -> int {
	if !snd.fx_kind_is_effect(n.kind) {
		return r.y + r.h / 2
	}
	return r.y + NODE_HEAD / 2
}

graph_out_port :: proc(n: ^snd.Fx_Node) -> [2]int {
	r := graph_node_rect(n)
	return {r.x + r.w, graph_port_y(n, r)}
}

graph_in_port :: proc(n: ^snd.Fx_Node) -> [2]int {
	r := graph_node_rect(n)
	return {r.x, graph_port_y(n, r)}
}

graph_row_rect :: proc(n: ^snd.Fx_Node, i: int) -> Rect {
	r := graph_node_rect(n)
	return Rect{r.x + NODE_PAD, r.y + NODE_HEAD + i * NODE_ROW, r.w - 2 * NODE_PAD, NODE_ROW}
}

GRAPH_LABEL_W :: 66
GRAPH_VALUE_W :: 56

graph_slider_rect :: proc(row: Rect) -> Rect {
	return Rect{row.x + GRAPH_LABEL_W, row.y, row.w - GRAPH_LABEL_W - GRAPH_VALUE_W, row.h}
}

// The small switches in the title of an effect node.
graph_head_buttons :: proc(n: ^snd.Fx_Node) -> (bypass, remove: Rect) {
	r := graph_node_rect(n)
	remove = Rect{r.x + r.w - 12 - 18, r.y + 5, 18, 18}
	bypass = Rect{remove.x - 4 - 20, r.y + 5, 20, 18}
	return
}

fx_color :: proc(k: snd.Fx_Kind) -> Color {
	switch k {
	case .Input:
		return COL_GREEN
	case .Output:
		return COL_PLAY
	case .Gain:
		return Color{160, 168, 190, 255}
	case .Filter:
		return Color{96, 160, 255, 255}
	case .Delay:
		return Color{70, 204, 228, 255}
	case .Reverb:
		return Color{156, 126, 255, 255}
	case .Chorus:
		return Color{110, 210, 160, 255}
	case .Distortion:
		return Color{255, 112, 92, 255}
	case .Crusher:
		return Color{255, 172, 70, 255}
	case .Tremolo:
		return Color{240, 122, 204, 255}
	case .Compressor:
		return Color{190, 222, 90, 255}
	}
	return COL_ACCENT
}

// A wire as a polyline: a cubic Bezier that leaves `a` to the right and arrives at `b` from the left.
WIRE_SEGS :: 28

wire_points :: proc(a, b: [2]int) -> (pts: [WIRE_SEGS + 1][2]f32) {
	ax, ay := f32(a.x), f32(a.y)
	bx, by := f32(b.x), f32(b.y)
	dx := max(abs(bx - ax) * 0.5, 46)
	p0 := [2]f32{ax, ay}
	p1 := [2]f32{ax + dx, ay}
	p2 := [2]f32{bx - dx, by}
	p3 := [2]f32{bx, by}
	for i in 0 ..= WIRE_SEGS {
		t := f32(i) / WIRE_SEGS
		u := 1 - t
		w0 := u * u * u
		w1 := 3 * u * u * t
		w2 := 3 * u * t * t
		w3 := t * t * t
		pts[i] = {w0 * p0.x + w1 * p1.x + w2 * p2.x + w3 * p3.x, w0 * p0.y + w1 * p1.y + w2 * p2.y + w3 * p3.y}
	}
	return
}

// The distance from the point to the segment.
seg_dist :: proc(px, py, ax, ay, bx, by: f32) -> f32 {
	dx, dy := bx - ax, by - ay
	l2 := dx * dx + dy * dy
	t: f32 = 0
	if l2 > 0 {
		t = clamp(((px - ax) * dx + (py - ay) * dy) / l2, 0, 1)
	}
	cx, cy := ax + t * dx, ay + t * dy
	return math.sqrt_f32((px - cx) * (px - cx) + (py - cy) * (py - cy))
}

wire_hit :: proc(a, b: [2]int, px, py: int) -> bool {
	pts := wire_points(a, b)
	for i in 0 ..< WIRE_SEGS {
		if seg_dist(f32(px), f32(py), pts[i].x, pts[i].y, pts[i + 1].x, pts[i + 1].y) <= 6 {
			return true
		}
	}
	return false
}

// The node whose rectangle is under a screen position (the last drawn = the topmost first).
graph_node_at :: proc(g: ^snd.Fx_Graph, px, py: int) -> int {
	for i := len(g.nodes) - 1; i >= 0; i -= 1 {
		if ui.contains(graph_node_rect(&g.nodes[i]), px, py) {
			return i
		}
	}
	return -1
}

dist2 :: proc(a: [2]int, px, py: int) -> int {
	return (a.x - px) * (a.x - px) + (a.y - py) * (a.y - py)
}

// ---- adding, removing, arranging -------------------------------------------------------------------------------

graph_validate_selection :: proc(g: ^snd.Fx_Graph) {
	if graph_ed.sel_node != 0 && snd.fx_find(g, graph_ed.sel_node) < 0 {
		graph_ed.sel_node = 0
	}
	if w := graph_ed.sel_wire; w.from != 0 && !snd.fx_has_edge(g, w.from, w.to) {
		graph_ed.sel_wire = {}
	}
}

nodes_overlap :: proc(g: ^snd.Fx_Graph, x, y, w, h: int, ignore: u16) -> bool {
	m := 14
	for &n in g.nodes {
		if n.id == ignore {
			continue
		}
		nw, nh := graph_node_size(&n)
		nx, ny := int(n.x), int(n.y)
		if x < nx + nw + m && nx < x + w + m && y < ny + nh + m && ny < y + h + m {
			return true
		}
	}
	return false
}

// Lays the nodes out in columns, left to right, by how far each is from the Input.
graph_arrange :: proc(g: ^snd.Fx_Graph) {
	n := len(g.nodes)
	if n == 0 {
		return
	}
	layer := make([]int, n, context.temp_allocator)
	// Longest distance from a node without inputs (the graph has no loops, so n rounds are enough).
	for _ in 0 ..< n {
		for e in g.edges {
			a := snd.fx_find(g, e.from)
			b := snd.fx_find(g, e.to)
			if a >= 0 && b >= 0 {
				layer[b] = max(layer[b], layer[a] + 1)
			}
		}
	}
	top := 0
	for l in layer {
		top = max(top, l)
	}
	if oi := snd.fx_find_kind(g, .Output); oi >= 0 {
		m := 0
		for l, i in layer {
			if i != oi {
				m = max(m, l)
			}
		}
		layer[oi] = m + 1
		top = max(top, layer[oi])
	}
	// Columns, left to right; when the next one would not fit the canvas a new row starts below.
	_, _, cv := graph_areas()
	max_x := max(cv.w - 40, 400)
	Col :: struct {
		nodes: [dynamic]int,
		w, h:  int,
		row:   int,
		x:     int,
	}
	cols: [dynamic]Col
	cols.allocator = context.temp_allocator
	for l in 0 ..= top {
		c := Col{}
		c.nodes.allocator = context.temp_allocator
		for i in 0 ..< n {
			if layer[i] == l {
				append(&c.nodes, i)
			}
		}
		for a in 1 ..< len(c.nodes) { // (insertion sort by y)
			k := a
			for k > 0 && g.nodes[c.nodes[k]].y < g.nodes[c.nodes[k - 1]].y {
				c.nodes[k], c.nodes[k - 1] = c.nodes[k - 1], c.nodes[k]
				k -= 1
			}
		}
		for i in c.nodes {
			w, h := graph_node_size(&g.nodes[i])
			c.w = max(c.w, w)
			c.h += h + GRAPH_GAP_Y
		}
		append(&cols, c)
	}
	x := 30
	row := 0
	for &c in cols {
		if x > 30 && x + c.w > max_x {
			row += 1
			x = 30
		}
		c.row = row
		c.x = x
		x += c.w + GRAPH_GAP_X
	}
	y := 24
	for r in 0 ..= row {
		band := 0
		for c in cols {
			if c.row == r {
				band = max(band, c.h)
			}
		}
		for c in cols {
			if c.row != r {
				continue
			}
			cy := y + (band - c.h) / 2
			for i in c.nodes {
				_, h := graph_node_size(&g.nodes[i])
				g.nodes[i].x = f32(c.x)
				g.nodes[i].y = f32(cy)
				cy += h + GRAPH_GAP_Y
			}
		}
		y += band + 40
	}
}

// Puts the view so that the graph is in sight.
graph_ed_fit :: proc() {
	g := graph_shown()
	if len(g.nodes) == 0 {
		graph_ed.pan = {0, 0}
		return
	}
	minx, miny := 1 << 30, 1 << 30
	maxy := -(1 << 30)
	for &n in g.nodes {
		_, h := graph_node_size(&n)
		minx = min(minx, int(n.x))
		miny = min(miny, int(n.y))
		maxy = max(maxy, int(n.y) + h)
	}
	_, _, cv := graph_areas()
	graph_ed.pan[0] = minx - 30
	graph_ed.pan[1] = (miny + maxy) / 2 - cv.h / 2
	if cv.h > 0 && maxy - miny + 40 > cv.h {
		graph_ed.pan[1] = miny - 20
	}
}

// Adds an effect: into the selected wire, or after the selected node, or in front of the Output.
graph_add :: proc(kind: snd.Fx_Kind) {
	g := graph_edit()
	_, _, cv := graph_areas()
	// Where to put it: to the right of what it follows, or in the middle of the view.
	from, to: u16
	if w := graph_ed.sel_wire; w.from != 0 {
		from, to = w.from, w.to
	} else if si := snd.fx_find(g, graph_ed.sel_node); graph_ed.sel_node != 0 && si >= 0 && g.nodes[si].kind != .Output {
		from = graph_ed.sel_node
	} else if oi := snd.fx_find_kind(g, .Output); oi >= 0 {
		ins := snd.fx_inputs_of(g, g.nodes[oi].id)
		if len(ins) == 1 {
			from, to = ins[0], g.nodes[oi].id
		}
	}
	x := f32(graph_ed.pan[0] + cv.w / 2 - NODE_W / 2)
	y := f32(graph_ed.pan[1] + cv.h / 2 - 60)
	if fi := snd.fx_find(g, from); fi >= 0 {
		fw, _ := graph_node_size(&g.nodes[fi])
		x = g.nodes[fi].x + f32(fw + 34)
		y = g.nodes[fi].y
	}
	id, ok := snd.fx_add(g, kind, x, y)
	if !ok {
		ed_say("The graph has as many nodes as it can hold")
		return
	}
	if to != 0 { // into a wire
		snd.fx_disconnect(g, from, to)
		snd.fx_connect(g, from, id)
		snd.fx_connect(g, id, to)
	} else if from != 0 { // after a node: what it fed now follows the new one
		succ: [dynamic]u16
		succ.allocator = context.temp_allocator
		for e in g.edges {
			if e.from == from && e.to != id {
				append(&succ, e.to)
			}
		}
		for s in succ {
			snd.fx_disconnect(g, from, s)
		}
		snd.fx_connect(g, from, id)
		for s in succ {
			snd.fx_connect(g, id, s)
		}
	}
	ni := snd.fx_find(g, id)
	w, h := graph_node_size(&g.nodes[ni])
	if nodes_overlap(g, int(g.nodes[ni].x), int(g.nodes[ni].y), w, h, id) {
		graph_arrange(g)
	}
	graph_ed.sel_node = id
	graph_ed.sel_wire = {}
	ed_say("Added %s", snd.FX_INFO[kind].name)
	audition_test_note()
}

graph_remove_selected :: proc() {
	if graph_ed.sel_wire.from != 0 {
		w := graph_ed.sel_wire
		g := graph_edit()
		snd.fx_disconnect(g, w.from, w.to)
		graph_ed.sel_wire = {}
		return
	}
	if graph_ed.sel_node != 0 {
		g := graph_shown()
		i := snd.fx_find(g, graph_ed.sel_node)
		if i < 0 || !snd.fx_kind_is_effect(g.nodes[i].kind) {
			ed_say("The Input and the Output cannot be removed")
			return
		}
		id := graph_ed.sel_node
		g = graph_edit()
		snd.fx_remove(g, id)
		graph_ed.sel_node = 0
	}
}

graph_toggle_bypass :: proc(id: u16) {
	g := graph_edit()
	if i := snd.fx_find(g, id); i >= 0 && snd.fx_kind_is_effect(g.nodes[i].kind) {
		g.nodes[i].bypass = !g.nodes[i].bypass
	}
}

graph_reset :: proc() {
	g := graph_edit()
	name := g.name
	snd.fx_graph_destroy(g)
	g^ = snd.fx_graph_default()
	g.name = name
	graph_ed.sel_node = 0
	graph_ed.sel_wire = {}
	graph_ed_fit()
	ed_say("Effects removed")
}

// A test note on the instrument of the current track, through the graph that is shown (whether the track uses it or not).
audition_test_note :: proc() {
	inst := track_inst(ed.cur_track)
	audition_instrument(inst, inst_test_key(inst), ed.def_vel, 0.6, graph_shown())
}

// ---- parameters ------------------------------------------------------------------------------------------------------

// Sets a parameter (the first change of a drag is the undo step).
graph_set_param :: proc(id: u16, pi: int, v: f32, same_step: bool) {
	g := graph_edit(same_step)
	i := snd.fx_find(g, id)
	if i < 0 {
		return
	}
	info := snd.FX_INFO[g.nodes[i].kind].params
	if pi < 0 || pi >= len(info) {
		return
	}
	g.nodes[i].p[pi] = clamp(v, info[pi].lo, info[pi].hi)
}

// Moves a choice parameter one step (round: after the last comes the first).
graph_step_choice :: proc(id: u16, pi: int, dir: int) {
	g := graph_shown()
	i := snd.fx_find(g, id)
	if i < 0 {
		return
	}
	info := snd.FX_INFO[g.nodes[i].kind].params[pi]
	n := int(info.hi - info.lo) + 1
	cur := int(math.round_f32(g.nodes[i].p[pi] - info.lo))
	graph_set_param(id, pi, info.lo + f32(((cur + dir) % n + n) % n), false)
}

graph_slider_from_mouse :: proc(g: ^snd.Fx_Graph) {
	i := snd.fx_find(g, graph_ed.drag_id)
	if i < 0 {
		return
	}
	n := &g.nodes[i]
	info := snd.FX_INFO[n.kind].params[graph_ed.param]
	sl := graph_slider_rect(graph_row_rect(n, graph_ed.param))
	t := clamp(f32(in_.mx - (sl.x + 6)) / f32(max(sl.w - 12, 1)), 0, 1)
	v := snd.fx_param_from_t(info, t)
	if abs(n.p[graph_ed.param] - v) > 1e-6 {
		graph_set_param(graph_ed.drag_id, graph_ed.param, v, graph_ed.changed)
		graph_ed.changed = true
	}
}

// ---- mouse ---------------------------------------------------------------------------------------------------------------

graph_mouse :: proc() {
	g := graph_shown()
	graph_validate_selection(g)
	tb, pal, cv := graph_areas()

	// A drag in progress.
	if graph_ed.drag != .None {
		graph_drag_update(g)
		return
	}

	// The toolbar buttons.
	b_test, b_arrange, b_fit, b_reset := graph_toolbar_buttons(tb)
	if in_.pressed[BTN_L] && mouse_in(tb) {
		switch {
		case mouse_in(b_test):
			audition_test_note()
		case mouse_in(b_arrange):
			graph_arrange(graph_edit())
			graph_ed_fit()
		case mouse_in(b_fit):
			graph_ed_fit()
		case mouse_in(b_reset):
			graph_reset()
		}
		return
	}
	if mouse_in(b_test) || mouse_in(b_arrange) || mouse_in(b_fit) || mouse_in(b_reset) {
		cursor_hint(.POINTING_HAND)
	}

	// The library and the list of effects.
	if mouse_in(pal) {
		graph_panel_mouse(pal)
		return
	}
	if !mouse_in(cv) {
		return
	}

	// The wheel over a parameter changes it; anywhere else it scrolls the canvas (Shift: sideways).
	if in_.wheel_y != 0 {
		if ni, pi := graph_param_at(g, in_.mx, in_.my); ni >= 0 {
			n := &g.nodes[ni]
			info := snd.FX_INFO[n.kind].params[pi]
			if info.unit == .Choice {
				graph_step_choice(n.id, pi, int(in_.wheel_y))
			} else {
				fine := in_.shift
				t := snd.fx_param_to_t(info, n.p[pi]) + (0.01 if fine else 0.04) * in_.wheel_y
				graph_set_param(n.id, pi, snd.fx_param_from_t(info, t), false)
			}
		} else if in_.shift {
			graph_ed.pan[0] -= int(in_.wheel_y * 60)
		} else {
			graph_ed.pan[1] -= int(in_.wheel_y * 60)
		}
	}
	if in_.wheel_x != 0 {
		graph_ed.pan[0] -= int(in_.wheel_x * 60)
	}

	// Hover feedback.
	if pi, _ := graph_port_at(g, in_.mx, in_.my); pi >= 0 {
		cursor_hint(.CROSSHAIR)
	} else if ni := graph_node_at(g, in_.mx, in_.my); ni >= 0 {
		if _, pj := graph_param_at(g, in_.mx, in_.my); pj >= 0 {
			cursor_hint(.RESIZE_EW)
		} else {
			cursor_hint(.POINTING_HAND)
		}
	}

	if in_.pressed[BTN_M] {
		graph_ed.drag = .Pan
		graph_ed.grab = {in_.mx, in_.my}
		return
	}

	if in_.pressed[BTN_R] {
		// Right-click: cut a wire, or step a choice backwards.
		if ni, pi := graph_param_at(g, in_.mx, in_.my); ni >= 0 {
			if snd.FX_INFO[g.nodes[ni].kind].params[pi].unit == .Choice {
				graph_step_choice(g.nodes[ni].id, pi, -1)
			}
			return
		}
		if graph_node_at(g, in_.mx, in_.my) < 0 {
			if e, ok := graph_wire_at(g, in_.mx, in_.my); ok {
				ge := graph_edit()
				snd.fx_disconnect(ge, e.from, e.to)
				graph_ed.sel_wire = {}
			}
		}
		return
	}

	if !in_.pressed[BTN_L] {
		return
	}
	// ---- a left click on the canvas ----
	// The dots first: they stick out of their node, and they are the way to wire.
	if pi, is_out := graph_port_at(g, in_.mx, in_.my); pi >= 0 {
		n := &g.nodes[pi]
		graph_ed.sel_node = n.id
		graph_ed.sel_wire = {}
		if is_out {
			graph_ed.drag = .Wire
			graph_ed.drag_id = n.id
		} else if ins := snd.fx_inputs_of(g, n.id); len(ins) > 0 {
			graph_ed.drag = .Pickup
			graph_ed.drag_id = ins[len(ins) - 1]
			graph_ed.drag_to = n.id
			graph_ed.grab = {in_.mx, in_.my}
		}
		return
	}
	ni := graph_node_at(g, in_.mx, in_.my)
	if ni >= 0 {
		n := &g.nodes[ni]
		graph_ed.sel_node = n.id
		graph_ed.sel_wire = {}
		// The switches in the title.
		if snd.fx_kind_is_effect(n.kind) {
			bp, rm := graph_head_buttons(n)
			if mouse_in(bp) {
				graph_toggle_bypass(n.id)
				return
			}
			if mouse_in(rm) {
				graph_remove_selected()
				return
			}
		}
		// A parameter.
		if _, pi := graph_param_at(g, in_.mx, in_.my); pi >= 0 {
			info := snd.FX_INFO[n.kind].params[pi]
			if in_.dbl {
				graph_set_param(n.id, pi, info.def, false)
				return
			}
			if info.unit == .Choice {
				graph_step_choice(n.id, pi, 1)
				return
			}
			graph_ed.drag = .Slider
			graph_ed.drag_id = n.id
			graph_ed.param = pi
			graph_ed.changed = false
			graph_slider_from_mouse(g)
			audition_test_note()
			return
		}
		// The body: move the node.
		r := graph_node_rect(n)
		graph_ed.drag = .Node
		graph_ed.drag_id = n.id
		graph_ed.grab = {in_.mx - r.x, in_.my - r.y}
		graph_ed.changed = false
		return
	}
	// A wire?
	if e, ok := graph_wire_at(g, in_.mx, in_.my); ok {
		graph_ed.sel_wire = e
		graph_ed.sel_node = 0
		return
	}
	// Empty canvas: deselect, and a drag scrolls.
	graph_ed.sel_node = 0
	graph_ed.sel_wire = {}
	graph_ed.drag = .Pan
	graph_ed.grab = {in_.mx, in_.my}
}

graph_over_port :: proc(n: ^snd.Fx_Node, output: bool) -> bool {
	p := graph_out_port(n) if output else graph_in_port(n)
	return dist2(p, in_.mx, in_.my) <= (PORT_R + 5) * (PORT_R + 5)
}

// The node whose dot is under a screen position, and whether it is its output dot (-1 if none).
graph_port_at :: proc(g: ^snd.Fx_Graph, px, py: int) -> (node: int, output: bool) {
	for i := len(g.nodes) - 1; i >= 0; i -= 1 {
		n := &g.nodes[i]
		if n.kind != .Output && dist2(graph_out_port(n), px, py) <= (PORT_R + 5) * (PORT_R + 5) {
			return i, true
		}
		if n.kind != .Input && dist2(graph_in_port(n), px, py) <= (PORT_R + 5) * (PORT_R + 5) {
			return i, false
		}
	}
	return -1, false
}

// The node and parameter whose row is under a screen position (-1 if none).
graph_param_at :: proc(g: ^snd.Fx_Graph, px, py: int) -> (node, param: int) {
	ni := graph_node_at(g, px, py)
	if ni < 0 || !snd.fx_kind_is_effect(g.nodes[ni].kind) {
		return -1, -1
	}
	n := &g.nodes[ni]
	for i in 0 ..< len(snd.FX_INFO[n.kind].params) {
		if ui.contains(graph_row_rect(n, i), px, py) {
			return ni, i
		}
	}
	return -1, -1
}

graph_wire_at :: proc(g: ^snd.Fx_Graph, px, py: int) -> (e: snd.Fx_Edge, ok: bool) {
	for ed_ in g.edges {
		a := snd.fx_find(g, ed_.from)
		b := snd.fx_find(g, ed_.to)
		if a < 0 || b < 0 {
			continue
		}
		if wire_hit(graph_out_port(&g.nodes[a]), graph_in_port(&g.nodes[b]), px, py) {
			return ed_, true
		}
	}
	return {}, false
}

graph_drag_update :: proc(g: ^snd.Fx_Graph) {
	_, _, cv := graph_areas()
	switch graph_ed.drag {
	case .None:
	case .Pan:
		if in_.down[BTN_L] || in_.down[BTN_M] {
			cursor_hint(.RESIZE_ALL)
			graph_ed.pan[0] -= in_.dmx
			graph_ed.pan[1] -= in_.dmy
		} else {
			graph_ed.drag = .None
		}
	case .Node:
		if !in_.down[BTN_L] {
			graph_ed.drag = .None
			return
		}
		i := snd.fx_find(g, graph_ed.drag_id)
		if i < 0 {
			graph_ed.drag = .None
			return
		}
		nx := f32(in_.mx - graph_ed.grab[0] - cv.x + graph_ed.pan[0])
		ny := f32(in_.my - graph_ed.grab[1] - cv.y + graph_ed.pan[1])
		if nx == g.nodes[i].x && ny == g.nodes[i].y {
			return
		}
		cursor_hint(.RESIZE_ALL)
		ge := graph_edit(graph_ed.changed)
		graph_ed.changed = true
		if j := snd.fx_find(ge, graph_ed.drag_id); j >= 0 {
			ge.nodes[j].x = nx
			ge.nodes[j].y = ny
		}
	case .Slider:
		if !in_.down[BTN_L] {
			graph_ed.drag = .None
			return
		}
		cursor_hint(.RESIZE_EW)
		graph_slider_from_mouse(g)
	case .Pickup:
		if !in_.down[BTN_L] {
			graph_ed.drag = .None
			return
		}
		if abs(in_.mx - graph_ed.grab[0]) + abs(in_.my - graph_ed.grab[1]) >= 5 { // pulled: the wire comes off the input
			ge := graph_edit()
			snd.fx_disconnect(ge, graph_ed.drag_id, graph_ed.drag_to)
			graph_ed.drag = .Wire
		}
	case .Wire:
		cursor_hint(.CROSSHAIR)
		if in_.down[BTN_L] {
			return
		}
		graph_ed.drag = .None
		target := graph_node_at(g, in_.mx, in_.my)
		if target < 0 {
			return
		}
		to := g.nodes[target].id
		if why := snd.fx_connect_problem(g, graph_ed.drag_id, to); why != "" {
			ed_say("Cannot wire that: %s", why)
			return
		}
		ge := graph_edit()
		snd.fx_connect(ge, graph_ed.drag_id, to)
		graph_ed.sel_wire = {graph_ed.drag_id, to}
		graph_ed.sel_node = 0
	}
}

// ---- keys ---------------------------------------------------------------------------------------------------------------

graph_keys :: proc() {
	if global_keys() {
		return
	}
	if hit(.Nav_Cancel) {
		if graph_ed.sel_node != 0 || graph_ed.sel_wire.from != 0 {
			graph_ed.sel_node = 0
			graph_ed.sel_wire = {}
		} else if play_active {
			play_halt()
		} else {
			ed.view = .Roll
		}
	}
	if rep(.Nav_Delete) || rep(.Nav_Backspace) {
		graph_remove_selected()
	}
	for c in in_.chars {
		switch c {
		case 'x':
			graph_remove_selected()
		case 'b':
			if graph_ed.sel_node != 0 {
				graph_toggle_bypass(graph_ed.sel_node)
			}
		case 't':
			audition_test_note()
		case 'a':
			graph_arrange(graph_edit())
			graph_ed_fit()
		case 'f':
			graph_ed_fit()
		case 'n':
			graph_new()
		case 'r':
			graph_rename()
		case 'u':
			run_action(.Edit_Undo)
		case ' ':
			run_action(.Play_Toggle)
		case ':':
			run_action(.Palette)
		case '?':
			run_action(.Help_Keys)
		case '{':
			run_action(.Track_Prev)
		case '}':
			run_action(.Track_Next)
		case 'M':
			run_action(.Track_Mute)
		case 'S':
			run_action(.Track_Solo)
		}
	}
}

// ---- drawing ---------------------------------------------------------------------------------------------------------

graph_toolbar_buttons :: proc(tb: Rect) -> (test, arrange, fit, reset: Rect) {
	h := TOOLBAR_H - 12
	y := tb.y + 6
	x := tb.x + tb.w - 10
	reset = Rect{x - 70, y, 70, h}
	x -= 70 + 6
	fit = Rect{x - 52, y, 52, h}
	x -= 52 + 6
	arrange = Rect{x - 80, y, 80, h}
	x -= 80 + 6
	test = Rect{x - 96, y, 96, h}
	return
}

graph_draw :: proc() {
	g := graph_shown()
	graph_validate_selection(g)
	tb, pal, cv := graph_areas()
	fill(lay.roll, COL_BG0)

	// ---- the canvas ----
	saved := clip_to(cv)
	fill(cv, Color{20, 22, 27, 255})
	// A grid of dots that moves with the nodes.
	step := 28
	ox := ((cv.x - graph_ed.pan[0]) % step + step) % step
	oy := ((cv.y - graph_ed.pan[1]) % step + step) % step
	for y := cv.y + oy; y < cv.y + cv.h; y += step {
		for x := cv.x + ox; x < cv.x + cv.w; x += step {
			fill(Rect{x, y, 2, 2}, Color{255, 255, 255, 14})
		}
	}
	// The wires.
	for e in g.edges {
		a := snd.fx_find(g, e.from)
		b := snd.fx_find(g, e.to)
		if a < 0 || b < 0 {
			continue
		}
		sel := graph_ed.sel_wire == e
		graph_draw_wire(graph_out_port(&g.nodes[a]), graph_in_port(&g.nodes[b]), fx_color(g.nodes[a].kind), sel, g.nodes[b].bypass || g.nodes[a].bypass)
	}
	// The nodes (the selected one on top).
	for &n in g.nodes {
		if n.id != graph_ed.sel_node {
			graph_draw_node(g, &n)
		}
	}
	if i := snd.fx_find(g, graph_ed.sel_node); i >= 0 {
		graph_draw_node(g, &g.nodes[i])
	}
	// A wire that is being pulled.
	if graph_ed.drag == .Wire {
		if a := snd.fx_find(g, graph_ed.drag_id); a >= 0 {
			target := graph_node_at(g, in_.mx, in_.my)
			end := [2]int{in_.mx, in_.my}
			ok := false
			if target >= 0 {
				ok = snd.fx_connect_problem(g, graph_ed.drag_id, g.nodes[target].id) == ""
				if ok {
					end = graph_in_port(&g.nodes[target])
				}
			}
			col := fx_color(g.nodes[a].kind)
			if target >= 0 && !ok {
				col = COL_RED
			}
			graph_draw_wire(graph_out_port(&g.nodes[a]), end, col, true, false)
		}
	}
	clip_restore(saved)
	frame(cv, COL_LINE)

	graph_draw_palette(pal)
	graph_draw_toolbar(tb, g)
}

graph_draw_wire :: proc(a, b: [2]int, col: Color, selected, dim: bool) {
	pts := wire_points(a, b)
	c := col
	if dim {
		c = with_alpha(col, 0.4)
	}
	thick: f32 = 2.5
	if selected {
		thick = 3.5
		for i in 0 ..< WIRE_SEGS { // a soft glow under the selected wire
			line_f(pts[i].x, pts[i].y, pts[i + 1].x, pts[i + 1].y, 8, with_alpha(col, 0.2))
		}
		c = lighten(col, 0.35)
	}
	for i in 0 ..< WIRE_SEGS {
		line_f(pts[i].x, pts[i].y, pts[i + 1].x, pts[i + 1].y, thick, c)
	}
}

graph_draw_port :: proc(p: [2]int, col: Color, hot, filled: bool) {
	rr: f32 = PORT_R + (2 if hot else 0)
	circle(p.x, p.y, rr + 2, Color{0, 0, 0, 120})
	circle(p.x, p.y, rr, lighten(col, 0.25) if hot else col)
	if !filled {
		circle(p.x, p.y, rr - 3, COL_BG0)
	}
}

graph_draw_node :: proc(g: ^snd.Fx_Graph, n: ^snd.Fx_Node) {
	r := graph_node_rect(n)
	_, _, cv := graph_areas()
	if r.x > cv.x + cv.w || r.x + r.w < cv.x || r.y > cv.y + cv.h || r.y + r.h < cv.y {
		return
	}
	col := fx_color(n.kind)
	sel := n.id == graph_ed.sel_node
	effect := snd.fx_kind_is_effect(n.kind)
	dim := n.bypass
	shadow(r, 8, 12, 0.35)
	fill_round(r, 8, COL_BG2)
	// The title bar in the color of the kind.
	head := Rect{r.x, r.y, r.w, NODE_HEAD if effect else r.h}
	hc := mix(COL_BG3, col, 0.30 if !dim else 0.1)
	if effect {
		fill_round(Rect{r.x, r.y, r.w, NODE_HEAD + 8}, 8, hc)
		fill(Rect{r.x, r.y + NODE_HEAD, r.w, 8}, COL_BG2) // (only the top corners of the bar are round)
		hline(r.x + 1, r.x + r.w - 2, r.y + NODE_HEAD, Color{0, 0, 0, 80})
	} else {
		fill_round(head, 8, hc)
	}
	frame_round(r, 8, lighten(col, 0.3) if sel else COL_LINE2)
	if sel {
		frame_round(ui.inset(r, -1), 9, with_alpha(col, 0.55))
	}
	name := snd.FX_INFO[n.kind].name
	chip := Rect{r.x + 10, head.y + (NODE_HEAD - 12) / 2 if effect else r.y + r.h / 2 - 6, 5, 12}
	fill_round(chip, 2, col if !dim else COL_FAINT)
	if effect {
		text_in(Rect{r.x + 20, r.y, r.w - 20 - 70, NODE_HEAD}, name, COL_TEXT if !dim else COL_FAINT, .Bold, .Left, 4)
		bp, rm := graph_head_buttons(n)
		draw_flag(bp, "B", n.bypass, COL_MUTE)
		draw_flag(rm, "x", false, COL_RED)
	} else {
		text_in(Rect{r.x + 20, r.y + 4, r.w - 24, 20}, name, COL_TEXT, .Bold, .Left, 4)
		sub := "the instrument" if n.kind == .Input else "what you hear"
		text_in(Rect{r.x + 20, r.y + 22, r.w - 24, 18}, sub, COL_FAINT, .Small, .Left, 4)
	}
	// The parameters.
	if effect {
		info := snd.FX_INFO[n.kind].params
		for p, i in info {
			row := graph_row_rect(n, i)
			sl := graph_slider_rect(row)
			active := (graph_ed.drag == .Slider && graph_ed.drag_id == n.id && graph_ed.param == i) || (graph_ed.drag == .None && hover(row))
			text_in(Rect{row.x, row.y, GRAPH_LABEL_W, row.h}, p.name, COL_DIM if !dim else COL_FAINT, .Small, .Left, 0)
			val := snd.fx_param_text(n.kind, i, n.p[i])
			if p.unit == .Choice {
				box := Rect{sl.x, sl.y + 3, sl.w + GRAPH_VALUE_W, sl.h - 6}
				fill_round(box, 4, COL_BG0 if !active else COL_BG1)
				frame_round(box, 4, COL_LINE2)
				text_in(box, val, lighten(col, 0.3) if !dim else COL_FAINT, .Small, .Center, 2)
			} else {
				draw_slider(Rect{sl.x + 6, sl.y, sl.w - 12, sl.h}, snd.fx_param_to_t(p, n.p[i]), col if !dim else COL_FAINT, active, p.unit == .Pan)
				text_in(Rect{row.x + row.w - GRAPH_VALUE_W, row.y, GRAPH_VALUE_W, row.h}, val, COL_TEXT if active else COL_DIM, .Small, .Right, 0)
			}
		}
	}
	// The ports.
	if n.kind != .Input {
		graph_draw_port(graph_in_port(n), col, graph_ed.drag == .None && hover(r) && graph_over_port(n, false), len(snd.fx_inputs_of(g, n.id)) > 0)
	}
	if n.kind != .Output {
		graph_draw_port(graph_out_port(n), col, (graph_ed.drag == .None && hover(r) && graph_over_port(n, true)) || (graph_ed.drag == .Wire && graph_ed.drag_id == n.id), true)
	}
}

// Text that wraps at the width of the box (a word at a time).
graph_text_wrapped :: proc(r: Rect, s: string, col: Color) {
	line := 0
	start := 0
	i := 0
	last_space := -1
	lh := row_height(.Small)
	for i <= len(s) {
		if i == len(s) || s[i] == ' ' {
			seg := s[start:i]
			if text_width(seg, .Small) > r.w && last_space > start {
				text(r.x, r.y + line * lh, s[start:last_space], col, .Small)
				line += 1
				start = last_space + 1
			}
			last_space = i
		}
		i += 1
	}
	if start < len(s) {
		text(r.x, r.y + line * lh, s[start:], col, .Small)
	}
}

graph_draw_toolbar :: proc(tb: Rect, g: ^snd.Fx_Graph) {
	gradient_v(tb, COL_BG3, COL_BG2)
	hline(tb.x, tb.x + tb.w - 1, tb.y + tb.h - 1, COL_LINE)
	col := track_color(ed.cur_track)
	fill_round(Rect{tb.x + 10, tb.y + 9, 5, tb.h - 18}, 2, col)
	users, mine := graph_users()
	title := "No graph selected"
	sub := fmt.tprintf("Add an effect to make a graph for track %d, or pick one in the list", ed.cur_track + 1)
	if graph_ed.sel_graph > 0 {
		title = snd.fx_graph_name(g)
		others := users - (1 if mine else 0)
		switch {
		case mine && others == 0:
			sub = fmt.tprintf("track %d plays through it", ed.cur_track + 1)
		case mine:
			sub = fmt.tprintf("track %d plays through it, and %d other track%s", ed.cur_track + 1, others, "" if others == 1 else "s")
		case users == 0:
			sub = fmt.tprintf("no track plays through it: click its circle in the list for track %d", ed.cur_track + 1)
		case:
			sub = fmt.tprintf("%d track%s play%s through it, track %d does not: click its circle in the list", users, "" if users == 1 else "s", "s" if users == 1 else "", ed.cur_track + 1)
		}
	}
	text(tb.x + 24, tb.y + 4, title, COL_TEXT, .Bold)
	text(tb.x + 24, tb.y + 21, sub, COL_FAINT, .Small)
	b_test, b_arrange, b_fit, b_reset := graph_toolbar_buttons(tb)
	draw_button(b_test, "Test note")
	draw_button(b_arrange, "Arrange")
	draw_button(b_fit, "Fit")
	draw_button(b_reset, "Clear")
	live, connected := snd.fx_live(g)
	_ = live
	if !connected {
		text_in(Rect{tb.x, tb.y, b_test.x - tb.x - 10, tb.h}, "Input is not wired to the Output: no sound", COL_RED, .Small, .Right, 0)
	}
}

_ :: math
