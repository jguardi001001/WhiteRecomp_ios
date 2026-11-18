package main

import "core:math"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

import ui "shared:iv_ui"

// ---------------------------------------------------------------------------
// Drawing: thin helpers over raylib at the real resolution of the window.
//
// All layout is done in integer "logical" pixels. ui_scale (a number like 1, 1.25, 2) turns
// them into device pixels, so the whole interface scales with the display and with F11 / F12
// while the text stays sharp: every font is baked at its exact device size (fonts_load).
// Rectangles are x, y, width, height. Colors are rl.Color.
// ---------------------------------------------------------------------------

Color :: rl.Color

// The rectangle type and all the rectangle math (inset, cut, center, ...) are the shared `ui` package's: it does no drawing.
Rect :: ui.Rect

win_w, win_h: int // the window in logical pixels
ui_scale: f32 = 1

// A logical coordinate in device pixels (rounded, so neighbouring rectangles tile without gaps).
dev :: #force_inline proc(v: int) -> i32 {
	return i32(math.floor(f32(v) * ui_scale + 0.5))
}

// Thickness of a "one pixel" line in device pixels.
line_px :: #force_inline proc() -> i32 {
	return max(1, i32(ui_scale))
}

// ---- colors ---------------------------------------------------------------------------------

with_alpha :: proc(c: Color, a: f32) -> Color {
	return Color{c.r, c.g, c.b, u8(clamp(f32(c.a) * a, 0, 255))}
}

mix :: proc(a, b: Color, t: f32) -> Color {
	k := clamp(t, 0, 1)
	return Color {
		u8(f32(a.r) + (f32(b.r) - f32(a.r)) * k),
		u8(f32(a.g) + (f32(b.g) - f32(a.g)) * k),
		u8(f32(a.b) + (f32(b.b) - f32(a.b)) * k),
		u8(f32(a.a) + (f32(b.a) - f32(a.a)) * k),
	}
}

lighten :: proc(c: Color, t: f32) -> Color {
	return mix(c, Color{255, 255, 255, c.a}, t)
}

darken :: proc(c: Color, t: f32) -> Color {
	return mix(c, Color{0, 0, 0, c.a}, t)
}

// ---- clipping (a scissor rectangle) -------------------------------------------------------------

Clip :: struct {
	x0, y0, x1, y1: int,
}

clip: Clip

clip_apply :: proc() {
	x0 := dev(clip.x0)
	y0 := dev(clip.y0)
	rl.BeginScissorMode(x0, y0, max(dev(clip.x1) - x0, 0), max(dev(clip.y1) - y0, 0))
}

clip_reset :: proc() {
	clip = Clip{0, 0, win_w, win_h}
	clip_apply()
}

// Restrict drawing to `r` (inside the current clip); returns the old clip to give back to clip_restore.
clip_to :: proc(r: Rect) -> Clip {
	old := clip
	clip = Clip{max(r.x, old.x0), max(r.y, old.y0), min(r.x + r.w, old.x1), min(r.y + r.h, old.y1)}
	clip_apply()
	return old
}

clip_restore :: proc(c: Clip) {
	clip = c
	clip_apply()
}

rect_visible :: proc(r: Rect) -> bool {
	return r.x < clip.x1 && r.x + r.w > clip.x0 && r.y < clip.y1 && r.y + r.h > clip.y0
}

// ---- shapes ---------------------------------------------------------------------------------------

fill :: proc(r: Rect, c: Color) {
	if r.w <= 0 || r.h <= 0 || c.a == 0 || !rect_visible(r) {
		return
	}
	x0 := dev(r.x)
	y0 := dev(r.y)
	rl.DrawRectangle(x0, y0, max(dev(r.x + r.w) - x0, 1), max(dev(r.y + r.h) - y0, 1), c)
}

// Horizontal line from x0 to x1 inclusive, one pixel thick.
hline :: proc(x0, x1, y: int, c: Color) {
	a := min(x0, x1)
	b := max(x0, x1)
	if c.a == 0 || y < clip.y0 - 1 || y >= clip.y1 || b < clip.x0 || a >= clip.x1 {
		return
	}
	px := dev(max(a, clip.x0 - 1))
	rl.DrawRectangle(px, dev(y), max(dev(min(b, clip.x1) + 1) - px, 1), line_px(), c)
}

vline :: proc(x, y0, y1: int, c: Color) {
	a := min(y0, y1)
	b := max(y0, y1)
	if c.a == 0 || x < clip.x0 - 1 || x >= clip.x1 || b < clip.y0 || a >= clip.y1 {
		return
	}
	py := dev(max(a, clip.y0 - 1))
	rl.DrawRectangle(dev(x), py, line_px(), max(dev(min(b, clip.y1) + 1) - py, 1), c)
}

