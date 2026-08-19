package main

// The interactive application: `run_app` is a keyboard-driven screen router
// (Main Menu -> Play a Song / Import / Practice Drill / Settings / Quit). It
// owns the window, the fullscreen render-texture/letterbox path, and the
// audio/store/drill lifecycles. Per-screen HUD drawing lives in drill_view.odin.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

import "clock"
import "menu"
import "songlib"
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
		// preload cab IRs for the realtime live-monitor chain (same files)
		cab_paths: [len(g_ir_files)]string
		for e, i in g_ir_files do cab_paths[i] = e.path
		audio_monitor_load_cabs(cab_paths[:])
	}
	defer sf_close()
	defer nam_amp_close()
	defer if audio_ok do audio_monitor_enable(false)

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

	// import / library screen state
	browser: Browser
	defer browser_close(&browser)
	lib: Library_View
	defer library_view_close(&lib)
	defer import_cancel() // don't orphan a running separator if the app quits mid-import
	import_name_buf: [256]u8
	import_name: string
	start_dir_buf: [512]u8
	start_dir := default_music_dir(start_dir_buf[:])

	// player screen state
	player_song: Song_Audio
	defer stems_free(&player_song)
	defer player_close() // runs before stems_free (LIFO): stop the producer, then free
	player_sel: int
	player_dir_buf, player_name_buf: [512]u8
	player_dir, player_name: string

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
				library_view_reload(&lib, LIBRARY_DIR)
				screen = .Library
			case 1:
				browser_open(&browser, start_dir)
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
			if audio_ok { // audio in/out device selection (for the Rocksmith cable etc.)
				if rl.IsKeyPressed(.ONE) do cycle_capture_device()
				if rl.IsKeyPressed(.TWO) do cycle_playback_device()
			}
			if audio_ok && rl.IsKeyPressed(.C) {
				if offset, ok := run_calibration(5); ok {
					calib_status = fmt.bprintf(calib_buf[:], "offset %d samples (%.2f ms)", offset, clock.samples_to_ms(u64(abs(offset))))
				} else {
					calib_status = "no click detected (need input)"
				}
			}
			if rl.IsKeyPressed(.ESCAPE) do screen = .Main_Menu

		case .Import:
			if rl.IsKeyPressed(.DOWN) do browser_move(&browser, 1)
			if rl.IsKeyPressed(.UP) do browser_move(&browser, -1)
			if rl.IsKeyPressed(.BACKSPACE) do browser_up(&browser)
			if rl.IsKeyPressed(.ENTER) {
				if action, path := browser_enter(&browser); action == .Import {
					import_name = string(import_name_buf[:copy(import_name_buf[:], base_name(path))])
					out_buf: [512]u8
					import_start(path, song_out_dir(out_buf[:], path))
					screen = .Importing
				}
			}
			if rl.IsKeyPressed(.ESCAPE) do screen = .Main_Menu

		case .Importing:
			// leave when the user acknowledges (ESC always; ENTER once finished).
			_, st := import_progress()
			done := st == .Done || st == .Error
			if rl.IsKeyPressed(.ESCAPE) || (done && rl.IsKeyPressed(.ENTER)) {
				import_cancel() // kill a still-running separator so the join is prompt
				import_reset()
				library_view_reload(&lib, LIBRARY_DIR)
				screen = .Library
			}

		case .Library:
			if rl.IsKeyPressed(.DOWN) do library_view_move(&lib, 1)
			if rl.IsKeyPressed(.UP) do library_view_move(&lib, -1)
			if rl.IsKeyPressed(.ENTER) && len(lib.songs) > 0 {
				s := lib.songs[lib.sel]
				if sa, ok := stems_load(s.dir); ok {
					player_song = sa
					ctl, rig, _ := prefs_load(s.dir)
					for i in 0 ..< 6 do player_song.ctl[i] = ctl[i]
					apply_rig(rig)
					player_dir = string(player_dir_buf[:copy(player_dir_buf[:], s.dir)])
					player_name = string(player_name_buf[:copy(player_name_buf[:], s.name)])
					player_sel = 0
					player_open(player_song)
					player_set_speed(rig.speed) // after open (which resets speed to 1.0)
					screen = .Player
				}
			}
			if rl.IsKeyPressed(.ESCAPE) do screen = .Main_Menu

		case .Player:
			SR :: int(clock.SAMPLE_RATE)
			if rl.IsKeyPressed(.SPACE) do player_toggle()
			if rl.IsKeyPressed(.RIGHT) do player_seek(player_cursor() + 5 * SR)
			if rl.IsKeyPressed(.LEFT) do player_seek(player_cursor() - 5 * SR)
			if rl.IsKeyPressed(.DOWN) do player_sel = menu.move(player_sel, 6, 1)
			if rl.IsKeyPressed(.UP) do player_sel = menu.move(player_sel, 6, -1)
			if rl.IsKeyPressed(.EQUAL) || rl.IsKeyPressed(.KP_ADD) {
				player_set_level(player_sel, player_ctl(player_sel).level + 0.05)
			}
			if rl.IsKeyPressed(.MINUS) || rl.IsKeyPressed(.KP_SUBTRACT) {
				player_set_level(player_sel, player_ctl(player_sel).level - 0.05)
			}
			if rl.IsKeyPressed(.M) do player_toggle_mute(player_sel)
			if rl.IsKeyPressed(.S) do player_toggle_solo(player_sel)
			if rl.IsKeyPressed(.LEFT_BRACKET) do player_set_speed(player_speed() - 0.05)
			if rl.IsKeyPressed(.RIGHT_BRACKET) do player_set_speed(player_speed() + 0.05)
			// live-monitor rig controls
			if rl.IsKeyPressed(.G) do audio_monitor_enable(!audio_monitor_on())
			if rl.IsKeyPressed(.NINE) do audio_set_monitor_level(clamp(audio_monitor_level() - 0.05, 0, 1))
			if rl.IsKeyPressed(.ZERO) do audio_set_monitor_level(clamp(audio_monitor_level() + 0.05, 0, 1))
			if rl.IsKeyPressed(.COMMA) do audio_set_monitor_drive(clamp(audio_monitor_drive() - 0.25, 0.5, 8))
			if rl.IsKeyPressed(.PERIOD) do audio_set_monitor_drive(clamp(audio_monitor_drive() + 0.25, 0.5, 8))
			if rl.IsKeyPressed(.B) do audio_set_monitor_cab((audio_monitor_cab() + 1) % (audio_monitor_cab_count() + 1))
			if rl.IsKeyPressed(.Z) do adjust_monitor_tone(-1, 0)
			if rl.IsKeyPressed(.X) do adjust_monitor_tone(1, 0)
			if rl.IsKeyPressed(.C) do adjust_monitor_tone(0, -1)
			if rl.IsKeyPressed(.V) do adjust_monitor_tone(0, 1)
			if rl.IsKeyPressed(.ESCAPE) {
				prefs_save(player_dir, player_snapshot_ctl(), current_rig()) // remember mix + rig + speed
				audio_monitor_enable(false) // stop monitoring on the menus
				player_close()
				stems_free(&player_song)
				screen = .Library
			}
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
			library_view_draw(&lib)
		case .Import:
			browser_draw(&browser)
		case .Importing:
			importing_draw(import_name)
		case .Player:
			player_view_draw(player_name, player_sel)
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
	Importing,
	Player,
}

