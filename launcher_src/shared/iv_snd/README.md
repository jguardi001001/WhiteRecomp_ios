# iv_snd - audio library

A self-contained Odin package (`import snd "shared:iv_snd"`, package `iv_snd`): a song format made of timed events, a
sequencer, a software synthesizer with a library of effect graphs, a track-based score model for programs
that edit songs, sound effects and the mixer that ties them together. It is a standalone package with no knowledge of any program that uses it, and it
depends only on `core:` libraries (no Raylib, no sound device): the program opens the
device and calls `snd.audio_render` from the audio callback. `vendor:miniaudio` is not needed.
(PlanCol's own songs and its device code live outside this folder: `plancol/embed/tracks/` and `audio.odin`.)

## Overview

```
Score (tracks of notes) --score_to_song--> Song (events)      (what an editor edits: see "Scores")

Song (events) -> Sequencer -> Synth (128 channels, 256 voices) --+--> Reverb, Delay (shared sends) --\
                                  |                              |                                    +-> mix -> soft limiter -> output
                                  +-- per instrument: its Effect graph (from the library; own bus) --/
SFX (WAV samples, synthesized notes) ----------------------------------------------------------------/
```

* `music.odin` - `Song`, `Track`, `Event`, builder procs (`song_note`, `song_set_instrument`, ...)
* `score.odin` - `Score`: a song as tracks of notes (instrument + mixer per track, no channels, no controller numbers), for editors; converts to and from `Song`
* `graph.odin` - `Fx_Graph`: after-effects as a graph of nodes (filter, delay, reverb, chorus, ...), the library of graphs (`Song.graphs`, `Score.graphs`) that instruments and tracks name, and the processing that plays them
* `music_io.odin` - native binary format (`song_save` / `song_load`; only the current version is read) and Standard MIDI File import (no MIDI export)
* `patch.odin` - `Patch` (the parameters of the synthesizer) and the basic synth sounds
* `instrument.odin` - `Instrument`: a list of zones laid out on the keys, each playing a synth patch or a PCM recording
* `synth.odin` - voices, channels, oscillators, filter, envelopes
* `note_fx.odin` - effects of single notes: vibrato and portamento (Bezier pitch curves)
* `sequencer.odin` - plays a song in real time, sample accurate
* `fx.odin` - reverb, delay (echo) and soft limiter
* `sfx.odin` - WAV loading and sample playback
* `audio.odin` - `Audio` manager: mixes music + SFX, volumes, fades, thread safety
* `library.odin` - the instrument library: every ready-made instrument, in groups, found by name
* `sample.odin` - PCM recordings (WAV import) and the frozen root-key detection
* `wav.odin` - WAV writer for dumping audio

## Using it

```odin
audio: snd.Audio
snd.audio_init(&audio, 44100)

// in the audio callback (any thread):
snd.audio_render(&audio, interleaved_stereo_f32_slice)

// from the main thread:
song, _ := snd.song_load("title.psng")   // the program brings its own music: the library has no songs of its own
snd.music_play(&audio, &song, loop = true, fade_in = 2)   // the song must outlive playback
snd.music_stop(&audio, fade_out = 1.5)
snd.music_change(&audio, &other, loop = true, fade_out = 0.35, fade_in = 0.35)   // see below
snd.music_pause(&audio); snd.music_resume(&audio)
snd.audio_set_master_volume(&audio, 0.8)                  // also _music_ and _sfx_ volumes

sfx, ok := snd.sfx_from_wav(wav_bytes)                    // PCM 8/16/24/32 or float, mono/stereo
snd.sfx_play(&audio, &sfx, volume = 1, pan = -0.3, pitch = 1)
snd.sfx_play_patch(&audio, snd.patch_bell(), key = 84, duration = 0.2)   // a synthesized blip
```

### Delay (echo)

A stereo delay with feedback, a tone control in the feedback loop, optional ping-pong, and optional tempo sync.
Like the reverb it is a send effect: a channel's **CC 94** says how much of it goes in (0..127, default **0**,
so nothing uses it unless a song asks for it; with every send at 0 the audio is bit for bit what it was without
the effect). The settings (CC 102-106) apply to the whole song, are read from any channel, and are reset when a
song starts. With sync on, the echo time is `beats x 60 / tempo`, and follows tempo changes; the longest echo is
4 seconds. The delay is emptied when the music switches, like the reverb. Sound effects (`sfx_play_patch`) never
use it. Note: Roland GS files use CC 94 for a "variation" effect, so a MIDI file imported from a GS device may now
turn the delay on for the channels that set it.

