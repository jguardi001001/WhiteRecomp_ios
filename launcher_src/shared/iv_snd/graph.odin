package iv_snd

import "core:fmt"
import "core:math"

// ---------------------------------------------------------------------------
// Effect graphs: after-effects for an instrument.
//
// A graph is a set of nodes joined by wires. The sound of every note that is sent through the
// graph is added up and goes into the graph's Input node; whatever reaches the Output node is
// what is heard. In between are effect nodes (filter, delay, reverb, chorus, distortion, ...),
// wired in series, in parallel or both. A node with several wires coming in adds them up.
// Nothing needs to be wired in a particular order: the graph is sorted before it plays.
//
//   Input --> Filter --> Delay --> Output
//          \                    /
//           +----> Chorus ---->+              (a parallel branch)
//
// Graphs are not part of an instrument. They live in a LIBRARY of their own (Song.graphs, and
// Score.graphs for programs that edit songs): as many graphs as you like, each with a name. An
// instrument (Instrument.graph) or, in a score, a track (Score_Track.graph) says which graph of the
// library it is played through, by number (1 = the first graph; 0 = none). Any number of instruments
// and tracks can use the same graph: each of them is processed on its own (own echoes, own reverb
// tail) by its own copy of the processing, with the settings of the one graph, so changing the graph
// changes them all. A graph that nothing uses stays in the library.
//
// A graph that changes nothing (no graph at all, or only Input wired straight to Output) is not
// processed: the sound is bit for bit what it was without graphs.
//
// This file is the model (nodes, wires, the parameters and what they mean: Fx_Graph and
// the procedures that edit it), the library, the sound processing (Fx_Runtime) and the file format
// of graphs (chunk "FXG1", see music_io.odin). The editor that draws and edits graphs is
// part of the tools that use this library (tools/snd_editor), not of it.
// ---------------------------------------------------------------------------

FX_NODE_MAX :: 32 // nodes in one graph (including the Input and Output)
FX_PARAM_MAX :: 8 // parameters of a node (a list of floats, so more can be added at the end)

Fx_Kind :: enum u8 {
	Input, // the sound of the instrument (one per graph)
	Output, // what is heard (one per graph)
	Gain, // level, pan and stereo width
	Filter, // low-pass, high-pass, band-pass, notch
	Delay, // echoes
	Reverb, // a room
	Chorus, // chorus and flanger
	Distortion, // overdrive
	Crusher, // fewer bits and a lower sample rate
	Tremolo, // loudness wobble, or auto-pan
	Compressor, // evens out loud and soft
}

// How a parameter is shown (and what its numbers mean).
Fx_Unit :: enum u8 {
	Number,
	Percent, // 0..1 shown as 0..100 %
	Millis, // milliseconds
	Hertz,
	Decibel,
	Pan, // -1 (left) .. 1 (right)
	Ratio, // x : 1
	Choice, // a whole number that picks one of `choices`
}

Fx_Param :: struct {
	name:    string,
	lo, hi:  f32,
	def:     f32,
	unit:    Fx_Unit,
	log:     bool, // a slider moves through the range in equal ratios (frequencies)
	choices: []string, // Unit == .Choice
}

Fx_Kind_Info :: struct {
	name:   string,
	blurb:  string, // one line: what it does
	params: []Fx_Param,
}

FX_DELAY_SYNC_NAMES := []string{"free", "1/16", "1/8 triplet", "1/8", "dotted 1/8", "1/4", "dotted 1/4", "1/2", "dotted 1/2", "1 bar"}

FX_INFO := [Fx_Kind]Fx_Kind_Info {
	.Input = {"Input", "The sound of the instrument.", nil},
	.Output = {"Output", "What is heard.", nil},
	.Gain = {"Gain", "Level, pan and stereo width.", []Fx_Param{{"Level", -60, 12, 0, .Decibel, false, nil}, {"Pan", -1, 1, 0, .Pan, false, nil}, {"Width", 0, 2, 1, .Percent, false, nil}}},
	.Filter = {
		"Filter",
		"Cuts the highs or the lows of the sound.",
		[]Fx_Param{{"Mode", 0, 3, 0, .Choice, false, []string{"low-pass", "high-pass", "band-pass", "notch"}}, {"Cutoff", 20, 20000, 2000, .Hertz, true, nil}, {"Resonance", 0, 1, 0.2, .Percent, false, nil}, {"Mix", 0, 1, 1, .Percent, false, nil}},
	},
	.Delay = {
		"Delay",
		"Echoes that repeat and fade.",
		[]Fx_Param {
			{"Time", 10, 2000, 350, .Millis, true, nil},
			{"Sync", 0, 9, 0, .Choice, false, FX_DELAY_SYNC_NAMES},
			{"Feedback", 0, 0.95, 0.4, .Percent, false, nil},
			{"Tone", 0, 1, 0.35, .Percent, false, nil},
			{"Ping-pong", 0, 1, 0, .Choice, false, []string{"off", "on"}},
			{"Mix", 0, 1, 0.3, .Percent, false, nil},
		},
	},
	.Reverb = {"Reverb", "The sound of a room.", []Fx_Param{{"Room", 0, 1, 0.5, .Percent, false, nil}, {"Damping", 0, 1, 0.4, .Percent, false, nil}, {"Mix", 0, 1, 0.3, .Percent, false, nil}}},
	.Chorus = {
		"Chorus",
		"Thickens the sound; with a short delay it is a flanger.",
		[]Fx_Param{{"Rate", 0.05, 8, 0.8, .Hertz, true, nil}, {"Depth", 0, 1, 0.5, .Percent, false, nil}, {"Delay", 1, 40, 12, .Millis, true, nil}, {"Feedback", -0.9, 0.9, 0, .Percent, false, nil}, {"Mix", 0, 1, 0.5, .Percent, false, nil}},
	},
	.Distortion = {"Distortion", "Overdrive: pushes the sound into saturation.", []Fx_Param{{"Drive", 0, 1, 0.4, .Percent, false, nil}, {"Tone", 0, 1, 0.7, .Percent, false, nil}, {"Level", -24, 6, -3, .Decibel, false, nil}, {"Mix", 0, 1, 1, .Percent, false, nil}}},
	.Crusher = {"Crusher", "Fewer bits and a lower sample rate: a lo-fi sound.", []Fx_Param{{"Bits", 1, 16, 8, .Number, false, nil}, {"Downsample", 1, 64, 4, .Number, false, nil}, {"Mix", 0, 1, 1, .Percent, false, nil}}},
	.Tremolo = {"Tremolo", "The loudness wobbles (or the sound sweeps left and right).", []Fx_Param{{"Rate", 0.1, 20, 5, .Hertz, true, nil}, {"Depth", 0, 1, 0.5, .Percent, false, nil}, {"Mode", 0, 1, 0, .Choice, false, []string{"tremolo", "auto-pan"}}}},
	.Compressor = {
		"Compressor",
		"Evens out loud and soft parts.",
		[]Fx_Param{{"Threshold", -60, 0, -18, .Decibel, false, nil}, {"Ratio", 1, 20, 4, .Ratio, true, nil}, {"Attack", 0.1, 100, 10, .Millis, true, nil}, {"Release", 10, 1000, 120, .Millis, true, nil}, {"Makeup", 0, 24, 0, .Decibel, false, nil}},
	},
}

