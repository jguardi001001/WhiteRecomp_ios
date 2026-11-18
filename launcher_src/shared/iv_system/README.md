# iv_system

Windows, input and 2D rendering for Odin programs: Vulkan first, then OpenGL, then a CPU backend (the last two are not written yet). Part of the `shared`
collection (`import iv "shared:iv_system"`). **Status:** the window layer (Windows, and Linux on Wayland), the renderer front end and the
Vulkan backend work and are tested (a real swapchain, every draw call, render targets, textures). OpenGL, the CPU backend
and a macOS platform layer are not written.

```
iv_system/
  iv_system.odin          glue: open a window + the best backend, pump, close        (package iv_system)
  platform/               the operating system's window and events                    (package platform)
    platform.odin           what is the same everywhere: Window, events, feed_input
    platform_windows.odin   Win32
    platform_linux.odin     Wayland (xdg-shell, xdg-decoration), with wayland_linux.odin (protocol bindings)
                            and xkb_linux.odin (layouts, text)          [macOS: platform_darwin.odin, later]
  ren/                    backend-agnostic 2D rendering                               (package ren)
    types.odin              Color, Vertex, Command, Texture, Blend, Material
    draw_list.odin          the drawing calls: only record into a draw list
    text.odin               Font (a glyph table you give), draw_text, font_measure
    handle.odin             generational handles and the Pool a backend keeps objects in
    ren.odin                Backend interface, Native_Surface, Renderer, Factory, create_first
    vulkan/                 the Vulkan backend                                          (package ren_vulkan)
    opengl/, software/      NOT WRITTEN: importing them does not compile (#panic)       (ren_opengl, ren_software)
    auto/                   which backends exist + the order they are tried            (package ren_auto)
  examples/hello/         opens a window, says which backend it got, draws shapes, sprites, a render target
  tools/linux_check/      runs the Linux tests from a Windows machine (WSL + a headless weston)
```

`platform` and `ren` do not import each other. `platform` needs `shared:iv_input` (it hands the window's keys and mouse to an
`input.Context`); `ren` needs `shared:iv_ui` (its rectangles are `ui.Rect`). Only the root package and the example import both.

## Using it

```odin
app, ok := iv.open({title = "Hello", width = 1280, height = 720})
defer iv.close(app)
ctx: input.Context(My_Signal)

for !app.window.close_requested {
	iv.pump(app, &ctx)                           // messages, input into ctx, the renderer told about resizes
	dl := ren.begin_frame(&app.renderer, ren.BLACK)

	ren.push_clip(dl, panel); defer ren.pop_clip(dl)      // state that nests is a stack: clip, offset, tint, blend, target
	ren.draw_rect(dl, button, ren.color_f(1, 0, 0))       // what is drawn is a typed call
	ren.draw_text(dl, font, "Save", {button.x + 4, button.y}, ren.WHITE)

	ren.end_frame(&app.renderer)
}
```

Build with `-collection:shared=<path to shared>`. Try it: `odin run iv_system/examples/hello -collection:shared=...`
(add `-- -frames 60` to run 60 frames and exit).

## The design in short

* **Recording is separate from drawing.** Every call appends vertices, indices and commands to a `Draw_List` (plain
  Odin, no GPU, no window). The backend gets the finished list once per frame. That is what makes three backends
  possible and testable, and it batches by itself: neighbours with the same state merge into one command (= one draw
  call).
* **A stack only for state that nests** (clip, offset, tint, blend, render target). Drawing is typed calls
  (`draw_rect`, `draw_image`, `draw_line`, `draw_text`, `draw_mesh`): the arguments are the whole meaning, nothing depends
  on a mode set elsewhere. `scope_clip(dl, r)` and friends pop themselves at the end of the block.
* **One vertex format, a fixed set of materials** (`Solid`, `Textured`, `Coverage`, `Sdf`) and blends (`Alpha`,
  `Opaque`, `Additive`). No user shaders in the public API: that is what keeps the CPU backend able to draw exactly what
  the GPU ones draw.
* **`ren` does not know the platform.** It takes a `Native_Surface` (kind, window handle, display, size, dpi). Anything can
  make one: the platform layer, SDL, a test.
