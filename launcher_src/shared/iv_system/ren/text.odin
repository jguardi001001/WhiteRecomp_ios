package ren

import "core:math"
import ui "../../iv_ui"

// ---------------------------------------------------------------------------
// Text, drawn from a glyph table: pictures of the letters in an atlas texture and where each one goes. The renderer itself
// does not rasterize fonts. Two ways to make a Font:
//  * font_create: a table the program has (a bitmap font it made, an atlas of an asset);
//  * ren/ttf: a TrueType font, rasterized by stb_truetype at the size wanted, a glyph at a time as it is first drawn,
//    into an atlas texture (a one-channel .Coverage texture, which every backend can draw: the CPU one by copying
//    the coverage into the picture).
// `font_measure` has the shape ui.Text_Size_Proc wants, so the layout code of the `iv_ui` package measures with the
// same numbers that draw_text uses:
//
//   m := ui.Measure{size = ren.font_measure, user = font}
// ---------------------------------------------------------------------------

Glyph :: struct {
	codepoint: rune,
	src:       ui.Rect, // the glyph in the atlas, in texels
	offset:    [2]int, // from the pen position (the left end of the baseline's line box: its top) to the glyph's top left corner
	advance:   f32, // how far the pen moves (a fraction for a TrueType font; the pen is rounded to a whole pixel to draw)
}

Font_Desc :: struct {
	texture:     Texture, // the atlas (made with texture_create)
	atlas_size:  [2]int, // its size in texels (for the UVs)
	material:    Material, // .Coverage (R8 atlas), .Textured (RGBA atlas) or .Sdf
	line_height: int, // distance between lines
	ascent:      int, // from the top of a line to its baseline
	glyphs:      []Glyph,
	fallback:    rune, // drawn for a rune the table does not have (0 = skip it)
}

Font :: struct {
	texture:     Texture,
	atlas_size:  [2]int,
	material:    Material,
	line_height: int,
	ascent:      int,
	fallback:    rune,
	glyphs:      map[rune]Glyph,

	// For a font that makes its glyphs when they are first needed (ren/ttf): called for a rune that is not in `glyphs`; the
	// glyph it returns is kept. `kerning` (optional) is how far the pen moves besides the advance between two runes.
	provider:    proc(f: ^Font, c: rune) -> (Glyph, bool),
	kerning:     proc(f: ^Font, a, b: rune) -> f32,
	user:        rawptr, // the provider's own state
	on_destroy:  proc(f: ^Font), // (the provider's cleanup)
}

font_create :: proc(desc: Font_Desc, allocator := context.allocator) -> ^Font {
	f := new(Font, allocator)
	f.texture = desc.texture
	f.atlas_size = desc.atlas_size
	f.material = desc.material
	f.line_height = desc.line_height
	f.ascent = desc.ascent
	f.fallback = desc.fallback
	f.glyphs = make(map[rune]Glyph, allocator)
	for g in desc.glyphs {
		f.glyphs[g.codepoint] = g
	}
	return f
}

font_destroy :: proc(f: ^Font) {
	if f == nil {
		return
	}
	if f.on_destroy != nil {
		f.on_destroy(f)
	}
	delete(f.glyphs)
	free(f)
}

// The glyph of a rune: from the table, else from the font's provider, else the fallback's.
glyph_of :: proc(f: ^Font, c: rune) -> (g: Glyph, ok: bool) {
	if g, ok = f.glyphs[c]; ok {
		return
	}
	if f.provider != nil {
		if g, ok = f.provider(f, c); ok {
			f.glyphs[c] = g
			return
		}
	}
	if f.fallback != 0 && f.fallback != c {
		return glyph_of(f, f.fallback)
	}
	return {}, false
}

// The size of a text: the widest line, and (number of lines) * line height. A '\n' starts a new line.
// Has the shape of ui.Text_Size_Proc: `user` is the ^Font.
font_measure :: proc(user: rawptr, text: string) -> (w, h: int) {
	f := (^Font)(user)
	if f == nil {
		return 0, 0
	}
	line_w: f32
	widest: f32
	h = f.line_height
	previous: rune
	for c in text {
		if c == '\n' {
			widest = max(widest, line_w)
			line_w = 0
			previous = 0
			h += f.line_height
			continue
		}
		if g, ok := glyph_of(f, c); ok {
			if previous != 0 && f.kerning != nil {
				line_w += f.kerning(f, previous, c)
			}
			line_w += g.advance
		}
		previous = c
	}
	widest = max(widest, line_w)
	return int(math.ceil(widest)), h
}

// Draws a text with the top left corner of its first line at `pos`; returns the width of its widest line.
draw_text :: proc(dl: ^Draw_List, f: ^Font, text: string, pos: [2]int, color: Color) -> int {
	if f == nil {
		return 0
	}
	pen_x := f32(pos.x)
	line_y := pos.y
	widest: f32
	previous: rune
	for c in text {
		if c == '\n' {
			widest = max(widest, pen_x - f32(pos.x))
			pen_x = f32(pos.x)
			line_y += f.line_height
			previous = 0
			continue
		}
		g, ok := glyph_of(f, c)
		if !ok {
			previous = c
			continue
		}
		if previous != 0 && f.kerning != nil {
			pen_x += f.kerning(f, previous, c)
		}
		if !ui.is_empty(g.src) {
			x := int(math.round(pen_x)) + g.offset.x
			dst := ui.Rect{x, line_y + g.offset.y, g.src.w, g.src.h}
			draw_image(dl, f.texture, dst, uv_rect(g.src, f.atlas_size.x, f.atlas_size.y), color, f.material)
		}
		pen_x += g.advance
		previous = c
	}
	return int(math.ceil(max(widest, pen_x - f32(pos.x))))
}