fx_kind_is_effect :: proc(k: Fx_Kind) -> bool {
	return k != .Input && k != .Output
}

// ---- the graph ---------------------------------------------------------------------------

Fx_Node :: struct {
	id:     u16, // never changes, never reused in a graph: wires and the running state refer to it
	kind:   Fx_Kind,
	bypass: bool, // the node passes its input through unchanged
	x, y:   f32, // where an editor draws it (the library does not use it)
	p:      [FX_PARAM_MAX]f32,
}

Fx_Edge :: struct {
	from, to: u16, // node ids: the output of `from` goes into `to`
}

Fx_Graph :: struct {
	name:    Patch_Label, // what the library and the editors call it (fx_graph_name)
	nodes:   [dynamic]Fx_Node,
	edges:   [dynamic]Fx_Edge,
	next_id: u16,
}

// A node of this kind with the default parameters.
fx_node_make :: proc(kind: Fx_Kind, id: u16, x, y: f32) -> Fx_Node {
	n := Fx_Node {
		id   = id,
		kind = kind,
		x    = x,
		y    = y,
	}
	for p, i in FX_INFO[kind].params {
		n.p[i] = p.def
	}
	return n
}

// A graph that only has an Input wired to an Output (it changes nothing). The start of every graph made in an editor.
fx_graph_default :: proc() -> Fx_Graph {
	g: Fx_Graph
	append(&g.nodes, fx_node_make(.Input, 1, 40, 120))
	append(&g.nodes, fx_node_make(.Output, 2, 620, 120))
	append(&g.edges, Fx_Edge{1, 2})
	g.next_id = 3
	return g
}

fx_graph_destroy :: proc(g: ^Fx_Graph) {
	delete(g.nodes)
	delete(g.edges)
	g^ = {}
}

fx_graph_clone :: proc(g: ^Fx_Graph) -> Fx_Graph {
	c: Fx_Graph
	c.name = g.name
	append(&c.nodes, ..g.nodes[:])
	append(&c.edges, ..g.edges[:])
	c.next_id = g.next_id
	return c
}

// The index of the node with this id, or -1.
fx_find :: proc(g: ^Fx_Graph, id: u16) -> int {
	for n, i in g.nodes {
		if n.id == id {
			return i
		}
	}
	return -1
}

fx_find_kind :: proc(g: ^Fx_Graph, kind: Fx_Kind) -> int {
	for n, i in g.nodes {
		if n.kind == kind {
			return i
		}
	}
	return -1
}

// Adds an effect node (not an Input or Output: a graph has one of each). Returns its id.
fx_add :: proc(g: ^Fx_Graph, kind: Fx_Kind, x, y: f32) -> (id: u16, ok: bool) {
	if !fx_kind_is_effect(kind) || len(g.nodes) >= FX_NODE_MAX {
		return 0, false
	}
	id = max(g.next_id, 1)
	for fx_find(g, id) >= 0 { // (a graph made by hand may have an id above next_id)
		id += 1
	}
	g.next_id = id + 1
	append(&g.nodes, fx_node_make(kind, id, x, y))
	return id, true
}

fx_has_edge :: proc(g: ^Fx_Graph, from, to: u16) -> bool {
	for e in g.edges {
		if e.from == from && e.to == to {
			return true
		}
	}
	return false
}

// Can the output of `a` be followed, through any number of wires, to `b`?
fx_reaches :: proc(g: ^Fx_Graph, a, b: u16) -> bool {
	seen: [FX_NODE_MAX]bool
	stack: [FX_NODE_MAX * 2]u16
	top := 0
	stack[top] = a
	top += 1
	for top > 0 {
		top -= 1
		cur := stack[top]
		if cur == b {
			return true
		}
		ci := fx_find(g, cur)
		if ci < 0 || seen[ci] {
			continue
		}
		seen[ci] = true
		for e in g.edges {
			if e.from == cur && top < len(stack) {
				stack[top] = e.to
				top += 1
			}
		}
	}
	return false
}

// Why a wire cannot be made (nothing when it can).
fx_connect_problem :: proc(g: ^Fx_Graph, from, to: u16) -> string {
	fi := fx_find(g, from)
	ti := fx_find(g, to)
	switch {
	case fi < 0 || ti < 0:
		return "no such node"
	case from == to:
		return "a node cannot feed itself"
	case g.nodes[fi].kind == .Output:
		return "the Output has no output"
	case g.nodes[ti].kind == .Input:
		return "the Input has no input"
	case fx_has_edge(g, from, to):
		return "those two are wired already"
	case fx_reaches(g, to, from):
		return "that would make a loop"
	case len(g.edges) >= FX_NODE_MAX * 4:
		return "too many wires"
	}
	return ""
}

