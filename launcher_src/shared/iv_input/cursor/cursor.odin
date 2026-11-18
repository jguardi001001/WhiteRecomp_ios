// The directory is iv_input/cursor, the package iv_input_cursor (`import cursor "shared:iv_input/cursor"`).
package iv_input_cursor

import input ".."
import "../../iv_system/ren"

// ---------------------------------------------------------------------------
// The cursor of the gamepad (iv_input's `nav_*`): a white arrow with a gray gradient, or a pointing hand over what can be clicked, and a dark
// gray shadow that falls to the bottom left (the light is at the top right). Made of triangles for a `ren.Draw_List`, in window px. It is
// a package of its own so that `iv_input` does not need the renderer: programs that draw their cursor some other way leave this out and
// ask `input.nav_cursor`.
// ---------------------------------------------------------------------------

// The arrow, in a grid 12 wide and 19 high with its tip at (0, 0): its outline, and the triangles it is filled with.
ARROW_POINTS :: [7][2]f32{{0, 0}, {0, 16}, {3.8, 12.4}, {6.5, 18.6}, {9, 17.4}, {6.3, 11.4}, {11.2, 11.4}}
ARROW_TRIS :: [5][3]int{{0, 1, 2}, {0, 2, 5}, {0, 5, 6}, {2, 3, 4}, {2, 4, 5}}
ARROW_H :: f32(18.6) // how high that grid is

// The hand that points, for when the cursor is over something to click: the classic one, with the index finger up, three fingers folded and
// stepping down to the right, a short thumb pointing out to the left, and the palm with the cuff under it. It is made of convex pieces, in
// cells of that picture (x to the right, y down, 26.7 cells high); HAND_S makes a cell the size it has in the grid of the arrow, and the tip of
// the index finger (HAND_TIP) is the point that points. A thin gap between the fingers lets the shadow show through as the line that parts them.
Hand_Poly :: struct {
	n:   int,
	pts: [8][2]f32,
}

HAND_S :: f32(0.7)
HAND_TIP :: f32(7.2)

HAND :: [?]Hand_Poly {
	{6, {{5.6, 1.0}, {6.4, 0}, {8.0, 0}, {8.8, 1.0}, {8.8, 14}, {5.6, 14}, {}, {}}}, // the index finger
	{6, {{9.8, 7.2}, {10.6, 6.4}, {11.6, 6.4}, {12.4, 7.2}, {12.4, 16}, {9.8, 16}, {}, {}}}, // the next one
	{6, {{13.0, 8.4}, {13.8, 7.6}, {14.8, 7.6}, {15.6, 8.4}, {15.6, 16}, {13.0, 16}, {}, {}}},
	{6, {{16.2, 9.8}, {17.0, 9.0}, {19.5, 9.0}, {20.3, 9.8}, {20.3, 17}, {16.2, 17}, {}, {}}}, // the little finger
	{8, {{5.6, 11.0}, {20.3, 11.0}, {20.3, 17.8}, {18.8, 22.8}, {18.8, 26.7}, {6.2, 26.7}, {6.2, 23.3}, {5.6, 15.5}}}, // the palm and the cuff
	{4, {{2.2, 15.5}, {5.8, 15.5}, {6.3, 23.3}, {4.0, 19.0}, {}, {}, {}, {}}}, // under the thumb: the slope from it to the cuff
	{6, {{0.0, 11.8}, {0.8, 11.0}, {5.8, 11.0}, {5.8, 15.0}, {1.9, 15.0}, {0.0, 13.2}, {}, {}}}, // the thumb
}

// The gray of the arrow's filling at a point of its grid: white at the tip, going to gray towards the tail.
arrow_gray :: proc(p: [2]f32) -> u8 {
	t := clamp((p.x / 11.2) * 0.35 + (p.y / ARROW_H) * 0.65, 0, 1)
	return u8(255 - t * 120)
}

// The gray of the filling at a point of the hand (in the grid of the arrow): the same gradient as the arrow's.
hand_gray :: proc(p: [2]f32) -> u8 {
	return arrow_gray({(p.x + HAND_TIP * HAND_S) / (20.3 * HAND_S) * 11.2, p.y})
}

hand_grid :: proc(c: [2]f32) -> [2]f32 {
	return {(c.x - HAND_TIP) * HAND_S, c.y * HAND_S}
}

// Draws the cursor, if there is one to show (a gamepad is the main input, the program has not turned the cursor off with
// `input.nav_show_cursor`, and there are rectangles to be on or the cursor is free): over the whole interface, so call it last. `size_scale`
// is how big it is made (1: `cursor_height` px high; programs scale it with the window, say clamp(window_h / 810, 1, 3)).
draw :: proc(ctx: ^input.Context($S), dl: ^ren.Draw_List, size_scale: f32 = 1) {
	c := input.nav_cursor(ctx)
	if !c.visible {
		return
	}
	at := c.at
	k := c.height / ARROW_H * size_scale
	// The shape as triangles (points of the grid): the arrow, or the hand.
	tri_pts: [96][2]f32
	nt := 0
	hand := c.hand
	if hand {
		for poly in HAND {
			for i in 1 ..< poly.n - 1 {
				tri_pts[nt * 3], tri_pts[nt * 3 + 1], tri_pts[nt * 3 + 2] = hand_grid(poly.pts[0]), hand_grid(poly.pts[i]), hand_grid(poly.pts[i + 1])
				nt += 1
			}
		}
	} else {
		pts := ARROW_POINTS
		for t in ARROW_TRIS {
			tri_pts[nt * 3], tri_pts[nt * 3 + 1], tri_pts[nt * 3 + 2] = pts[t[0]], pts[t[1]], pts[t[2]]
			nt += 1
		}
	}
	shadow := [2]f32{-0.9 * k, 1.1 * k}
	verts := make([dynamic]ren.Vertex, 0, 2 * nt * 3, context.temp_allocator)
	idx := make([dynamic]u32, 0, 2 * nt * 3, context.temp_allocator)
	for pass in 0 ..< 2 { // the shadow first, then the arrow (or the hand)
		for p in tri_pts[:nt * 3] {
			c: u8 = 56
			a: u8 = 150
			off := shadow
			if pass == 1 {
				c = hand_gray(p) if hand else arrow_gray(p)
				a = 255
				off = {}
			}
			append(&idx, u32(len(verts)))
			append(&verts, ren.Vertex{pos = {at.x + p.x * k + off.x, at.y + p.y * k + off.y}, color = {c, c, c, a}})
		}
	}
	ren.draw_mesh(dl, verts[:], idx[:])
}