* **Text:** `ren` does not rasterize fonts. You give it a glyph table and an atlas texture; `font_measure` has the shape
  `ui.Text_Size_Proc` wants, so layout (`ui`) and drawing use the same numbers.
* **Handles, not pointers:** textures are `u32` handles with a generation, so a destroyed texture's handle is refused.

## Choosing a backend

`ren.create_first(surface, factories, order)` goes through `order` (default: Vulkan, the only backend written; the full design is Vulkan, OpenGL, Software): for each backend
that has a factory it asks `probe()` (does this computer have what it needs? asked **without a window**, so a "no" costs
nothing) and then `create(surface)`. The first success wins; `Create_Report` says what happened to each. If nothing
works the renderer is a **null renderer**: it records and drops, `end_frame` returns `.Skipped`, the program still runs.

**The Windows window problem.** `SetPixelFormat` can be called once per window, so a window an OpenGL attempt has touched
cannot be given to anything else. A factory that has this problem sets `fresh_window = true`; if its `create` fails
`create_first` stops with `needs_new_window` and `next_index`, and `iv.open` calls `platform.recreate_window` (same
`^Window`, new HWND, same title/size/place) and goes on with the rest. Vulkan does not need this: its probe makes only an
instance (no window), and a failed surface can be thrown away. The Vulkan loader is loaded at run time (never linked), so
a computer without Vulkan still starts the program.

## Custom shaders, more texture formats, TrueType text

* **Custom fragment shaders** (`ren.Shader`, `shader_create`, `draw_shader`, `draw_shader_mesh`): ren's vertex shader and vertex
  format are used, the program supplies the fragment shader as SPIR-V (`Shader_Desc`): one uniform block (set 0, binding 0, scalar
  layout: packed like a C struct) and up to 16 `sampler2D` (set 1). Each draw copies its uniforms, so a struct of the program's
  own that is changed between passes is all that is needed. The Vulkan backend can run them; a CPU backend cannot (so a
  program that uses them needs Vulkan). `tools/glsl_to_spv.py` turns GLSL written the way raylib's shaders are (loose `uniform`s,
  `in vec2 fragTexCoord;`) into the SPIR-V and an Odin file with the uniform struct and the sampler names; it uses Khronos
  glslang (`tools/glslang/bin/glslang.exe`, downloaded from github.com/KhronosGroup/glslang, release main-tot). Row indices in a
  target count from the top, like every other row in ren (`gl_FragCoord.y - 0.5`).
* **Texture formats:** `RGBA8`, `R8` (reads as gray in all of rgb, alpha 1), `RG8` (gray in rgb, alpha from the second byte),
  `RGBA16F`, `RGBA32F`; `Wrap` (`Clamp`, `Repeat`); render targets may be RGBA8 / RGBA16F / RGBA32F (the pipelines for each
  format are made when first needed).
* **TrueType text** (`ren/ttf`, package `ren_ttf`): stb_truetype rasterizes glyphs on demand into an R8 atlas texture, and
  `ren.draw_text` draws them with the `.Coverage` material, which every backend can draw (a CPU backend would copy the coverage
  into its picture): the same API on all of them. Glyph advances are fractional, the pen is rounded to a pixel to draw. Needs
  the compiled stb libraries of the Odin install (`vendor/stb/lib`; on Linux build them with `vendor/stb/src/build_stb.sh`).
  `create_em` makes a font by its em instead of its whole height (the same em gives the same look in fonts of different line heights),
  `is_full` says that the glyph atlas has no room left (make a new font), and `Metrics` (`metrics_init`, `metrics_advance`) gives a font's
  advances in em with no atlas or size, so that text can be measured the same at any window size.
* **Window flags:** `Window_Desc.flags` (`bit_set[Window_Flag]`: `.No_Decorations`, `.Fixed_Size`, `.Maximized`, `.Fullscreen`, `.Hidden`,
  `.Always_On_Top`; the empty set is the ordinary window, so a flag always says what is different) replaces the old `fixed_size`, `hidden`
  and `fullscreen` booleans. They can change while the window lives: `set_decorated`, `set_resizable`, `set_always_on_top`, `set_fullscreen`,
  `maximize` / `restore` / `minimize` / `toggle_maximize`, and `Window.maximized` says where it is. A window without decorations draws its own
  title bar: `set_hit_test(w, proc(w, x, y, user) -> Hit_Region, user)` tells Windows which part is the caption (`.Caption`: drag to move, double click
  to maximize, snap, the system menu on a right click) and the resize handles along the edges are answered by `platform` itself; `request_close`
  closes it as the close button would. On Wayland there is no hit test (the program calls `begin_move` when the button goes down on its title bar).