// Wires the output of `from` into `to`. False (and nothing changes) if that is not allowed: see fx_connect_problem.
fx_connect :: proc(g: ^Fx_Graph, from, to: u16) -> bool {
	if fx_connect_problem(g, from, to) != "" {
		return false
	}
	append(&g.edges, Fx_Edge{from, to})
	return true
}

fx_disconnect :: proc(g: ^Fx_Graph, from, to: u16) {
	for i := len(g.edges) - 1; i >= 0; i -= 1 {
		if g.edges[i].from == from && g.edges[i].to == to {
			ordered_remove(&g.edges, i)
		}
	}
}

// Removes an effect node and its wires. With `bridge` the things that fed it are wired to the things it fed, so
// that deleting a node from the middle of a chain keeps the chain.
fx_remove :: proc(g: ^Fx_Graph, id: u16, bridge := true) -> bool {
	i := fx_find(g, id)
	if i < 0 || !fx_kind_is_effect(g.nodes[i].kind) {
		return false
	}
	preds: [dynamic]u16
	succs: [dynamic]u16
	preds.allocator = context.temp_allocator
	succs.allocator = context.temp_allocator
	for e in g.edges {
		if e.to == id {
			append(&preds, e.from)
		}
		if e.from == id {
			append(&succs, e.to)
		}
	}
	for k := len(g.edges) - 1; k >= 0; k -= 1 {
		if g.edges[k].from == id || g.edges[k].to == id {
			ordered_remove(&g.edges, k)
		}
	}
	ordered_remove(&g.nodes, i)
	if bridge {
		for p in preds {
			for s in succs {
				fx_connect(g, p, s)
			}
		}
	}
	return true
}

// The ids of the nodes feeding `id`.
fx_inputs_of :: proc(g: ^Fx_Graph, id: u16, allocator := context.temp_allocator) -> []u16 {
	out: [dynamic]u16
	out.allocator = allocator
	for e in g.edges {
		if e.to == id {
			append(&out, e.from)
		}
	}
	return out[:]
}

// ---- the library of graphs ------------------------------------------------------------------------
//
// A library is a plain [dynamic]Fx_Graph (Song.graphs, Score.graphs). Graphs are referred to by NUMBER:
// 1 is the first graph of the library, 0 means "no graph" (the same way Zone.sample_id counts recordings).

fx_graph_name :: proc(g: ^Fx_Graph) -> string {
	return patch_label_string(&g.name)
}

fx_graph_set_name :: proc(g: ^Fx_Graph, name: string) {
	g.name = patch_label_make(name)
}

// The graph with this number, or nil for 0 and numbers that are not in the library.
fx_library_get :: proc(lib: []Fx_Graph, number: int) -> ^Fx_Graph {
	if number >= 1 && number <= len(lib) {
		return &lib[number - 1]
	}
	return nil
}

// The number of the graph with this name, or 0.
fx_library_find :: proc(lib: []Fx_Graph, name: string) -> int {
	for &g, i in lib {
		if fx_graph_name(&g) == name {
			return i + 1
		}
	}
	return 0
}

// `base`, or `base 2`, `base 3`... : a name no graph of the library has (in the temporary allocator).
fx_library_unique_name :: proc(lib: []Fx_Graph, base: string) -> string {
	b := base if len(base) > 0 else "Graph"
	if len(b) > PATCH_LABEL_LEN - 6 {
		b = b[:PATCH_LABEL_LEN - 6]
	}
	if fx_library_find(lib, b) == 0 {
		return b
	}
	for k := 2; ; k += 1 {
		name := fmt.tprintf("%s %d", b, k)
		if fx_library_find(lib, name) == 0 {
			return name
		}
	}
}

// Puts a graph into the library (it owns it from now on) under a name made unique, and returns its number.
fx_library_add :: proc(lib: ^[dynamic]Fx_Graph, name: string, g: Fx_Graph) -> int {
	n := g
	fx_graph_set_name(&n, fx_library_unique_name(lib^[:], name))
	append(lib, n)
	return len(lib^)
}

// Takes a graph out of the library. The numbers of the graphs after it go down by one: whoever refers to graphs
// has to follow (song_graph_remove and score_graph_remove do).
fx_library_remove :: proc(lib: ^[dynamic]Fx_Graph, number: int) {
	if number < 1 || number > len(lib^) {
		return
	}
	fx_graph_destroy(&lib^[number - 1])
	ordered_remove(lib, number - 1)
}

fx_library_destroy :: proc(lib: ^[dynamic]Fx_Graph) {
	for &g in lib^ {
		fx_graph_destroy(&g)
	}
	delete(lib^)
	lib^ = nil
}

fx_library_clone :: proc(lib: []Fx_Graph) -> [dynamic]Fx_Graph {
	out: [dynamic]Fx_Graph
	for &g in lib {
		append(&out, fx_graph_clone(&g))
	}
	return out
}

// What a graph number becomes when the graph `removed` leaves the library.
fx_number_after_remove :: proc(number, removed: int) -> int {
	switch {
	case number == removed:
		return 0
	case number > removed:
		return number - 1
	}
	return number
}

// Takes a graph out of the song's library; the instruments that played through it play dry now.
song_graph_remove :: proc(s: ^Song, number: int) {
	if number < 1 || number > len(s.graphs) {
		return
	}
	fx_library_remove(&s.graphs, number)
	for inst in s.instruments {
		inst.graph = fx_number_after_remove(inst.graph, number)
	}
}

// Which nodes are on a path from the Input to the Output (those are the ones that matter), and whether there is one.
fx_live :: proc(g: ^Fx_Graph) -> (live: [FX_NODE_MAX]bool, connected: bool) {
	in_i := fx_find_kind(g, .Input)
	out_i := fx_find_kind(g, .Output)
	if in_i < 0 || out_i < 0 {
		return
	}
	in_id := g.nodes[in_i].id
	out_id := g.nodes[out_i].id
	for n, i in g.nodes {
		if i < FX_NODE_MAX && fx_reaches(g, in_id, n.id) && fx_reaches(g, n.id, out_id) {
			live[i] = true
		}
	}
	connected = live[in_i] && live[out_i]
	return
}

