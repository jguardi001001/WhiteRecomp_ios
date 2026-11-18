// Text for programs: TrueType text laid out in a way that does not depend on the pixel size, drawn into a ren.Draw_List.
//
//   tf: iv_text.Typeface
//   iv_text.typeface_init(&tf, &renderer)
//   iv_text.typeface_set_fonts(&tf, {                                  // the font stack, first = highest priority
//       {data = LATIN_TTF},                                            // the main font: it sets the line height
//       {data = JAPANESE_TTF, em_scale = 0.85},                        // used for the characters the one before it has no glyph for, and so on
//       {data = SYMBOLS_TTF},
//   })
//   iv_text.set_furigana(&tf, true)                                    // readings above the letters on or off (see ruby.odin)
//   w := iv_text.width(&tf, "Hello", 18)                               // 18 = the em, in pixels of the target
//   iv_text.draw(dl, &tf, "漢{{かん}}字{{じ}}", {20, 40}, 18, ren.WHITE)    // (x, y) is the top left of the line
//   iv_text.typeface_frame_end(&tf)                                    // after ren.end_frame: once a frame
//
// What it adds to ren_ttf:
//  * A font stack: several fonts as one. Each character comes from the first font of the stack that has it (Latin, then Japanese, then symbols ...), each
//    with its own relative size. The stack is the program's to change at any time (`typeface_set_fonts`: a game that shows Japanese first when the language
//    is Japanese); the fonts are the bytes of .ttf files that the program keeps alive (a #load is fine).
//  * Two caches, both with a fixed size that does not grow whatever the text:
//      - which font a character comes from and its advance (the fonts' tables are searched one after the other: slow for a character that only the last
//        font has), the most recently used `glyph_cache` characters;
//      - the pictures of the letters, in an atlas texture for each font and pixel size, the glyphs that were used last. When the atlas is full the one
//        used longest ago is replaced by the new one: the text on the screen never stops being drawn because an earlier screen filled the atlas. (A glyph
//        that has been drawn in the current frame is never replaced: it is already in the frame's draw list. So `typeface_frame_end` must be called each frame,
//        and an atlas must have room for the glyphs of one frame: see Font_Spec.atlas_size.)
//  * Widths are worked out from the font's advances in em, not from the glyphs of one pixel size: the same text is laid out the same at every size and
//    scale (a screen does not jump about as a window is resized), measuring needs no GPU, and a size can be any number (the fonts are made at the nearest
//    whole pixel size, kept for next time).
//  * Wrapping, splitting and cursor placement (x_at, byte_near) that agree with what draw does.
//  * Readings (furigana / ruby): a reading written after a letter in double braces, "漢{{かん}}字{{じ}}", is drawn small above it when `furigana` is on, and
//    is left out when it is off; either way it takes no room in the line. See ruby.odin.
//  * A ui.Measure of the typeface (measure_of), so the layout of iv_ui measures with the numbers draw uses.
//
// Not done: shaping (a character is a glyph: no ligatures, no right-to-left, no combining marks), kerning (so that widths stay the same at every
// size), sub-pixel glyph positions, colour fonts.
package iv_text

import "base:runtime"
import "core:math"
import ren "../iv_system/ren"
import ren_ttf "../iv_system/ren/ttf"

TYPEFACE_SIZES_KEEP :: 48 // pixel sizes of one font kept at most (the one used longest ago is dropped)
GLYPH_CACHE_DEFAULT :: 4096 // characters whose font is remembered
ATLAS_SIZE_DEFAULT :: 1024

// A font of the stack, as `typeface_set_fonts` takes it.
Font_Spec :: struct {
	data:       []u8, // the .ttf bytes: they must stay as they are while the typeface lives (a #load is fine)
	em_scale:   f32, // the size of this font's em relative to the typeface's (a Japanese font looks big at the same em: 0.85); 0 = 1
	dy:         f32, // how far down this font's letters sit from the common baseline, in em of the typeface
	atlas_size: int, // the side of the atlas of one pixel size of this font, in texels; 0 = ATLAS_SIZE_DEFAULT (1024: some 1200 glyphs at 18 px)
}

