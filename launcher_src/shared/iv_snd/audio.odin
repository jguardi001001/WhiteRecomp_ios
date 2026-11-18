package iv_snd

import "core:math"
import "core:slice"
import "core:sync"

// ---------------------------------------------------------------------------
// The audio manager: owns the music synthesizer + sequencer, the sound effect
// voices and the master mix.
//
// The program calls audio_render() from the operating system's audio callback; that
// fills the output buffer with the mixed music and sound effects. All other
// procedures may be called from the main thread at any time: they take the same
// lock for a very short moment. Nothing allocates while rendering.
// ---------------------------------------------------------------------------

BLOCK :: 256 // largest piece rendered at once (the callback may ask for more; it is split)

// How the gain follows the progress f (0..1) of a music fade.
Fade_Curve :: enum u8 {
	Linear, // gain = f
	Eased, // gain = 1 - (1 - f)^2: leaves quickly, lands softly. Faded out and then in,
	//        it traces the same curve as a picture dissolving and re-forming (p^2 out, 1 - (1 - q)^2 in).
}

// A change of music that is waiting for the current music to finish fading out.
Pending_Music :: struct {
	active:  bool,
	song:    ^Song, // nil = just stop
	loop:    bool,
	wait:    int, // samples until the switch
	fade_in: f32, // seconds
}

Audio :: struct {
	mutex:         sync.Mutex,
	ready:         bool,
	sample_rate:   int,

	// Volumes (linear, 1 = full).
	master:        f32,
	music_volume:  f32,
	sfx_volume:    f32,

	// Music.
	music:         Synth,
	seq:           Sequencer,
	reverb:        Reverb,
	delay:         Delay,
	fade:          f32, // progress of the music fade, 0 (silent) .. 1 (full)
	fade_target:   f32,
	fade_step:     f32, // per sample
	fade_curve:    Fade_Curve,
	pending:       Pending_Music, // a change of music waiting for its fade-out to end

	// Sound effects.
	sfx_synth:     Synth,
	sfx_voices:    [MAX_SFX_VOICES]Sfx_Voice,
	sfx_serial:    u32,
	preview_owner: rawptr, // the effect graph (of an instrument being previewed) that plays on the sfx synthesizer's preview bus

	// Scratch buffers.
	ml, mr, ms, md: [BLOCK]f32, // music left / right / reverb send / delay send
	xl, xr, xs, xd: [BLOCK]f32, // sound effects left / right / (unused sends)
}

audio_init :: proc(a: ^Audio, sample_rate: int = 44100) {
	a^ = {}
	a.sample_rate = sample_rate
	a.master = 0.8
	a.music_volume = 1
	a.sfx_volume = 1
	a.fade = 1
	a.fade_target = 1
	synth_init(&a.music, f32(sample_rate))
	synth_init(&a.sfx_synth, f32(sample_rate))
	reverb_init(&a.reverb, f32(sample_rate))
	delay_init(&a.delay, f32(sample_rate))
	a.ready = true
}

audio_shutdown :: proc(a: ^Audio) {
	sync.mutex_lock(&a.mutex)
	defer sync.mutex_unlock(&a.mutex)
	if a.ready {
		a.ready = false
		synth_reset(&a.music) // lets go of the samples that sounding notes hold
		synth_reset(&a.sfx_synth)
		reverb_destroy(&a.reverb)
		delay_destroy(&a.delay)
	}
}

// ---- volumes ---------------------------------------------------------------------

audio_set_master_volume :: proc(a: ^Audio, v: f32) {
	sync.mutex_lock(&a.mutex)
	a.master = clamp(v, 0, 2)
	sync.mutex_unlock(&a.mutex)
}

audio_set_music_volume :: proc(a: ^Audio, v: f32) {
	sync.mutex_lock(&a.mutex)
	a.music_volume = clamp(v, 0, 2)
	sync.mutex_unlock(&a.mutex)
}

audio_set_sfx_volume :: proc(a: ^Audio, v: f32) {
	sync.mutex_lock(&a.mutex)
	a.sfx_volume = clamp(v, 0, 2)
	sync.mutex_unlock(&a.mutex)
}