// A graph that changes nothing: no nodes at all, or nothing between the Input and the Output (and nothing
// that could make the sound silent). Such a graph is not processed.
fx_is_trivial :: proc(g: ^Fx_Graph) -> bool {
	if len(g.nodes) == 0 {
		return true
	}
	live, connected := fx_live(g)
	if !connected {
		return false // not wired through: the instrument is silent, which is not "no effect"
	}
	for n, i in g.nodes {
		if i < FX_NODE_MAX && live[i] && fx_kind_is_effect(n.kind) {
			return false
		}
	}
	// Only Input and Output are on a path: it must be one wire, and a gain-free path is a straight pass.
	return true
}

// A graph that is just what fx_graph_default makes (apart from where the nodes are drawn): not stored in files.
fx_is_default :: proc(g: ^Fx_Graph) -> bool {
	return len(g.nodes) == 0 || (len(g.nodes) == 2 && len(g.edges) == 1 && fx_find_kind(g, .Input) >= 0 && fx_find_kind(g, .Output) >= 0 && fx_is_trivial(g))
}

fx_equal :: proc(a, b: ^Fx_Graph) -> bool {
	if len(a.nodes) != len(b.nodes) || len(a.edges) != len(b.edges) {
		return false
	}
	for n, i in a.nodes {
		if n != b.nodes[i] {
			return false
		}
	}
	for e, i in a.edges {
		if e != b.edges[i] {
			return false
		}
	}
	return true
}

// Makes a graph that was read from a file (or built carelessly) safe to play: unique ids, one Input and one Output,
// no wires to nowhere, no loops, parameters in range. A graph that cannot be saved (no Input or Output) is emptied.
fx_sanitize :: proc(g: ^Fx_Graph) {
	// Unique ids, one Input, one Output, at most FX_NODE_MAX nodes.
	kept: [dynamic]Fx_Node
	kept.allocator = context.temp_allocator
	have_in, have_out := false, false
	for n in g.nodes {
		x := n
		if len(kept) >= FX_NODE_MAX || x.id == 0 || int(x.kind) > int(max(Fx_Kind)) {
			continue
		}
		dup := false
		for k in kept {
			if k.id == x.id {
				dup = true
			}
		}
		if dup {
			continue
		}
		if x.kind == .Input {
			if have_in {
				continue
			}
			have_in = true
		}
		if x.kind == .Output {
			if have_out {
				continue
			}
			have_out = true
		}
		for p, i in FX_INFO[x.kind].params {
			x.p[i] = clamp(x.p[i], p.lo, p.hi)
			if p.unit == .Choice {
				x.p[i] = math.round_f32(x.p[i])
			}
		}
		append(&kept, x)
	}
	if !have_in || !have_out {
		clear(&g.nodes)
		clear(&g.edges)
		g.next_id = 1
		return
	}
	clear(&g.nodes)
	append(&g.nodes, ..kept[:])
	// Wires: only between nodes that exist, and only those that keep the graph free of loops.
	old := make([dynamic]Fx_Edge, context.temp_allocator)
	append(&old, ..g.edges[:])
	clear(&g.edges)
	for e in old {
		fx_connect(g, e.from, e.to)
	}
	top: u16 = 0
	for n in g.nodes {
		top = max(top, n.id)
	}
	g.next_id = max(g.next_id, top + 1)
}

// ---- how parameters look and move -------------------------------------------------------------

// 0..1 for a slider showing value `v` of a parameter.
fx_param_to_t :: proc(p: Fx_Param, v: f32) -> f32 {
	if p.hi <= p.lo {
		return 0
	}
	if p.log && p.lo > 0 {
		return clamp(math.ln_f32(max(v, p.lo) / p.lo) / math.ln_f32(p.hi / p.lo), 0, 1)
	}
	return clamp((v - p.lo) / (p.hi - p.lo), 0, 1)
}

// The value a slider at `t` (0..1) means. A choice is rounded to a whole number.
fx_param_from_t :: proc(p: Fx_Param, t: f32) -> f32 {
	tt := clamp(t, 0, 1)
	v: f32
	if p.log && p.lo > 0 {
		v = p.lo * math.exp_f32(tt * math.ln_f32(p.hi / p.lo))
	} else {
		v = p.lo + tt * (p.hi - p.lo)
	}
	if p.unit == .Choice {
		v = math.round_f32(v)
	} else if p.unit == .Percent {
		v = math.round_f32(v * 100) / 100 // whole percents
	}
	return clamp(v, p.lo, p.hi)
}

// The text of a value ("350 ms", "-6.0 dB", "40%", "low-pass").
fx_param_text :: proc(kind: Fx_Kind, i: int, v: f32) -> string {
	info := FX_INFO[kind].params
	if i < 0 || i >= len(info) {
		return ""
	}
	p := info[i]
	switch p.unit {
	case .Number:
		if p.hi - p.lo >= 20 || v == math.round_f32(v) {
			return fmt.tprintf("%.0f", v)
		}
		return fmt.tprintf("%.2f", v)
	case .Percent:
		return fmt.tprintf("%.0f%%", v * 100)
	case .Millis:
		if v >= 1000 {
			return fmt.tprintf("%.2f s", v / 1000)
		}
		if v < 10 {
			return fmt.tprintf("%.1f ms", v)
		}
		return fmt.tprintf("%.0f ms", v)
	case .Hertz:
		if v >= 1000 {
			return fmt.tprintf("%.2f kHz", v / 1000)
		}
		if v >= 100 {
			return fmt.tprintf("%.0f Hz", v)
		}
		if v >= 10 {
			return fmt.tprintf("%.1f Hz", v)
		}
		return fmt.tprintf("%.2f Hz", v)
	case .Decibel:
		if kind == .Gain && v <= p.lo + 0.05 {
			return "-inf dB"
		}
		return fmt.tprintf("%+.1f dB", v)
	case .Pan:
		pct := int(math.round_f32(abs(v) * 100))
		if pct == 0 {
			return "center"
		}
		return fmt.tprintf("%s%d", "L" if v < 0 else "R", pct)
	case .Ratio:
		return fmt.tprintf("%.1f : 1", v)
	case .Choice:
		k := clamp(int(math.round_f32(v)), 0, max(len(p.choices) - 1, 0))
		if k < len(p.choices) {
			return p.choices[k]
		}
		return ""
	}
	return ""
}

