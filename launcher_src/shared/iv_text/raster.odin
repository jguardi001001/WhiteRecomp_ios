package iv_text

import "core:log"
import "core:math"
import stbtt "vendor:stb/truetype"
import ren "../iv_system/ren"
import ui "../iv_ui"

// ---------------------------------------------------------------------------
// The pictures of the letters. One Raster is one font of the stack at one pixel size: an atlas texture (R8, coverage) cut into square cells, each big
// enough for any glyph of that size, and an LRU cache that says which glyph is in which cell. A glyph is rasterized (by stb_truetype) into a cell the first
// time it is drawn; when every cell is taken the cell of the glyph that was used least recently is given to the new one. Cells never move and every glyph
// has the same kind of place, so nothing is packed again and nothing fragments.
//
// What was used in the current frame is not given up (the draw list of the frame points at it, and the texels are changed before the frame is drawn): if
// every cell was used in this frame the glyph is not drawn (and a warning is logged, once) instead of drawing the wrong letter. Make the atlas bigger
// for that (Font_Spec.atlas_size) or draw less at that size.
// ---------------------------------------------------------------------------

RASTER_PADDING :: 1 // texels round each glyph in its cell: the edge of a glyph never bleeds into the next one
RASTER_CELL :: 1.5 // the side of a cell in em: glyphs of the usual fonts are within one em of their origin, with some room for ones that hang out
RASTER_CELLS_MIN :: 64 // an atlas for a big size is made bigger (by doubling) until it has this many cells

// Where a glyph is in the atlas.
Glyph_Image :: struct {
	cell:   i32, // the number of its cell
	src:    ui.Rect, // in the atlas, in texels (empty: the glyph has no picture, a space)
	offset: [2]int, // from the pen position (x) and the baseline (y) to the top left corner of the picture
}

Raster :: struct {
	source:     int, // index in Typeface.sources
	px:         i32, // the em in pixels
	scale:      f32, // stb's scale: pixels per font unit
	atlas:      ren.Texture,
	atlas_size: int, // the side of the atlas in texels
	cell:       [2]int, // the size of a cell in texels (with the padding)
	cols:       int,
	cells:      int, // cols * rows
	next_cell:  int, // the cells below this one have been used; the ones above never
	free_cells: [dynamic]i32, // cells that were given up and are not in use now
	glyphs:     Lru(Glyph_Image), // as many places as there are cells
	used:       u64, // the frame this raster was last asked for (typeface.frame)
	warned:     bool, // the "no room" warning was given
}

// The raster of a font of the stack at the em `em_px` (made the first time; the one used longest ago is dropped when there are too many sizes).
@(private)
raster_at :: proc(tf: ^Typeface, source: int, em_px: f32) -> ^Raster {
	s := &tf.sources[source]
	px := max(i32(math.round(em_px)), 4)
	if r, ok := s.rasters[px]; ok {
		r.used = tf.frame
		return r
	}
	if len(s.rasters) >= TYPEFACE_SIZES_KEEP {
		drop_oldest_raster(tf, s)
	}
	r := raster_make(tf, source, px)
	if r != nil {
		s.rasters[px] = r
	}
	return r
}

// Moves the raster that was asked for longest ago to the dead ones (unless every one was asked for in this frame).
@(private)
drop_oldest_raster :: proc(tf: ^Typeface, s: ^Source) {
	oldest_px: i32 = -1
	oldest: ^Raster
	for px, r in s.rasters {
		if oldest == nil || r.used < oldest.used {
			oldest, oldest_px = r, px
		}
	}
	if oldest != nil && oldest.used < tf.frame {
		append(&tf.dead, oldest)
		delete_key(&s.rasters, oldest_px)
	}
}

