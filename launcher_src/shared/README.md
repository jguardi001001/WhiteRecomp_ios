# shared

Odin packages that are meant to be used by more than one project. Nothing in here knows about any particular program.

Every project that uses them compiles with the folder as a collection named `shared`:

```
odin build . -collection:shared=C:/Users/psivstar/Documents/proj/shared
```

and imports them like this:

```odin
import ui "shared:ui"
import "shared:input"
import input_rl "shared:input/raylib"
```

(`ols.json` in this folder and in each project tells the language server where the collection is.)
Run the tests of a package with `odin test <package> -define:ODIN_TEST_THREADS=1` from this folder.

| package | what it is | imports |
|---|---|---|
| `iv_ui` | Rectangle math for user interfaces: insets, padding, cutting strips off, equal and weighted splits, grids, centering, aspect fitting, popups kept on the screen, scroll thumbs and slider math, and rectangles for text (through a measuring procedure the program passes in). Every procedure returns a `Rect`. No drawing, no state. Components (buttons, sliders, lists) are made by each program out of these, so each program has its own look. | nothing |
| `iv_input` | The abstract side of input: its own enums for keys, mouse buttons, gamepad buttons and axes; the state of each device as the program reports it (`set_key_state(&ctx, .A, {.Down, .Pressed})`); and signals bound to sources through a table the program owns (`signal_pressed(&ctx, .UI_Confirm)`). No default bindings, no hardware. Also a gamepad as the pointer of a mouse-driven interface (`nav_*`): every frame the program submits the rectangles the cursor may be on (`nav_begin`, `nav_rect`, `update_nav`); the cursor is always at the middle of one, moved to the nearest one in the direction of the D-pad or left stick; with none there is no cursor, and when they come back it is on the default one the program marks. See below. | `iv_ui` (for `Rect`) |
| `iv_input/raylib` | The one place that feeds `iv_input` from raylib (`poll`), plus the key tables to translate names. Programs that use something else write their own poll and leave this out. | `iv_input`, `vendor:raylib` |
| `iv_input/cursor` | Draws the gamepad's cursor (an arrow, or a pointing hand over what can be clicked, with a shadow) into a `ren.Draw_List`: `cursor.draw(&ctx, dl, size_scale)`. Only if `input.nav_cursor(&ctx)` says it is visible; `input.nav_show_cursor(&ctx, false)` turns it off. A package of its own so that `iv_input` does not need the renderer. | `iv_input`, `iv_system/ren` |
| `iv_snd` | Audio: a song format of timed events, a sequencer, a software synthesizer with a library of effect graphs, a track-based score model, sound effects and the mixer. Only `core:` imports: the program opens the sound device and calls `audio_render` from its callback. `iv_snd/editor` is the DAW-style song editor (a program: `iv_snd/editor/build.bat`). See `iv_snd/README.md`. | nothing (the editor: `iv_ui`, `iv_input`, `vendor:raylib`) |
| `iv_datafile` | Reading and writing a program's data. Text files of lines (`next_line`, `next_word`, `next_int`, `fields`; text is raw, no escape codes) for data packs, settings and saves; and a binary format of tagged, versioned chunks with a checksum (`Writer`, `Reader`, `begin_chunk`, `next_chunk`, `seal`) that a newer file can extend without breaking an older reader; `save_file` keeps the old file whole if the program dies half way. | `core` only |
| `iv_i18n` | Strings in several languages: a `Catalog` of texts by key and language code, fallback to the default language and then to the key, a language that can be translated a bit at a time (`missing`, `coverage`), `{name}` and plural placeholders (`{n\|item\|items}`), furigana markup that can be shown or stripped, and a strings file that names its languages once at the top and each key once, with a line of text per language under it (`load_text`, `save_text`). `load_text_static` reads an embedded file without copying: the catalog's keys and texts are views into it (a flat hash index, no maps, no per-string allocation). No global state. | `iv_datafile` |
| `iv_text` | TrueType text laid out by advances in em, so the same screen is laid out the same at any size and measuring needs no GPU: a font stack as one `Typeface` (the program gives the .ttf bytes in priority order with `typeface_set_fonts`; each character comes from the first font that has it), `width`, `wrap`, `split`, cursor placement, furigana (`漢{{かん}}字{{じ}}`, drawn above the letters or left out: `set_furigana`), `draw` into a `ren.Draw_List`, and a `ui.Measure` for `iv_ui`. Two fixed-size LRU caches: which font draws a character, and the glyph pictures in each atlas (the glyph used longest ago gives up its cell when the atlas is full). | `iv_system/ren`, `iv_ui` |
| `iv_anim` | Easing curves (33), `Tween`, exactly solved `Spring`, keyframe `Track`, `Timer`, flip-book `Frames`, frame-rate-independent `approach`, and a `Pool` that animates values through pointers and forgets them. Takes the seconds that passed; no clock, no drawing. | `core` only |
| `iv_debug` | Immediate-mode widgets for programmers' tools: windows (move, resize, collapse, scroll, raise), buttons, check boxes, drag-or-type number fields, sliders, drop-downs, lists, trees, color and vector editors, plots, tooltips, and `inspect(&ctx, "name", &value)`, which makes an editor for any struct from its type (`debug:"range=0:10"` tags). A plain dark theme, no skin: not for players. | `iv_text`, `iv_system/ren`, `iv_ui` (`iv_input` for `input_from`) |
| `iv_system` | Windows, input and 2D rendering (Vulkan, then OpenGL, then CPU). The window layer (Windows, Linux/Wayland) and the Vulkan backend work; OpenGL, the CPU backend and other operating systems are not written and do not compile: see `iv_system/README.md`. The root package is only glue; the pieces are `iv_system/platform` (Win32 and Wayland windows and events, feeds `iv_input`), `iv_system/ren` (backend-agnostic draw list and the `Backend` interface), `iv_system/ren/vulkan` and `iv_system/ren/auto`. | `iv_ui`, `iv_input`, `core`, `vendor:vulkan` |