// A one pixel outline inside the rectangle.
frame :: proc(r: Rect, c: Color) {
	if r.w <= 0 || r.h <= 0 || c.a == 0 || !rect_visible(r) {
		return
	}
	x0 := dev(r.x)
	y0 := dev(r.y)
	x1 := dev(r.x + r.w)
	y1 := dev(r.y + r.h)
	t := line_px()
	rl.DrawRectangle(x0, y0, x1 - x0, t, c)
	rl.DrawRectangle(x0, y1 - t, x1 - x0, t, c)
	rl.DrawRectangle(x0, y0 + t, t, max(y1 - y0 - 2 * t, 0), c)
	rl.DrawRectangle(x1 - t, y0 + t, t, max(y1 - y0 - 2 * t, 0), c)
}

gradient_v :: proc(r: Rect, top, bottom: Color) {
	if r.w <= 0 || r.h <= 0 || !rect_visible(r) {
		return
	}
	x0 := dev(r.x)
	y0 := dev(r.y)
	rl.DrawRectangleGradientV(x0, y0, max(dev(r.x + r.w) - x0, 1), max(dev(r.y + r.h) - y0, 1), top, bottom)
}

gradient_h :: proc(r: Rect, left, right: Color) {
	if r.w <= 0 || r.h <= 0 || !rect_visible(r) {
		return
	}
	x0 := dev(r.x)
	y0 := dev(r.y)
	rl.DrawRectangleGradientH(x0, y0, max(dev(r.x + r.w) - x0, 1), max(dev(r.y + r.h) - y0, 1), left, right)
}

round_rec :: proc(r: Rect, radius: int) -> (rec: rl.Rectangle, roundness: f32) {
	x0 := dev(r.x)
	y0 := dev(r.y)
	w := max(dev(r.x + r.w) - x0, 1)
	h := max(dev(r.y + r.h) - y0, 1)
	rec = rl.Rectangle{f32(x0), f32(y0), f32(w), f32(h)}
	roundness = clamp(f32(radius) * ui_scale * 2 / f32(min(w, h)), 0, 1)
	return
}

fill_round :: proc(r: Rect, radius: int, c: Color) {
	if r.w <= 0 || r.h <= 0 || c.a == 0 || !rect_visible(r) {
		return
	}
	if radius <= 0 || r.w < 3 || r.h < 3 {
		fill(r, c)
		return
	}
	rec, k := round_rec(r, radius)
	rl.DrawRectangleRounded(rec, k, 6, c)
}

frame_round :: proc(r: Rect, radius: int, c: Color) {
	if r.w <= 0 || r.h <= 0 || c.a == 0 || !rect_visible(r) {
		return
	}
	if radius <= 0 || r.w < 3 || r.h < 3 {
		frame(r, c)
		return
	}
	rec, k := round_rec(r, radius)
	rl.DrawRectangleRoundedLinesEx(rec, k, 6, f32(line_px()), c)
}

circle :: proc(cx, cy: int, radius: f32, c: Color) {
	if c.a == 0 {
		return
	}
	rl.DrawCircleV(rl.Vector2{f32(dev(cx)), f32(dev(cy))}, radius * ui_scale, c)
}

// A filled triangle (the corners in any order), in logical coordinates.
triangle :: proc(ax, ay, bx, by, cx, cy: f32, c: Color) {
	a := rl.Vector2{ax * ui_scale, ay * ui_scale}
	b := rl.Vector2{bx * ui_scale, by * ui_scale}
	d := rl.Vector2{cx * ui_scale, cy * ui_scale}
	area := (b.x - a.x) * (d.y - a.y) - (d.x - a.x) * (b.y - a.y)
	if area > 0 {
		rl.DrawTriangle(a, d, b, c)
	} else {
		rl.DrawTriangle(a, b, d, c)
	}
}

// A soft drop shadow around a rectangle (drawn before the rectangle itself).
shadow :: proc(r: Rect, radius: int, size: int, strength: f32 = 0.45) {
	steps := 6
	layer := u8(clamp(strength * 255 / f32(steps) * 0.8, 1, 255))
	for i in 0 ..< steps { // from the widest, faintest layer in to the narrowest
		g := size * (steps - i) / steps
		fill_round(Rect{r.x - g, r.y - g + size / 3, r.w + 2 * g, r.h + 2 * g}, radius + g, Color{0, 0, 0, layer})
	}
}

