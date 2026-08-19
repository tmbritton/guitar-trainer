package main

// `--screenshot` mode: seed a temp trial log with realistic history, render the
// drill / progress / feedback / fullscreen screens, and write PNGs for visual
// inspection. Opens a window but takes no input. Dispatched from `main`.

import "core:fmt"
import "core:os"
import rl "vendor:raylib"

import "store"

// screenshot renders the drill screen and the progress panel (with some seeded
// trial data so they aren't empty) and writes PNGs, for visual inspection.
screenshot :: proc() {
	which := "drill"
	for a in os.args {
		if a == "progress" || a == "feedback" || a == "fullscreen" {
			which = a
		}
	}
	// A wider window for the fullscreen shot so the letterbox bars are visible.
	win_w, win_h: i32 = WINDOW_W, WINDOW_H
	if which == "fullscreen" {
		win_w, win_h = 1280, 600
	}
	rl.InitWindow(win_w, win_h, "Guitar Trainer")
	defer rl.CloseWindow()

	audio_ok := audio_init()
	defer if audio_ok do audio_shutdown()
	sf_load_default()
	di_load("assets/clean.sf2")
	nam_amp_load_default()
	ir_load_default()
	defer sf_close()
	defer nam_amp_close()

	path :: "/tmp/gt_shot.db"
	os.remove(path)
	db, _ := store.open(path)
	defer store.close(&db)
	defer os.remove(path)

	// Seed a realistic-looking history: several degrees, mixed accuracy.
	seed :: proc(s: ^store.Store, deg, midi: i64, correct: bool) {
		store.insert_trial(s, store.Trial_Row{ts = 1000, session_id = 1000, key = 60, target_degree = deg, target_midi = midi, detected_midi = midi, correct = correct, response_ms = 700})
	}
	mix := []struct {
		deg:     i64,
		correct: bool,
	}{{1, true}, {1, true}, {1, true}, {2, true}, {2, false}, {3, true}, {3, false}, {3, false}, {5, true}, {5, true}, {6, false}, {4, true}}
	for m in mix {
		seed(&db, m.deg, 60 + m.deg, m.correct)
	}

	d := drill_init(&db, 1000)
	defer drill_destroy(&d)
	// advance into a trial so the drill screen shows a key + "listen" state
	if audio_ok {
		for _ in 0 ..< 3 {
			drill_update(&d)
		}
	}
	// give it a last-result so the reveal line shows
	d.last_had_result = true
	d.last_correct = true
	d.last_target = 64
	d.last_detected = 64
	d.total = len(mix)
	d.correct_count = 7

	g_shot_drill = &d
	// One capture per process (a second TakeScreenshot in the same process reads
	// an undrawn buffer). Pick the screen via the arg parsed above.
	switch which {
	case "progress":
		shot_frame(proc() {drill_draw_progress(g_shot_drill)}, "gt_progress.png")
		fmt.println("wrote gt_progress.png")
	case "feedback":
		d.phase = .Feedback // force the revealed-note state for the shot
		d.last_correct = true
		shot_frame(proc() {drill_draw(g_shot_drill, true, true)}, "gt_feedback.png")
		fmt.println("wrote gt_feedback.png")
	case "fullscreen":
		// Render the 800x480 scene to a texture and blit it letterboxed into the
		// wide window — the same path run_app uses at real fullscreen.
		tgt := rl.LoadRenderTexture(WINDOW_W, WINDOW_H)
		defer rl.UnloadRenderTexture(tgt)
		rl.SetTextureFilter(tgt.texture, .POINT)
		for _ in 0 ..< 2 {
			rl.BeginTextureMode(tgt)
			rl.ClearBackground(UI_BG)
			drill_draw(g_shot_drill, true, true)
			rl.EndTextureMode()
			rl.BeginDrawing()
			rl.ClearBackground(rl.BLACK)
			blit_fit(tgt, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()))
			rl.EndDrawing()
		}
		rl.TakeScreenshot("gt_fullscreen.png")
		fmt.println("wrote gt_fullscreen.png")
	case:
		shot_frame(proc() {drill_draw(g_shot_drill, true, true)}, "gt_drill.png")
		fmt.println("wrote gt_drill.png")
	}
}

@(private = "file")
g_shot_drill: ^Drill

@(private = "file")
shot_frame :: proc(draw: proc(), file: cstring) {
	// render a couple of frames so the framebuffer is valid, then capture
	for _ in 0 ..< 2 {
		rl.BeginDrawing()
		rl.ClearBackground({18, 18, 22, 255})
		draw()
		rl.EndDrawing()
	}
	rl.TakeScreenshot(file)
}