// A font of the typeface.
Source :: struct {
	data:       []u8,
	em_scale:   f32,
	dy:         f32,
	atlas_size: int,
	metrics:    ren_ttf.Metrics,
	ascent:     f32, // em (of this font, before em_scale)
	descent:    f32,
	line_gap:   f32,
	rasters:    map[i32]^Raster, // by pixel size, made the first time they are drawn
}

// Which font draws a character, and its advance (in em of the typeface).
Glyph_Info :: struct {
	source: i16, // index in sources; -1: no font has it
	adv:    f32,
	drawn:  rune, // the character that is drawn: `r`, or '?' when no font has `r`
}

Typeface :: struct {
	renderer:   ^ren.Renderer,
	sources:    [dynamic]Source,
	glyphs:     Lru(Glyph_Info), // which font draws which character (the recently used ones)
	dead:       [dynamic]^Raster, // atlases that were dropped: kept until the frame that may use them is done
	frame:      u64, // the number of frames done (typeface_frame_end): what the caches stamp their uses with
	furigana:   bool, // draw the readings above the letters (see ruby.odin)
	ruby_scale: f32, // the em of a reading relative to the letter's em
	ruby_gap:   f32, // how far the bottom of a reading is above the top of the letters, in em
	literal:    bool, // "{{" is not a reading, only two letters (an editor that shows raw text sets this)
	allocator:  runtime.Allocator,
}

// `glyph_cache`: how many characters' fonts are remembered (a Japanese game uses a few thousand).
typeface_init :: proc(tf: ^Typeface, r: ^ren.Renderer, glyph_cache := GLYPH_CACHE_DEFAULT, allocator := context.allocator) {
	tf.renderer = r
	tf.allocator = allocator
	tf.sources = make([dynamic]Source, allocator)
	tf.dead = make([dynamic]^Raster, allocator)
	lru_init(&tf.glyphs, glyph_cache, allocator)
	tf.ruby_scale = 0.5
	tf.ruby_gap = 0.05
}

typeface_destroy :: proc(tf: ^Typeface) {
	typeface_clear_fonts(tf)
	for r in tf.dead {
		raster_destroy(tf, r)
	}
	delete(tf.sources)
	delete(tf.dead)
	lru_destroy(&tf.glyphs)
	tf^ = {}
}

// Turns the readings on or off: with them on `draw` puts each reading above its letter (leave room for them: ruby_room), with them off the readings
// are left out as if the text did not have them. Text that is laid out (widths, wrapping) is the same either way.
set_furigana :: proc(tf: ^Typeface, on: bool) {
	tf.furigana = on
}

// ---- the font stack --------------------------------------------------------------------------------------------------------------

// Adds a font at the end of the stack (the lowest priority so far). The first one added is the main one: its ascent and descent decide the line height
// and where the baseline is. false if the bytes are not a TrueType font (it is not added).
typeface_add :: proc(tf: ^Typeface, data: []u8, em_scale: f32 = 1, dy: f32 = 0, atlas_size := ATLAS_SIZE_DEFAULT) -> (index: int, ok: bool) {
	s := Source {
		data       = data,
		em_scale   = em_scale if em_scale > 0 else 1,
		dy         = dy,
		atlas_size = atlas_size if atlas_size > 0 else ATLAS_SIZE_DEFAULT,
	}
	if !looks_like_a_font(data) || !ren_ttf.metrics_init(&s.metrics, data) {
		return -1, false
	}
	s.ascent, s.descent, s.line_gap = ren_ttf.metrics_vertical(&s.metrics)
	s.rasters = make(map[i32]^Raster, tf.allocator)
	append(&tf.sources, s)
	lru_clear(&tf.glyphs) // (a character may now come from this font)
	return len(tf.sources) - 1, true
}

// Makes the stack these fonts, in this order (the first has the highest priority), instead of what it was: every picture and every remembered font of
// a character is forgotten. A spec whose bytes are not a font is left out. Returns how many were added. Call it with no fonts to empty the stack.
typeface_set_fonts :: proc(tf: ^Typeface, specs: []Font_Spec) -> (added: int) {
	typeface_clear_fonts(tf)
	for spec in specs {
		if _, ok := typeface_add(tf, spec.data, spec.em_scale, spec.dy, spec.atlas_size); ok {
			added += 1
		}
	}
	return
}

