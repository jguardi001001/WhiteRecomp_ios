# snd_editor - PlanCol sound editor

A keyboard-and-mouse "DAW" for the game's songs: a piano roll for one instrument track at a time, an
instrument per track, a library of after-effect node graphs that any tracks can share, faders, playback, and WAV export. It has a dark,
full-color look like a traditional DAW: smooth text at the real resolution of the window (it follows the
display's scale; `F11` / `F12` make the whole interface bigger or smaller), every track has its own color, and
the notes, the track list and the faders show it.

It is a separate program that imports the shared `iv_snd` package (`import snd "shared:iv_snd"`), so what you hear in the
editor is exactly what the game plays.

```
shared\iv_snd\editor\build.bat                  (Windows: builds an optimized snd_editor.exe and runs it)
shared\iv_snd\editor\build.bat songs\title.psng     (open a file at start; .mid works too: MIDI files can be opened, not saved)
odin build shared/iv_snd/editor -o:speed -collection:shared=shared    (the same by hand, from the proj folder)
snd_editor --selftest                           (checks the project model, the effect graphs, the export and more, without a window)
snd_editor --export song.psng out.wav [loops]   (renders a WAV file without a window and says how long it took)
snd_editor --shot out.png [--dialog help] [--view graph] [--track 3] [song.psng]   (draws the window once into a picture; see main.odin)
```

**Build it with `-o:speed`** (`build.bat` does). Odin's default build is not optimized and the synthesizer
then renders about five times slower: exporting a 2.5 minute song takes about a second optimized and five
seconds without. The export dialog warns when the program was built without it.

## Tracks

A **track** is one sequence of notes with its own instrument and its own mixer settings (volume, pan, reverb
send, delay send). There is no limit on what a track plays: any number of notes can sound at once, chords,
overlapping notes, even the same key struck again before the last one has ended (the notes of a track never cut
each other off). Nothing in the editor is a channel, a program number or a controller: those are details of the
song format the game's player reads, and the editor makes them when it plays or saves a song.

* The **piano roll shows one track at a time**: the current one. Other tracks' notes are not drawn and cannot be
  touched. `View > Show other tracks` (or `Ctrl+P`, "ghost") shows them as faint outlines; clicking a ghost note
  switches to its track. Switching tracks scrolls the roll to where the track's notes are.
* The track list (top right) has a row per track: color, name, instrument, number of notes (`[fx]` marks an
  instrument that has effects), and the **M** (mute) and **S** (solo) switches. Click a row to make it current,
  double-click to rename it, `+` adds a track, `Tab` / `Shift+Tab` go to the next / previous one. Tracks can have
  the same instrument (they then share its sound editor settings and its effects).
* Under the list are the faders of the current track: **Volume, Pan, Reverb, Delay**. Drag them, double-click to
  reset one, right-click to type a percentage, or use the wheel over it. Dragging a fader is one step of undo and
  does not cut the notes that are sounding. Reverb and Delay are how much of the track goes into the shared
  reverb and echo of the song (`Song > Reverb and delay settings...`).
* `Edit > Move to track` moves the selected notes (`Ctrl+A` selects the notes of
  every track) to the current track.

## Files

The project is stored as a PSNG file, the same format the game's songs use (`iv_snd/music_io.odin`).
Whatever else the editor needs to remember is stored in extra chunks of that file, which the
`snd` package keeps when it loads a file and ignores when it plays one:

| Chunk | Content |
| --- | --- |
| `SAMP` | the WAV recordings the zones play (PCM only; written by `snd`). The instruments themselves, with their zones, patches, root keys and loops, are part of the file proper |
| `NFX1` | the vibrato and portamento of single notes (written by `snd`; the editor keeps them when it saves, but has no controls for them yet) |
| `FXG1` | the library of effect graphs and which instrument plays through which (written by `snd`, see below) |
| `SCOR` | how the tracks were laid out (name, channels) so that tracks, their names and empty tracks come back exactly (written by `snd`'s score) |
| `EDIT` | the editor's view: grid, zoom, scroll, cursor, current track, velocity, loop playback switch |

`File > Open` also reads Standard MIDI files: each MIDI program becomes an ordinary synth instrument of the song
(named like the program, "Violin", "Church Organ", ...), a drum channel gets the library's "Standard Drums", and
every MIDI channel that plays notes becomes a track. That is all the MIDI the editor has: it only reads such
files, it never writes one. Songs are saved as PSNG, and exported as WAV. Only the current version of the song format
opens; files of older versions are refused.
The game's songs are ordinary files, `plancol/embed/tracks/*.psng`: open them with `File > Open`, rework them and save them back;
the game compiles them in with `#load`. Files can also be dropped on the window. A song made some other way
(channels used for several instruments in turn, volume sweeps and the like) opens as tracks and plays the same:
what a track cannot show as a field is carried along unchanged.

`File > Export WAV` renders the song once (mute and solo are respected, so you can export a single
track) and lets the last notes die away (at most four seconds; the file ends sooner when the sound
is already silent; with echoes in the project it waits for the last one). `Export WAV (loops)` plays the intro and then
repeats the loop section the number of times you give and fades out. The rendering happens in small slices between the frames of the
editor, so the window stays alive: a dialog shows the progress, and `Esc` or *Cancel* stops it without writing a file.

## Effects: the node graph

After-effects are **graphs of nodes** that the sound of a track goes through before it is mixed. The graphs are a **library of
the project**, separate from instruments and tracks: make as many as you like, and make any number of tracks play
through the same one. A track just says which graph it plays through. Change the graph and every track that uses it
changes, and each track still gets its own echoes and its own reverb tail. A graph that no track uses stays in the library and in the file.

* In the track panel, **Fx: ...** picks the graph of the current track (*No effects*, one of the graphs with the number of
  tracks that use it, or *New graph...*); **Edit** (or `Ctrl+G`, `View > Effect graphs`, `Esc` to go back) opens the graph editor.
* The **list on the left** of the editor is the library. Click a graph to look at it (and edit it), click its **circle** to make
  the current track play through it (click again: no effects), double-click a name (or `r`) to rename, **New** (`n`), **Copy**
  (a copy that nobody uses yet) and **Delete** (tracks that used it play dry; it asks first when tracks use it). `x3` at the right of
  a row is how many tracks use the graph. `Tab` goes to another track, and the editor shows the graph that track uses.
* Add an effect with no graph selected and one is made for you (and the current track plays through it if it had none).
* Every change, including the library operations, is one step of undo.

```
 Input --> Filter --> Delay --> Reverb --> Output
        \                                 /
         +-------> Chorus ---------------+          a parallel branch
```

* **Input** is the sound of the track, **Output** is what you hear. Wire them through effects, in a row or in
  parallel: a node with several wires coming in adds them up, and one output can feed several nodes. Loops are refused.
  A graph that is only Input -> Output (or no graph) is not processed at all and sounds as before.
* The effects (click one in the list on the left to add it: into the selected wire, after the selected node, or in front
  of the Output): **Gain** (level, pan, stereo width), **Filter** (low-pass, high-pass, band-pass, notch), **Delay** (echoes; free time or
  tempo sync, feedback, tone, ping-pong), **Reverb**, **Chorus** (a short delay makes it a flanger), **Distortion**,
  **Crusher** (fewer bits, lower sample rate), **Tremolo** (or auto-pan), **Compressor**. Most have a *Mix* that crossfades dry and wet.
* On a node: drag its **title** to move it, the **B** switch bypasses it, **x** removes it (the chain closes up). Its
  parameters are sliders (drag, wheel, double-click to reset) or choices (click for the next, right-click for the previous).
* Wiring: drag from the dot on the right of a node to a dot on the left of another. Pull a wire off the dot it ends
  in to move it, drop it in empty space to cut it. Click a wire to select it, `Delete` removes it, right-click cuts it.
* Keys: `Delete`/`x` remove the selected node or wire, `b` bypass, `t` play a test note through the graph, `a` arrange the
  nodes in columns, `f` fit the view, `Esc` deselect / back. Scroll the canvas with the wheel (`Shift`: sideways), the middle
  button or by dragging empty space.
* Every change is one step of undo, and is heard at once while the song plays (the echoes and reverb tails go on). Notes you
  audition (keys, clicking the piano keys, *Test note*) go through the graph too.
* *Test note* plays a note of the current track's instrument through the graph you are looking at, whether the track uses it
  or not, so you can try a graph before you give it to a track.

## Reverb and delay (the song's shared effects)

The sound engine also has a shared reverb (a room) and a stereo echo that every track can send to with its Reverb and
Delay faders. The **Delay fader is 0 for every track** until you turn it up, so songs sound as they did before. The
settings belong to the whole song and are edited in `Song > Reverb and delay settings...`: the size and damping of the room,
the time between echoes (10 ms steps), the feedback (how long it repeats), the tone (how much duller each echo gets),
ping-pong (echoes jump between left and right) and tempo sync (the time follows the song's tempo, in note lengths from 1/16
to a bar; the free time is then ignored). The dialog shows the echo time that results at the tempo under the cursor.

## Keys

Every command can be found by name with **Ctrl+P** (also `:`): type a few letters of it. `F1` shows
this list inside the editor.

| Keys | |
| --- | --- |
| `h` `j` `k` `l` or arrows | cursor left / down / up / right (one grid step in time, one semitone in pitch) |
| `H` `L`, `Ctrl` + left / right | one bar left / right |
| `J` `K`, `Ctrl` + down / up | one octave down / up |
| `0` `$` `w` `b` | start, end, next note, previous note |
| `4l`, `3K`, ... | a number before a move repeats it |
| `i` or `Enter` | insert a note at the cursor (`a`: insert and step forward, for typing a melody) |
| `x` or `Delete` | delete the selected notes, or the one under the cursor |
| `Shift` + arrows | select: the notes in the rectangle from where the cursor was when you started |
| `s` | select / unselect the note under the cursor |
| `Alt` + arrows | move the selected notes (or the one under the cursor) by one grid step / one semitone; one step of undo while `Alt` is held |
| `<` `>` | shorter / longer by one grid step |
| `-` `+` | softer / louder (velocity, about 5% a step) |
| `q` | quantize to the grid |
| `y` `p`, `Ctrl+D` | copy, paste at the cursor, duplicate |
| `u`, `Ctrl+R` | undo, redo (also `Ctrl+Z`, `Ctrl+Shift+Z`) |
| `[` `]` | coarser / finer grid (1/1 down to 1/32 and triplets) |
| `z` `Z` | zoom in / out (`Ctrl` + wheel too; `Alt` + wheel makes the key rows taller / shorter) |
| `F11` `F12` | bigger / smaller interface |
| `Tab` / `Shift+Tab` (or `{` `}`) | next / previous track |
| `Ctrl+I` | choose the instrument of the track (the list plays each one as you move) |
| `Ctrl+T` | edit the sound of the track's instrument |
| `Ctrl+G` | the effect graphs (the library, and the graph of the track) / back to the piano roll |
| `M` `S` | mute / solo the track |
| `Space` | play from the cursor / stop; `F5` from the start; `F6` loop on / off |
| `,` `.` | the loop starts / ends at the cursor |
| `t` | tempo from the cursor on |
| `Ctrl+O` `S` `N` `E` `Q` | open, save (`Shift`: save as), new, export WAV, quit |
| `F10` | the menu bar (then `h` `l` `j` `k`, `Enter`) |

## Mouse

Everything can also be done with the mouse: the menu bar, the buttons and read-outs in the transport bar (click the position, the
tempo, the time signature or the velocity to type a value; the wheel over the tempo, grid or velocity changes it), the
track list (click to choose, `M` / `S` to mute and solo, double-click a track to rename it), and the four faders of the current track.

In the piano roll: click to put the cursor there, click a note to select it (`Shift` adds), drag a note to move
it and its right end to resize it, drag in empty space to select with a rectangle, double-click empty space to
insert a note, right-click a note to delete it. The wheel scrolls (`Shift`: sideways, `Ctrl`: zoom), the middle
button drags the view, the bars at the right and bottom scroll, a click in the ruler sets the position (and jumps
there while playing), a click on the piano keys sounds the key, and dragging in the VELOCITY lane at the bottom changes
velocities. Velocity is shown in percent.

## Instruments

Every instrument is a list of **zones** laid out on the keyboard. A zone is a range of keys and where its sound comes from: a
**synth sound** (a set of parameters for the synthesizer) or a **recording** (a WAV file). A plain synth instrument is one synth zone
over all keys, a drum kit is a row of recordings, and one instrument can mix the two. Any track can play any instrument.

`Ctrl+I` opens the instrument list of the current track. At the top are **Import a WAV file as an instrument...** and
**New instrument...** (an empty one: you add the zones), then the **library** (basic sounds, strings, pads, keys, plucked strings, bells, leads, bass, effects and
the **Standard Drums** kit; `Library: <category> - <name>`), then the instruments already in this song (numbered, marked
`synth`, `samples` or `mixed`). The list can be previewed before you pick. A picked library instrument is copied into the song, and an
instrument that no track plays any more is dropped from the song.

`Ctrl+T` edits the instrument of the track: an instrument that is one synth sound opens the **sound editor** (oscillators, filter,
envelopes, effects ...; `z` there goes to the zones), any other opens the **zone editor**. The first change to the default instrument
(what a track plays until it gets one) copies it into the song.

### Zones

A zone is a range of keys, where its sound comes from (a recording or a synth sound) and its settings. The first zone that holds a
key plays it; keys that no zone holds stay silent.

* `a` adds a WAV file as a zone on the next free key, `f` adds **every WAV file of the folder** of the file you choose
  (in the order of their names, one key each, from the next free key), `s` adds a zone with a synth sound (a basic piano to start
  with) on all the keys after the last one used, `r` replaces the sound of the zone with a recording, `d` deletes the zone.
  The *Sound* setting switches the selected zone between a recording and a synth sound.
* `e` opens the **sound editor** for the selected zone: for a zone with a synth sound that is the sound itself, for a zone with
  a recording it is what shapes the recording (envelope, filter, loudness, pan; the oscillator rows are left out).
* `j` `k` select a zone, `Tab` selects one of its settings: first and last key, the sound (recording / synth), which recording of the song it plays,
  *follows the key* (pitched; off = the same sound on every key), *plays to its end* (one-shot), the **root key**,
  the **loop**, tuning, volume, pan and the **choke group** (zones of one group cut each other off, as an open hi-hat is cut by
  a closed one). `h` `l` change a setting (`H` `L` bigger steps), `Space` plays the zone, `n` renames the instrument. A zone with a synth sound has no
  recording, root key or loop settings.
* The **root key** is the key at which the recording sounds as recorded. It is optional: "auto" means it has not been worked out
  yet. The first time a zone follows the key its root is found from the pitch of the recording, and from then on it is a real value
  stored in the zone (shown like "C4 +3c"; a "?" means the recording had no clear pitch and C4 is only a default). `h` `l` change
  it by a semitone (`H` `L` by 0.1), `R` finds it again. It is never recomputed when a file is opened.
* The **loop** (on/off, start and end in frames of the recording) makes the sound repeat while the key is held. Turning it on
  looks for a seamless loop (a steady pitch is needed); without one the whole recording loops. Start and end can be moved by hand
  (`H` `L` move by about 1% of the recording).
* **Import a WAV file as an instrument** makes an instrument with one zone over all keys that follows the key; its root key is found
  automatically and shown in the status line ("no pitch found" for noise and drums, which then play as C4).
* When the instrument has recording zones that do not follow the key (a drum kit), the piano roll's key column shows the recording each key
  plays instead of the note names.
* The recordings are stored once in the file (`SAMP`), the zones in the instruments. Recordings that no zone uses any
  more are dropped when the file is saved.

## How it works

* The model is the library's **score** (`iv_snd/score.odin`): tracks, each with its instrument and mixer settings, and every note ONE
  record (start, length, key, velocity, track); plus the tempo changes, the loop, the shared reverb and delay settings and the
  instruments, and the library of effect graphs (`iv_snd/graph.odin`) that tracks refer to by number. The editor only gives it short names (`project.odin`).
  `snd.score_from_song` and `snd.score_to_song` convert to and from the `snd.Song` the sequencer plays and the file stores: a track
  gets as many channels as its notes need (a note goes on the first channel that has no note of the same key still sounding),
  and the events a score has no field for are carried through unchanged, so `--selftest` can check that the game's songs
  come back with every note and render to identical audio.
* A note without an end (like the long drones of the game's songs, which are released by the song's own loop
  controller) is an "open" note: drawn with a dotted line after it.
* Playback runs the real sequencer and synthesizer. Every edit while the song plays makes a new copy of the song and
  hands it to `snd.music_replace_song`, so you hear changes at once and the music does not restart. Without a sound
  device the sequencer is driven by a silent clock, so everything else still works. The effect graphs run on a bus per
  instrument in the synthesizer (tracks that use one graph each get their own state); a replaced song keeps the state of the nodes that are still there.
* Undo keeps up to 100 snapshots of the whole project. Recordings are shared between snapshots (they are never
  changed in place); the instruments, with their zones, root keys and loops, and the library of effect graphs, are copied into each snapshot.

## Files of the editor

| File | |
| --- | --- |
| `main.odin` | window, frame loop, `--export` and `--shot` |
| `gfx.odin` | `Rect` (the shared `ui` package's: all layout is cut with `ui.cut_*` and friends) and drawing at the real resolution: shapes, clipping, TrueType fonts (Segoe UI and Consolas, else the embedded Liberation Sans), all in "logical" pixels that the interface scale turns into device pixels |
| `theme.odin` | the colors, the track colors and the widgets (buttons, sliders, dialog frame, icons) |
| `input.odin` | what the editor works with each frame (the pointer in logical pixels, wheel notches, double click, typed characters, modifiers), worked out from the shared `iv_input` package after `input_rl.poll` (shared:iv_input/raylib); dropped files; the mouse cursor |
| `keymap.odin` | the editor's `Signal` enum (navigation keys, the global commands) and the table of what each is bound to: the program's own table, which the shared `input` package reads on every query, so it can be changed while the editor runs |
| `project.odin` | the names the editor uses for the library's score |
| `editor.odin` | editor state, undo and all editing operations |
| `roll.odin` | the piano roll: layout, drawing, mouse and the keyboard commands |
| `graph_ed.odin` | the effect graph editor: the node view, wiring, sliders, adding and arranging nodes |
| `graph_lib.odin` | the library of graphs in the editor: the list, new / copy / delete / rename, which track uses which, the picker |
| `ui.odin` | transport bar, track list with the faders, status bar |
| `menu.odin` | the command list (menus, palette and keys share it) and the menu bar |
| `modal.odin` | file dialog, command palette, prompts, instrument list, sound editor, zone editor, reverb and delay settings, help, export progress |
| `play.odin` | audio device and playback, auditioning notes |
| `fileio.odin` | loading, saving, and the WAV export (a job that renders a few milliseconds per frame) |
| `selftest.odin`, `selftest_export.odin`, `selftest_graph.odin` | `--selftest` |
| `build.bat` | builds with `-o:speed` (and the `shared` collection) and runs |

## Test songs

`testdata/tracks/*.psng` are copies of the game's songs; `--selftest` reads them from disk (they are not compiled into the editor) to check that songs survive the trip through the project model, saving and export. `testsong.odin` writes one more test song in code. Neither belongs to the `iv_snd` library: a program that uses it makes its own music.