### Changing music in step with an animation

`music_change(&audio, &song, loop, fade_out, fade_in)` fades the current music out,
then switches to `song` on the exact sample where the fade-out ends, and fades it
in (`song` nil = silence). Call it when the animation starts, with the two halves
of its duration, and the music follows the picture. The default `Fade_Curve.Eased`
has the gain `1 - (1 - f)^2` for fade progress `f`, which is the same curve as a
picture dissolving out (`p^2`) and re-forming in (`1 - (1 - q)^2`); `.Linear` is the
plain ramp. The reverb is emptied at the switch so the old room does not ring into the
new music. A second call during a fade simply takes over from the current level.

`audio_render` never allocates and takes a lock that the other procedures hold
only for an instant. Offline: `snd.render_song(&song, seconds)` returns the samples
(see `plancol/tools/render_wav`, which writes a WAV file).

## Songs

A song has `ticks_per_beat`, tracks of events (each event has a tick, a kind and a
channel 0..127; up to `MAX_TRACKS` = 256 event tracks play, and `MAX_VOICES` = 256 notes can sound at once), optional loop points (`loop_start`, `loop_end` ticks) and the instruments
it uses (`Song.instruments`) with the recordings its zones play (`Song.samples`). Any channel can play any
instrument; there are no special channels (a drum kit is just an instrument of sample zones on whichever channel you like).

| Event | a | b | v | Meaning |
| --- | --- | --- | --- | --- |
| `Note_On` | key | velocity 1..127 | | start a note |
| `Note_Off` | key | | | release it |
| `Control` | controller | value 0..127 | | 1 mod wheel (vibrato), 6 + RPN 0 bend range, 7 volume, 10 pan, 11 expression, 64 sustain pedal, 91 reverb send, **94 delay send**, 120/123 all sound/notes off. Also: **92** reverb size and **93** reverb damping (global, any channel; default room 53, damping 47), the delay settings **102** time (value x 10 ms, 1 = 10 ms), **103** feedback (0..127 = 0..0.95), **104** tone (0 = bright echoes, 127 = dark), **105** ping-pong (64 or more = on) and **106** tempo sync (0 = free time, 1..9 = 1/16, 1/8 triplet, 1/8, dotted 1/8, 1/4, dotted 1/4, 1/2, dotted 1/2, a whole note; follows the song's tempo), all global; and **85** with a value of 64 or more: notes keep sounding when the song loops back (see below) |
| `Pitch_Bend` | -8192..8191 | | | default range 2 semitones |
| `Tempo` | microseconds per beat | | | |
| `Set_Instrument` | index into `Song.instruments` | | | the channel plays that instrument from now on |
| `Set_Patch_Param` | `Patch_Param` | | new value | **special**: change a parameter of the channel's patch (also notes already sounding), e.g. a filter sweep |

Events at the same tick are handled in this order: tempo, instruments, controllers, parameters, bends,
note-offs, note-ons.

### Effects of a single note (`note_fx.odin`)

A note can have a vibrato and a portamento of its own, independent of its channel, its instrument and the
rest of the song. The effects are laid out over the **length of the note** (from its `Note_On` to the next
`Note_Off` of the same channel and key in the same track), as fractions: 0.0 is the start of the note and 1.0
is its end.

```odin
fx := snd.Note_Fx {
	// 0.4 semitones either side, 6.7 swings a second, from the middle of the note to its end,
	// fading in and out over 10% of that stretch
	vibrato = snd.note_vibrato(0.4, 0.15, start = 0.5, end = 1.0, fade = 0.1),
	// starts 2 semitones below the note and slides up to it, arriving after 15% of the note
	glide   = {snd.glide_in(-2, 0.15), {}},
}
snd.song_note_with_fx(&s, t, 0, 960, 0, 64, 100, fx)    // like song_note, then the effects
```

* **Vibrato** (`Note_Vibrato`): `semitones` is the pitch variance (the peak deviation to either side),
  `period` the time of one swing in seconds, `start` / `end` the part of the note it is active in
  (0.0 to 1.0), `fade` how much of that part is used to fade it in and out (0 = hard edges). The swing
  starts at the note's own pitch, so it begins without a jump.
* **Portamento** (`Pitch_Curve`, up to two per note, their offsets add): a cubic Bezier through four
  points `(x, y)`, x = how far into the note (0.0 to 1.0), y = the offset in semitones from the note's
  pitch. Before the first point's x the offset is the first point's y, after the last point's x it is the
  last point's y. One curve can slide into the note (`glide_in(semitones, until)`: the note starts away
  from its pitch and arrives after `until` of its length), slide away at the end
  (`glide_out(semitones, from)`: on pitch until `from`, then off by `semitones` at the end), or
  anything else: `glide_between(x0, y0, x1, y1)` for a slide from one point to another, `pitch_curve(p0, p1,
  p2, p3)` for the Bezier points themselves. `Glide_Shape.Smooth` (the default) eases out of the start and
  into the end, `.Linear` is a straight line. A curve in `glide[0]` and one in `glide[1]` give a slide in and
  a slide out on the same note.