## ui

```odin
screen := ui.make_rect(0, 0, w, h)
top, rest  := ui.cut_top(screen, 40)                   // the title bar, and the rest
side, main := ui.cut_left(ui.inset(rest, 8), 220, 4)   // a side panel with a 4 px gap, and the main area
button     := ui.center(side, 120, 28)
label      := ui.text_rect(measure, "Save", button, .Center, .Center)

measure := ui.Measure{size = my_text_size}             // my_text_size :: proc(user: rawptr, text: string) -> (w, h: int)
```

All values are whole numbers in whatever units the program lays out in.

## input

```odin
Signal :: enum { UI_Confirm, UI_Back, Jump }           // the program's own names

ctx: input.Context(Signal)
table := []input.Binding(Signal){
	input.make_binding(Signal, .UI_Confirm, input.on_key(.Enter), input.on_pad_button(.Face_Down)),
	input.make_binding(Signal, .Jump, input.on_key(.Space), input.on_key(.Z, {.Ctrl}, exact = true)),
}
input.use_bindings(&ctx, &table)                        // the module keeps the pointer: edit the table whenever you like

// each frame
input_rl.poll(&ctx)                                      // or: input.begin_frame(&ctx) and your own set_* calls
if input.signal_pressed(&ctx, .UI_Confirm) { ... }
```

Querying: `signal_state` (held), `signal_pressed`, `signal_released`, `signal_repeated` (pressed or key repeat), `signal_value`
and `signal_axis` (0..1 or -1..1, for sticks and triggers). For a settings screen: `listen` (what was pressed this frame),
`rebind`, `find_conflict`, `source_text`.

Reporting: `set_key_state` / `set_key_down` / `set_key_repeat`, `set_mouse_state` / `set_mouse_down` / `set_mouse_position` /
`add_wheel`, `set_pad_button_state` / `set_pad_button_down` / `set_pad_axis` / `set_pad_connected`, `push_char`.

## gamepad as a pointer

```odin
// every frame, after the devices were reported (set_pad_* / the backend's pump)
input.nav_begin(&ctx, window_size)                       // the rectangles of THIS frame, in the px of the window and the mouse
input.nav_rect(&ctx, new_game, default = true)           // the cursor starts here when the rectangles come back (else the first)
input.nav_rect(&ctx, load_game)
input.nav_slider(&ctx, volume_rect, VOLUME, knob_x)      // left / right turn it (nav_slider_step); the cursor is on the knob
input.nav_scrolls(&ctx)                                  // a list that scrolls: up / down past its end turn nav_wheel
change := input.update_nav(&ctx, dt)                     // .Entered: hide the system's cursor; .Left: show it again at nav_position

pointer := input.nav_pointer(&ctx)                       // the cursor while a gamepad is the main input (nav_active), else the mouse
cursor.draw(&ctx, draw_list)                             // iv_input/cursor, last of all
```

A gamepad that is only found does not count until it is used. The module keeps which rectangle the cursor is on and where it is; the real
mouse, when it moves, takes the cursor where it is. A frame that submits no rectangles (a screen on its way) has none: the cursor goes away, and
comes back on the default rectangle. `nav_free_cursor` makes it a free cursor with no rectangles (a map), `nav_rest_at` where it rests then,
`nav_stick_zoom` makes the right stick a smooth zoom (`nav_zoom`) instead of the wheel (`nav_wheel`), `nav_show_cursor` turns the drawing off.
Call `nav_begin` ... `nav_end` again after the picture is made if the rectangles moved: the cursor goes with its rectangle.