@(private)
raster_make :: proc(tf: ^Typeface, source: int, px: i32) -> ^Raster {
	s := &tf.sources[source]
	side := int(math.ceil(f32(px) * RASTER_CELL)) + 2 * RASTER_PADDING
	atlas_size := s.atlas_size
	for (atlas_size / side) * (atlas_size / side) < RASTER_CELLS_MIN && atlas_size < 4096 {
		atlas_size *= 2
	}
	cols := atlas_size / side
	if cols < 1 {
		log.errorf("iv_text: a %d px glyph does not fit in an atlas of %d", px, atlas_size)
		return nil
	}
	atlas, ok := ren.texture_create(tf.renderer, {width = atlas_size, height = atlas_size, format = .R8, filter = .Nearest, use = {.Dynamic}})
	if !ok {
		log.error("iv_text: the renderer could not make a glyph atlas")
		return nil
	}
	r := new(Raster, tf.allocator)
	r.source = source
	r.px = px
	r.scale = f32(px) / s.metrics.upem
	r.atlas = atlas
	r.atlas_size = atlas_size
	r.cell = {side, side}
	r.cols = cols
	r.cells = cols * cols
	r.free_cells = make([dynamic]i32, tf.allocator)
	r.used = tf.frame
	lru_init(&r.glyphs, r.cells, tf.allocator)
	return r
}

@(private)
raster_destroy :: proc(tf: ^Typeface, r: ^Raster) {
	if r == nil {
		return
	}
	ren.texture_destroy(tf.renderer, r.atlas)
	lru_destroy(&r.glyphs)
	delete(r.free_cells)
	free(r, tf.allocator)
}

// Where the picture of a glyph is: from the cache, or rasterized into a cell now. ok = false when it cannot be drawn (too big for a cell, or no cell
// that was not used in this frame). A glyph with no picture (a space) is ok with an empty `src`.
@(private)
raster_glyph :: proc(tf: ^Typeface, ras: ^Raster, c: rune) -> (img: Glyph_Image, ok: bool) {
	if g := lru_get(&ras.glyphs, c, tf.frame); g != nil {
		return g^, true
	}
	s := &tf.sources[ras.source]
	x0, y0, x1, y1: i32
	stbtt.GetCodepointBitmapBox(&s.metrics.info, c, ras.scale, ras.scale, &x0, &y0, &x1, &y1)
	w, h := int(x1 - x0), int(y1 - y0)
	if w <= 0 || h <= 0 { // a space: it moves the pen and has no picture
		return {}, true
	}
	if w + 2 * RASTER_PADDING > ras.cell.x || h + 2 * RASTER_PADDING > ras.cell.y {
		if !ras.warned {
			ras.warned = true
			log.warnf("iv_text: a glyph of %dx%d px does not fit in a cell of %dx%d (U+%04X): it is not drawn", w, h, ras.cell.x, ras.cell.y, u32(c))
		}
		return {}, false
	}

	// a cell: one given up before, else one never used, else the one of the glyph used longest ago (unless that was used in this frame)
	cell: i32 = -1
	if len(ras.free_cells) > 0 {
		cell = pop(&ras.free_cells)
	} else if ras.next_cell < ras.cells {
		cell = i32(ras.next_cell)
		ras.next_cell += 1
	} else {
		_, old, used, has := lru_oldest(&ras.glyphs)
		if !has || used >= tf.frame {
			if !ras.warned {
				ras.warned = true
				log.warnf("iv_text: the %dx%d glyph atlas has no cell that was not used in this frame (%d cells): glyphs that are not in it yet are not drawn", ras.atlas_size, ras.atlas_size, ras.cells)
			}
			return {}, false
		}
		cell = old.cell
		lru_evict_oldest(&ras.glyphs)
	}

	pixels := make([]u8, w * h, context.temp_allocator)
	stbtt.MakeCodepointBitmap(&s.metrics.info, raw_data(pixels), i32(w), i32(h), i32(w), ras.scale, ras.scale, c)
	cx, cy := int(cell) % ras.cols, int(cell) / ras.cols
	region := ui.Rect{cx * ras.cell.x + RASTER_PADDING, cy * ras.cell.y + RASTER_PADDING, w, h}
	if !ren.texture_update(tf.renderer, ras.atlas, region, pixels) {
		append(&ras.free_cells, cell) // (the cell is still free)
		return {}, false
	}
	img = Glyph_Image {
		cell   = cell,
		src    = region,
		offset = {int(x0), int(y0)},
	}
	lru_add(&ras.glyphs, c, img, tf.frame)
	return img, true
}