* **Platform additions:** clipboard (`clipboard_text`, `set_clipboard_text`; process-local on Wayland until wl_data_device is done),
  `pick_folder` and `pick_save_file` (the system's folder and save dialogs, blocking; full Explorer windows on Windows (`IFileOpenDialog` with `FOS_PICKFOLDERS`, `IFileSaveDialog`),
  not done on Wayland: they report "cancelled"), the system's fonts (`list_font_families`, `font_data`: a family's bytes by name, from
  GDI on Windows; not done on Linux yet),
  cursor visibility and shape, `set_mouse_position` (not on Wayland), `set_visible`, `maximize`, `mouse_inside`, and gamepads
  (`read_gamepads` / `feed_input`: XInput on Windows; `/dev/input/js*` on Linux, untested without a pad, xpad layout assumed).

## Batteries included: ren/assets (package `ren_assets`)

A `Library` is one map of shaders by name and one map of fonts by name. The shaders and fonts that come with iv_system and the ones a program
brings are put in by the same procedures and are the same thing in it (an entry does not say where it came from, and adding a name that is
taken replaces it, so a program can override a builtin):

```odin
lib: ren_assets.Library
ren_assets.library_init(&lib)
ren_assets.add_builtins(&lib, &renderer)                      // or add_builtin_shaders / add_builtin_shader(&lib, &renderer, "neon") / add_builtin_font(...)
ren_assets.shader_add(&lib, &renderer, "wobble", {spirv = WOBBLE_SPV[:], uniform_size = size_of(Wobble_Uniforms), sampler_count = 1}, {"texture0"})
ren_assets.shader_add_file(&lib, &renderer, "tint", "assets/tint.spv", uniform_size = 16, sampler_count = 1)   // a .spv file at run time
sh, _ := ren_assets.shader_get(&lib, "neon")                  // a ren.Shader, builtin or not: draw it with ren.draw_shader
font := ren_assets.font_make(&lib, &renderer, "orbitron_bold", 18)   // a ren.Font (ren_ttf) from a font of the library
```

* **Your own shaders:** write GLSL the way `tools/glsl_to_spv.py` describes (it makes SPIR-V and an Odin file with the uniform struct and sampler
  names), then `shader_add` the array, or compile to `.spv` with glslang and `shader_add_file` / `shader_add_spv` it at run time. `shader_info`
  gives a shader's uniform size and sampler names, `sampler_index` the place of a texture by name.
* **Builtin shaders** (`ren/assets/shaders/*.fs`, rebuilt into `shaders_spv.odin` with `ren/assets/build_shaders.bat` after changing one):
  `bloom_extract`, `blur`, `bloom_combine` and `neon`.
* **Builtin fonts** (`ren/assets/fonts`, all SIL OFL, see `LICENSES.txt`): `liberation_sans_bold`, `noto_sans_regular`, `orbitron_bold`. A font that
  is not added (`add_builtin_font` for one) is not referenced, so its bytes do not go into the program.
* **Bloom:** `bloom_create(&lib, &renderer, w, h)`, then `bloom_apply(dl, &bloom, scene, dst_rect, params)` draws a scene texture (a render target
  the program drew into) with the parts brighter than `params.threshold` glowing, in two sizes. It runs the three bloom shaders by name.
* **Neon:** draw lines (rectangle outlines, vector graphics, text) into a render target cleared to transparent (Linear filter), then
  `neon_apply(dl, &lib, lines, {w, h}, dst_rect, params)` draws them as neon tubes: a white-hot core and a tight and a wide halo in each line's own
  colour. `Neon_Params.flicker` multiplies the halos (`neon_flicker(time)` makes a hum). Used with `Blend.Premultiplied` it can go over a picture;
  its result can also be the scene of a bloom for an even stronger glow.

The shaders need a backend that can run custom shaders (Vulkan).