// ---- running a graph ---------------------------------------------------------------------------------
//
// An Fx_Runtime is a graph that is playing: the graph (its own copy), and for every node the state of its
// processing (the delay lines, filter memory, ...). When the graph is edited while it plays, the runtime is
// given the new graph (fx_runtime_set): nodes that are still there (same id, same kind) keep their state, so
// the echoes go on and nothing clicks.

FX_IDLE_SECONDS :: 5.5 // a graph that has heard and given nothing for this long stops being processed until sound arrives (longer than any echo)
FX_QUIET :: f32(1e-7)
FX_CHORUS_MAX_MS :: 60
REVERB_NODE_GAIN :: f32(1.0) // the reverb node's wet level relative to its input

Fx_State :: struct {
	id:      u16,
	kind:    Fx_Kind,
	out:     [2][BLOCK]f32, // this node's output for the block being processed
	z:       [2][4]f32, // filter memory, tone filters, ...
	sm:      [4]f32, // smoothed parameters (< 0: not set yet)
	lfo:     f32, // phase of an LFO, 0..1
	env:     f32, // compressor level
	hold:    [2]f32, // crusher: the held sample
	count:   f32, // crusher: samples since the held one
	line:    [2][]f32, // delay and chorus lines
	pos:     int, // write position in the lines
	time:    f32, // delay time now, in samples (< 0: not set yet)
	rev:     ^Reverb,
}

Fx_Runtime :: struct {
	sample_rate: f32,
	graph:       Fx_Graph, // the copy that plays
	states:      [dynamic]Fx_State, // states[i] belongs to graph.nodes[i] (each is big: it is heap allocated one by one)
	order:       [dynamic]int, // node indexes, inputs before the nodes they feed
	quiet:       int, // samples the graph has been silent (in and out)
	tl, tr:      [BLOCK]f32, // the summed input of the node being processed
}

fx_state_free_buffers :: proc(s: ^Fx_State) {
	delete(s.line[0])
	delete(s.line[1])
	if s.rev != nil {
		reverb_destroy(s.rev)
		free(s.rev)
	}
	s.line = {}
	s.rev = nil
}

fx_state_alloc_buffers :: proc(s: ^Fx_State, sr: f32) {
	switch s.kind {
	case .Delay:
		n := int(DELAY_MAX_SECONDS * sr) + 8
		s.line[0] = make([]f32, n)
		s.line[1] = make([]f32, n)
	case .Chorus:
		n := int(FX_CHORUS_MAX_MS * 0.001 * sr) + 8
		s.line[0] = make([]f32, n)
		s.line[1] = make([]f32, n)
	case .Reverb:
		s.rev = new(Reverb)
		reverb_init(s.rev, sr)
	case .Input, .Output, .Gain, .Filter, .Distortion, .Crusher, .Tremolo, .Compressor:
	}
	s.time = -1
	s.sm = {-1, -1, -1, -1}
}

// A new runtime for a graph (nil if the graph changes nothing: use the dry sound).
fx_runtime_new :: proc(g: ^Fx_Graph, sample_rate: f32) -> ^Fx_Runtime {
	if fx_is_trivial(g) {
		return nil
	}
	tables_init()
	rt := new(Fx_Runtime)
	rt.sample_rate = sample_rate
	fx_runtime_set(rt, g)
	return rt
}

fx_runtime_destroy :: proc(rt: ^Fx_Runtime) {
	if rt == nil {
		return
	}
	for &s in rt.states {
		fx_state_free_buffers(&s)
	}
	delete(rt.states)
	delete(rt.order)
	fx_graph_destroy(&rt.graph)
	free(rt)
}

// Gives the runtime a new version of its graph. Nodes that are still there keep their state.
fx_runtime_set :: proc(rt: ^Fx_Runtime, g: ^Fx_Graph) {
	old_states := rt.states
	rt.states = nil
	used := make([]bool, len(old_states), context.temp_allocator)
	fx_graph_destroy(&rt.graph)
	rt.graph = fx_graph_clone(g)
	for n in rt.graph.nodes {
		found := -1
		for s, i in old_states {
			if !used[i] && s.id == n.id && s.kind == n.kind {
				found = i
				break
			}
		}
		if found >= 0 {
			used[found] = true
			append(&rt.states, old_states[found])
		} else {
			st := Fx_State {
				id   = n.id,
				kind = n.kind,
			}
			fx_state_alloc_buffers(&st, rt.sample_rate)
			append(&rt.states, st)
		}
	}
	for &s, i in old_states {
		if !used[i] {
			fx_state_free_buffers(&s)
		}
	}
	delete(old_states)

	// Process order: a node after everything that feeds it (a depth-first walk from the Output, backwards).
	clear(&rt.order)
	visited := make([]bool, len(rt.graph.nodes), context.temp_allocator)
	visit :: proc(rt: ^Fx_Runtime, visited: []bool, i: int) {
		if visited[i] {
			return
		}
		visited[i] = true
		id := rt.graph.nodes[i].id
		for e in rt.graph.edges {
			if e.to == id {
				if j := fx_find(&rt.graph, e.from); j >= 0 {
					visit(rt, visited, j)
				}
			}
		}
		append(&rt.order, i)
	}
	live, _ := fx_live(&rt.graph)
	for n, i in rt.graph.nodes {
		if i < FX_NODE_MAX && live[i] && n.kind == .Output {
			visit(rt, visited, i)
		}
	}
	// Nodes that do not lead to the Output are not processed at all.
}