// ---- music -------------------------------------------------------------------------

// Starts `song` (which must stay alive and unchanged while it plays), replacing
// whatever music was playing. `fade_in` is in seconds.
music_play :: proc(a: ^Audio, song: ^Song, loop := true, fade_in: f32 = 0, start_tick: u32 = 0) {
	sync.mutex_lock(&a.mutex)
	defer sync.mutex_unlock(&a.mutex)
	if !a.ready || song == nil {
		return
	}
	a.pending = {}
	music_begin(a, song, loop, fade_in, start_tick)
	a.fade_curve = .Linear
}

// Starts `song` now (the lock is held by the caller).
music_begin :: proc(a: ^Audio, song: ^Song, loop: bool, fade_in: f32, start_tick: u32 = 0) {
	synth_reset(&a.music) // also puts the channels on the default instrument and the reverb and delay settings back to the defaults
	synth_graphs_sync(&a.music, song) // the effect graphs of the song's instruments
	seq_start(&a.seq, song, f64(a.sample_rate), loop)
	if start_tick > 0 {
		seq_seek(&a.seq, &a.music, f64(start_tick))
	}
	if fade_in > 0 {
		a.fade = 0
		a.fade_target = 1
		a.fade_step = 1 / (fade_in * f32(a.sample_rate))
	} else {
		a.fade = 1
		a.fade_target = 1
	}
}

// Stops the music, optionally fading out over `fade_out` seconds first.
music_stop :: proc(a: ^Audio, fade_out: f32 = 0) {
	if fade_out > 0 {
		music_change(a, nil, false, fade_out, 0, .Linear)
		return
	}
	sync.mutex_lock(&a.mutex)
	defer sync.mutex_unlock(&a.mutex)
	if !a.ready {
		return
	}
	a.pending = {}
	seq_stop(&a.seq)
	synth_all_off(&a.music, false)
}

// Changes the music in two steps: the music playing now fades out over `fade_out`
// seconds, then `song` starts from its beginning and fades in over `fade_in`
// seconds (`song` nil = silence). The switch happens on the exact sample where the
// fade-out ends, so a program can match the fades to an animation: call this when the
// animation starts, with the two halves of its duration (the screen is hidden at
// the half-way point).
//
// If no music is playing the call still waits `fade_out` seconds before starting
// `song`, so the timing is the same. `song` must stay alive while it plays.
music_change :: proc(
	a: ^Audio,
	song: ^Song,
	loop := true,
	fade_out: f32 = 0.5,
	fade_in: f32 = 0.5,
	curve := Fade_Curve.Eased,
) {
	sync.mutex_lock(&a.mutex)
	defer sync.mutex_unlock(&a.mutex)
	if !a.ready {
		return
	}
	wait := max(int(fade_out * f32(a.sample_rate)), 0)
	a.fade_curve = curve
	a.pending = Pending_Music {
		active  = true,
		song    = song,
		loop    = loop,
		wait    = wait,
		fade_in = fade_in,
	}
	if wait > 0 && a.fade > 0 {
		a.fade_target = 0
		a.fade_step = a.fade / f32(wait)
	} else {
		a.fade_target = a.fade // nothing audible to fade
	}
}

// The moment a pending change happens (the lock is held by the caller).
music_switch :: proc(a: ^Audio) {
	p := a.pending
	a.pending = {}
	seq_stop(&a.seq)
	synth_all_off(&a.music, true)
	reverb_clear(&a.reverb) // the old room must not ring into the new music
	delay_clear(&a.delay) // and the old echoes must not repeat into it
	if p.song == nil {
		a.fade = 1
		a.fade_target = 1
		return
	}
	music_begin(a, p.song, p.loop, p.fade_in)
}

// Swaps the song that is playing for an edited version of it (a song editor calls this
// after every change) without a break: playback goes on from where it is. The old song
// may be freed once this returns. Does nothing if no music is playing.
music_replace_song :: proc(a: ^Audio, song: ^Song, loop := true) {
	sync.mutex_lock(&a.mutex)
	defer sync.mutex_unlock(&a.mutex)
	if !a.ready || song == nil || !a.seq.playing {
		return
	}
	synth_graphs_sync(&a.music, song) // (a graph that was only edited keeps its echoes and tails)
	seq_replace_song(&a.seq, &a.music, song, loop)
}