LIBRARY_DIR :: "library"

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

	// audio in/out devices (the Rocksmith cable is input-only, so in and out can
	// be different devices)
	ui_panel(40, 228, 720, 58, UI_FRAME_DK)
	rl.DrawText("AUDIO", 54, 236, 16, UI_DIM)
	rl.DrawText(fmt.ctprintf("in  %s", device_label(audio_capture_devices(), audio_selected_capture())), 130, 236, 18, UI_INK)
	rl.DrawText(fmt.ctprintf("out %s", device_label(audio_playback_devices(), audio_selected_playback())), 130, 260, 18, UI_INK)

	rl.DrawText("F / V   guitar  /  preset          1   cycle audio IN device", 40, 306, 18, UI_INK)
	rl.DrawText("N / A   neural amp on-off / model   2   cycle audio OUT device", 40, 332, 18, UI_INK)
	rl.DrawText("B / I   cabinet  /  on-off          C   calibrate latency", 40, 358, 18, UI_INK)

	rl.DrawText("ESC  back", 40, 448, 16, {90, 90, 120, 255})
}

// default_music_dir is where the import browser starts: $HOME/Music if it
// exists, else $HOME, else the current directory. Written into `buf`.
default_music_dir :: proc(buf: []u8) -> string {
	home_buf: [400]u8
	home := os.get_env(home_buf[:], "HOME")
	if home == "" do return "."
	music_buf: [512]u8
	music := fmt.bprintf(music_buf[:], "%s/Music", home)
	if os.exists(music) do return string(buf[:copy(buf, music)])
	return string(buf[:copy(buf, home)])
}

// base_name returns the final path component (filename) of `path`.
base_name :: proc(path: string) -> string {
	if s := strings.last_index_byte(path, '/'); s >= 0 do return path[s + 1:]
	return path
}

// cycle_capture_device / cycle_playback_device step through system-default (-1)
// then each enumerated device, re-initing the duplex device and saving the choice.
cycle_capture_device :: proc() {
	next := audio_selected_capture() + 1
	if next >= len(audio_capture_devices()) do next = -1
	audio_reinit(next, audio_selected_playback())
}

cycle_playback_device :: proc() {
	next := audio_selected_playback() + 1
	if next >= len(audio_playback_devices()) do next = -1
	audio_reinit(audio_selected_capture(), next)
}

// device_label names the selected device for a list, or "system default" for -1.
device_label :: proc(devs: []Audio_Device, sel: int) -> cstring {
	if sel >= 0 && sel < len(devs) do return fmt.ctprintf("%s", devs[sel].name)
	return "system default"
}

// apply_rig pushes a song's saved rig onto the live monitor (audio.odin globals).
apply_rig :: proc(r: Rig) {
	audio_monitor_enable(r.monitor)
	audio_set_monitor_drive(r.drive)
	audio_set_monitor_tone(r.bass_db, r.treble_db)
	audio_set_monitor_level(r.level)
	audio_set_monitor_cab(r.cab)
}

// current_rig snapshots the live monitor + speed for saving with the song.
current_rig :: proc() -> Rig {
	b, tr := audio_monitor_tone()
	return Rig {
		monitor = audio_monitor_on(),
		drive = audio_monitor_drive(),
		bass_db = b,
		treble_db = tr,
		level = audio_monitor_level(),
		cab = audio_monitor_cab(),
		speed = player_speed(),
	}
}

// adjust_monitor_tone nudges the monitor bass/treble shelves (dB), clamped.
adjust_monitor_tone :: proc(dbass, dtreble: f32) {
	b, tr := audio_monitor_tone()
	audio_set_monitor_tone(clamp(b + dbass, -12, 12), clamp(tr + dtreble, -12, 12))
}

// song_out_dir is the library folder for an imported file: "library/<slug>".
// Written into `buf`.
song_out_dir :: proc(buf: []u8, path: string) -> string {
	n := copy(buf, LIBRARY_DIR + "/")
	s := songlib.slug(base_name(path), buf[n:])
	return string(buf[:n + len(s)])
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