fx_db_to_lin :: proc(db: f32) -> f32 {
	return math.pow_f32(10, db / 20)
}

// Mixes a dry and a wet sample: mix 0 is all dry, 1 all wet.
fx_mix :: #force_inline proc(dry, wet, mix: f32) -> f32 {
	return dry + (wet - dry) * mix
}

fx_clean :: #force_inline proc(x: f32) -> f32 {
	if abs(x) < 1e-20 {
		return 0
	}
	if !(abs(x) < 1e6) { // also catches NaN
		return 0
	}
	return x
}

// Processes one block: `in_l`, `in_r` (the summed sound of the instrument) go through the graph and the result
// is ADDED to `out_l`, `out_r`. `bpm` is the tempo, for tempo-synced delays.
fx_runtime_process :: proc(rt: ^Fx_Runtime, in_l, in_r, out_l, out_r: []f32, n: int, bpm: f32) {
	// A graph that has been silent for longer than any echo lasts is skipped until sound arrives again.
	in_peak: f32 = 0
	for i in 0 ..< n {
		in_peak = max(in_peak, abs(in_l[i]), abs(in_r[i]))
	}
	idle_limit := int(FX_IDLE_SECONDS * rt.sample_rate)
	if in_peak < FX_QUIET && rt.quiet > idle_limit {
		return
	}

	out_peak: f32 = 0
	for oi in rt.order {
		node := &rt.graph.nodes[oi]
		st := &rt.states[oi]
		if node.kind == .Input {
			for i in 0 ..< n {
				st.out[0][i] = in_l[i]
				st.out[1][i] = in_r[i]
			}
			continue
		}
		// What comes in: the outputs of the nodes wired to this one, added up.
		for i in 0 ..< n {
			rt.tl[i] = 0
			rt.tr[i] = 0
		}
		for e in rt.graph.edges {
			if e.to != node.id {
				continue
			}
			j := fx_find(&rt.graph, e.from)
			if j < 0 {
				continue
			}
			src := &rt.states[j]
			for i in 0 ..< n {
				rt.tl[i] += src.out[0][i]
				rt.tr[i] += src.out[1][i]
			}
		}
		if node.kind == .Output {
			for i in 0 ..< n {
				st.out[0][i] = rt.tl[i]
				st.out[1][i] = rt.tr[i]
			}
			continue
		}
		if node.bypass {
			for i in 0 ..< n {
				st.out[0][i] = rt.tl[i]
				st.out[1][i] = rt.tr[i]
			}
			continue
		}
		fx_process_node(rt, node, st, n, bpm)
		for c in 0 ..< 2 {
			for i in 0 ..< n {
				st.out[c][i] = fx_clean(st.out[c][i])
			}
		}
	}
	if oi := fx_find_kind(&rt.graph, .Output); oi >= 0 {
		st := &rt.states[oi]
		for i in 0 ..< n {
			out_l[i] += st.out[0][i]
			out_r[i] += st.out[1][i]
			out_peak = max(out_peak, abs(st.out[0][i]), abs(st.out[1][i]))
		}
	}
	if in_peak < FX_QUIET && out_peak < FX_QUIET {
		rt.quiet += n
	} else {
		rt.quiet = 0
	}
}

