package main

import "core:math"
import snd "shared:iv_snd"

// The song carries its own instruments (a glass patch, and the drum kit, an instrument of sample zones from the library) and a Set_Patch_Param (a slow
// filter sweep on the pad).

Chord :: struct {
	root: int, // MIDI key of the lowest note
	third: int, // semitones above the root
	fifth: int,
}

demo_song :: proc() -> snd.Song {
	s: snd.Song
	snd.song_init(&s, "Demo: Earthrise", 84)
	BAR :: 1920 // ticks per bar (4/4 at 480 ticks per beat)

	chords := [8]Chord{{57, 3, 7}, {53, 4, 7}, {60, 4, 7}, {55, 4, 7}, {57, 3, 7}, {53, 4, 7}, {55, 4, 7}, {52, 3, 7}}

	// -- setup track: channel volumes, pans, reverb, instruments --
	setup := snd.song_add_track(&s, "setup")
	pad_inst := snd.song_add_synth(&s, snd.patch_pad(), "Warm Pad")
	bass_inst := snd.song_add_synth(&s, snd.patch_bass(), "Synth Bass")
	glass_inst := snd.song_add_synth(&s, glass_patch(), "Glass")
	lead_inst := snd.song_add_synth(&s, snd.patch_lead_square(), "Square Lead")
	snd.song_set_instrument(&s, setup, 0, 0, pad_inst)
	snd.song_set_instrument(&s, setup, 0, 1, bass_inst)
	snd.song_set_instrument(&s, setup, 0, 2, glass_inst)
	snd.song_set_instrument(&s, setup, 0, 3, lead_inst)
	if drums_lib, ok := snd.library_find("Standard Drums"); ok { // an instrument of sample zones: a drum kit
		snd.song_set_instrument(&s, setup, 0, 9, snd.song_add_instrument(&s, snd.library_instrument(drums_lib)))
	}
	snd.song_control(&s, setup, 0, 9, 91, 15)
	snd.song_control(&s, setup, 0, 0, 7, 100)
	snd.song_control(&s, setup, 0, 0, 91, 105)
	snd.song_control(&s, setup, 0, 1, 7, 105)
	snd.song_control(&s, setup, 0, 1, 91, 20)
	snd.song_control(&s, setup, 0, 2, 7, 95)
	snd.song_control(&s, setup, 0, 2, 10, 88) // a little to the right
	snd.song_control(&s, setup, 0, 2, 91, 110)
	snd.song_control(&s, setup, 0, 3, 7, 100)
	snd.song_control(&s, setup, 0, 3, 10, 40)
	snd.song_control(&s, setup, 0, 3, 91, 80)
	snd.song_control(&s, setup, 0, 9, 7, 105)

	// -- pad: one chord per bar, with the filter opening and closing over the song --
	pad := snd.song_add_track(&s, "pad")
	for bar in 0 ..< 16 {
		c := chords[bar % 8]
		t := u32(bar * BAR)
		snd.song_note(&s, pad, t, BAR - 60, 0, c.root, 72)
		snd.song_note(&s, pad, t, BAR - 60, 0, c.root + c.third, 66)
		snd.song_note(&s, pad, t, BAR - 60, 0, c.root + c.fifth, 66)
		snd.song_note(&s, pad, t, BAR - 60, 0, c.root + 12, 52)
		for half in 0 ..< 2 {
			pos := f32(bar * 2 + half) / 32 // 0..1 over the song
			sweep := 0.5 - 0.5 * math.cos_f32(pos * f32(math.TAU)) // opens, then closes again
			snd.song_param(&s, pad, t + u32(half * BAR / 2), 0, .Cutoff, 700 + 2200 * sweep)
		}
	}

	// -- bass --
	bass := snd.song_add_track(&s, "bass")
	for bar in 0 ..< 16 {
		c := chords[bar % 8]
		t := u32(bar * BAR)
		r := c.root - 12
		snd.song_note(&s, bass, t, 720, 1, r, 100)
		snd.song_note(&s, bass, t + 960, 420, 1, r, 88)
		snd.song_note(&s, bass, t + 1440, 420, 1, r + 7, 84)
	}

	// -- arpeggio from bar 3 --
	arp := snd.song_add_track(&s, "arp")
	for bar in 2 ..< 16 {
		c := chords[bar % 8]
		t := u32(bar * BAR)
		notes := [6]int{c.root + 12, c.root + 12 + c.third, c.root + 12 + c.fifth, c.root + 24, c.root + 12 + c.fifth, c.root + 12 + c.third}
		for i in 0 ..< 8 {
			vel := 70 if i % 2 == 0 else 52
			snd.song_note(&s, arp, t + u32(i * 240), 220, 2, notes[i % 6], vel)
		}
	}

	// -- lead melody in the second half --
	Note :: struct {
		at, key, len: int,
	}
	lead := snd.song_add_track(&s, "lead")
	melody := [8][]Note {
		{{0, 76, 720}, {720, 74, 240}, {960, 72, 480}, {1440, 69, 480}},
		{{0, 69, 720}, {720, 72, 240}, {960, 76, 480}, {1440, 77, 480}},
		{{0, 79, 480}, {480, 76, 480}, {960, 72, 960}},
		{{0, 74, 720}, {720, 71, 240}, {960, 67, 480}, {1440, 71, 480}},
		{{0, 76, 480}, {480, 79, 480}, {960, 81, 960}},
		{{0, 77, 720}, {720, 76, 240}, {960, 72, 960}},
		{{0, 74, 480}, {480, 71, 480}, {960, 74, 480}, {1440, 79, 480}},
		{{0, 76, 1800}},
	}
	for bar in 8 ..< 16 {
		for n in melody[bar - 8] {
			snd.song_note(&s, lead, u32(bar * BAR + n.at), u32(n.len - 20), 3, n.key, 84)
		}
	}

	// -- drums from bar 5 (channel 10 plays the drum kit: the keys pick the drum) --
	drums := snd.song_add_track(&s, "drums")
	for bar in 4 ..< 16 {
		t := u32(bar * BAR)
		snd.song_note(&s, drums, t, 120, 9, 36, 110)
		snd.song_note(&s, drums, t + 960, 120, 9, 36, 100)
		snd.song_note(&s, drums, t + 480, 120, 9, 38, 78)
		snd.song_note(&s, drums, t + 1440, 120, 9, 38, 82)
		for i in 0 ..< 8 {
			snd.song_note(&s, drums, t + u32(i * 240), 100, 9, 42, 50 if i % 2 == 0 else 34)
		}
	}

	s.end_tick = 16 * BAR
	s.loop_start = 0
	s.loop_end = 16 * BAR
	snd.song_finish(&s)
	return s
}

// A bell-like FM instrument that lives inside the demo song.
glass_patch :: proc() -> snd.Patch {
	p := snd.patch_base()
	p.osc[0] = {.Sine, 1, 0, 0.5}
	p.osc[1] = {.Sine, 1, 12.03, 0.5}
	p.fm = 1.4
	p.amp_env = {0.002, 0.5, 0.0, 0.4}
	p.filter_env = {0.001, 0.25, 0.1, 0.2}
	p.volume = 0.3
	return p
}