// Lets every sounding music note ring out (release phase) now: for a song editor that
// has just removed or muted notes whose note-offs will never come.
music_release_all :: proc(a: ^Audio) {
	sync.mutex_lock(&a.mutex)
	defer sync.mutex_unlock(&a.mutex)
	synth_all_off(&a.music, false)
}

// Where the music is, in ticks of the song that is playing (0 if nothing is).
music_position_ticks :: proc(a: ^Audio) -> f64 {
	sync.mutex_lock(&a.mutex)
	defer sync.mutex_unlock(&a.mutex)
	if !a.seq.playing || a.seq.song == nil {
		return 0
	}
	return a.seq.pos_ticks
}

// Pauses the notes that sound, keeps the position (for a "stop" button that remembers where it was).
music_pause :: proc(a: ^Audio) {
	sync.mutex_lock(&a.mutex)
	defer sync.mutex_unlock(&a.mutex)
	if a.seq.playing && !a.seq.paused {
		a.seq.paused = true
		synth_all_off(&a.music, false)
	}
}

music_resume :: proc(a: ^Audio) {
	sync.mutex_lock(&a.mutex)
	a.seq.paused = false
	sync.mutex_unlock(&a.mutex)
}

music_is_playing :: proc(a: ^Audio) -> bool {
	sync.mutex_lock(&a.mutex)
	defer sync.mutex_unlock(&a.mutex)
	return a.seq.playing
}

// True once a song that does not loop has played to its end.
music_has_finished :: proc(a: ^Audio) -> bool {
	sync.mutex_lock(&a.mutex)
	defer sync.mutex_unlock(&a.mutex)
	return a.seq.finished
}

// Playback speed multiplier (1 = normal).
music_set_speed :: proc(a: ^Audio, speed: f64) {
	sync.mutex_lock(&a.mutex)
	defer sync.mutex_unlock(&a.mutex)
	if a.seq.song != nil {
		a.seq.speed = clamp(speed, 0.25, 4)
		seq_update_tempo(&a.seq)
	}
}

// ---- sound effects ----------------------------------------------------------------

// Plays a loaded sound (it must stay alive while it plays). `pitch` 1 = original.
sfx_play :: proc(a: ^Audio, sfx: ^Sfx, volume: f32 = 1, pan: f32 = 0, pitch: f32 = 1, loop := false) -> Sfx_Handle {
	sync.mutex_lock(&a.mutex)
	defer sync.mutex_unlock(&a.mutex)
	if !a.ready || sfx == nil || sfx_frames(sfx) < 2 {
		return {index = -1}
	}
	idx := -1
	for i in 0 ..< MAX_SFX_VOICES {
		if !a.sfx_voices[i].active {
			idx = i
			break
		}
	}
	if idx < 0 { // all busy: take the one that has played the longest
		best: f64 = -1
		for i in 0 ..< MAX_SFX_VOICES {
			if a.sfx_voices[i].pos > best && !a.sfx_voices[i].loop {
				best = a.sfx_voices[i].pos
				idx = i
			}
		}
		if idx < 0 {
			idx = 0
		}
	}
	gl, gr := pan_gains(pan)
	a.sfx_serial += 1
	a.sfx_voices[idx] = Sfx_Voice {
		active = true,
		serial = a.sfx_serial,
		sfx    = sfx,
		pos    = 0,
		step   = f64(sfx.rate) / f64(a.sample_rate) * f64(max(pitch, 0.05)),
		gl     = gl * volume,
		gr     = gr * volume,
		loop   = loop,
	}
	return {index = idx, serial = a.sfx_serial}
}

sfx_stop :: proc(a: ^Audio, h: Sfx_Handle) {
	sync.mutex_lock(&a.mutex)
	defer sync.mutex_unlock(&a.mutex)
	if h.index >= 0 && h.index < MAX_SFX_VOICES && a.sfx_voices[h.index].serial == h.serial {
		a.sfx_voices[h.index].active = false
	}
}

