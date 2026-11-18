package main

import "core:fmt"
import "core:math"
import "core:os"
import snd "shared:iv_snd"

// ---------------------------------------------------------------------------
// More of --selftest: the effect graphs (iv_snd/graph.odin) and the track model (iv_snd/score.odin).
// ---------------------------------------------------------------------------

// A graph that wires the Input through the given effects, in a row, to the Output.
graph_chain :: proc(kinds: ..snd.Fx_Kind) -> snd.Fx_Graph {
	g := snd.fx_graph_default()
	snd.fx_disconnect(&g, 1, 2)
	prev := u16(1)
	for k in kinds {
		id, _ := snd.fx_add(&g, k, 0, 0)
		snd.fx_connect(&g, prev, id)
		prev = id
	}
	snd.fx_connect(&g, prev, 2)
	return g
}

// Sets parameter `pi` of the node `id`.
graph_set_value :: proc(g: ^snd.Fx_Graph, id: u16, pi: int, v: f32) {
	g.nodes[snd.fx_find(g, id)].p[pi] = v
}

// A song with one note of an instrument (a plain synth sound) that has this effect graph (may be nil).
graph_test_song :: proc(patch: snd.Patch, g: ^snd.Fx_Graph, key := 60, vel := 40, ticks := u32(960)) -> snd.Song {
	s: snd.Song
	snd.song_init(&s, "graph test", 120)
	idx := snd.song_add_instrument(&s, snd.instrument_synth(patch, "test"))
	if g != nil {
		s.instruments[idx].graph = snd.fx_library_add(&s.graphs, "test", snd.fx_graph_clone(g)) // (the graph is in the song's library; the instrument names it)
	}
	snd.song_set_instrument(&s, 0, 0, 0, idx)
	snd.song_control(&s, 0, 0, 0, snd.SCORE_CC_REVERB, 0) // (no send to the shared reverb: only the graph colors the sound)
	snd.song_note(&s, 0, 0, ticks, 0, key, vel)
	snd.song_finish(&s)
	return s
}

render_graph_song :: proc(patch: snd.Patch, g: ^snd.Fx_Graph, seconds: f32, key := 60, vel := 40, ticks := u32(960)) -> []f32 {
	s := graph_test_song(patch, g, key, vel, ticks)
	defer snd.song_destroy(&s)
	return snd.render_song(&s, seconds)
}

energy_of :: proc(b: []f32, from, to: int) -> f64 {
	e: f64 = 0
	for i in from ..< min(to, len(b) / 2) {
		e += f64(b[i * 2]) * f64(b[i * 2]) + f64(b[i * 2 + 1]) * f64(b[i * 2 + 1])
	}
	return e
}

peak_of :: proc(b: []f32) -> f32 {
	p: f32 = 0
	for v in b {
		p = max(p, abs(v))
	}
	return p
}

finite_all :: proc(b: []f32) -> bool {
	for v in b {
		if !(abs(v) < 1e4) {
			return false
		}
	}
	return true
}