fx_process_node :: proc(rt: ^Fx_Runtime, node: ^Fx_Node, st: ^Fx_State, n: int, bpm: f32) {
	sr := rt.sample_rate
	inv_sr := 1 / sr
	tl := rt.tl[:]
	tr := rt.tr[:]
	p := &node.p
	switch node.kind {
	case .Input, .Output:
		// handled by the caller

	case .Gain:
		lin: f32 = 0
		if p[0] > -59.9 {
			lin = fx_db_to_lin(p[0])
		}
		ang := (clamp(p[1], -1, 1) + 1) * f32(math.PI) * 0.25
		gl := lin * math.cos_f32(ang) * math.SQRT_TWO
		gr := lin * math.sin_f32(ang) * math.SQRT_TWO
		if st.sm[0] < 0 {
			st.sm[0], st.sm[1] = gl, gr
		}
		width := p[2]
		dl := (gl - st.sm[0]) / f32(n)
		dr := (gr - st.sm[1]) / f32(n)
		cl, cr := st.sm[0], st.sm[1]
		for i in 0 ..< n {
			cl += dl
			cr += dr
			m := (tl[i] + tr[i]) * 0.5
			s := (tl[i] - tr[i]) * 0.5 * width
			st.out[0][i] = (m + s) * cl
			st.out[1][i] = (m - s) * cr
		}
		st.sm[0], st.sm[1] = gl, gr

	case .Filter:
		mode := int(math.round_f32(p[0]))
		fc := clamp(p[1], 20, sr * 0.45)
		if st.sm[0] < 0 {
			st.sm[0] = fc
		}
		st.sm[0] += (fc - st.sm[0]) * 0.3 // (the cutoff glides from block to block)
		g := math.tan_f32(f32(math.PI) * st.sm[0] / sr)
		res := clamp(p[2], 0, 1)
		q := 0.6 + res * res * 14
		k := 1 / q
		a1 := 1 / (1 + g * (g + k))
		a2 := g * a1
		a3 := g * a2
		mix := p[3]
		for c in 0 ..< 2 {
			src := tl if c == 0 else tr
			ic1, ic2 := st.z[c][0], st.z[c][1]
			for i in 0 ..< n {
				x := src[i]
				v3 := x - ic2
				v1 := a1 * ic1 + a2 * v3
				v2 := ic2 + a2 * ic1 + a3 * v3
				ic1 = 2 * v1 - ic1
				ic2 = 2 * v2 - ic2
				y: f32
				switch mode {
				case 0:
					y = v2
				case 1:
					y = x - k * v1 - v2
				case 2:
					y = k * v1
				case:
					y = x - k * v1
				}
				st.out[c][i] = fx_mix(x, y, mix)
			}
			st.z[c][0], st.z[c][1] = fx_clean(ic1), fx_clean(ic2)
		}

	case .Delay:
		size := len(st.line[0])
		if size == 0 {
			return
		}
		target := delay_resolve_seconds(p[0] * 0.001, int(math.round_f32(p[1])), bpm) * sr
		if st.time < 0 {
			st.time = target
		}
		glide := 1 / max(0.05 * sr, 1)
		fb := clamp(p[2], 0, DELAY_FEEDBACK_MAX)
		a := 1 - 0.9 * clamp(p[3], 0, 1)
		ping := p[4] >= 0.5
		mix := p[5]
		for i in 0 ..< n {
			st.time += (target - st.time) * glide
			rp := f32(st.pos) - st.time
			if rp < 0 {
				rp += f32(size)
			}
			i0 := int(rp)
			frac := rp - f32(i0)
			if i0 >= size {
				i0 -= size
			}
			i1 := i0 + 1
			if i1 >= size {
				i1 = 0
			}
			dl := st.line[0][i0] + (st.line[0][i1] - st.line[0][i0]) * frac
			dr := st.line[1][i0] + (st.line[1][i1] - st.line[1][i0]) * frac
			st.z[0][0] = fx_clean(st.z[0][0] + a * (dl - st.z[0][0]))
			st.z[1][0] = fx_clean(st.z[1][0] + a * (dr - st.z[1][0]))
			fl := st.z[0][0] * fb
			fr := st.z[1][0] * fb
			in_l := tl[i]
			in_r := tr[i]
			if ping {
				mono := (tl[i] + tr[i]) * 0.5
				in_l = mono + fr
				in_r = fl
			} else {
				in_l += fl
				in_r += fr
			}
			st.line[0][st.pos] = in_l
			st.line[1][st.pos] = in_r
			st.pos += 1
			if st.pos >= size {
				st.pos = 0
			}
			st.out[0][i] = fx_mix(tl[i], dl, mix)
			st.out[1][i] = fx_mix(tr[i], dr, mix)
		}

	case .Reverb:
		if st.rev == nil {
			return
		}
		st.rev.feedback = 0.70 + 0.27 * clamp(p[0], 0, 1)
		st.rev.damp = 0.8 * clamp(p[1], 0, 1)
		mix := p[2]
		send: [BLOCK]f32
		wl: [BLOCK]f32
		wr: [BLOCK]f32
		for i in 0 ..< n {
			send[i] = (tl[i] + tr[i]) * 0.5
		}
		reverb_process(st.rev, send[:], wl[:], wr[:], n)
		for i in 0 ..< n {
			st.out[0][i] = fx_mix(tl[i], wl[i] * REVERB_NODE_GAIN, mix)
			st.out[1][i] = fx_mix(tr[i], wr[i] * REVERB_NODE_GAIN, mix)
		}

	case .Chorus:
		size := len(st.line[0])
		if size == 0 {
			return
		}
		rate := p[0]
		delay_ms := clamp(p[2], 1, 40)
		amp_ms := clamp(p[1], 0, 1) * 0.45 * delay_ms
		fb := clamp(p[3], -0.9, 0.9)
		mix := p[4]
		for i in 0 ..< n {
			ph := st.lfo
			for c in 0 ..< 2 {
				pc := ph + 0.25 * f32(c)
				pc -= math.floor_f32(pc)
				d := (delay_ms + amp_ms * sine_lookup(pc)) * 0.001 * sr
				rp := f32(st.pos) - d
				for rp < 0 {
					rp += f32(size)
				}
				i0 := int(rp)
				frac := rp - f32(i0)
				if i0 >= size {
					i0 -= size
				}
				i1 := i0 + 1
				if i1 >= size {
					i1 = 0
				}
				wet := st.line[c][i0] + (st.line[c][i1] - st.line[c][i0]) * frac
				x := tl[i] if c == 0 else tr[i]
				st.line[c][st.pos] = fx_clean(x + fb * wet)
				st.out[c][i] = fx_mix(x, wet, mix)
			}
			st.pos += 1
			if st.pos >= size {
				st.pos = 0
			}
			st.lfo += rate * inv_sr
			st.lfo -= math.floor_f32(st.lfo)
		}

	case .Distortion:
		drive := clamp(p[0], 0, 1)
		gain := 1 + 40 * drive * drive
		norm := 1 / drive_shape(gain)
		fc := 600 * math.pow_f32(2, clamp(p[1], 0, 1) * 5)
		a := 1 - math.exp_f32(-f32(math.TAU) * min(fc, sr * 0.45) * inv_sr)
		level := fx_db_to_lin(p[2])
		mix := p[3]
		for c in 0 ..< 2 {
			src := tl if c == 0 else tr
			lp := st.z[c][0]
			for i in 0 ..< n {
				x := src[i]
				y := drive_shape(x * gain) * norm
				lp += a * (y - lp)
				st.out[c][i] = fx_mix(x, lp * level, mix)
			}
			st.z[c][0] = fx_clean(lp)
		}

	case .Crusher:
		levels := math.pow_f32(2, clamp(p[0], 1, 16) - 1)
		factor := clamp(p[1], 1, 64)
		mix := p[2]
		for i in 0 ..< n {
			st.count += 1
			if st.count >= factor {
				st.count -= factor
				st.hold[0] = math.round_f32(tl[i] * levels) / levels
				st.hold[1] = math.round_f32(tr[i] * levels) / levels
			}
			st.out[0][i] = fx_mix(tl[i], st.hold[0], mix)
			st.out[1][i] = fx_mix(tr[i], st.hold[1], mix)
		}

	case .Tremolo:
		rate := p[0]
		depth := clamp(p[1], 0, 1)
		pan_mode := p[2] >= 0.5
		for i in 0 ..< n {
			g0 := 1 - depth * (0.5 + 0.5 * sine_lookup(st.lfo))
			g1 := g0
			if pan_mode {
				ph := st.lfo + 0.5
				ph -= math.floor_f32(ph)
				g1 = 1 - depth * (0.5 + 0.5 * sine_lookup(ph))
			}
			st.out[0][i] = tl[i] * g0
			st.out[1][i] = tr[i] * g1
			st.lfo += rate * inv_sr
			st.lfo -= math.floor_f32(st.lfo)
		}

	case .Compressor:
		thr := p[0]
		ratio := max(p[1], 1)
		ac := math.exp_f32(-1 / (max(p[2], 0.1) * 0.001 * sr))
		rc := math.exp_f32(-1 / (max(p[3], 1) * 0.001 * sr))
		makeup := p[4]
		env := st.env
		for i in 0 ..< n {
			det := max(abs(tl[i]), abs(tr[i]))
			if det > env {
				env = ac * env + (1 - ac) * det
			} else {
				env = rc * env + (1 - rc) * det
			}
			env_db := 20 * math.log10_f32(max(env, 1e-6))
			over := env_db - thr
			red: f32 = 0
			if over > 0 {
				red = over * (1 - 1 / ratio)
			}
			g := fx_db_to_lin(makeup - red)
			st.out[0][i] = tl[i] * g
			st.out[1][i] = tr[i] * g
		}
		st.env = fx_clean(env)
	}
}