* The effects follow the written length of the note, not the sound: after the note-off the vibrato is over
  and a curve stays at its last value while the note rings out.
* They change the pitch of oscillators and of sample playback. A plucked string (the Pluck waveform) is tuned
  when the note starts and does not follow them. The tempo at the start of the note is used for the whole note.
* A note's effects are stored in `Song.note_fx` (`song_add_note_fx` stores one set once, however many notes
  use it) and the note refers to them with `Event.fx`; `song_event_fx(&song, event)` reads them back.
  Playing a note outside a song: `synth_note_on_fx(&synth, channel, key, velocity, &fx, length_in_seconds)`.

### Loops

`loop_start` / `loop_end` mark the part that repeats; what comes before `loop_start`
plays once (an intro) and its events are not repeated, so channel setup belongs
there. Normally the sequencer releases every sounding note when it jumps back. A pad
or drone with a long release would then leave a hole in the sound at the join, so a
song can send controller 85 = 127: notes then ring through the jump and the song
must end them itself (a note-off at or before `loop_end`). A song can also start
each chord a little before the previous one ends, and on alternate channels so a
note-off cannot hit the next chord's notes (PlanCol's songs in `plancol/embed/tracks/` were made this way).
Set_Patch_Param sweeps should be periodic over the loop so that they join without a jump.

Write songs in code:

```odin
s: snd.Song
snd.song_init(&s, "my song", bpm = 100)
t := snd.song_add_track(&s, "lead")
lead := snd.song_add_synth(&s, my_patch, "My Lead")      // an instrument of the song (index)
snd.song_set_instrument(&s, t, 0, 0, lead)        // channel 0 plays it from tick 0
snd.song_note(&s, t, 0, 480, 0, 60, 100)          // tick, length, channel, key, velocity
snd.song_param(&s, t, 1920, 0, .Cutoff, 900)      // special event
snd.song_finish(&s)                               // sorts the events, computes the length
snd.song_save(&s, "my_song.psng")
```