run_graph_tests :: proc() {
	SR :: 44100

	// ---- the model: nodes, wires, loops, removing, cleaning up ----
	{
		g := snd.fx_graph_default()
		defer snd.fx_graph_destroy(&g)
		check(len(g.nodes) == 2 && len(g.edges) == 1 && snd.fx_is_trivial(&g) && snd.fx_is_default(&g), "graph: the default is Input -> Output and changes nothing")
		check(!snd.fx_connect(&g, 2, 1), "graph: the Output cannot feed anything")
		delay, ok := snd.fx_add(&g, .Delay, 100, 50)
		check(ok && snd.fx_is_trivial(&g), "graph: a node that is not wired in changes nothing")
		chorus, _ := snd.fx_add(&g, .Chorus, 100, 150)
		check(snd.fx_connect(&g, 1, delay) && snd.fx_connect(&g, delay, chorus) && snd.fx_connect(&g, chorus, 2), "graph: wires made")
		check(!snd.fx_connect(&g, chorus, delay), "graph: a loop is refused")
		check(!snd.fx_connect(&g, delay, chorus), "graph: the same wire twice is refused")
		check(!snd.fx_connect(&g, delay, delay), "graph: a node cannot feed itself")
		check(!snd.fx_connect(&g, 2, delay) && !snd.fx_connect(&g, delay, 1), "graph: nothing goes into the Input or out of the Output")
		check(!snd.fx_is_trivial(&g) && !snd.fx_is_default(&g), "graph: effects on the way make it a real one")
		snd.fx_disconnect(&g, 1, 2)
		// Removing the Delay from the middle of the chain keeps the chain.
		check(snd.fx_remove(&g, delay), "graph: remove a node")
		check(snd.fx_has_edge(&g, 1, chorus) && snd.fx_has_edge(&g, chorus, 2) && snd.fx_find(&g, delay) < 0, "graph: the chain is kept (bridged)")
		check(!snd.fx_remove(&g, 1) && !snd.fx_remove(&g, 2), "graph: Input and Output stay")
		// Unwired Input: not trivial (silence).
		snd.fx_disconnect(&g, 1, chorus)
		check(!snd.fx_is_trivial(&g), "graph: an Input that is not wired through is silence, not 'no effect'")
		// Cleaning up a damaged graph.
		bad: snd.Fx_Graph
		append(&bad.nodes, snd.fx_node_make(.Input, 1, 0, 0), snd.fx_node_make(.Output, 2, 0, 0), snd.fx_node_make(.Delay, 3, 0, 0), snd.fx_node_make(.Delay, 3, 0, 0), snd.fx_node_make(.Input, 4, 0, 0))
		bad.nodes[2].p[0] = 99999
		append(&bad.edges, snd.Fx_Edge{1, 3}, snd.Fx_Edge{3, 2}, snd.Fx_Edge{2, 3}, snd.Fx_Edge{3, 9}, snd.Fx_Edge{3, 1})
		snd.fx_sanitize(&bad)
		check(len(bad.nodes) == 3 && len(bad.edges) == 2 && bad.nodes[2].p[0] == 2000, "graph: sanitize drops duplicates and bad wires, clamps values (%d nodes, %d wires, %f)", len(bad.nodes), len(bad.edges), bad.nodes[2].p[0])
		snd.fx_graph_destroy(&bad)
	}

	// ---- the file: the library of graphs is stored with the song and comes back, with who uses what ----
	{
		g := graph_chain(.Filter, .Delay, .Reverb)
		defer snd.fx_graph_destroy(&g)
		graph_set_value(&g, 3, 1, 777)
		s := graph_test_song(snd.patch_organ(), &g)
		plain := graph_test_song(snd.patch_organ(), nil)
		bytes := snd.song_encode(&s, context.temp_allocator)
		check(len(bytes) > len(snd.song_encode(&plain, context.temp_allocator)), "graph file: the graph is stored")
		back, bok := snd.song_decode(bytes)
		check(bok && len(back.instruments) == 1 && len(back.graphs) == 1, "graph file: loads")
		if bok && len(back.instruments) == 1 && len(back.graphs) == 1 {
			check(back.instruments[0].graph == 1, "graph file: the instrument names its graph")
			check(snd.fx_equal(&back.graphs[0], &g) && snd.fx_graph_name(&back.graphs[0]) == "test", "graph file: the graph comes back as it was, with its name")
			check(back.graphs[0].nodes[snd.fx_find(&back.graphs[0], 3)].p[1] == 777, "graph file: parameters")
			c := snd.song_clone(&back)
			check(snd.fx_equal(&c.graphs[0], &g) && len(c.graphs[0].nodes) == 5 && c.instruments[0].graph == 1, "graph: song_clone copies the library")
			snd.song_destroy(&c)
			a := snd.render_song(&s, 3)
			b := snd.render_song(&back, 3)
			samples_equal("graph file: the loaded song sounds the same", a, b)
			delete(a)
			delete(b)
		}
		snd.song_destroy(&back)
		snd.song_destroy(&s)
		snd.song_destroy(&plain)
	}

	// ---- the library is not part of the instruments: many graphs, any number of instruments on one graph, unused graphs kept ----
	{
		s: snd.Song
		snd.song_init(&s, "library", 120)
		defer snd.song_destroy(&s)
		ga := graph_chain(.Delay)
		gb := graph_chain(.Distortion)
		gc := graph_chain(.Chorus)
		a_num := snd.fx_library_add(&s.graphs, "echo", ga)
		b_num := snd.fx_library_add(&s.graphs, "echo", gb) // (the same name: made unique)
		c_num := snd.fx_library_add(&s.graphs, "wide", gc)
		check(a_num == 1 && b_num == 2 && c_num == 3 && snd.fx_graph_name(&s.graphs[1]) == "echo 2", "library: numbers by order, names made unique (%s)", snd.fx_graph_name(&s.graphs[1]))
		check(snd.fx_library_find(s.graphs[:], "wide") == 3 && snd.fx_library_get(s.graphs[:], 0) == nil && snd.fx_library_get(s.graphs[:], 4) == nil, "library: find by name, 0 and out of range give nothing")
		for k in ([?]int{1, 0, 1}) { // three instruments: two of them on graph 1, one with none
			idx := snd.song_add_instrument(&s, snd.instrument_synth(snd.patch_organ(), "organ"))
			s.instruments[idx].graph = k
		}
		bytes := snd.song_encode(&s, context.temp_allocator)
		back, ok := snd.song_decode(bytes)
		check(ok && len(back.graphs) == 3 && len(back.instruments) == 3, "library file: loads (%d graphs)", len(back.graphs))
		if ok && len(back.graphs) == 3 && len(back.instruments) == 3 {
			check(back.instruments[0].graph == 1 && back.instruments[1].graph == 0 && back.instruments[2].graph == 1, "library file: who uses what (%d %d %d)", back.instruments[0].graph, back.instruments[1].graph, back.instruments[2].graph)
			check(snd.fx_graph_name(&back.graphs[2]) == "wide" && snd.fx_equal(&back.graphs[1], &s.graphs[1]), "library file: graphs nobody uses are kept")
			snd.song_graph_remove(&back, 1)
			check(len(back.graphs) == 2 && back.instruments[0].graph == 0 && back.instruments[2].graph == 0 && snd.fx_graph_name(&back.graphs[1]) == "wide", "library: removing a graph: its users play dry, the numbers after it go down")
		}
		snd.song_destroy(&back)
	}

	// ---- one graph on two instruments is the same as the same graph twice: each is processed on its own ----
	{
		g := graph_chain(.Delay)
		defer snd.fx_graph_destroy(&g)
		graph_set_value(&g, 3, 0, 180)
		graph_set_value(&g, 3, 5, 0.6)
		build :: proc(g: ^snd.Fx_Graph, shared: bool) -> snd.Song {
			s: snd.Song
			snd.song_init(&s, "two", 120)
			n1 := snd.fx_library_add(&s.graphs, "fx", snd.fx_graph_clone(g))
			n2 := n1 if shared else snd.fx_library_add(&s.graphs, "fx copy", snd.fx_graph_clone(g))
			for k in 0 ..< 2 {
				idx := snd.song_add_instrument(&s, snd.instrument_synth(snd.patch_organ(), "organ"))
				s.instruments[idx].graph = n1 if k == 0 else n2
				snd.song_set_instrument(&s, 0, 0, k, idx)
				snd.song_control(&s, 0, 0, k, snd.SCORE_CC_REVERB, 0)
				snd.song_note(&s, 0, u32(k) * 720, 240, k, 60 + 7 * k, 40)
			}
			snd.song_finish(&s)
			return s
		}
		one := build(&g, true)
		two := build(&g, false)
		a := snd.render_song(&one, 4)
		b := snd.render_song(&two, 4)
		samples_equal("library: two instruments on one graph sound like two copies of it", a, b)
		check(len(one.graphs) == 1 && len(two.graphs) == 2 && peak_of(a) > 0.01, "library: shared graph, audible")
		delete(a)
		delete(b)
		snd.song_destroy(&one)
		snd.song_destroy(&two)
	}

	// ---- an instrument without effects is bit for bit what it was; a graph that changes nothing too ----
	{
		def := snd.fx_graph_default()
		a := render_graph_song(snd.patch_organ(), nil, 2)
		b := render_graph_song(snd.patch_organ(), &def, 2)
		samples_equal("graph: Input -> Output is the dry sound", a, b)
		check(peak_of(a) > 0.01, "graph: the test note is audible (%f)", peak_of(a))
		snd.fx_graph_destroy(&def)

		// A node that is bypassed does nothing.
		g := graph_chain(.Gain)
		graph_set_value(&g, 3, 0, -30)
		g.nodes[snd.fx_find(&g, 3)].bypass = true
		c := render_graph_song(snd.patch_organ(), &g, 2)
		samples_equal("graph: a bypassed node does nothing", a, c)
		delete(c)
		snd.fx_graph_destroy(&g)
		delete(a)
		delete(b)
	}

	// ---- what the effects do ----
	{
		dry := render_graph_song(snd.patch_organ(), nil, 2)
		defer delete(dry)

		// Gain: -6 dB is half the amplitude, so a quarter of the energy.
		g := graph_chain(.Gain)
		graph_set_value(&g, 3, 0, -6.0206)
		quiet := render_graph_song(snd.patch_organ(), &g, 2)
		ratio := energy_of(quiet, 0, 2 * SR) / energy_of(dry, 0, 2 * SR)
		check(abs(ratio - 0.25) < 0.01, "gain -6 dB: energy ratio %f, wanted 0.25", ratio)
		delete(quiet)
		// Pan: all the way left, nothing on the right.
		graph_set_value(&g, 3, 0, 0)
		graph_set_value(&g, 3, 1, -1)
		left := render_graph_song(snd.patch_organ(), &g, 2)
		le, re: f64
		for i in 0 ..< SR {
			le += f64(left[i * 2]) * f64(left[i * 2])
			re += f64(left[i * 2 + 1]) * f64(left[i * 2 + 1])
		}
		check(le > 0.001 && re < le * 1e-9, "gain: panned left (%g, %g)", le, re)
		delete(left)
		snd.fx_graph_destroy(&g)

		// Delay: with only the echo (mix 100%) nothing is heard before the first echo.
		g = graph_chain(.Delay)
		graph_set_value(&g, 3, 0, 100) // 100 ms
		graph_set_value(&g, 3, 2, 0) // no feedback
		graph_set_value(&g, 3, 5, 1) // mix: echo only
		echo := render_graph_song(snd.patch_organ(), &g, 2)
		first := -1
		for i in 0 ..< len(echo) / 2 {
			if echo[i * 2] != 0 || echo[i * 2 + 1] != 0 {
				first = i
				break
			}
		}
		check(abs(first - SR / 10) <= 2, "delay node: first echo at frame %d, wanted %d", first, SR / 10)
		check(energy_of(echo, SR / 10, 2 * SR) > 0.5 * energy_of(dry, 0, 2 * SR) * 0.5, "delay node: the echo is as loud as the sound")
		delete(echo)
		// Tempo sync: a quarter note at 120 BPM is 500 ms (the "Time" is ignored).
		graph_set_value(&g, 3, 1, 5)
		sync := render_graph_song(snd.patch_organ(), &g, 2)
		first = -1
		for i in 0 ..< len(sync) / 2 {
			if sync[i * 2] != 0 || sync[i * 2 + 1] != 0 {
				first = i
				break
			}
		}
		check(abs(first - SR / 2) <= 2, "delay node: synced to a quarter note: first echo at frame %d, wanted %d", first, SR / 2)
		delete(sync)
		snd.fx_graph_destroy(&g)

		// Filter: a low-pass far below the note takes most of it away; a high-pass above it too.
		bright := snd.patch_lead_saw()
		dry_b := render_graph_song(bright, nil, 2, 72, 90)
		g = graph_chain(.Filter)
		graph_set_value(&g, 3, 0, 0)
		graph_set_value(&g, 3, 1, 200)
		lp := render_graph_song(bright, &g, 2, 72, 90)
		r1 := energy_of(lp, 0, 2 * SR) / energy_of(dry_b, 0, 2 * SR)
		check(r1 < 0.15, "filter: a 200 Hz low-pass leaves %f of a 523 Hz note", r1)
		graph_set_value(&g, 3, 0, 1)
		graph_set_value(&g, 3, 1, 12000)
		hp := render_graph_song(bright, &g, 2, 72, 90)
		r2 := energy_of(hp, 0, 2 * SR) / energy_of(dry_b, 0, 2 * SR)
		check(r2 < 0.2, "filter: a 12 kHz high-pass leaves %f of the sound", r2)
		delete(lp)
		delete(hp)
		delete(dry_b)
		snd.fx_graph_destroy(&g)

		// Reverb: there is sound after the note has ended (note: 0.5 s; look from 1.0 s on).
		g = graph_chain(.Reverb)
		graph_set_value(&g, 3, 2, 1)
		rv := render_graph_song(snd.patch_organ(), &g, 3, 60, 40, 480)
		dry_s := render_graph_song(snd.patch_organ(), nil, 3, 60, 40, 480)
		tail := energy_of(rv, SR, 3 * SR)
		tail_dry := energy_of(dry_s, SR, 3 * SR)
		check(tail > 100 * max(tail_dry, 1e-12) && tail > 1e-4, "reverb node: a tail after the note (%g vs dry %g)", tail, tail_dry)
		check(finite_all(rv), "reverb node: finite")
		delete(rv)
		delete(dry_s)
		snd.fx_graph_destroy(&g)

		// Parallel branches add up: Input -> Gain A and Input -> Gain B, both -> Output.
		g = snd.fx_graph_default()
		snd.fx_disconnect(&g, 1, 2)
		ga, _ := snd.fx_add(&g, .Gain, 0, 0)
		gb, _ := snd.fx_add(&g, .Gain, 0, 0)
		graph_set_value(&g, ga, 0, -6.0206)
		graph_set_value(&g, gb, 0, -6.0206)
		snd.fx_connect(&g, 1, ga)
		snd.fx_connect(&g, 1, gb)
		snd.fx_connect(&g, ga, 2)
		snd.fx_connect(&g, gb, 2)
		par := render_graph_song(snd.patch_organ(), &g, 2)
		ratio = energy_of(par, 0, 2 * SR) / energy_of(dry, 0, 2 * SR)
		check(abs(ratio - 1) < 0.01, "graph: two -6 dB branches add up to the dry sound (ratio %f)", ratio)
		delete(par)
		snd.fx_graph_destroy(&g)
	}

	// ---- every kind of effect: finite, audible, and cheap enough ----
	{
		for kind in snd.Fx_Kind {
			if !snd.fx_kind_is_effect(kind) {
				continue
			}
			g := graph_chain(kind)
			out := render_graph_song(snd.patch_lead_saw(), &g, 1.5, 64, 100)
			name := snd.FX_INFO[kind].name
			check(finite_all(out), "effect %s: finite output", name)
			check(peak_of(out) > 0.002 && peak_of(out) < 4, "effect %s: peak %f", name, peak_of(out))
			// Extreme settings must not blow up either.
			for pi in 0 ..< len(snd.FX_INFO[kind].params) {
				p := snd.FX_INFO[kind].params[pi]
				graph_set_value(&g, 3, pi, p.hi)
			}
			out2 := render_graph_song(snd.patch_lead_saw(), &g, 1.5, 64, 100)
			check(finite_all(out2), "effect %s: finite at the highest settings", name)
			for pi in 0 ..< len(snd.FX_INFO[kind].params) {
				p := snd.FX_INFO[kind].params[pi]
				graph_set_value(&g, 3, pi, p.lo)
			}
			out3 := render_graph_song(snd.patch_lead_saw(), &g, 1.5, 64, 100)
			check(finite_all(out3), "effect %s: finite at the lowest settings", name)
			// The text of every value can be made.
			for pi in 0 ..< len(snd.FX_INFO[kind].params) {
				check(len(snd.fx_param_text(kind, pi, snd.FX_INFO[kind].params[pi].def)) > 0, "effect %s: text of parameter %d", name, pi)
			}
			delete(out)
			delete(out2)
			delete(out3)
			snd.fx_graph_destroy(&g)
		}
	}

	// ---- what it costs: all nine effects in a row on one instrument ----
	{
		g := graph_chain(.Gain, .Filter, .Delay, .Reverb, .Chorus, .Distortion, .Crusher, .Tremolo, .Compressor)
		t0 := now()
		out := render_graph_song(snd.patch_lead_saw(), &g, 4, 64, 80, 1920)
		dt := now() - t0
		t1 := now()
		plain := render_graph_song(snd.patch_lead_saw(), nil, 4, 64, 80, 1920)
		dt0 := now() - t1
		check(finite_all(out) && dt < 1.0, "graph cost: 4 s of audio through nine effects took %.2f s", dt)
		fmt.printfln("graphs: 4 s of audio render in %.0f ms dry, %.0f ms through nine effects in a row (%.1f%% of real time)", dt0 * 1000, dt * 1000, dt / 4 * 100)
		delete(out)
		delete(plain)
		snd.fx_graph_destroy(&g)
	}

	// ---- editing a graph while it plays keeps what the effects hold (the echoes go on) ----
	{
		g := graph_chain(.Delay)
		defer snd.fx_graph_destroy(&g)
		graph_set_value(&g, 3, 0, 50) // 50 ms = 2205 frames
		graph_set_value(&g, 3, 2, 0)
		graph_set_value(&g, 3, 5, 1)
		rt := snd.fx_runtime_new(&g, SR)
		check(rt != nil, "runtime: a graph with a delay is processed")
		if rt != nil {
			in_l, in_r, out_l, out_r: [snd.BLOCK]f32
			in_l[0] = 1
			in_r[0] = 1
			snd.fx_runtime_process(rt, in_l[:], in_r[:], out_l[:], out_r[:], snd.BLOCK, 120)
			in_l[0] = 0
			in_r[0] = 0
			g2 := snd.fx_graph_clone(&g)
			graph_set_value(&g2, 3, 5, 1) // (edited: the very same node)
			g2.nodes[snd.fx_find(&g2, 3)].x = 500
			snd.fx_runtime_set(rt, &g2)
			snd.fx_graph_destroy(&g2)
			echo_at := -1
			for blk in 1 ..< 12 {
				out_l = {}
				out_r = {}
				snd.fx_runtime_process(rt, in_l[:], in_r[:], out_l[:], out_r[:], snd.BLOCK, 120)
				for i in 0 ..< snd.BLOCK {
					if abs(out_l[i]) > 0.5 {
						echo_at = blk * snd.BLOCK + i
					}
				}
			}
			check(echo_at == 2205, "runtime: the echo survives an edit of the graph (at %d, wanted 2205)", echo_at)
			// A silent graph is skipped after a while, and picks up again when sound arrives.
			zero: [snd.BLOCK]f32
			for _ in 0 ..< int(snd.FX_IDLE_SECONDS * SR) / snd.BLOCK + 40 {
				out_l = {}
				snd.fx_runtime_process(rt, zero[:], zero[:], out_l[:], out_r[:], snd.BLOCK, 120)
			}
			check(rt.quiet > int(snd.FX_IDLE_SECONDS * SR), "runtime: a graph that has been silent for long is idle (%d)", rt.quiet)
			in_l[0] = 1
			out_l = {}
			snd.fx_runtime_process(rt, in_l[:], in_r[:], out_l[:], out_r[:], snd.BLOCK, 120)
			check(rt.quiet == 0, "runtime: sound wakes it up again")
			snd.fx_runtime_destroy(rt)
		}
	}

	// ---- through the sequencer: replacing the song (an edit) while it plays keeps the effect going ----
	{
		g := graph_chain(.Delay)
		defer snd.fx_graph_destroy(&g)
		graph_set_value(&g, 3, 0, 300)
		graph_set_value(&g, 3, 2, 0.5)
		graph_set_value(&g, 3, 5, 0.5)
		s1 := graph_test_song(snd.patch_organ(), &g, 60, 40, 240)
		graph_set_value(&g, 3, 0, 320) // the edit
		s2 := graph_test_song(snd.patch_organ(), &g, 60, 40, 240)
		a := new(snd.Audio)
		snd.audio_init(a, SR)
		snd.music_play(a, &s1, false)
		buf := make([]f32, 2 * SR / 2 * 2)
		snd.audio_render(a, buf[:SR])
		snd.music_replace_song(a, &s2, false)
		snd.audio_render(a, buf[SR:])
		check(finite_all(buf) && energy_of(buf, SR / 2 + 200, SR) > 1e-6, "sequencer: the echoes go on after the song was replaced")
		delete(buf)
		snd.audio_shutdown(a)
		free(a)
		snd.song_destroy(&s1)
		snd.song_destroy(&s2)
	}

	// ---- no limit on the notes of a track: 200 notes at once (many of them on the same key) all sound ----
	{
		p := snd.score_new()
		defer snd.score_free(&p)
		for i in 0 ..< 200 {
			append(&p.notes, snd.Score_Note{start = 0, len = 1920, track = 0, key = u8(24 + (i % 80)), vel = 60})
		}
		s := snd.score_to_song(&p, .Play_Once)
		a := new(snd.Audio)
		snd.audio_init(a, SR)
		snd.music_play(a, &s, false)
		buf := make([]f32, 2 * 1024)
		snd.audio_render(a, buf)
		n := snd.synth_active_voices(&a.music)
		check(n >= 195, "voices: %d of 200 simultaneous notes are sounding", n)
		delete(buf)
		snd.audio_shutdown(a)
		free(a)
		snd.song_destroy(&s)
	}
	fmt.println("graphs: model, file, every effect, edits while playing, 200 voices checked")
}

