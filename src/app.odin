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
	// Must precede InitWindow — config flags set afterwards are ignored.
	rl.SetConfigFlags({.WINDOW_RESIZABLE})
	rl.InitWindow(WINDOW_W, WINDOW_H, "Guitar Trainer")
	defer rl.CloseWindow()

	// An ordinary window: fullscreen is the window manager's job, and forcing it
	// took over the machine while a long import ran. Every screen is drawn at a
	// fixed 800x480 into an offscreen texture, then scaled and centred (black
	// letterbox) to whatever size the window is, so any size works.
	// The cursor stays visible — you need it to move and resize the window.
	rl.SetWindowMinSize(WINDOW_W / 2, WINDOW_H / 2) // below this the text stops being readable
	rl.SetTargetFPS(60)

	// raylib's default exit key is ESC, which would close the window from any
	// screen before the per-screen handlers below could treat ESC as "go back".
	// Disable it and let each screen decide; only .Main_Menu quits on ESC.
	// WindowShouldClose() still reports a real window-manager close (X, alt-F4).
	rl.SetExitKey(.KEY_NULL)

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
	player_dir_buf, player_name_buf, player_artist_buf: [512]u8
	player_dir, player_name, player_artist: string
	// A song chosen while the previous (cancelled) load is still draining. ESC
	// deliberately does not join the decode workers, so for a moment the loader
	// refuses a new job — without this latch that ENTER would vanish with no
	// feedback at all, which is exactly the "the app dropped my keystroke"
	// feeling the async load was meant to remove.
	pending_open: bool
	defer stems_load_shutdown() // don't leave decode workers running on quit

	screen := Screen.Main_Menu
	main_items := [?]cstring{"Play a Song", "Import Song", "Practice Drill", "Settings", "Quit"}
	main_menu := Menu_Widget {
		title = "GUITAR TRAINER",
		items = main_items[:],
	}

	for !rl.WindowShouldClose() {
		frame_begin()

		// Drag-drop import: dropping an audio file anywhere starts the same import
		// flow as the file browser (unless an import is already running).
		if rl.IsFileDropped() {
			dropped := rl.LoadDroppedFiles()
			// ignore drops while a song is playing or an import is running (those
			// screens own state we'd otherwise leak by switching away).
			if dropped.count > 0 && screen != .Importing && screen != .Loading && screen != .Player {
				path := string(dropped.paths[0])
				if songlib.is_supported_audio(path) {
					// leaving the Drill mid-trial must abandon it (drain the ring,
					// reset to Idle) — same as the ESC handler, else a stray onset
					// gets misattributed to a phantom trial on return.
					if screen == .Drill && audio_ok do drill_abandon(&d)
					import_name = string(import_name_buf[:copy(import_name_buf[:], base_name(path))])
					out_buf: [512]u8
					import_start(path, song_out_dir(out_buf[:], path))
					screen = .Importing
				}
			}
			rl.UnloadDroppedFiles(dropped)
		}

		// ---- update the current screen ----
		switch screen {
		case .Main_Menu:
			switch menu_input(&main_menu) {
			case 0:
				library_view_reload(&lib, library_root())
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
			switch browser.mode {
			case .Path:
				// Text entry owns the keyboard while it's open.
				for c := rl.GetCharPressed(); c != 0; c = rl.GetCharPressed() {
					browser_path_char(&browser, c)
				}
				if rl.IsKeyPressed(.BACKSPACE) do browser_path_backspace(&browser)
				if rl.IsKeyPressed(.V) && (rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)) {
					for c in string(rl.GetClipboardText()) do browser_path_char(&browser, c)
				}
				if rl.IsKeyPressed(.ENTER) do browser_path_commit(&browser)
				if rl.IsKeyPressed(.ESCAPE) do browser.mode = .Browse

			case .Places:
				if rl.IsKeyPressed(.DOWN) do browser.place_sel = menu.move(browser.place_sel, len(browser.places), 1)
				if rl.IsKeyPressed(.UP) do browser.place_sel = menu.move(browser.place_sel, len(browser.places), -1)
				if rl.IsKeyPressed(.ENTER) do browser_places_enter(&browser)
				if rl.IsKeyPressed(.ESCAPE) do browser.mode = .Browse

			case .Browse:
				if rl.IsKeyPressed(.DOWN) do browser_move(&browser, 1)
				if rl.IsKeyPressed(.UP) do browser_move(&browser, -1)
				if rl.IsKeyPressed(.BACKSPACE) do browser_up(&browser)
				if rl.IsKeyPressed(.P) do browser_open_places(&browser)
				if rl.IsKeyPressed(.L) do browser_path_begin(&browser)
				if rl.IsKeyPressed(.SPACE) do browser_toggle_mark(&browser)
				if rl.IsKeyPressed(.C) do browser_clear_marks(&browser)
				if rl.IsKeyPressed(.I) && browser_mark_count(&browser) > 0 {
					// Batch: expand the marked albums/folders into a file queue.
					// Everything already in the library is skipped, so nothing
					// is separated twice.
					if queue_expand(browser.marks[:]) > 0 && queue_start() {
						browser_clear_marks(&browser)
						import_name = ""
						screen = .Importing
					} else {
						// Everything marked is already in the library — say so,
						// or the keypress looks like it was dropped.
						browser_set_status(&browser, "already imported — nothing to do")
					}
				}
				if rl.IsKeyPressed(.ENTER) {
					if action, path := browser_enter(&browser); action == .Import {
						import_name = string(import_name_buf[:copy(import_name_buf[:], base_name(path))])
						out_buf: [512]u8
						import_start(path, song_out_dir(out_buf[:], path))
						screen = .Importing
					}
				}
				if rl.IsKeyPressed(.ESCAPE) do screen = .Main_Menu
			}

		case .Importing:
			// A batch run advances itself: when one song finishes, the queue
			// starts the next. queue_poll is a no-op for a single import.
			queue_poll()
			// leave when the user acknowledges (ESC always; ENTER once finished).
			// A batch's completion comes from the queue's latched flag, never
			// from the per-song state: queue_poll resets that as it retires the
			// last song, so it reads Idle forever after.
			_, st := import_progress()
			done := queue_is_batch() ? queue_finished() : (st == .Done || st == .Error)
			if rl.IsKeyPressed(.ESCAPE) || (done && rl.IsKeyPressed(.ENTER)) {
				queue_cancel() // drop any remaining queue
				import_cancel() // kill a still-running separator so the join is prompt
				import_reset()
				library_view_reload(&lib, library_root())
				screen = .Library
			}

		case .Library:
			if rl.IsKeyPressed(.DOWN) do library_view_move(&lib, 1)
			if rl.IsKeyPressed(.UP) do library_view_move(&lib, -1)
			if rl.IsKeyPressed(.ENTER) {
				// ENTER descends Artist -> Album -> Song; only the Song level
				// yields a song to load.
				if s, chosen := library_view_enter(&lib); chosen {
					// Decoding six stems takes seconds; it runs on workers now
					// (stemload.odin) so the UI keeps drawing. Copy the display
					// strings out of the Song here — it points into lib.songs,
					// which a library reload would free underneath us.
					player_dir = string(player_dir_buf[:copy(player_dir_buf[:], s.dir)])
					// Show the tagged title, not the folder slug.
					player_name = string(
						player_name_buf[:copy(player_name_buf[:], song_title(s))],
					)
					player_artist = string(
						player_artist_buf[:copy(player_artist_buf[:], song_artist(s))],
					)
					// If the loader is still draining a cancelled job it refuses
					// here; the Loading screen retries every frame and says so.
					pending_open = !stems_load_begin(player_dir)
					screen = .Loading
				}
			}
			// ESC walks back up the drill-down, and only leaves for the menu
			// once we're at the top (Artist) level.
			if rl.IsKeyPressed(.ESCAPE) && !library_view_back(&lib) do screen = .Main_Menu

		case .Loading:
			// ESC abandons the load. It does not join the workers — a stem on a
			// network share can take seconds, and blocking here would be the
			// very freeze this screen exists to remove. The load is left to
			// drain and is reaped by the per-frame stems_load_poll above.
			if rl.IsKeyPressed(.ESCAPE) {
				pending_open = false
				stems_load_cancel()
				screen = .Library
			} else if pending_open {
				pending_open = !stems_load_begin(player_dir) // retry until it takes
			} else if stems_load_poll() == .Ready {
				if sa, took := stems_load_take(); took {
					player_song = sa
					ctl, rig, _ := prefs_load(player_dir)
					for i in 0 ..< 6 do player_song.ctl[i] = ctl[i]
					apply_rig(rig)
					player_sel = 0
					player_open(player_song)
					player_set_speed(rig.speed) // after open (which resets speed to 1.0)
					screen = .Player
				}
			}
			// A .Failed load stays on screen with its message until ESC — the
			// alternative is bouncing back to the library with no explanation.

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
			if rl.IsKeyPressed(.D) do audio_set_monitor_dry(!audio_monitor_dry())
			if rl.IsKeyPressed(.L) do player_loop_mark() // A-B loop: mark A, mark B, clear
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
		case .Loading:
			loading_draw(player_name, player_artist, pending_open)
		case .Player:
			player_view_draw(player_name, player_artist, player_sel)
		}
		rl.EndTextureMode()

		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		blit_fit(target, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()))
		rl.EndDrawing()
	}
}