## The Vulkan backend

Needs Vulkan 1.3 (dynamic rendering, synchronization2). Loaded at run time; `probe()` answers without a window.

* **Presentation mode:** the first of `ren_vulkan.present_mode_order` that the window system offers. The default is
  `{.MAILBOX, .FIFO}`: mailbox (the newest finished frame replaces the waiting one: no tearing, low latency, unthrottled)
  where it exists, otherwise FIFO (vsync, which every driver has). Tearing `.IMMEDIATE` is opt-in
  (`present_mode_order = {.IMMEDIATE, .FIFO}`). The chosen mode is part of `backend.name`
  (`Vulkan 1.3, AMD Radeon (TM) Graphics, fifo (vsync)`). A mailbox swapchain gets at least 3 images.
* **A frame:** the list's vertices and indices are copied into the frame's host-visible buffers (2 frames in flight);
  dynamic rendering draws into the swapchain image; each `ren.Command` is one scissor + pipeline + descriptor set + indexed
  draw. A command whose target differs from the previous one closes the pass and opens another (render-target textures get
  their layout transitions and barriers, and can be sampled by what follows in the same frame). The first window pass clears
  with `begin_frame`'s colour (nil keeps what the image had).
* **Pipelines:** 3 shaders (textured, coverage, SDF; `.Solid` samples a 1 x 1 white texture) x 3 blends x 2 target formats,
  all made at startup. The shaders are SPIR-V assembled by `ren/vulkan/shaders/build_shaders.py` (the `.spvasm` files, with the
  GLSL they implement beside them): no SDK or glslc is needed to build, and `glslc` output could replace them.
* **Textures:** `texture_create` / `texture_update` return at once; the texels are staged and copied at the start of the next
  frame (or at `texture_read`). A texture made without pixels is cleared to transparent black. `texture_read` waits for the GPU
  and returns the texels: for tests, screenshots and comparing backends.
* **Colours** are written as given (UNORM swapchain formats, no sRGB conversion), blending is not gamma-corrected, so the
  CPU backend can match it exactly.
* **Resizing and minimizing:** the swapchain is made again when the surface's size changes; a minimized window returns
  `.Skipped`; a lost device returns `.Device_Lost` (destroy the renderer and make a new one).
* **Limits:** at most 2048 textures (one descriptor set each); each buffer and image has its own memory allocation (a
  sub-allocator is the first thing to add if that matters); no read-back of the window itself (draw into a target and
  `texture_read` it); `Native_Surface{kind = .None}` (headless) is not supported by this backend yet; surfaces: Win32 and Wayland.

## The seams that are still to be written