run_score_tests :: proc() {
	// ---- lanes: notes of one track never cut each other off ----
	{
		p := snd.score_new()
		defer snd.score_free(&p)
		// Three notes on the same key that overlap, a chord, and a note that starts when another ends.
		append(&p.notes, snd.Score_Note{start = 0, len = 480, track = 0, key = 60, vel = 100})
		append(&p.notes, snd.Score_Note{start = 240, len = 480, track = 0, key = 60, vel = 100})
		append(&p.notes, snd.Score_Note{start = 360, len = 480, track = 0, key = 60, vel = 100})
		append(&p.notes, snd.Score_Note{start = 0, len = 960, track = 0, key = 64, vel = 100})
		append(&p.notes, snd.Score_Note{start = 480, len = 480, track = 0, key = 62, vel = 100})
		append(&p.notes, snd.Score_Note{start = 960, len = 480, track = 0, key = 60, vel = 100}) // (the lane of the first one is free again)
		lanes := snd.score_lanes(&p)
		check(lanes[0] == 3, "score: three overlapping notes of one key need 3 lanes (%d)", lanes[0])
		s := snd.score_to_song(&p, .Save)
		chans: [256]bool
		nchan := 0
		for e in s.tracks[1].events {
			if e.kind == .Note_On && !chans[e.channel] {
				chans[e.channel] = true
				nchan += 1
			}
		}
		check(nchan == 3, "score: the notes use 3 channels of the song (%d)", nchan)
		// Every note-off ends the note on its own channel: the note-ons and note-offs pair up per channel and key.
		open: [256][128]int
		for e in s.tracks[1].events {
			#partial switch e.kind {
			case .Note_On:
				open[e.channel][e.a] += 1
				check(open[e.channel][e.a] == 1, "score: two notes of key %d sound on channel %d at tick %d", e.a, e.channel, e.tick)
			case .Note_Off:
				open[e.channel][e.a] -= 1
			}
		}
		snd.song_destroy(&s)
	}

	// ---- tracks have no channel limit: 40 tracks, each its own channels ----
	{
		p := snd.score_new()
		defer snd.score_free(&p)
		for i in 1 ..< 40 {
			snd.score_add_track(&p, fmt.tprintf("t%d", i))
		}
		for i in 0 ..< 40 {
			append(&p.notes, snd.Score_Note{start = u32(i) * 10, len = 480, track = i, key = u8(40 + i), vel = 90})
		}
		s := snd.score_to_song(&p, .Play_Once)
		chans: [256]bool
		n := 0
		for &t in s.tracks {
			for e in t.events {
				if e.kind == .Note_On && !chans[e.channel] {
					chans[e.channel] = true
					n += 1
				}
			}
		}
		check(n == 40, "score: 40 tracks use 40 channels (%d)", n)
		snd.song_destroy(&s)
	}

	// ---- saving: empty tracks, names, instruments, mixer settings and the shared settings come back ----
	{
		p := snd.score_new()
		defer snd.score_free(&p)
		snd.score_add_track(&p, "bass")
		snd.score_add_track(&p, "nothing yet")
		p.tracks[0].name = snd.score_name_make("lead")
		harp, _ := snd.library_find("Harp")
		hi := append_instrument(&p, snd.library_instrument(harp))
		p.tracks[0].inst = hi
		snd.score_track_set_mix(&p.tracks[1], .Volume, 0.5)
		snd.score_track_set_mix(&p.tracks[1], .Pan, -0.5)
		p.tracks[2].inst = hi
		snd.score_track_set_mix(&p.tracks[2], .Delay, 0.25)
		append(&p.notes, snd.Score_Note{start = 0, len = 480, track = 0, key = 60, vel = 100})
		append(&p.notes, snd.Score_Note{start = 0, len = 480, track = 0, key = 60, vel = 100}) // (same key: two lanes)
		append(&p.notes, snd.Score_Note{start = 480, len = 480, track = 1, key = 40, vel = 100})
		snd.score_master_set_step(&p.master, .Delay_Time, 55)
		snd.score_master_set_step(&p.master, .Room, 100)
		snd.score_set_tempo(&p, 0, 100)
		snd.score_set_tempo(&p, 960, 140)
		s := snd.score_to_song(&p, .Save)
		bytes := snd.song_encode(&s, context.temp_allocator)
		snd.song_destroy(&s)
		loaded, ok := snd.song_decode(bytes)
		check(ok, "score file: loads")
		q := snd.score_from_song(&loaded)
		snd.song_destroy(&loaded)
		check(len(q.tracks) == 3, "score file: the three tracks come back, the empty one too (%d)", len(q.tracks))
		if len(q.tracks) == 3 {
			check(snd.score_name_str(&q.tracks[0].name) == "lead" && snd.score_name_str(&q.tracks[1].name) == "bass" && snd.score_name_str(&q.tracks[2].name) == "nothing yet", "score file: track names")
			check(q.tracks[0].inst == 0 && q.tracks[1].inst == -1 && q.tracks[2].inst == 0, "score file: track instruments (%d %d %d)", q.tracks[0].inst, q.tracks[1].inst, q.tracks[2].inst)
			check(q.tracks[1].set == {.Volume, .Pan} && abs(q.tracks[1].volume - 0.5) < 0.01 && abs(q.tracks[1].pan + 0.5) < 0.02, "score file: mixer settings (%v %f %f)", q.tracks[1].set, q.tracks[1].volume, q.tracks[1].pan)
			check(q.tracks[0].set == {} && q.tracks[2].set == {.Delay}, "score file: settings that were never set stay unset")
			check(len(q.notes) == 3, "score file: notes (%d)", len(q.notes))
		}
		check(q.master.set == {.Delay_Time, .Room} && snd.score_master_step(&q.master, .Delay_Time) == 55 && snd.score_master_step(&q.master, .Room) == 100, "score file: the reverb and delay settings")
		check(len(q.tempo) == 2 && q.tempo[0].us == 600000 && q.tempo[1].tick == 960, "score file: tempo changes")
		snd.score_free(&q)
	}

	// ---- mixer settings that nobody set write nothing at all ----
	{
		p := snd.score_new()
		defer snd.score_free(&p)
		append(&p.notes, snd.Score_Note{start = 0, len = 480, track = 0, key = 60, vel = 100})
		s := snd.score_to_song(&p, .Play_Once)
		controls := 0
		for &t in s.tracks {
			for e in t.events {
				if e.kind == .Control || e.kind == .Set_Instrument {
					controls += 1
				}
			}
		}
		check(controls == 0, "score: an untouched track writes no setup events (%d)", controls)
		snd.song_destroy(&s)
	}

	// ---- graphs belong to the score's library; a track names the graph it plays through, and tracks can share one ----
	{
		p := snd.score_new()
		defer snd.score_free(&p)
		snd.score_add_track(&p, "second")
		snd.score_add_track(&p, "third")
		snd.score_add_track(&p, "dry")
		harp, _ := snd.library_find("Harp")
		hi := append_instrument(&p, snd.library_instrument(harp))
		p.tracks[2].inst = hi
		p.tracks[3].inst = hi
		g1 := snd.score_graph_add(&p, "echo")
		g2 := snd.score_graph_add(&p, "echo") // (a name that is taken: made unique)
		g3 := snd.score_graph_add(&p, "never used")
		check(g1 == 1 && g2 == 2 && g3 == 3 && snd.fx_graph_name(&p.graphs[1]) == "echo 2", "score graphs: numbers and unique names")
		gp := snd.fx_library_get(p.graphs[:], g1)
		snd.fx_disconnect(gp, 1, 2)
		delay, _ := snd.fx_add(gp, .Delay, 0, 0)
		snd.fx_connect(gp, 1, delay)
		snd.fx_connect(gp, delay, 2)
		p.tracks[0].graph = g1 // the first two tracks play through the same graph, on the default instrument
		p.tracks[1].graph = g1
		p.tracks[2].graph = g2 // the third on another graph, the fourth on none, both on the harp
		check(snd.score_graph_users(&p, g1) == 2 && snd.score_graph_users(&p, g2) == 1 && snd.score_graph_users(&p, g3) == 0, "score graphs: how many tracks use each")
		check(snd.score_track_graph(&p, 0) == snd.score_track_graph(&p, 1) && snd.score_track_graph(&p, 0) != nil && snd.score_track_graph(&p, 3) == nil, "score graphs: two tracks, one graph")
		for ti in 0 ..< 4 {
			append(&p.notes, snd.Score_Note{start = u32(ti) * 240, len = 240, track = ti, key = u8(60 + ti), vel = 80})
		}

		s := snd.score_to_song(&p, .Save)
		check(len(s.graphs) == 3, "score graphs: the song gets the whole library (%d)", len(s.graphs))
		named := 0
		for inst in s.instruments {
			if inst.graph != 0 {
				named += 1
			}
		}
		// Instruments of the song: the harp as it is (its track 4 plays dry), the default instrument with graph 1 (both tracks),
		// the harp with graph 2.
		check(len(s.instruments) == 3 && named == 2, "score graphs: the song's instruments that name a graph (%d of %d)", named, len(s.instruments))
		bytes := snd.song_encode(&s, context.temp_allocator)
		snd.song_destroy(&s)
		loaded, ok := snd.song_decode(bytes)
		check(ok && len(loaded.graphs) == 3, "score graphs: the file keeps the library, the unused graph too")
		q := snd.score_from_song(&loaded)
		check(len(q.tracks) == 4 && len(q.graphs) == 3, "score graphs: tracks and graphs come back (%d, %d)", len(q.tracks), len(q.graphs))
		if len(q.tracks) == 4 {
			check(q.tracks[0].graph == 1 && q.tracks[1].graph == 1 && q.tracks[2].graph == 2 && q.tracks[3].graph == 0, "score graphs: who plays through what (%d %d %d %d)", q.tracks[0].graph, q.tracks[1].graph, q.tracks[2].graph, q.tracks[3].graph)
			check(q.tracks[2].inst == q.tracks[3].inst && q.tracks[2].inst >= 0, "score graphs: the instruments are only sounds again: the harp is one instrument (%d %d)", q.tracks[2].inst, q.tracks[3].inst)
			check(len(q.instruments) == 1 && q.tracks[0].inst == -1 && q.tracks[1].inst == -1, "score graphs: and no copies of it are left; the default instrument is the default again (%d instruments)", len(q.instruments))
		}
		for i in q.instruments {
			check(i.graph == 0, "score graphs: instruments of a score name no graph")
		}
		// The graph is heard: the track with the echo has a tail the dry one has not.
		qs := snd.score_to_song(&q, .Play_Once)
		with := snd.render_song(&qs, 4)
		snd.score_graph_remove(&q, 1)
		check(q.tracks[0].graph == 0 && q.tracks[1].graph == 0 && q.tracks[2].graph == 1 && len(q.graphs) == 2, "score graphs: removing a graph: its tracks play dry, the numbers after it go down")
		qd := snd.score_to_song(&q, .Play_Once)
		without := snd.render_song(&qd, 4)
		diff: f64 = 0
		for i in 0 ..< min(len(with), len(without)) {
			d := f64(with[i] - without[i])
			diff += d * d
		}
		check(diff > 1e-3 * energy_of(with, 0, 4 * 44100), "score graphs: the graph is heard: the song differs from the dry one (%e of %e)", diff, energy_of(with, 0, 4 * 44100))
		delete(with)
		delete(without)
		snd.song_destroy(&qs)
		snd.song_destroy(&qd)
		snd.song_destroy(&loaded)
		snd.score_free(&q)
		// Copies (undo) keep the library.
		c := snd.score_clone(&p)
		check(len(c.graphs) == 3 && snd.fx_equal(&c.graphs[0], &p.graphs[0]) && c.tracks[1].graph == 1, "score graphs: score_clone copies the library and the tracks' graphs")
		snd.score_free(&c)
	}
	fmt.println("tracks: lanes, channels, saving (empty tracks, names, mixer, shared settings), graph library checked")
}