or load a `.mid` file (`snd.song_load` recognises both formats). A MIDI file's program numbers are mapped
onto ordinary synth instruments that are added to the song, named like the MIDI program ("Violin",
"Church Organ", ...; `midi_program_patch` is the rough family-by-family mapping), and a MIDI drum channel
(channel 10) gets the library's "Standard Drums". Nothing of the MIDI numbering stays in the song
afterwards; the song cannot be saved as a MIDI file. Loops come from `loopStart` / `loopEnd` markers or
controller 111.

## Scores: tracks of notes (`score.odin`)

A `Song` is what the sequencer plays and the file stores: events with channels and controller numbers, in the manner
of the first versions of this library. Programs that **edit** songs should not have to think that way, so there is a
second model, the `Score`: a list of **tracks**, and a track is one sequence of notes with its own instrument
(`Score_Track.inst`) and mixer settings (`volume`, `pan`, `reverb`, `delay`: how much of it goes to the shared reverb and
echo). A track has **no limit on how many notes sound at once**: chords, overlapping notes, the same key struck again before
the last note ended. Notes are single records (`Score_Note`: start, length, key, velocity), the tempo changes are a list of
their own, and the settings of the shared reverb and delay are named fields (`Score_Master`). There are no channels and
no controller numbers anywhere in it.

```odin
p := snd.score_new()                                   // one empty track, 120 BPM
append(&p.notes, snd.Score_Note{start = 0, len = 480, track = 0, key = 60, vel = 100})
snd.score_track_set_mix(&p.tracks[0], .Reverb, 0.4)
song := snd.score_to_song(&p, .Play_Once)              // channels are handed out here
snd.music_play(&audio, &song, loop = false)
q := snd.score_from_song(&song)                        // and back (a PSNG or MIDI file loaded with song_load works the same)
```

`score_to_song` gives every track as many channels ("lanes") as it needs: a note goes on the first lane that has no
note of the same key still sounding, so a track's notes never cut each other off. Mute and solo (`Score_Track.mute`,
`solo`) are applied by the `Play_Loop` / `Play_Once` modes; `Save` writes everything, plus a `"SCOR"` chunk (name and
channels of every track) so that a saved score opens with the same tracks, names and empty tracks. A song made some
other way opens as tracks (the channels a song track uses become tracks; channels of one song track that are set up
alike are joined), and whatever a score has no field for (a volume sweep, a filter sweep, a change of instrument half
way, controller 85 and the like) is kept as `extra` events and written back unchanged, so a song plays the same after it went
through a score. `score_free`, `score_clone`, `score_prune_instruments` and `score_prune_samples` are the housekeeping.

## Effect graphs: after-effects (`graph.odin`)

A graph (`Fx_Graph`) is nodes joined by wires. The sound that is sent through it is added up and goes into the **Input** node;
what reaches the **Output** node is heard. Between them are effect nodes (`Fx_Kind`: Gain, Filter, Delay, Reverb, Chorus,
Distortion, Crusher, Tremolo, Compressor), in a row or in parallel (a node with several wires coming in adds them up; loops
are refused). Every kind has a table of parameters in `FX_INFO` (name, range, default, unit), which is also what an editor
builds its sliders from; `fx_param_text`, `fx_param_to_t` and `fx_param_from_t` show and move values. A graph that is empty, or
only wires Input to Output (`fx_is_trivial`), is not processed: the sound is bit for bit what it was without graphs.

**Graphs are not part of instruments.** They live in a **library** of their own: `Song.graphs` (`Score.graphs` in a score), as
many as you like, each with a name (`fx_graph_name`). An instrument (`Instrument.graph`), or in a score a track
(`Score_Track.graph`), says which graph it is played through by **number** (1 = the first graph, 0 = none, the way
`Zone.sample_id` counts recordings). **Any number of instruments and tracks can use the same graph**: they all follow its
settings (change the graph, change them all), but each is processed on its own, with its own echoes and its own reverb tail,
exactly as if each had a copy. A graph nobody uses stays in the library (and in the file).

