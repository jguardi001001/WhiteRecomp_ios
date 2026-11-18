package main

import "base:runtime"
import "core:c"
import "core:math"
import "core:time"
import rl "vendor:raylib"
import snd "shared:iv_snd"

// ---------------------------------------------------------------------------
// Audio output and playback.
//
// The editor plays a copy of the project made with project_to_song (mute and solo
// applied). While it plays, every change of the project makes a new copy that
// replaces the old one in the running sequencer (snd.music_replace_song), so edits
// are heard at once and playback does not restart. If the computer has no sound device
// the sequencer is still run on a silent clock, so everything else works the same.
// ---------------------------------------------------------------------------

AUDIO_RATE :: 44100
AUDIO_BUFFER_FRAMES :: 1024
MASTER_VOLUME :: f32(0.8)

audio: snd.Audio
audio_stream: rl.AudioStream
audio_on: bool

play_song: snd.Song // the copy that is playing
play_active: bool // playing (or paused: not used)
play_rev: int // project revision the copy was made from
play_from: u32 // tick playback started at (the position the stop button returns to)
play_loop: bool
silent_frames: f64 // frames owed to the silent clock

audio_callback :: proc "c" (buffer: rawptr, frames: c.uint) {
	context = runtime.default_context()
	out := ([^]f32)(buffer)[:int(frames) * 2]
	snd.audio_render(&audio, out)
}

audio_start :: proc() {
	snd.audio_init(&audio, AUDIO_RATE)
	snd.audio_set_master_volume(&audio, MASTER_VOLUME)
	rl.InitAudioDevice()
	if !rl.IsAudioDeviceReady() {
		return
	}
	rl.SetAudioStreamBufferSizeDefault(AUDIO_BUFFER_FRAMES)
	audio_stream = rl.LoadAudioStream(AUDIO_RATE, 32, 2)
	rl.SetAudioStreamCallback(audio_stream, audio_callback)
	rl.PlayAudioStream(audio_stream)
	audio_on = true
}

audio_stop :: proc() {
	if audio_on {
		rl.UnloadAudioStream(audio_stream)
		audio_on = false
	}
	rl.CloseAudioDevice()
	snd.audio_shutdown(&audio)
	snd.song_destroy(&play_song)
}

// ---- transport -------------------------------------------------------------------------

play_start :: proc(tick: u32) {
	snd.music_stop(&audio)
	snd.song_destroy(&play_song)
	play_loop = ed.loop_on && ed.p.loop_end > ed.p.loop_start
	play_song = project_to_song(&ed.p, .Play_Loop if play_loop else .Play_Once)
	play_rev = ed.rev
	ed.need_release = false
	play_from = tick
	snd.music_play(&audio, &play_song, play_loop, 0, tick)
	play_active = true
}

play_halt :: proc() {
	if !play_active {
		return
	}
	snd.music_stop(&audio)
	snd.sfx_stop_all(&audio)
	play_active = false
}

play_toggle :: proc(from: u32) {
	if play_active {
		play_halt()
	} else {
		play_start(from)
	}
}

// The tick the play head is at (the cursor when nothing plays).
play_pos :: proc() -> u32 {
	if play_active {
		return u32(max(snd.music_position_ticks(&audio), 0))
	}
	return ed.cursor_tick
}

// Called every frame: runs the silent clock, notices the end of the song and passes
// changes of the project on to the sequencer.
play_update :: proc(dt: f32) {
	if !audio_on {
		// No device: render (and throw away) the audio the clock says is due.
		silent_frames += f64(dt) * AUDIO_RATE
		scratch: [2 * 1024]f32
		for silent_frames >= 1024 {
			snd.audio_render(&audio, scratch[:])
			silent_frames -= 1024
		}
	}
	if !play_active {
		return
	}
	if !play_loop && snd.music_has_finished(&audio) {
		play_active = false
		return
	}
	if ed.rev != play_rev {
		old := play_song
		mode := Song_Mode.Play_Loop if play_loop else Song_Mode.Play_Once
		play_song = project_to_song(&ed.p, mode)
		play_rev = ed.rev
		snd.music_replace_song(&audio, &play_song, play_loop)
		if ed.need_release {
			snd.music_release_all(&audio) // a note that was deleted or muted must not hang
			ed.need_release = false
		}
		old2 := old
		snd.song_destroy(&old2)
	}
}

// ---- audition --------------------------------------------------------------------------

// Plays a short test note on the instrument of a track (through its effect graph).
audition :: proc(track, key, vel: int) {
	if !ed.audition_on {
		return
	}
	audition_instrument(track_inst(track), key, vel, 0.28, snd.score_track_graph(&ed.p, track))
}

// A short test note on any instrument (the zone the key is in plays: a recording or a synth sound), through an
// effect graph if one is given.
audition_instrument :: proc(inst: ^snd.Instrument, key, vel: int, length: f32 = 0.28, graph: ^snd.Fx_Graph = nil) {
	_, z, ok := snd.instrument_note(inst, key)
	if !ok {
		return
	}
	dur := length
	if z != nil && z.one_shot && z.sample != nil { // plays to its end
		dur = clamp(snd.sample_seconds(z.sample) + 0.05, dur, 4)
	}
	snd.sfx_play_instrument(&audio, inst, key, dur, f32(vel) / 127, 0, graph)
}

// Plays one zone of an instrument on a key it holds: its root key if that is one of them (a recording that follows
// the keys), else the first key of a recording zone, else middle C or the nearest key to it (a synth sound).
audition_zone :: proc(z: ^snd.Zone, length: f32 = 0.6) {
	if z == nil || (z.source == .Sample && z.sample == nil) {
		return
	}
	key := clamp(60, int(z.key_lo), int(z.key_hi))
	if z.source == .Sample {
		key = int(z.key_lo)
		if z.pitched && z.has_root {
			if rk := int(math.round_f32(z.root_key)); rk >= int(z.key_lo) && rk <= int(z.key_hi) {
				key = rk
			}
		}
	}
	dur := length
	if z.one_shot && z.sample != nil { // plays to its end
		dur = clamp(snd.sample_seconds(z.sample) + 0.05, 0.3, 4)
	}
	snd.sfx_play_zone(&audio, z, key, dur, 0.8)
}

clock_start: time.Tick
clock_started: bool

// Seconds since the program started (works without a window too).
now :: proc() -> f64 {
	if !clock_started {
		clock_start = time.tick_now()
		clock_started = true
	}
	return time.duration_seconds(time.tick_since(clock_start))
}