// Adds an instrument to a score (the score owns it) and returns its index.
append_instrument :: proc(p: ^snd.Score, inst: ^snd.Instrument) -> int {
	append(&p.instruments, inst)
	snd.instruments_resolve(p.instruments[len(p.instruments) - 1:], p.samples[:])
	return len(p.instruments) - 1
}

_ :: math

// ---- the graph editor's mouse logic, driven with synthetic input (no window) -----------------------

ui_press :: proc(x, y: int) {
	shot_mouse(x, y, true, true, false)
	graph_mouse()
}

ui_move :: proc(x, y: int) {
	shot_mouse(x, y, false, true, false)
	graph_mouse()
}

ui_release :: proc(x, y: int) {
	shot_mouse(x, y, false, false, true)
	graph_mouse()
	shot_mouse(x, y, false, false, false)
}

ui_click :: proc(x, y: int) {
	ui_press(x, y)
	ui_release(x, y)
}

ui_drag :: proc(x0, y0, x1, y1: int) {
	ui_press(x0, y0)
	ui_move((x0 + x1) / 2, (y0 + y1) / 2)
	ui_move(x1, y1)
	ui_release(x1, y1)
}

center :: proc(r: Rect) -> (int, int) {
	return r.x + r.w / 2, r.y + r.h / 2
}