// ---- file format -----------------------------------------------------------------------------------------
//
// Chunk "FXG1": the library of graphs (graph numbers are the order in it): varlen count of graphs, then per graph
// its name (a string) and the graph: varlen node count and per node: varlen id, u8 kind, u8 flags (1 = bypass), f32 x,
// f32 y, varlen parameter count and that many f32 (so a parameter can be added to a kind later); then varlen wire count
// and per wire varlen from and varlen to (node ids). After the graphs: varlen count of instruments that play through a
// graph, and per instrument its varlen index and the varlen number of its graph.

fx_graph_encode :: proc(w: ^Writer, g: ^Fx_Graph) {
	w_varlen(w, u32(len(g.nodes)))
	for n in g.nodes {
		w_varlen(w, u32(n.id))
		w_u8(w, u8(n.kind))
		w_u8(w, 1 if n.bypass else 0)
		w_f32(w, n.x)
		w_f32(w, n.y)
		np := len(FX_INFO[n.kind].params)
		w_varlen(w, u32(np))
		for i in 0 ..< np {
			w_f32(w, n.p[i])
		}
	}
	w_varlen(w, u32(len(g.edges)))
	for e in g.edges {
		w_varlen(w, u32(e.from))
		w_varlen(w, u32(e.to))
	}
}

fx_graph_decode :: proc(r: ^Reader) -> Fx_Graph {
	g: Fx_Graph
	nn := int(r_varlen(r))
	for _ in 0 ..< min(nn, FX_NODE_MAX) {
		if !r.ok {
			break
		}
		id := u16(min(r_varlen(r), 65535))
		kind_raw := r_u8(r)
		flags := r_u8(r)
		x := r_f32(r)
		y := r_f32(r)
		np := int(r_varlen(r))
		if int(kind_raw) > int(max(Fx_Kind)) {
			r.ok = false
			break
		}
		node := fx_node_make(Fx_Kind(kind_raw), id, x, y)
		node.bypass = flags & 1 != 0
		for i in 0 ..< np {
			v := r_f32(r)
			if i < FX_PARAM_MAX && i < len(FX_INFO[node.kind].params) {
				node.p[i] = v
			}
		}
		append(&g.nodes, node)
	}
	ne := int(r_varlen(r))
	for _ in 0 ..< min(ne, FX_NODE_MAX * 4) {
		if !r.ok {
			break
		}
		a := u16(min(r_varlen(r), 65535))
		b := u16(min(r_varlen(r), 65535))
		append(&g.edges, Fx_Edge{a, b})
	}
	fx_sanitize(&g)
	return g
}

// The "FXG1" chunk of a song: its library of graphs and which instrument uses which. Nil if there are no graphs.
fx_graphs_chunk :: proc(s: ^Song, allocator := context.temp_allocator) -> []u8 {
	if len(s.graphs) == 0 {
		return nil
	}
	w: Writer
	w.buf.allocator = allocator
	w_varlen(&w, u32(len(s.graphs)))
	for &g in s.graphs {
		w_str(&w, fx_graph_name(&g))
		fx_graph_encode(&w, &g)
	}
	count := 0
	for inst in s.instruments {
		if inst.graph >= 1 && inst.graph <= len(s.graphs) {
			count += 1
		}
	}
	w_varlen(&w, u32(count))
	for inst, i in s.instruments {
		if inst.graph >= 1 && inst.graph <= len(s.graphs) {
			w_varlen(&w, u32(i))
			w_varlen(&w, u32(inst.graph))
		}
	}
	return w.buf[:]
}

// Reads an "FXG1" chunk: the song gets the library, and its instruments the graphs they play through.
fx_graphs_apply :: proc(body: []u8, s: ^Song) -> bool {
	r := Reader {
		data = body,
		ok   = true,
	}
	fx_library_destroy(&s.graphs)
	for inst in s.instruments {
		inst.graph = 0
	}
	count := int(r_varlen(&r))
	for _ in 0 ..< min(count, 4096) {
		if !r.ok {
			break
		}
		name := r_str(&r, context.temp_allocator)
		g := fx_graph_decode(&r)
		fx_graph_set_name(&g, name)
		append(&s.graphs, g)
	}
	uses := int(r_varlen(&r))
	for _ in 0 ..< min(uses, 65536) {
		if !r.ok {
			break
		}
		idx := int(r_varlen(&r))
		number := int(r_varlen(&r))
		if idx >= 0 && idx < len(s.instruments) && number >= 1 && number <= len(s.graphs) {
			s.instruments[idx].graph = number
		}
	}
	return r.ok
}