sfx_stop_all :: proc(a: ^Audio) {
	sync.mutex_lock(&a.mutex)
	defer sync.mutex_unlock(&a.mutex)
	for &v in a.sfx_voices {
		v.active = false
	}
	synth_all_off(&a.sfx_synth, true)
}

// Plays a synthesized note as a sound effect: `patch` at MIDI `key` for
// `duration` seconds (then its release tail).
sfx_play_patch :: proc(a: ^Audio, patch: Patch, key: int, duration: f32 = 0.2, velocity: f32 = 0.8, pan: f32 = 0) {
	sfx_play_note(a, patch, nil, key, duration, velocity, pan)
}

// Plays an instrument as a sound effect: key `key` for `duration` seconds (then its release tail). The zone
// that holds the key plays (a recording or a synthesizer sound); a key without a zone stays silent.
// The recordings of the instrument must be resolved (song_add_instrument and instruments_resolve do it).
// `graph` (may be nil) is the effect graph the note is played through (a graph of the song's library: an
// instrument only names its graph by number, so the caller looks it up).
sfx_play_instrument :: proc(a: ^Audio, inst: ^Instrument, key: int, duration: f32 = 0.2, velocity: f32 = 0.8, pan: f32 = 0, graph: ^Fx_Graph = nil) {
	if inst == nil {
		return
	}
	p, z, ok := instrument_note(inst, key)
	if !ok {
		return
	}
	sfx_play_note(a, p, z, key, duration, velocity, pan, graph)
}

// Plays one zone of an instrument as a sound effect, at key `key` (the zone is played whatever its key
// range; for the editor's test notes).
sfx_play_zone :: proc(a: ^Audio, z: ^Zone, key: int, duration: f32 = 0.2, velocity: f32 = 0.8, pan: f32 = 0) {
	if z == nil || (z.source == .Sample && z.sample == nil) {
		return
	}
	sfx_play_note(a, zone_patch(z), z, key, duration, velocity, pan)
}

// One note on the sound effect synthesizer: `patch` (with `zone`, if it comes from one) at `key`.
// `graph` (may be nil) is an effect graph the note goes through (the same one for later notes: its echoes and
// tails go on between them; a different graph replaces it).
sfx_play_note :: proc(a: ^Audio, patch: Patch, zone: ^Zone, key: int, duration, velocity, pan: f32, graph: ^Fx_Graph = nil) {
	sync.mutex_lock(&a.mutex)
	defer sync.mutex_unlock(&a.mutex)
	if !a.ready {
		return
	}
	c := &a.sfx_synth.channels[0]
	c.pan = clamp(pan, -1, 1)
	c.reverb = 0
	c.delay = 0
	c.volume = 1
	c.inst_index = -1
	if graph != nil && !fx_is_trivial(graph) {
		syn := &a.sfx_synth
		if syn.buses[PREVIEW_BUS] != nil && a.preview_owner != rawptr(graph) { // another instrument: its tails do not carry over
			fx_runtime_destroy(syn.buses[PREVIEW_BUS])
			syn.buses[PREVIEW_BUS] = nil
		}
		if syn.buses[PREVIEW_BUS] == nil {
			syn.buses[PREVIEW_BUS] = fx_runtime_new(graph, syn.sample_rate)
		} else {
			fx_runtime_set(syn.buses[PREVIEW_BUS], graph)
		}
		a.preview_owner = rawptr(graph)
		c.inst_index = PREVIEW_BUS
	}
	synth_voice_start(&a.sfx_synth, 0, clamp(key, 0, 127), velocity, patch, zone, max(duration, 0.01))
}

// Plays one recording once as a sound effect. key < 0: as recorded; otherwise it is played as a
// sampled instrument would play that key (relative to the root key of the recording, which is
// worked out here). duration 0: the whole recording.
sample_play :: proc(a: ^Audio, s: ^Sample, key: int = -1, volume: f32 = 0.8, pan: f32 = 0, duration: f32 = 0) {
	if s == nil || len(s.data) < 2 {
		return
	}
	z := zone_sample(0, 127, s, pitched = key >= 0, one_shot = false)
	z.patch.amp_env = {0.002, 0.1, 1, 0.12}
	zone_resolve(&z, s)
	k := key if key >= 0 else 60
	dur := duration
	if dur <= 0 {
		dur = sample_seconds(s)
		if key >= 0 && z.has_root {
			dur /= max(math.pow_f32(f32(2), (f32(k) - z.root_key) / 12), 0.01)
		}
	}
	sfx_play_zone(a, &z, k, dur, volume, pan)
}

