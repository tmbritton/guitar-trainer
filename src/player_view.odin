package main

// The Player screen (Play Along): a mixer strip — one row per stem with a level
// bar and MUTE/SOLO tags — a transport line (play/pause, position, speed), and a
// live-monitor rig line (your guitar's amp tone). Pure view over the player and
// audio-monitor getters; input is handled in the app router.

import "core:fmt"
import rl "vendor:raylib"

import "clock"
import "songlib"

STEM_ROW_H :: 40
STEM_TOP :: 84

player_view_draw :: proc(song_name: string, sel: int) {
	ui_text(fmt.ctprintf("%s", song_name), 40, 30, 30, UI_FRAME)

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
	if player_loop_on() do ui_text("LOOP A-B", 500, ty, 20, UI_GOOD)
	frac := tot > 0 ? f32(cur) / f32(tot) : 0
	bar_x, bar_w: i32 = 54, 666
	ui_meter(bar_x, ty + 28, bar_w, 10, frac, UI_BLUE)
	// A-B loop markers on the seek bar
	if player_loop_on() && tot > 0 {
		ax := bar_x + i32(f32(player_loop_a()) / f32(tot) * f32(bar_w))
		bx := bar_x + i32(f32(player_loop_b()) / f32(tot) * f32(bar_w))
		rl.DrawRectangle(ax, ty + 24, 2, 18, UI_GOOD)
		rl.DrawRectangle(bx, ty + 24, 2, 18, UI_GOOD)
	}

	// live-monitor rig
	my := ty + 52
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

	rl.DrawText("SPACE play   < > seek   UP/DOWN stem   +/- level   M mute   S solo   [ ] speed   L loop", 40, 440, 14, {90, 90, 120, 255})
	rl.DrawText("G monitor   D dry   , . drive   B cab   9 0 mon-level   Z X bass   C V treble   ESC back", 40, 460, 14, {90, 90, 120, 255})
}

// mmss formats a sample count as m:ss for the transport readout.
@(private = "file")
mmss :: proc(frames: int) -> string {
	secs := frames / int(clock.SAMPLE_RATE)
	return fmt.tprintf("%d:%02d", secs / 60, secs % 60)
}