// ---- fonts ----------------------------------------------------------------------------------------

Font_Id :: enum {
	Ui,
	Bold,
	Small,
	Mono,
	Mono_Big,
}

FONT_SIZE := [Font_Id]int {
	.Ui       = 13,
	.Bold     = 13,
	.Small    = 12,
	.Mono     = 13,
	.Mono_Big = 20,
}

Fnt :: struct {
	font:    rl.Font,
	px:      int, // baked size in device pixels
	cap_off: i32, // from the top of the text box down to the top of a capital letter
	cap_h:   i32, // height of a capital letter
	adv:     [256]f32, // advance widths in device pixels, indexed by character (32..255)
}

fonts: [Font_Id]Fnt
fonts_ready: bool

// The embedded font is the last resort (no system font found).
FONT_FALLBACK := #load("fonts/LiberationSans-Bold.ttf")

FONT_FILES_UI := [?]string{"C:/Windows/Fonts/segoeui.ttf", "C:/Windows/Fonts/arial.ttf", "/System/Library/Fonts/Supplemental/Arial.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"}
FONT_FILES_BOLD := [?]string{"C:/Windows/Fonts/segoeuib.ttf", "C:/Windows/Fonts/arialbd.ttf", "/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"}
FONT_FILES_MONO := [?]string{"C:/Windows/Fonts/consola.ttf", "C:/Windows/Fonts/cour.ttf", "/System/Library/Fonts/Menlo.ttc", "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"}

font_files :: proc(id: Font_Id) -> []string {
	switch id {
	case .Ui, .Small:
		return FONT_FILES_UI[:]
	case .Bold:
		return FONT_FILES_BOLD[:]
	case .Mono, .Mono_Big:
		return FONT_FILES_MONO[:]
	}
	return nil
}

fonts_unload :: proc() {
	if !fonts_ready {
		return
	}
	for &f in fonts {
		rl.UnloadFont(f.font)
		f = {}
	}
	fonts_ready = false
}

// (Re)loads every font at the size the current ui_scale asks for.
fonts_load :: proc() {
	fonts_unload()
	// Printable ASCII and Latin-1 (127..159 are control characters).
	cps: [(127 - 32) + (256 - 160)]rune
	n := 0
	for c in 32 ..< 127 {
		cps[n] = rune(c)
		n += 1
	}
	for c in 160 ..< 256 {
		cps[n] = rune(c)
		n += 1
	}
	default_tex := rl.GetFontDefault().texture.id
	for id in Font_Id {
		f := &fonts[id]
		f.px = max(int(math.round(f32(FONT_SIZE[id]) * ui_scale)), 6)
		loaded := false
		for path in font_files(id) {
			if !os.exists(path) {
				continue
			}
			font := rl.LoadFontEx(strings.clone_to_cstring(path, context.temp_allocator), i32(f.px), raw_data(cps[:]), i32(len(cps)))
			if font.texture.id != 0 && font.texture.id != default_tex { // (a failed load gives the built-in font)
				f.font = font
				loaded = true
				break
			}
		}
		if !loaded {
			f.font = rl.LoadFontFromMemory(".ttf", raw_data(FONT_FALLBACK), i32(len(FONT_FALLBACK)), i32(f.px), raw_data(cps[:]), i32(len(cps)))
		}
		rl.SetTextureFilter(f.font.texture, .BILINEAR)
		gi := rl.GetGlyphIndex(f.font, 'H')
		f.cap_off = f.font.glyphs[gi].offsetY
		f.cap_h = i32(f.font.recs[gi].height)
		for c in 32 ..< 256 {
			adv := rl.GetGlyphInfo(f.font, rune(c)).advanceX
			if adv == 0 {
				adv = i32(f.font.recs[rl.GetGlyphIndex(f.font, rune(c))].width)
			}
			f.adv[c] = f32(adv)
		}
	}
	fonts_ready = true
}

ui_set_scale :: proc(s: f32) {
	ui_scale = clamp(math.round(s * 4) / 4, 1, 3)
	if fonts_ready {
		fonts_load()
	}
}

// ---- text -------------------------------------------------------------------------------------------

Align :: enum {
	Left,
	Center,
	Right,
}

glyph_adv :: #force_inline proc(f: ^Fnt, cp: rune) -> f32 {
	if cp >= 32 && cp < 256 {
		return f.adv[cp]
	}
	return f.adv['?']
}

// Width of a text in device pixels.
text_width_dev :: proc(s: string, id := Font_Id.Ui) -> f32 {
	f := &fonts[id]
	w: f32 = 0
	for cp in s {
		if cp >= 32 {
			w += glyph_adv(f, cp)
		}
	}
	return w
}