// ---- rendering ---------------------------------------------------------------------

// Fills `out` (interleaved stereo float samples) with the next frames of audio.
// Call this from the audio callback; it may be asked for any number of frames.
audio_render :: proc(a: ^Audio, out: []f32) {
	frames := len(out) / 2
	sync.mutex_lock(&a.mutex)
	defer sync.mutex_unlock(&a.mutex)
	if !a.ready {
		slice.zero(out)
		return
	}

	done := 0
	for done < frames {
		n := min(frames - done, BLOCK)

		// A change of music happens exactly where its fade-out ends.
		if a.pending.active {
			if a.pending.wait <= 0 {
				music_switch(a)
			} else {
				n = min(n, a.pending.wait)
			}
		}

		// Reverb settings that the music may have changed.
		a.reverb.feedback = clamp(a.music.reverb_feedback, 0.3, 0.97)
		a.reverb.damp = clamp(a.music.reverb_damp, 0, 0.9)

		for buf in ([8]^[BLOCK]f32{&a.ml, &a.mr, &a.ms, &a.md, &a.xl, &a.xr, &a.xs, &a.xd}) {
			slice.zero(buf[:n])
		}

		// Music: sequencer -> synth -> reverb and delay.
		seq_render(&a.seq, &a.music, a.ml[:], a.mr[:], a.ms[:], a.md[:], n)
		reverb_process(&a.reverb, a.ms[:], a.ml[:], a.mr[:], n)
		// (the delay takes its settings after the sequencer has run, so that controllers at the very
		// start of a song already count for the first echoes)
		delay_set(&a.delay, synth_delay_seconds(&a.music), a.music.delay_feedback, a.music.delay_tone, a.music.delay_ping_pong)
		delay_process(&a.delay, a.md[:], a.ml[:], a.mr[:], n)

		// Sound effects: synthesized notes and sample voices.
		synth_render(&a.sfx_synth, a.xl[:], a.xr[:], a.xs[:], a.xd[:], n)
		sfx_voices_render(a.sfx_voices[:], a.xl[:], a.xr[:], n)

		mv := a.music_volume
		sv := a.sfx_volume
		for i in 0 ..< n {
			// Music fade in / out.
			if a.fade != a.fade_target {
				if a.fade < a.fade_target {
					a.fade = min(a.fade + a.fade_step, a.fade_target)
				} else {
					a.fade = max(a.fade - a.fade_step, a.fade_target)
				}
			}
			f := a.fade
			if a.fade_curve == .Eased {
				f = f * (2 - f) // 1 - (1 - f)^2
			}
			g := f * mv
			l := (a.ml[i] * g + a.xl[i] * sv) * a.master
			r := (a.mr[i] * g + a.xr[i] * sv) * a.master
			out[(done + i) * 2] = soft_clip(l)
			out[(done + i) * 2 + 1] = soft_clip(r)
		}
		if a.pending.active {
			a.pending.wait -= n
		}
		done += n
	}
}

// Renders `seconds` of `song` offline (no sound device): interleaved stereo float
// samples. For tests and for dumping songs to a WAV file.
render_song :: proc(song: ^Song, seconds: f32, sample_rate: int = 44100, loop := false, allocator := context.allocator) -> []f32 {
	a := new(Audio, allocator)
	defer free(a, allocator)
	audio_init(a, sample_rate)
	defer audio_shutdown(a)
	music_play(a, song, loop)
	frames := int(seconds * f32(sample_rate))
	out := make([]f32, frames * 2, allocator)
	pos := 0
	for pos < frames {
		n := min(frames - pos, 1024)
		audio_render(a, out[pos * 2:(pos + n) * 2])
		pos += n
	}
	return out
}
