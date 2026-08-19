package main

// The interactive application: `run_app` is a keyboard-driven screen router
// (Main Menu -> Play a Song / Import / Practice Drill / Settings / Quit). It
// owns the window, the fullscreen render-texture/letterbox path, and the
// audio/store/drill lifecycles. Per-screen HUD drawing lives in drill_view.odin.

import "core:fmt"
import "core:time"
import rl "vendor:raylib"

import "clock"
import "menu"
import "store"

run_app :: proc() {
	// NOTE: We deliberately do NOT call rl.InitAudioDevice(). Audio is owned by
	// a single duplex ma_device (see audio.odin), per the architecture rules.
	rl.InitWindow(WINDOW_W, WINDOW_H, "Guitar Trainer")
	defer rl.CloseWindow()

	// Launch fullscreen with nothing else on screen — a practice session should
	// have no competing UI. The drill is drawn at a fixed 800x480 into an
	// offscreen texture, then scaled and centred (black letterbox) to the display.
	rl.ToggleBorderlessWindowed()
	rl.HideCursor()
	rl.SetTargetFPS(60)

	target := rl.LoadRenderTexture(WINDOW_W, WINDOW_H)
	defer rl.UnloadRenderTexture(target)
	rl.SetTextureFilter(target.texture, .POINT) // crisp pixels when scaled up

	audio_ok := audio_init()
	defer if audio_ok do audio_shutdown()

	// Load a real sampled-guitar SoundFont for playback (falls back to the KS
	// synth if the assets aren't present).
	if audio_ok {
		sf_load_default()
		di_load("assets/clean.sf2") // clean DI source for the neural amp
		nam_amp_load_default() // neural amp model (real amp)
		ir_load_default() // cabinet IR
	}
	defer sf_close()
	defer nam_amp_close()

	db: store.Store
	store_ok := false
	if audio_ok {
		db, store_ok = store.open("trials.db")
	}
	defer if store_ok do store.close(&db)

	session := i64(time.time_to_unix(time.now()))
	d := drill_init(&db, session)
	defer drill_destroy(&d)

	calib_buf: [96]u8
	calib_status := "not calibrated — press C"
	show_progress := false

	screen := Screen.Main_Menu
	main_items := [?]cstring{"Play a Song", "Import Song", "Practice Drill", "Settings", "Quit"}
	main_menu := Menu_Widget {
		title = "GUITAR TRAINER",
		items = main_items[:],
	}

	for !rl.WindowShouldClose() {
		// ---- update the current screen ----
		switch screen {
		case .Main_Menu:
			switch menu_input(&main_menu) {
			case 0:
				screen = .Library
			case 1:
				screen = .Import
			case 2:
				screen = .Drill
			case 3:
				screen = .Settings
			case 4:
				return
			}
			if rl.IsKeyPressed(.ESCAPE) do return

		case .Drill:
			if audio_ok && store_ok do drill_update(&d)
			if store_ok && rl.IsKeyPressed(.P) do show_progress = !show_progress
			if rl.IsKeyPressed(.ESCAPE) {
				// leaving mid-trial: abandon it (don't log a miss) and drain any
				// onsets captured while the drill was off-screen.
				if audio_ok do drill_abandon(&d)
				screen = .Main_Menu
				show_progress = false
			}

		case .Settings:
			// Tone switches swap fonts/amps/IRs the render worker reads — only
			// when it's idle.
			if audio_ok && !render_busy() {
				if rl.IsKeyPressed(.F) do sf_next_font()
				if rl.IsKeyPressed(.V) do sf_next_preset()
				if rl.IsKeyPressed(.B) do ir_next()
				if rl.IsKeyPressed(.I) do ir_toggle()
				if rl.IsKeyPressed(.N) do nam_amp_toggle()
				if rl.IsKeyPressed(.A) do nam_amp_next()
			}
			if audio_ok && rl.IsKeyPressed(.C) {
				if offset, ok := run_calibration(5); ok {
					calib_status = fmt.bprintf(calib_buf[:], "offset %d samples (%.2f ms)", offset, clock.samples_to_ms(u64(abs(offset))))
				} else {
					calib_status = "no click detected (need input)"
				}
			}
			if rl.IsKeyPressed(.ESCAPE) do screen = .Main_Menu

		case .Library, .Import:
			if rl.IsKeyPressed(.ESCAPE) do screen = .Main_Menu
		}

		// ---- draw the current screen into the offscreen texture ----
		rl.BeginTextureMode(target)
		rl.ClearBackground(UI_BG)
		switch screen {
		case .Main_Menu:
			menu_draw(&main_menu)
		case .Drill:
			if show_progress && store_ok {
				drill_draw_progress(&d)
			} else {
				drill_draw(&d, audio_ok, store_ok)
			}
		case .Settings:
			settings_draw(audio_ok, calib_status)
		case .Library:
			stub_draw("PLAY A SONG", "coming soon — import a song first")
		case .Import:
			stub_draw("IMPORT SONG", "coming soon")
		}
		rl.EndTextureMode()

		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		blit_fit(target, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()))
		rl.EndDrawing()
	}
}