```odin
g := snd.fx_graph_default()                            // Input (id 1) -> Output (id 2)
snd.fx_disconnect(&g, 1, 2)
delay, _ := snd.fx_add(&g, .Delay, 0, 0)               // returns the id of the new node
snd.fx_connect(&g, 1, delay)
snd.fx_connect(&g, delay, 2)
g.nodes[snd.fx_find(&g, delay)].p[0] = 250             // Delay "Time": 250 ms
n := snd.fx_library_add(&song.graphs, "slap echo", g)  // the library owns it now; n is its number (1 here)
song.instruments[0].graph = n                          // two instruments on one graph:
song.instruments[1].graph = n
snd.song_graph_remove(&song, n)                        // takes it out; its users play dry, later numbers go down
```

The library: `fx_library_add` (under a name made unique), `fx_library_get` (nil for 0 or a number that is not there),
`fx_library_find`, `fx_library_remove`, `fx_library_clone`, `fx_library_destroy`; `song_graph_remove` and `score_graph_remove`
also renumber who used the graphs. A score adds `score_graph_add`, `score_graph_duplicate`, `score_graph_users` and
`score_track_graph`; `score_to_song` makes the instruments of the song that name the graphs (an instrument of the song is
a sound plus a graph, so a track with its graph gets one made for the pair), and `score_from_song` splits them again.

* The library is stored with the song (chunk `"FXG1"`, see below) and copied by `song_clone` / `score_clone`.
* While a song plays, the synthesizer gives every instrument that names a graph its own bus (`Synth.buses`, indexed like
  `Song.instruments`): the notes of the instrument are added up there, the graph (`Fx_Runtime`) processes them, and the
  result joins the mix. The shared reverb and delay sends of the channels are not affected. `music_replace_song` hands the
  new song's graphs to the running buses, and a node that is still there (same id and kind) **keeps its state**, so
  editing a graph while a song plays does not cut the echoes or the reverb tail. A bus that has heard and given nothing
  for 5.5 seconds is skipped until sound arrives.
* `sfx_play_instrument` takes the graph to play through (the editor's audition and test notes): the caller looks it up in
  the library, because an instrument only knows its number.
* The synthesizer never allocates while rendering: the buffers of the nodes (delay lines, reverb) are made when a song
  starts or is replaced.

## Instruments

An **instrument** (`instrument.odin`) is what a channel plays, and every instrument is built the same way: a
list of **zones** (up to `ZONE_MAX`) laid out on the keyboard, in the manner of a SoundFont. A zone is a key
range (`key_lo`..`key_hi`) and a **source** for its sound (`Zone.source`), which is one of two things:

* **Synth**: the zone's `Patch`, the set of parameters for the synthesizer: two oscillators (sine, triangle, saw,
  pulse, noise) or a two-operator FM pair, a filter (low/high/band-pass with its own envelope), an amp envelope, a
  pitch sweep, vibrato and a fixed frequency (drums). The zone plays that sound at the pitch of the key.
  `patch_base()` is the starting point for your own; `patch_piano`, `patch_epiano`, `patch_bell`, `patch_organ`,
  `patch_pluck`, `patch_bass`, `patch_strings`, `patch_pad`, `patch_brass`, `patch_lead_square`,
  `patch_lead_saw`, `patch_flute`, `patch_reed` and `patch_noise_fx` are the basic sounds.
* **Sample**: a PCM recording (see "Samplers" below). The zone's patch then shapes the recording: its envelope,
  filter, loudness, pan and auto-pan (the oscillators are not used).

So an instrument that is "just a synth sound" is one Synth zone over all 128 keys (`instrument_synth(patch,
name)`), a drum kit is a row of Sample zones, and the two can be mixed in one instrument: a recording on the
low keys and a synth pad above, say (`zone_synth`, `zone_sample`, `instrument_add_zone`). The first zone that
holds a key plays it.

