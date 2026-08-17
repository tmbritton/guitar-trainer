package main

// Retro "medicine-bottle" UI kit (Dr. Mario-inspired): chunky bordered panels,
// pill/capsule tokens, arcade stat boxes, drawn with raylib primitives + the
// built-in bitmap font. Purely presentational.

import rl "vendor:raylib"

// palette
UI_BG :: rl.Color{10, 10, 22, 255}
UI_PANEL :: rl.Color{18, 18, 42, 255}
UI_FRAME :: rl.Color{60, 199, 212, 255} // cyan bottle frame
UI_FRAME_DK :: rl.Color{28, 96, 108, 255}
UI_INK :: rl.Color{244, 244, 252, 255}
UI_DIM :: rl.Color{122, 122, 156, 255}
UI_GOOD :: rl.Color{72, 208, 106, 255} // nailed
UI_BAD :: rl.Color{229, 72, 77, 255} // miss
UI_GOLD :: rl.Color{244, 196, 48, 255}
UI_BLUE :: rl.Color{76, 140, 242, 255}
UI_SHADOW :: rl.Color{0, 0, 0, 210}

ui_text :: proc(txt: cstring, x, y, size: i32, col: rl.Color, shadow := true) {
	if shadow {
		off := max(size / 16, 2)
		rl.DrawText(txt, x + off, y + off, size, UI_SHADOW)
	}
	rl.DrawText(txt, x, y, size, col)
}

ui_text_center :: proc(txt: cstring, cx, y, size: i32, col: rl.Color, shadow := true) {
	w := rl.MeasureText(txt, size)
	ui_text(txt, cx - w / 2, y, size, col, shadow)
}

// panel: filled interior with a thick inner frame and a thin darker outer frame.
ui_panel :: proc(x, y, w, h: i32, frame := UI_FRAME) {
	rl.DrawRectangle(x, y, w, h, UI_PANEL)
	rl.DrawRectangleLinesEx({f32(x - 3), f32(y - 3), f32(w + 6), f32(h + 6)}, 2, UI_FRAME_DK)
	rl.DrawRectangleLinesEx({f32(x), f32(y), f32(w), f32(h)}, 4, frame)
}

// stat_box: a labelled arcade readout (eyebrow label + big value).
ui_stat :: proc(x, y, w, h: i32, label, value: cstring, accent := UI_FRAME) {
	ui_panel(x, y, w, h, accent)
	rl.DrawText(label, x + 14, y + 12, 16, UI_DIM)
	ui_text(value, x + 14, y + 32, 32, UI_INK)
}

// capsule: a Dr. Mario-style pill with a top sheen and a centred label.
ui_capsule :: proc(cx, cy, w, h: i32, col: rl.Color, label: cstring, label_size: i32) {
	rec := rl.Rectangle{f32(cx - w / 2), f32(cy - h / 2), f32(w), f32(h)}
	rl.DrawRectangleRounded(rec, 0.5, 12, col)
	rl.DrawRectangleRoundedLinesEx(rec, 0.5, 12, 3, rl.Color{0, 0, 0, 120})
	// cylindrical sheen across the top third
	hi := rl.Rectangle{rec.x + 8, rec.y + 6, rec.width - 16, rec.height / 3}
	rl.DrawRectangleRounded(hi, 0.6, 8, rl.Color{255, 255, 255, 45})
	if label != "" {
		ui_text_center(label, cx, cy - label_size / 2, label_size, {10, 10, 24, 255}, false)
	}
}

// bottle: a bordered container with a short neck; returns the inner rect (x,y,w,h)
// the caller can fill with stacked capsules.
ui_bottle :: proc(x, y, w, h: i32) -> (ix, iy, iw, ih: i32) {
	neck_w := w / 3
	neck_x := x + (w - neck_w) / 2
	// neck
	rl.DrawRectangle(neck_x, y, neck_w, 14, UI_PANEL)
	rl.DrawRectangleLinesEx({f32(neck_x), f32(y), f32(neck_w), 16}, 3, UI_FRAME)
	// body
	body_y := y + 14
	body_h := h - 14
	rl.DrawRectangle(x, body_y, w, body_h, {6, 6, 16, 255})
	rl.DrawRectangleLinesEx({f32(x), f32(body_y), f32(w), f32(body_h)}, 4, UI_FRAME)
	pad :: 10
	return x + pad, body_y + pad, w - 2 * pad, body_h - 2 * pad
}

// segmented meter (retro level bar).
ui_meter :: proc(x, y, w, h: i32, level01: f32, col := UI_GOOD) {
	segs :: 20
	gap :: 3
	sw := (w - (segs - 1) * gap) / segs
	lit := int(clamp(level01, 0, 1) * segs + 0.5)
	for i in 0 ..< segs {
		sx := x + i32(i) * (sw + gap)
		c := i < lit ? col : rl.Color{40, 40, 60, 255}
		rl.DrawRectangle(sx, y, sw, h, c)
	}
}