// Width of a text in logical pixels.
text_width :: proc(s: string, id := Font_Id.Ui) -> int {
	return int(math.ceil(text_width_dev(s, id) / ui_scale))
}

// How the shared `ui` package measures text for this program: the width of a line in the interface font and the height of
// its capitals, in logical pixels. Pass it to ui.text_rect, ui.hug, ui.wrap_rect and the others.
text_measure :: ui.Measure {
	size = proc(user: rawptr, s: string) -> (w, h: int) {
		return text_width(s), cap_height()
	},
}

// Height of a capital letter in logical pixels (rounded up).
cap_height :: proc(id := Font_Id.Ui) -> int {
	return int(math.ceil(f32(fonts[id].cap_h) / ui_scale))
}

// The text with characters the fonts do not have replaced by '?' and control characters removed
// (a temporary C string).
text_cstring :: proc(s: string) -> cstring {
	b: [dynamic]u8
	b.allocator = context.temp_allocator
	for cp in s {
		if cp < 32 {
			continue
		}
		if cp >= 256 {
			append(&b, '?')
		} else {
			buf, n := utf8.encode_rune(cp)
			append(&b, ..buf[:n])
		}
	}
	append(&b, 0)
	return cstring(raw_data(b))
}

// Draws at device coordinates, `dy` being the top of the capital letters.
text_dev :: proc(dx, dy: i32, s: string, c: Color, id: Font_Id) {
	if len(s) == 0 || c.a == 0 {
		return
	}
	f := &fonts[id]
	if int(dx) >= int(f32(clip.x1) * ui_scale) || int(dy) >= int(f32(clip.y1) * ui_scale) || int(dy) + f.px < int(f32(clip.y0) * ui_scale) {
		return
	}
	rl.DrawTextEx(f.font, text_cstring(s), rl.Vector2{f32(dx), f32(dy - f.cap_off)}, f32(f.px), 0, c)
}

// Draws `s` with the top of its capital letters at (x, y); returns the x after the last character.
text :: proc(x, y: int, s: string, c: Color, id := Font_Id.Ui) -> int {
	text_dev(dev(x), dev(y), s, c, id)
	return x + text_width(s, id)
}

// The longest start of `s` that fits `max_dev` device pixels (with ".." in place of the cut-off end).
fit_text :: proc(s: string, max_dev: f32, id: Font_Id) -> string {
	if text_width_dev(s, id) <= max_dev {
		return s
	}
	f := &fonts[id]
	dots := glyph_adv(f, '.') * 3
	acc: f32 = 0
	end := 0
	for i := 0; i < len(s); {
		cp, sz := utf8.decode_rune_in_string(s[i:])
		w := glyph_adv(f, cp)
		if acc + w + dots > max_dev {
			break
		}
		acc += w
		i += sz
		end = i
	}
	return strings.concatenate({s[:end], "..."}, context.temp_allocator)
}

// Draws `s` cut to `max_w` logical pixels.
text_fit :: proc(x, y: int, s: string, max_w: int, c: Color, id := Font_Id.Ui) -> int {
	if max_w <= 0 {
		return x
	}
	t := fit_text(s, f32(max_w) * ui_scale, id)
	return text(x, y, t, c, id)
}

// Draws `s` vertically centered in `r` (by the height of its capitals) and aligned horizontally, `pad`
// pixels from the edge. Long text is cut. Returns the x after the text.
text_in :: proc(r: Rect, s: string, c: Color, id := Font_Id.Ui, align := Align.Left, pad := 6) -> int {
	if len(s) == 0 || r.w <= 0 {
		return r.x + pad
	}
	f := &fonts[id]
	avail := f32(dev(r.x + r.w - pad) - dev(r.x + pad))
	t := fit_text(s, avail, id)
	w := text_width_dev(t, id)
	y0 := dev(r.y)
	y1 := dev(r.y + r.h)
	dy := y0 + (y1 - y0 - f.cap_h) / 2
	dx: i32
	switch align {
	case .Left:
		dx = dev(r.x + pad)
	case .Center:
		dx = dev(r.x) + i32((f32(dev(r.x + r.w) - dev(r.x)) - w) / 2)
	case .Right:
		dx = dev(r.x + r.w - pad) - i32(w)
	}
	text_dev(dx, dy, t, c, id)
	return int(math.round((f32(dx) + w) / ui_scale))
}

// The height in logical pixels of a line of text in a list (a comfortable row).
row_height :: proc(id := Font_Id.Ui) -> int {
	return FONT_SIZE[id] + 11
}
