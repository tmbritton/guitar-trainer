package main

// The Player screen (Play Along): a mixer strip — one row per stem with a level
// bar and MUTE/SOLO tags — a transport line (play/pause, position, speed), and a
// live-monitor rig line (your guitar's amp tone). Pure view over the player and
// audio-monitor getters; input is handled in the app router.

import "core:fmt"
import rl "vendor:raylib"

import "clock"
import "sections"
import "songlib"

// Tightened from 40/84 when the section list and practice readout were added:
// two new rows had to come out of the 480px panel without pushing the rig line
// into the footer.
STEM_ROW_H :: 38
STEM_TOP :: 78

// Player_Sections is what the view needs to know about saved practice sections.
// Passed in rather than read from a global so this file stays a pure view.
Player_Sections :: struct {
	list:     []sections.Section,
	armed:    int, // index into list, -1 = none armed
	passes:   int, // completed repetitions of the armed section
	manual:   bool, // the user overrode the ladder with [ / ]
	naming:   bool, // the name-entry field is open
	name:     string, // text typed so far
	status:   string, // one-line feedback (why a key did nothing)
}

player_view_draw :: proc(
	song_name, artist: string,
	sel: int,
	ps := Player_Sections{armed = -1},
) {
	ui_text(fmt.ctprintf("%s", song_name), 40, 24, 30, UI_FRAME)
	// Artist under the title, so the player reads like the library's Song row
	// rather than repeating the folder slug.
	if len(artist) > 0 do ui_text(fmt.ctprintf("%s", artist), 40, 56, 18, UI_DIM)

	for stem, i in songlib.STEMS {
		y := i32(STEM_TOP + i * STEM_ROW_H)
		c := player_ctl(i)
		if i == sel do ui_panel(36, y - 5, 724, STEM_ROW_H - 4, UI_FRAME)
		ui_text(fmt.ctprintf("%s", stem), 54, y, 20, i == sel ? UI_INK : UI_DIM)
		ui_meter(196, y + 1, 320, 16, c.level, c.mute ? UI_BAD : UI_GOOD)
		if c.mute do ui_text("MUTE", 536, y, 18, UI_BAD)
		if c.solo do ui_text("SOLO", 620, y, 18, UI_GOLD)
	}

	// transport
	ty := i32(STEM_TOP + 6 * STEM_ROW_H + 10)
	playing := player_playing()
	ui_text(playing ? "> PLAYING" : "|| PAUSED", 54, ty, 20, playing ? UI_GOOD : UI_GOLD)
	cur, tot := player_cursor(), player_frames()
	ui_text(fmt.ctprintf("%s / %s", mmss(cur), mmss(tot)), 210, ty, 20, UI_INK)
	ui_text(fmt.ctprintf("%.2fx", player_speed()), 420, ty, 20, UI_GOLD)
	// A named section implies the loop, so it replaces the generic label.
	armed_ok := ps.armed >= 0 && ps.armed < len(ps.list)
	if armed_ok {
		ui_text(fmt.ctprintf("[%s]", ps.list[ps.armed].name), 500, ty, 20, UI_GOOD)
	} else if player_loop_on() {
		ui_text("LOOP A-B", 500, ty, 20, UI_GOOD)
	}
	frac := tot > 0 ? f32(cur) / f32(tot) : 0
	bar_x, bar_w: i32 = 54, 666
	ui_meter(bar_x, ty + 28, bar_w, 10, frac, UI_BLUE)
	// Markers for every saved section, not just the armed pair — the whole point
	// of naming passages is seeing where they are.
	if tot > 0 {
		for sec, i in ps.list {
			col := i == ps.armed ? UI_GOOD : UI_GOLD // UI_DIM vanished against the meter
			ax := bar_x + i32(f32(sec.a) / f32(tot) * f32(bar_w))
			bx := bar_x + i32(f32(sec.b) / f32(tot) * f32(bar_w))
			rl.DrawRectangle(ax, ty + 24, 2, 18, col)
			rl.DrawRectangle(bx, ty + 24, 2, 18, col)
		}
		// An unsaved A-B span (marked with L but not yet named) still shows.
		if player_loop_on() && !armed_ok {
			ax := bar_x + i32(f32(player_loop_a()) / f32(tot) * f32(bar_w))
			bx := bar_x + i32(f32(player_loop_b()) / f32(tot) * f32(bar_w))
			rl.DrawRectangle(ax, ty + 24, 2, 18, UI_GOOD)
			rl.DrawRectangle(bx, ty + 24, 2, 18, UI_GOOD)
		}
	}

	// Practice readout for the armed section: repetitions, and what the tempo is
	// doing. "manual" means a [ / ] nudge took the ladder off the wheel.
	// The section list: every saved name on one line, the armed one lit. `N`
	// cycles through them, so you can see what you are cycling *to* rather than
	// stepping blind through a count.
	sy := ty + 46
	if len(ps.list) > 0 {
		x: i32 = 54
		for sec, i in ps.list {
			lit := i == ps.armed
			label := fmt.ctprintf("%s", sec.name)
			ui_text(label, x, sy, 16, lit ? UI_GOOD : UI_DIM)
			x += rl.MeasureText(label, 16) + 10
			if i < len(ps.list) - 1 {
				ui_text("/", x, sy, 16, {90, 90, 120, 255})
				x += 14
			}
			if x > 600 do break // the rest run off the panel; markers still show them
		}
	} else if player_loop_on() {
		ui_text("R  save this A-B span as a section", 54, sy, 16, UI_DIM)
	}

	// Practice readout for the armed section: repetitions, and what the tempo is
	// doing. "yielded" means a [ / ] nudge took the ladder off the wheel.
	py := sy + 20
	if armed_ok {
		sec := ps.list[ps.armed]
		state: cstring = "ladder off"
		if sec.ladder && ps.manual {
			state = "ladder yielded to you"
		} else if sec.ladder {
			state = fmt.ctprintf("ladder -> %.2fx", section_speed(sec, ps.passes))
		}
		ui_text(fmt.ctprintf("pass %d   %s", ps.passes, state), 54, py, 16, UI_DIM)
	}
	if len(ps.status) > 0 {
		ui_text(fmt.ctprintf("%s", ps.status), 300, py, 16, UI_GOLD)
	}
	if pr := player_preroll(); pr > 0 {
		ui_text(fmt.ctprintf("pre-roll %.1fs", f32(pr) / clock.SAMPLE_RATE), 620, py, 16, UI_DIM)
	}

	// live-monitor rig
	my := ty + 88 // section list (sy) and practice readout (py) sit between
	mon := audio_monitor_on()
	dry := audio_monitor_dry()
	ui_text(mon ? (dry ? "MON DRY" : "MON ON") : "MON OFF", 54, my, 18, mon ? UI_GOOD : UI_DIM)
	if dry {
		ui_text("clean passthrough (amp bypassed)", 176, my, 18, mon ? UI_INK : UI_DIM)
	} else {
		b, tr := audio_monitor_tone()
		cablabel := audio_monitor_cab() < audio_monitor_cab_count() ? fmt.ctprintf("cab %d", audio_monitor_cab() + 1) : fmt.ctprintf("no cab")
		ui_text(
			fmt.ctprintf("drv %.1f   %s   bass %+.0f   treb %+.0f   lvl %.2f", audio_monitor_drive(), cablabel, b, tr, audio_monitor_level()),
			176,
			my,
			18,
			mon ? UI_INK : UI_DIM,
		)
	}

	rl.DrawText("SPACE play  < > seek  UP/DOWN stem  +/- level  M mute  S solo  [ ] speed  L loop", 40, 428, 14, {90, 90, 120, 255})
	rl.DrawText("N arm section  R save span  K ladder  T pre-roll  DEL remove", 40, 446, 14, {90, 90, 120, 255})
	rl.DrawText("G monitor  D dry  , . drive  B cab  9 0 mon-level  Z X bass  C V treble  ESC back", 40, 464, 14, {90, 90, 120, 255})

	if ps.naming do name_field_draw(ps.name)
}

// name_field_draw is the overlay for naming a section. Modal: while it is open
// the router sends every keystroke here, so the panel must say how to leave.
@(private = "file")
name_field_draw :: proc(name: string) {
	ui_panel(120, 170, 560, 140, UI_FRAME)
	ui_text("NAME THIS SECTION", 148, 190, 22, UI_FRAME)
	rl.DrawRectangle(148, 232, 504, 34, UI_BG)
	ui_text(fmt.ctprintf("%s_", name), 158, 238, 22, UI_INK)
	rl.DrawText("ENTER  save      ESC  cancel", 148, 280, 14, {90, 90, 120, 255})
}

// mmss formats a sample count as m:ss for the transport readout.
@(private = "file")
mmss :: proc(frames: int) -> string {
	secs := frames / int(clock.SAMPLE_RATE)
	return fmt.tprintf("%d:%02d", secs / 60, secs % 60)
}