run_graph_ui_tests :: proc() {
	win_w, win_h = 1280, 760
	ed_init()
	layout_update()
	graph_ed_open()
	check(ed.view == .Graph, "graph ui: the view is open")
	g := graph_shown()
	check(len(g.nodes) == 2 && len(g.edges) == 1, "graph ui: an instrument without effects shows Input -> Output")
	check(len(ed.p.instruments) == 0 && len(ed.p.graphs) == 0 && len(ed.undo) == 0, "graph ui: looking at it changes nothing")

	_, pal, _ := graph_areas()
	// Add a Delay and then a Reverb from the list: each goes into the chain.
	delay_i := 0
	reverb_i := 0
	for k, i in GRAPH_PALETTE {
		if k == .Delay {
			delay_i = i
		}
		if k == .Reverb {
			reverb_i = i
		}
	}
	x, y := center(palette_row_rect(pal, delay_i))
	ui_click(x, y)
	g = graph_shown()
	check(len(g.nodes) == 3 && len(g.edges) == 2, "graph ui: Delay added into the chain (%d nodes, %d wires)", len(g.nodes), len(g.edges))
	check(len(ed.p.graphs) == 1 && ed.p.tracks[0].graph == 1 && len(ed.p.instruments) == 0 && len(ed.undo) == 1, "graph ui: the first edit made a graph in the library and the track plays through it; the instrument is not touched; one undo step")
	delay_id := graph_ed.sel_node
	x, y = center(palette_row_rect(pal, reverb_i))
	ui_click(x, y)
	g = graph_shown()
	check(len(g.nodes) == 4 && len(g.edges) == 3, "graph ui: Reverb added after the Delay (%d nodes, %d wires)", len(g.nodes), len(g.edges))
	reverb_id := graph_ed.sel_node
	check(snd.fx_has_edge(g, delay_id, reverb_id) && snd.fx_has_edge(g, reverb_id, 2) && !snd.fx_has_edge(g, delay_id, 2), "graph ui: Input -> Delay -> Reverb -> Output")

	// Drag the Delay's time slider to the right: one undo step for the whole drag.
	steps := len(ed.undo)
	di := snd.fx_find(g, delay_id)
	before := g.nodes[di].p[0]
	sl := graph_slider_rect(graph_row_rect(&g.nodes[di], 0))
	ui_drag(sl.x + sl.w / 3, sl.y + sl.h / 2, sl.x + sl.w - 8, sl.y + sl.h / 2)
	g = graph_shown()
	check(g.nodes[snd.fx_find(g, delay_id)].p[0] > before * 2, "graph ui: dragging the slider changes the value (%f -> %f)", before, g.nodes[snd.fx_find(g, delay_id)].p[0])
	check(len(ed.undo) == steps + 1, "graph ui: a drag of a slider is one step of undo (%d)", len(ed.undo) - steps)
	// A double click resets it.
	di = snd.fx_find(g, delay_id)
	sl = graph_slider_rect(graph_row_rect(&g.nodes[di], 0))
	in_.dbl = true
	ui_press(sl.x + sl.w / 2, sl.y + sl.h / 2)
	in_.dbl = false
	ui_release(sl.x + sl.w / 2, sl.y + sl.h / 2)
	g = graph_shown()
	check(g.nodes[snd.fx_find(g, delay_id)].p[0] == snd.FX_INFO[.Delay].params[0].def, "graph ui: a double click resets the value")
	// The choice (Sync): a click steps to the next.
	di = snd.fx_find(g, delay_id)
	row := graph_row_rect(&g.nodes[di], 1)
	cx, cy := center(row)
	ui_click(cx, cy)
	g = graph_shown()
	check(g.nodes[snd.fx_find(g, delay_id)].p[1] == 1, "graph ui: a click on a choice steps it")

	// Wire the Input straight to the Reverb as well (a parallel branch), by dragging from a dot to a dot.
	g = graph_shown()
	in_node := &g.nodes[snd.fx_find(g, 1)]
	rv_node := &g.nodes[snd.fx_find(g, reverb_id)]
	op := graph_out_port(in_node)
	ip := graph_in_port(rv_node)
	ui_drag(op[0], op[1], ip[0], ip[1])
	g = graph_shown()
	check(snd.fx_has_edge(g, 1, reverb_id) && len(g.edges) == 4, "graph ui: a wire dragged from the Input's dot to the Reverb's dot (%d wires)", len(g.edges))
	// A wire that would make a loop is refused.
	rv_node = &g.nodes[snd.fx_find(g, reverb_id)]
	dl_node := &g.nodes[snd.fx_find(g, delay_id)]
	op = graph_out_port(rv_node)
	ip = graph_in_port(dl_node)
	ui_drag(op[0], op[1], ip[0], ip[1])
	g = graph_shown()
	check(!snd.fx_has_edge(g, reverb_id, delay_id) && len(g.edges) == 4, "graph ui: a loop is refused")
	// Pull a wire off an input and drop it on nothing: it is gone.
	rv_node = &g.nodes[snd.fx_find(g, reverb_id)]
	ip = graph_in_port(rv_node)
	_, _, cv := graph_areas()
	ui_drag(ip[0], ip[1], cv.x + 30, cv.y + cv.h - 30)
	g = graph_shown()
	check(len(g.edges) == 3, "graph ui: a wire pulled off an input and dropped on nothing is removed (%d wires)", len(g.edges))
	ed_undo()
	g = graph_shown()
	check(len(g.edges) == 4, "graph ui: undo puts the wire back (%d)", len(g.edges))

	// Move a node by its title: one undo step; the others stay.
	steps = len(ed.undo)
	rv_node = &g.nodes[snd.fx_find(g, reverb_id)]
	r := graph_node_rect(rv_node)
	x0 := rv_node.x
	ui_drag(r.x + 60, r.y + 8, r.x + 60 - 40, r.y + 8 + 30)
	g = graph_shown()
	rv_node = &g.nodes[snd.fx_find(g, reverb_id)]
	check(rv_node.x == x0 - 40 && len(ed.undo) == steps + 1, "graph ui: a node moves with its title (%f -> %f), one undo step", x0, rv_node.x)

	// Delete the selected node: the chain closes up. Bypass.
	ui_click(graph_node_center(g, delay_id))
	check(graph_ed.sel_node == delay_id, "graph ui: a click selects a node")
	graph_remove_selected()
	g = graph_shown()
	check(snd.fx_find(g, delay_id) < 0 && snd.fx_has_edge(g, 1, reverb_id) && snd.fx_has_edge(g, reverb_id, 2), "graph ui: deleting a node keeps the chain")
	graph_toggle_bypass(reverb_id)
	g = graph_shown()
	check(g.nodes[snd.fx_find(g, reverb_id)].bypass, "graph ui: bypass")

	// ---- the library: several graphs, tracks that share one ----
	gp := graph_panel(pal)
	check(len(ed.p.graphs) == 1 && graph_ed.sel_graph == 1 && ed.p.tracks[0].graph == 1, "library ui: one graph, shown, used by track 1")
	// New: a second graph. Track 1 keeps its own.
	ui_click(center(gp.b_new))
	check(len(ed.p.graphs) == 2 && graph_ed.sel_graph == 2 && ed.p.tracks[0].graph == 1, "library ui: New makes a graph and shows it; track 1 keeps its graph (%d graphs)", len(ed.p.graphs))
	g = graph_shown()
	check(len(g.nodes) == 2 && snd.fx_graph_name(g) != snd.fx_graph_name(&ed.p.graphs[0]), "library ui: the new graph is empty and has a name of its own")
	// The circle of a row: the current track plays through that graph; again: it stops.
	cx, cy = center(graph_use_rect(graph_row_at(gp, 1)))
	ui_click(cx, cy)
	check(ed.p.tracks[0].graph == 2, "library ui: the circle of graph 2 makes track 1 play through it")
	ui_click(cx, cy)
	check(ed.p.tracks[0].graph == 0, "library ui: the circle again: no effects")
	// Two tracks on one graph.
	snd.score_add_track(&ed.p, "second")
	ed.cur_track = 0
	cx, cy = center(graph_use_rect(graph_row_at(gp, 0)))
	ui_click(cx, cy)
	ed.cur_track = 1
	ui_click(cx, cy)
	check(ed.p.tracks[0].graph == 1 && ed.p.tracks[1].graph == 1 && snd.score_graph_users(&ed.p, 1) == 2, "library ui: two tracks play through graph 1 (%d %d)", ed.p.tracks[0].graph, ed.p.tracks[1].graph)
	check(graph_ed.sel_graph == 1, "library ui: the list follows the click")
	// Editing it from track 2 changes what track 1 plays through too: it is one graph.
	gain_i := 0
	for k, i in GRAPH_PALETTE {
		if k == .Gain {
			gain_i = i
		}
	}
	nodes_before := len(ed.p.graphs[0].nodes)
	ui_click(center(palette_row_rect(pal, gain_i)))
	check(len(ed.p.graphs) == 2 && len(ed.p.graphs[0].nodes) == nodes_before + 1, "library ui: an effect added from track 2 is in the graph (%d nodes)", len(ed.p.graphs[0].nodes))
	check(snd.score_track_graph(&ed.p, 0) == snd.score_track_graph(&ed.p, 1), "library ui: both tracks see the same graph")
	// The song has a graph library and the tracks' graphs are on instruments of the song.
	song := project_to_song(&ed.p, .Play_Once)
	check(len(song.graphs) == 2 && len(song.instruments) == 1 && song.instruments[0].graph == 1, "library ui: the played song has the library; one instrument names graph 1 for both tracks (%d instruments)", len(song.instruments))
	snd.song_destroy(&song)
	// Another track's graph is looked at when the track changes; a track with none keeps the shown one.
	ed.cur_track = 0
	graph_ed.sel_graph = 2
	graph_ed.shown_trk = -1
	graph_shown()
	check(graph_ed.sel_graph == 1, "library ui: the view follows the track to its graph")
	// Copy: a graph of its own that nobody uses.
	ui_click(center(gp.b_copy))
	check(len(ed.p.graphs) == 3 && graph_ed.sel_graph == 3 && snd.score_graph_users(&ed.p, 3) == 0 && snd.fx_equal(&ed.p.graphs[2], &ed.p.graphs[0]) && snd.fx_graph_name(&ed.p.graphs[2]) != snd.fx_graph_name(&ed.p.graphs[0]), "library ui: Copy makes an equal graph under another name that no track uses")
	// Delete an unused graph: at once, and nothing else changes.
	steps = len(ed.undo)
	ui_click(center(gp.b_del))
	check(len(ed.p.graphs) == 2 && ed.p.tracks[0].graph == 1 && ed.p.tracks[1].graph == 1 && len(ed.undo) == steps + 1, "library ui: Delete takes an unused graph away, one undo step (%d graphs)", len(ed.p.graphs))
	ed_undo()
	check(len(ed.p.graphs) == 3, "library ui: undo brings it back")
	graph_do_delete(3)
	// Deleting a graph that tracks use: they play dry, the numbers after it go down.
	graph_do_delete(1)
	check(len(ed.p.graphs) == 1 && ed.p.tracks[0].graph == 0 && ed.p.tracks[1].graph == 0, "library ui: deleting graph 1: its tracks play dry (%d graphs)", len(ed.p.graphs))
	ed_undo()
	check(len(ed.p.graphs) == 2 && ed.p.tracks[0].graph == 1 && ed.p.tracks[1].graph == 1, "library ui: undo puts the graph and its users back")
	// The picker in the track panel: its choice is the same operation.
	track_set_graph(1, 2)
	check(ed.p.tracks[1].graph == 2 && ed.p.tracks[0].graph == 1, "library ui: track 2 on the other graph")

	// The library is a part of the project: saved and loaded with it.
	check(file_save("selftest_graph_ui.psng"), "graph ui: save")
	ed_set_project(project_new(), "")
	check(file_load("selftest_graph_ui.psng"), "graph ui: load")
	check(len(ed.p.instruments) == 0 && len(ed.p.graphs) == 2 && len(ed.p.tracks) == 2 && ed.p.tracks[0].graph == 1 && ed.p.tracks[1].graph == 2, "graph ui: the library and who plays through what come back with the project (%d graphs)", len(ed.p.graphs))
	check(snd.fx_find(&ed.p.graphs[0], reverb_id) >= 0 && len(ed.p.graphs[0].nodes) == 4 && snd.fx_graph_name(&ed.p.graphs[0]) != "", "graph ui: the graph comes back with the project")
	_ = os.remove("selftest_graph_ui.psng")
	shot_mouse(0, 0, false, false, false)
	ed_init()
	fmt.println("graph editor: adding, sliders, wiring, loops refused, pulling wires off, moving, deleting, undo, the shared library, saving checked")
}

graph_node_center :: proc(g: ^snd.Fx_Graph, id: u16) -> (int, int) {
	r := graph_node_rect(&g.nodes[snd.fx_find(g, id)])
	return r.x + r.w / 2, r.y + 8
}