// Takes every font out of the stack. (The atlases wait for the end of the frame to be freed: a glyph drawn earlier in the frame may still use one.)
typeface_clear_fonts :: proc(tf: ^Typeface) {
	for &s in tf.sources {
		for _, r in s.rasters {
			append(&tf.dead, r)
		}
		delete(s.rasters)
	}
	clear(&tf.sources)
	lru_clear(&tf.glyphs)
}

// A cheap check of the start of the file (stb_truetype does not check what it is given): TrueType, OpenType with outlines, or a collection.
@(private)
looks_like_a_font :: proc(data: []u8) -> bool {
	if len(data) < 64 {
		return false
	}
	true_type := data[0] == 0 && data[1] == 1 && data[2] == 0 && data[3] == 0
	tag := string(data[:4])
	return true_type || tag == "true" || tag == "OTTO" || tag == "ttcf"
}

// Call once a frame after the frame is made (ren.end_frame): frees the atlases that were dropped, and starts the next frame for the caches (what was
// used in a frame is not replaced during it).
typeface_frame_end :: proc(tf: ^Typeface) {
	for r in tf.dead {
		raster_destroy(tf, r)
	}
	clear(&tf.dead)
	tf.frame += 1
}

// ---- which font draws what -------------------------------------------------------------------------------------------------------

// The font that draws `r` (the first that has it; if none has it, the one that has '?') and its advance in em. source -1 when there is no font at all.
glyph_info :: proc(tf: ^Typeface, r: rune) -> Glyph_Info {
	if g := lru_get(&tf.glyphs, r, tf.frame); g != nil {
		return g^
	}
	g := Glyph_Info {
		source = -1,
	}
	for &s, i in tf.sources {
		if adv, has := ren_ttf.metrics_advance(&s.metrics, r); has {
			g = {i16(i), adv * s.em_scale, r}
			break
		}
	}
	if g.source < 0 && r != '?' {
		g = glyph_info(tf, '?')
	}
	if len(tf.glyphs.nodes) > 0 {
		if lru_full(&tf.glyphs) {
			lru_evict_oldest(&tf.glyphs)
		}
		if lru_get(&tf.glyphs, r, tf.frame) == nil { // ('?' may have just been added, as r itself)
			lru_add(&tf.glyphs, r, g, tf.frame)
		}
	}
	return g
}

// Does some font of the typeface have a glyph for `r`? (What a text field may accept.)
has_glyph :: proc(tf: ^Typeface, r: rune) -> bool {
	for &s in tf.sources {
		if _, has := ren_ttf.metrics_advance(&s.metrics, r); has {
			return true
		}
	}
	return false
}

// The advance of `r` in px at the em `size`.
advance :: proc(tf: ^Typeface, r: rune, size: f32) -> f32 {
	return glyph_info(tf, r).adv * size
}

// ---- vertical measures -----------------------------------------------------------------------------------------------------------

// From the top of a line to its baseline, in px (rounded).
ascent :: proc(tf: ^Typeface, size: f32) -> int {
	if len(tf.sources) == 0 {
		return 0
	}
	s := &tf.sources[0]
	return int(math.round(s.ascent * s.em_scale * size))
}

// How far letters hang below the baseline, in px (rounded up).
descent :: proc(tf: ^Typeface, size: f32) -> int {
	if len(tf.sources) == 0 {
		return 0
	}
	s := &tf.sources[0]
	return int(math.ceil(s.descent * s.em_scale * size))
}

// The height of one line of letters: ascent + descent + the font's line gap. (Readings are not in it: see ruby_height.)
line_height :: proc(tf: ^Typeface, size: f32) -> int {
	if len(tf.sources) == 0 {
		return 0
	}
	s := &tf.sources[0]
	return int(math.ceil((s.ascent + s.descent + s.line_gap) * s.em_scale * size))
}