A song owns its instruments (`Song.instruments`, `song_add_instrument`, `song_add_synth`), so a song file is
self-contained, and `Set_Instrument` events give them to channels. An instrument may name a graph of the song's library (see above). A channel that was given none plays
`default_instrument()` (Basic Piano). The Set_Patch_Param event changes one parameter of the channel while it
plays: it replaces that value in the patch of whichever zone plays a note (it stays in force until the channel
gets another instrument).

### More synth parameters

Besides the oscillator pair a `Patch` has:

* `Waveform.Pluck`: a plucked string (Karplus-Strong). `string_decay` is the ring time in seconds
  (how long the fundamental takes to fade by 60 dB), `string_bright` (0..1) how bright the pluck is.
  The string is tuned exactly, but it ignores pitch bend and vibrato and cannot play lower than about 22 Hz.
* `unison` (1..5) copies of oscillator 0, spread by `unison_detune` semitones (the copies are staggered
  so the beating stays gentle and the loudness is kept the same).
* `chorus_depth` / `chorus_rate`: a slow wobble in the pitch of the copies (depth is measured in cycles
  of the note's own wave, so it sounds the same on low and high notes).
* `tremolo_depth` / `tremolo_rate`: loudness wobble.
* `drive` (0..1): overdrive. The sound is pushed into a soft saturation before the filter, like a guitar amp;
  a low-pass filter after it plays the part of the speaker. 0 is off (the sound is untouched).
* `autopan_range` (two numbers, each -1 = left .. 1 = right) and `autopan_speed` (Hz, 0 = off): **auto-pan**.
  The sound sweeps between the two places, as a sine: it starts at `autopan_range[0]`, is at `autopan_range[1]`
  half a sweep later and is back after one (`autopan_speed` sweeps a second). It belongs to the instrument
  (the first zone whose patch has a speed), not to its notes: the sweep is a clock that belongs to the channel playing the instrument and it keeps
  running whether notes are sounding or not (it starts at `autopan_range[0]` when the song starts), and
  a note just sounds from the place the sweep is at, and moves with it for as long as it lasts. While it is
  on, it takes the place of the pan of the instrument and of the channel (controller 10). It follows the
  instrument of the channel (a change of instrument keeps the clock going, with the new instrument's range and
  speed). A song can change it while it plays with `Autopan_From`, `Autopan_To`
  and `Autopan_Speed`.

All of them can be changed from a song with `Patch_Param` (`Unison_Voices`, `Unison_Detune`, `Chorus_Depth`,
`Chorus_Rate`, `Tremolo_Depth`, `Tremolo_Rate`, `String_Decay`, `String_Brightness`, `Autopan_From`,
`Autopan_To`, `Autopan_Speed`, `Drive`). Patches are stored as a list of floats (43 now); a list that is shorter leaves the missing parameters at their defaults, so a parameter can be added at the end.

### The instrument library (`library.odin`)

The ready-made instruments in one catalogue, `LIBRARY`: `library_count()`, `library_name(i)`,
`library_category(i)`, `library_category_name(c)`, `library_instrument(i)` (a new `^Instrument` that you give to a
song with `song_add_instrument`, or free with `instrument_destroy`), `library_has_samples(i)` (whether the entry plays recordings) and `library_find(name)`
(index of an instrument by its exact name). A name never changes and neither does the sound
of an entry, so a song may refer to an instrument by name. New instruments can be
added anywhere; their loudness is matched so they can be swapped without touching the mixer.

* Basic: the plain all-round sounds (Basic Piano, E-Piano, Bell, Organ, Pluck, Bass, Strings, Pad, Brass, Square
  Lead, Saw Lead, Flute, Reed, Noise). MIDI imports are mapped onto these.
* Strings: Synth Strings, String Ensemble, Solina Strings, Slow Strings, Tremolo Strings, Staccato Strings,
  Cello Section, Violin Section.
* Pads: Warm Pad, Soft Warm Pad, Analog Pad, Velvet Pad, Sunrise Pad, Dusk Pad, Choir Pad, Nebula Pad
  (a slow cloud of detuned saws), Europa Pad (cold and hollow, pulse + triangle).
* Keys: E-Piano (Rhodes / Wurlitzer / FM / Dream), Crystal Piano, Celesta, Music Box, Soft Piano, Bright Piano,
  Honky-Tonk Piano, Dream Keys, Lunar Keys (soft FM music box).
* Plucked: Pizzicato Strings, Pizzicato Section, Pizzicato Staccato, Pizzicato Bass, Harp, Nylon Guitar.
* Bells: Starlight (glassy inharmonic FM chime), Ring Gong (huge metallic strike).
* Leads: Aurora (airy lead that swells in), Pulsar (a short sonar-like blip).
* Bass: Sub Orbit (round sub bass), Void Drone (a deep, almost motionless tone).
* Effects: Solar Wind (filtered noise gust), Comet (a tone that streaks down into its pitch).
* Drums: **Standard Drums**, an instrument of sample zones: the 15 drum sounds of the synthesizer (kick, rim, snare, clap, six toms,
  closed and open hat, two cymbals, cowbell) rendered once to PCM at 44.1 kHz the first time the kit is asked for
  (cached), placed on the General MIDI drum keys (35..59) with every other key a closed hat; the hats choke each other.

```odin
inst := snd.library_instrument(i)
idx := snd.song_add_instrument(&song, inst)       // the song takes it over (and the recordings it needs)
snd.song_set_instrument(&song, track, 0, channel, idx)
```

## Samplers: recordings on the keyboard (`instrument.odin`, `sample.odin`)

A `Sample` is only a mono 16 bit recording (`rate`, `data`; `sample_load_wav`, `sample_from_wav`, `sample_new`,
`sample_from_sfx`), shared by reference counting (`sample_retain`, `sample_release`): a song holds one share of each of
its samples and every sounding voice holds one too, so a song can be freed or replaced while its notes still ring.
At most `MAX_SAMPLE_FRAMES` (4 million frames, about 90 seconds); interpolation is 4-point Hermite.

A zone with `source = .Sample` plays a recording (`sample_id`, index + 1 in `Song.samples`, so a recording is stored
once however many zones use it). A key that no zone holds is silent, and so is a Sample zone without a recording.
Besides the key range and the source, the zones have these settings (those about the recording only matter to Sample
zones):

| Zone field | Meaning |
| --- | --- |
| `patch` | Synth: the sound. Sample: what shapes the recording (envelope, filter, volume, pan, auto-pan) |
| `pitched` | (Sample) on: the recording follows the key, played at the speed `2^((key - root_key)/12)` (a C4 recorded sound played on key 72 is an octave up); off (default): every key of the zone plays it as recorded, for drums |
| `root_key` | (Sample) the key (with a fraction) at which the recording sounds as recorded. Optional (`has_root`): when a pitched zone needs it and none is set, it is worked out from the recording and then **frozen** into the zone as a real value (see below) |
| `loop_on`, `loop_start`, `loop_end` | (Sample) frames of the recording: while the key is held the sound repeats between the two points; without a loop it plays once |
| `one_shot` | plays to its end, the note-off is ignored (drums). Off: the note-off releases it (a held sound needs a loop) |
| `tune`, `volume`, `pan` | semitones; 1 = as loud as the patch (a recording: as the normalised recording); -1..1 added to the pan of the patch |
| `group` | 1..255: notes of the same group on one channel cut each other off (open and closed hi-hat) |

Every recording is normalised to the same peak level (`Zone.gain`, set by `instruments_resolve`).

```odin
sm, _ := snd.sample_load_wav("sounds/kick.wav", "kick")
inst := snd.instrument_empty("my kit")
snd.instrument_add_zone(inst, snd.zone_sample(36, 36, sm))                      // unpitched, one-shot
snd.instrument_add_zone(inst, snd.zone_sample(42, 46, hat, group = 1, volume = 0.8))
snd.instrument_add_zone(inst, snd.zone_synth(60, 127, snd.patch_bell()))        // a synth sound on the high keys
bell := snd.instrument_from_sample(bell_sample, "Bell")                         // one pitched zone over all keys
idx := snd.song_add_instrument(&song, inst)       // adds the recordings to the song too
snd.sample_release(sm)                            // (drop your own share)
snd.sample_play(&audio, sm, key = 64, volume = 0.8)         // a recording as a one-off sound effect
snd.sfx_play_instrument(&audio, inst, key = 36, duration = 0.5)
```

**The root key is found once and then never changes.** `sample_detect_root_v1` is *frozen*: the most
dominant pitch is found with the YIN method (an exact whole-number difference function, so the result is the same
on every computer), on the loudest parts of the recording, within 27.5 to 4186 Hz, and the vote of those parts
gives the key rounded to 0.01 of a semitone. Recordings without a clear pitch (noise, drums, silence) get key 60 and
`root_known = false`. `zone_ensure_root` runs it for a pitched zone that has no root, and stores the result in the zone
(`has_root`, `root_key`, `root_version` 1); a zone that has a root is **never** analysed again, so changing the detection
later cannot change an old song. A better method would be added as `sample_detect_root_v2` for new zones only.
`--selftest` of the editor holds recorded results of v1 that must not change. `zone_set_root` sets a key by hand
(`root_version` becomes 0). `zone_find_loop` picks a loop of a whole number of periods between rising zero crossings
and switches the loop of the zone on. Unpitched zones never need a root.

## Native file format ("PSNG")

`"PSNG"`, version byte, then MIDI-style variable length integers: ticks per beat,
loop start, loop end, end tick, name, the instruments (a name and its zones; every zone has a patch as a list of floats, so
new parameters can be added later, and a zone that plays a recording adds its recording number, root key and loop), then
the tracks with delta-timed events. See the
comment at the top of `music_io.odin`.

Version 4 (written now) has the instrument list as above and **chunks** after the tracks: a count,
then per chunk a 4 letter id, a length and the bytes. `"SAMP"` holds the recordings of the song (name, rate, frames as
16 bit numbers; nothing else: root keys and loops belong to the zones). `"NFX1"` holds the effects of single notes (see "Effects of a
single note"): the list of effects, then which note of which track uses which; a program that does not know it
ignores it, and plays the notes without effects. Any other chunk is kept as it is in `Song.ext` when a file is
loaded and written back when it is saved (`song_ext_get`, `song_ext_set`), and is ignored by playback: that is where
the sound editor (`editor/`) stores its own settings (`"EDIT"`). `"FXG1"` holds the library of effect graphs
(a count, then per graph its name, its nodes with their parameters and its wires; then which instruments play through which
graph: their index and the number of the graph), and a saved score adds `"SCOR"` (the tracks of a score: name, first channel, number of
channels). Programs that do not know these chunks ignore them and play the song as it is.

Only version 4 is read; a file of another version is refused (`song_decode` returns false). Song files of the older
versions have to be made again (or loaded by an older build and saved).

## For tools

Used by `editor/`, and handy for other tools:

* `song_clone(&song)` deep copy (free with `song_destroy`); `song_tempo_map`, `song_tick_to_seconds`,
  `song_seconds_to_tick`, `song_length_ticks` follow the tempo changes.
* `music_play(&audio, &song, loop, fade_in, start_tick)` can start in the middle of a song: the
  setup events (instruments, controllers, tempo) before that tick are applied first.
* `music_replace_song(&audio, &new_song, loop)` swaps the playing song for an edited version without
  a restart (the old song may be freed after it returns); `music_release_all` lets sounding notes ring
  out; `music_position_ticks` tells where the music is.
* `patch_get_param` (counterpart of `patch_set_param`), `patch_label_make`, `instrument_clone`, `instruments_resolve`
  (after a tool changes zones or recordings).