// frame_begin is the prologue of every run_app frame.
//
// It is a named procedure rather than two inline statements so --tempcheck can
// drive the *actual* per-frame reset: an inline free_all would leave the fix
// with no regression coverage at all, since a headless test can never enter
// run_app's loop.
frame_begin :: proc() {
	// Odin's temp allocator is a growing arena — it reclaims nothing until
	// something frees it. Draw code formats a dozen strings a frame, so without
	// this the process grows for as long as the window is open. Safe because
	// nothing that outlives a frame is temp-allocated: browser entries, library
	// songs and their tags are all cloned into the heap allocator (asserted by
	// --tempcheck).
	free_all(context.temp_allocator)

	// Advance the async stem loader. Called unconditionally, not just on the
	// Loading screen: this is what reaps a load the user cancelled, which by
	// then is running behind whatever screen they went back to.
	stems_load_poll()
}

// ---- screens ----

Screen :: enum {
	Main_Menu,
	Drill,
	Settings,
	Library,
	Import,
	Importing,
	Loading,
	Player,
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
	audio_set_monitor_dry(r.dry)
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
		dry = audio_monitor_dry(),
	}
}

// adjust_monitor_tone nudges the monitor bass/treble shelves (dB), clamped.
adjust_monitor_tone :: proc(dbass, dtreble: f32) {
	b, tr := audio_monitor_tone()
	audio_set_monitor_tone(clamp(b + dbass, -12, 12), clamp(tr + dtreble, -12, 12))
}

// song_out_dir is the library folder for an imported file:
// "<library>/<slug>-<hash>". The hash is over the full source path — without it
// two files with the same name in different albums ("Album A/01 Intro.mp3" and
// "Album B/01 Intro.mp3") resolved to the same folder and the second separation
// silently overwrote the first. Written into `buf`.
song_out_dir :: proc(buf: []u8, path: string) -> string {
	n := copy(buf, library_root())
	n += copy(buf[n:], "/")
	s := songlib.unique_slug(path, buf[n:])
	return string(buf[:n + len(s)])
}

// song_out_dir_legacy is the pre-hash folder name ("<library>/<slug>"), kept so
// songs imported before the collision fix are still recognised as imported and
// are never needlessly separated again. See already_imported.
song_out_dir_legacy :: proc(buf: []u8, path: string) -> string {
	n := copy(buf, library_root())
	n += copy(buf[n:], "/")
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
