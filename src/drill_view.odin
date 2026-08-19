package main

// Drill screen rendering: the minimal training HUD and the progress panel. Pure
// view code over Drill state + the trial log — no input, no state changes. The
// drill state machine itself lives in drill.odin; the router that shows these
// lives in app.odin.

import "core:fmt"
import "core:math"
import rl "vendor:raylib"

import "music"
import "store"

// deg_color grades a per-degree accuracy: green mastered, gold learning, red weak.
deg_color :: proc(pct: int, seen: bool) -> rl.Color {
	if !seen {
		return {50, 50, 74, 255}
	}
	if pct >= 70 {
		return UI_GOOD
	}
	if pct >= 40 {
		return UI_GOLD
	}
	return UI_BAD
}

// drill_draw_progress renders the progress view (toggle with P), derived entirely
// from the trial log: practice days, totals, a naive recent-vs-overall trend, and
// per-degree accuracy bars.
drill_draw_progress :: proc(d: ^Drill) {
	ui_text("PROGRESS", 22, 16, 28, UI_FRAME)

	days := store.practice_days(d.db)
	att, cor := store.overall(d.db)
	racc_a, racc_c := store.recent_accuracy(d.db, 20)
	overall_pct := att > 0 ? int(100 * cor / att) : 0
	recent_pct := racc_a > 0 ? int(100 * racc_c / racc_a) : 0

	// top row of arcade stat boxes
	ui_stat(22, 60, 240, 62, "PRACTICE DAYS", fmt.ctprintf("%d", days))
	ui_stat(280, 60, 240, 62, "TRIALS", fmt.ctprintf("%d", att))
	ui_stat(538, 60, 240, 62, "ACCURACY", fmt.ctprintf("%d%%", overall_pct), UI_GOLD)

	trend: cstring = "warming up"
	tcol := UI_DIM
	if racc_a >= 5 {
		if recent_pct > overall_pct + 5 {
			trend = "improving";tcol = UI_GOOD
		} else if recent_pct < overall_pct - 5 {
			trend = "dipping";tcol = UI_BAD
		} else {
			trend = "steady";tcol = UI_FRAME
		}
	}
	rl.DrawText(fmt.ctprintf("recent %d trials: %d%%", racc_a, recent_pct), 22, 138, 18, UI_INK)
	ui_text(trend, 300, 138, 18, tcol, false)

	// per-degree accuracy as coloured pill-meters
	att_d, cor_d := store.degree_stats(d.db)
	rl.DrawText("BY SCALE DEGREE", 22, 176, 16, UI_DIM)
	track_x, track_w: i32 = 70, 480
	for deg in 1 ..= 7 {
		a := int(att_d[deg])
		c := int(cor_d[deg])
		pct := a > 0 ? 100 * c / a : 0
		y := i32(202 + (deg - 1) * 34)
		// degree token
		ui_capsule(40, y + 12, 40, 26, UI_BLUE, fmt.ctprintf("%d", deg), 22)
		// track + fill
		rl.DrawRectangleRoundedLinesEx({f32(track_x), f32(y), f32(track_w), 24}, 0.5, 8, 2, {60, 60, 84, 255})
		if a > 0 {
			fill := i32(pct) * track_w / 100
			if fill < 12 {
				fill = 12
			}
			rl.DrawRectangleRounded({f32(track_x), f32(y), f32(fill), 24}, 0.5, 8, deg_color(pct, true))
		}
		rl.DrawText(fmt.ctprintf("%3d%%  n=%d", pct, a), track_x + track_w + 12, y + 4, 16, UI_DIM)
	}

	rl.DrawText("P back to drill  ·  ESC menu", 22, 452, 16, {90, 90, 120, 255})
}