// ---- screens ----

Screen :: enum {
	Main_Menu,
	Drill,
	Settings,
	Library,
	Import,
}

Menu_Widget :: struct {
	title: cstring,
	items: []cstring,
	sel:   int,
}

// menu_input handles up/down and returns the activated index on Enter, else -1.
menu_input :: proc(m: ^Menu_Widget) -> int {
	if rl.IsKeyPressed(.DOWN) do m.sel = menu.move(m.sel, len(m.items), 1)
	if rl.IsKeyPressed(.UP) do m.sel = menu.move(m.sel, len(m.items), -1)
	if rl.IsKeyPressed(.ENTER) do return m.sel
	return -1
}

menu_draw :: proc(m: ^Menu_Widget) {
	ui_text(m.title, 40, 40, 40, UI_FRAME)
	for it, i in m.items {
		y := i32(154 + i * 52)
		if i == m.sel {
			ui_panel(36, y - 6, 440, 42, UI_FRAME)
		}
		ui_text(it, 56, y, 26, i == m.sel ? UI_INK : UI_DIM)
	}
	rl.DrawText("UP / DOWN  move     ENTER  select     ESC  quit", 40, 448, 16, {90, 90, 120, 255})
}

settings_draw :: proc(audio_ok: bool, calib_status: string) {
	ui_text("SETTINGS", 40, 40, 40, UI_FRAME)
	if !audio_ok {
		ui_text("audio device failed to start", 40, 130, 20, UI_BAD)
		return
	}
	tone: cstring = "chip synth (no soundfont)"
	if nam_amp_active() {
		tone = fmt.ctprintf("clean DI -> %s -> cab %s", nam_amp_status(), ir_status())
	} else if sf_loaded() {
		tone = fmt.ctprintf("%s / %s   ·   cab %s", g_sf.label, sf_preset_name(), ir_status())
	}
	ui_panel(40, 120, 720, 58, UI_GOLD)
	rl.DrawText("TONE", 54, 130, 16, UI_DIM)
	ui_text(tone, 54, 148, 20, UI_INK)

	rl.DrawText(fmt.ctprintf("calibration:  %s", calib_status), 40, 200, 18, UI_DIM)

	rl.DrawText("F / V   guitar  /  preset", 40, 260, 18, UI_INK)
	rl.DrawText("N / A   neural amp on-off  /  model", 40, 288, 18, UI_INK)
	rl.DrawText("B / I   cabinet  /  on-off", 40, 316, 18, UI_INK)
	rl.DrawText("C       calibrate round-trip latency", 40, 344, 18, UI_INK)

	rl.DrawText("ESC  back", 40, 448, 16, {90, 90, 120, 255})
}

stub_draw :: proc(title, msg: cstring) {
	ui_text(title, 40, 40, 40, UI_FRAME)
	ui_text(msg, 40, 160, 22, UI_DIM)
	rl.DrawText("ESC  back", 40, 448, 16, {90, 90, 120, 255})
}

// blit_fit draws the 800x480 scene texture scaled to fit (sw, sh), centred, with
// black letterbox bars — so the fixed-layout drill fills any display cleanly.
blit_fit :: proc(target: rl.RenderTexture2D, sw, sh: f32) {
	scale := min(sw / WINDOW_W, sh / WINDOW_H)
	dw := WINDOW_W * scale
	dh := WINDOW_H * scale
	src := rl.Rectangle{0, 0, WINDOW_W, -WINDOW_H} // negative height flips the render texture
	dst := rl.Rectangle{(sw - dw) / 2, (sh - dh) / 2, dw, dh}
	rl.DrawTexturePro(target.texture, src, dst, {0, 0}, 0, rl.WHITE)
}
