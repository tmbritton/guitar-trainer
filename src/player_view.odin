package main

// The Player screen (Play Along): a mixer strip — one row per stem with a level
// bar and MUTE/SOLO tags — plus a transport line (play/pause, position, seek
// bar). Pure view over the player getters (player.odin); input is handled in the
// app router.

import "core:fmt"
import rl "vendor:raylib"

import "clock"
import "songlib"

STEM_ROW_H :: 44
STEM_TOP :: 96

player_view_draw :: proc(song_name: string, sel: int) {
	ui_text(fmt.ctprintf("%s", song_name), 40, 32, 32, UI_FRAME)

	for stem, i in songlib.STEMS {
		y := i32(STEM_TOP + i * STEM_ROW_H)
		c := player_ctl(i)
		if i == sel do ui_panel(36, y - 6, 724, STEM_ROW_H - 4, UI_FRAME)
		ui_text(fmt.ctprintf("%s", stem), 56, y, 22, i == sel ? UI_INK : UI_DIM)
		ui_meter(200, y + 2, 320, 18, c.level, c.mute ? UI_BAD : UI_GOOD)
		if c.mute do ui_text("MUTE", 540, y, 20, UI_BAD)
		if c.solo do ui_text("SOLO", 630, y, 20, UI_GOLD)
	}

	// transport
	ty := i32(STEM_TOP + 6 * STEM_ROW_H + 14)
	playing := player_playing()
	ui_text(playing ? "> PLAYING" : "|| PAUSED", 56, ty, 22, playing ? UI_GOOD : UI_GOLD)
	cur, tot := player_cursor(), player_frames()
	ui_text(fmt.ctprintf("%s / %s", mmss(cur), mmss(tot)), 210, ty, 22, UI_INK)
	frac := tot > 0 ? f32(cur) / f32(tot) : 0
	ui_meter(56, ty + 34, 664, 12, frac, UI_BLUE)

	rl.DrawText(
		"SPACE play/pause   < / > seek   UP/DOWN stem   + / - level   M mute   S solo   ESC back",
		40,
		456,
		15,
		{90, 90, 120, 255},
	)
}

// mmss formats a sample count as m:ss for the transport readout.
@(private = "file")
mmss :: proc(frames: int) -> string {
	secs := frames / int(clock.SAMPLE_RATE)
	return fmt.tprintf("%d:%02d", secs / 60, secs % 60)
}