| need | where | when |
|---|---|---|
| Vulkan surface from a window | `ren/vulkan/ren_vulkan_windows.odin` `create_surface` | written (Win32) |
| OpenGL context from a window (WGL / EGL / NSOpenGL) | `platform`: `gl_create_context`, `gl_swap` (per OS: it is the platform's job) | with the OpenGL backend |
| CPU backend shows its pixels | `platform`: `present_pixels(window, pixels, w, h)` (`StretchDIBits`, `wl_shm`, a `CALayer`) | with the CPU backend |
| CPU backend draws to memory only | `Native_Surface{kind = .None}`: runs without a window: tests and screenshots | with the CPU backend |

## Linux (Wayland only)

`platform_linux.odin` talks to the compositor through libwayland-client (linked: Vulkan's Wayland WSI is handed the very
same `wl_display`, so the connection cannot be a private one). The protocol bindings that libwayland does not carry
(xdg-shell, xdg-decoration: their `wl_interface` tables, requests and listeners) are written by hand in `wayland_linux.odin`.
libxkbcommon (keymaps: which key is which letter, what it types) and libwayland-cursor (the pointer image) are loaded at run
time; without them keys are positional, no text is typed and the cursor image is the compositor's default.

* **One connection, many windows:** each window is an xdg_toplevel; `poll` reads the socket without blocking, runs the
  listeners and makes the key repeats (a Wayland program repeats keys itself, from the compositor's rate and delay).
* **Sizes:** `Window.size` is in buffer pixels = the compositor's logical size x the integer scale (from the monitors the
  window is on, or `wl_surface.preferred_buffer_scale`). The compositor chooses the size of a window; a program chooses it only
  by drawing at another size, which is what `set_size` and the Vulkan swapchain do. A window **appears when something is
  drawn into it** (the first buffer attached by the graphics backend), so the `.Hidden` window flag cannot be honoured, and a
  compositor like weston answers fullscreen / unfullscreen requests of a never-shown window only when it is first shown.
* **Decorations:** if the compositor offers xdg-decoration it draws the title bar (`Window.decorated`). GNOME does not: the
  window is bare, and a custom title bar and edges use `platform.begin_move` / `begin_resize` (Windows has them too).
* **Vulkan:** `ren/vulkan/ren_vulkan_linux.odin` (`libvulkan.so.1`, `VK_KHR_wayland_surface`). Which device can present is
  decided against the real surface, since Wayland can only answer for a given `wl_display`. A frame waits at most a second
  for an image (Wayland stops sending frame callbacks to a hidden window), then is skipped.
* **Not done:** fractional scales (wp_fractional_scale + wp_viewporter), IME and dead keys (text-input-v3), clipboard
  (wl_data_device), cursor shapes of the program's choice, touch, X11 (not planned).
* **Tested** under weston's headless backend with Mesa's lavapipe (a software Vulkan), including the whole path
  window -> swapchain -> draw -> read back, and fullscreen and back with the swapchain following. See `tools/linux_check`.

## What does not compile (on purpose)

What is not written yet fails at compile time with a message, instead of quietly doing nothing:

* **Unsupported operating systems:** `platform`, `ren/vulkan` and the `iv_system` glue have a `*_unsupported.odin` for every
  OS but Windows and Linux (`#+build !windows` and `!linux`), which is a `#panic`: building for macOS or a BSD stops with
  "this operating system is not supported yet". (`ren`, `iv_ui` and `iv_input` are plain Odin and compile everywhere.)
* **`ren/opengl` and `ren/software`:** the packages exist as placeholders that `#panic` when imported, with a comment on
  how each is to be written. They are not in `ren/auto`, and `ren.DEFAULT_ORDER` is `{.Vulkan}` for now (`ren.FULL_ORDER` is
  the whole design, which the tests of the choice logic use with fake backends). `Backend_Kind` still has `.OpenGL` and
  `.Software`, so that the interface and the order logic are already the final ones.

## Other operating systems

* **macOS:** `platform_darwin.odin` (Cocoa through Odin's Objective-C intrinsics). OpenGL there is frozen at 4.1 and
  Vulkan needs MoltenVK, so the real backend is Metal, which this design (a `Backend` interface) leaves room for.
* **Windows** has D3D11 as a more reliable middle step than OpenGL; it fits as another `Backend_Kind`.

## Known limits and decisions left

* Windows: frames stall while the title bar or an edge is dragged (Win32's modal loop); IME composition, clipboard and
  cursor shapes are missing.
* Vulkan needs 1.3 (dynamic rendering). Older drivers fall through to the next backend.
* Mailbox is not offered on every driver (not on the AMD one this was developed on): FIFO is used there, and logged.
* Undecided: a palette / 1-bit material for the game's look (a fixed material every backend implements), rounded
  rectangles and circles (today `draw_mesh`), render-target blending rules, pixel-center conventions for the CPU backend
  (to be fixed when it is written; it is the reference the others are tested against).

## Tests

```
odin test iv_system/ren          -define:ODIN_TEST_THREADS=1      draw list, batching, stacks, text, handles, backend choice (fake backends)
odin test iv_system/platform     -define:ODIN_TEST_THREADS=1      makes hidden windows and posts them key / mouse / close messages
odin test iv_system/ren/vulkan   -define:ODIN_TEST_THREADS=1      the probe, then every draw call on a real swapchain: render targets read back and checked pixel by pixel
```

On Linux the same commands run under a Wayland session (`WAYLAND_DISPLAY`; `weston --backend=headless --socket=wayland-test` is
enough, with Mesa's lavapipe for Vulkan); the window tests skip themselves without one. From Windows,
`tools/linux_check/run_in_wsl.sh` builds the tests as a plain program (Odin cannot link a Linux test runner when
cross-compiling), links it in WSL and runs it under a headless weston.