// drill_draw renders the minimal training HUD. Deliberately spare: no per-note
// green/red, the target degree stays hidden until the answer is revealed.
drill_draw :: proc(d: ^Drill, audio_ok, store_ok: bool) {
	ui_text("GUITAR TRAINER", 22, 16, 28, UI_FRAME)

	if !audio_ok {
		ui_text("audio device failed to start", 22, 90, 20, UI_BAD)
		return
	}
	if !store_ok {
		ui_text("trial log failed to open", 22, 90, 20, UI_BAD)
		return
	}

	// --- left HUD: KEY / TRIAL / ACC arcade boxes ---
	acc := d.total > 0 ? 100 * d.correct_count / d.total : 0
	ui_stat(22, 60, 158, 62, "KEY", fmt.ctprintf("%s", music.note_name(d.trial.key.tonic_midi)))
	ui_stat(22, 138, 158, 62, "TRIAL", fmt.ctprintf("%d", d.total))
	ui_stat(22, 216, 158, 62, "ACCURACY", fmt.ctprintf("%d%%", acc), UI_GOLD)

	// --- center playfield ---
	px, py, pw, ph: i32 = 200, 60, 372, 300
	ui_panel(px, py, pw, ph)
	cx := px + pw / 2

	phase_label: cstring = ""
	switch d.phase {
	case .Idle, .Confirm:
		phase_label = "READY"
	case .Prep:
		phase_label = "GET READY"
	case .Listen:
		phase_label = "LISTEN"
	case .Fb_Prep, .Feedback:
		phase_label = d.last_correct ? "NAILED IT" : "NOT QUITE"
	}
	lc := d.phase == .Feedback ? (d.last_correct ? UI_GOOD : UI_BAD) : UI_FRAME
	ui_text_center(phase_label, cx, py + 26, 28, lc)

	// the note capsule: hidden while listening, revealed (coloured) on feedback.
	// A gentle breathing pulse while listening signals "your turn" without being
	// a per-note correctness cue.
	cap_col := UI_BLUE
	cap_label: cstring = "?"
	if d.phase == .Feedback {
		cap_col = d.last_correct ? UI_GOOD : UI_BAD
		cap_label = fmt.ctprintf("%s", music.note_name(d.last_target))
	}
	pulse: f32 = 1
	if d.phase == .Listen {
		pulse = 1 + 0.03 * f32(math.sin(rl.GetTime() * 4))
	}
	ui_capsule(cx, py + 150, i32(220 * pulse), i32(96 * pulse), cap_col, cap_label, 56)

	sub: cstring = "play the note you heard"
	if d.phase == .Feedback && d.last_had_result {
		played := d.last_detected >= 0 ? music.note_name(d.last_detected) : "no note"
		sub = fmt.ctprintf("you played %s", played)
	} else if d.phase != .Listen {
		sub = ""
	}
	ui_text_center(sub, cx, py + 226, 18, UI_DIM)

	// --- right: the session bottle, fills with capsules per answered trial ---
	bx, by, bw, bh: i32 = 596, 60, 178, 300
	rl.DrawText("SESSION", bx + 4, by - 22, 16, UI_DIM)
	ix, iy, iw, ih := ui_bottle(bx, by, bw, bh)
	pill_h: i32 = 20
	gap: i32 = 6
	capacity := ih / (pill_h + gap)
	shown := min(i32(d.total), capacity)
	for i in 0 ..< shown {
		// stack from the bottom; greens (nailed) first, then misses
		yy := iy + ih - (i + 1) * (pill_h + gap) + gap
		col := i < i32(d.correct_count) ? UI_GOOD : UI_BAD
		ui_capsule(ix + iw / 2, yy + pill_h / 2, iw - 8, pill_h, col, "", 0)
	}

	// --- input meter ---
	rl.DrawText("INPUT", 22, 384, 16, UI_DIM)
	ui_meter(90, 384, 482, 16, clamp(audio_input_level() * 4, 0, 1))

	// --- footer: current tone (read-only; switch it in Settings) ---
	tone: cstring = "TONE  chip synth (no soundfont)"
	if nam_amp_active() {
		tone = fmt.ctprintf("RIG  clean DI -> %s -> cab %s", nam_amp_status(), ir_status())
	} else if sf_loaded() {
		tone = fmt.ctprintf("TONE  %s / %s  ·  cab %s", g_sf.label, sf_preset_name(), ir_status())
	}
	rl.DrawText(tone, 22, 418, 16, UI_GOLD)
	rl.DrawText("P progress  ·  ESC menu", 22, 450, 14, {90, 90, 120, 255})
}
