package main

// `--screenshot` mode: seed a temp trial log with realistic history, render the
// drill / progress / feedback / fullscreen screens, and write PNGs for visual
// inspection. Opens a window but takes no input. Dispatched from `main`.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

import "clock"
import "store"

// screenshot renders the drill screen and the progress panel (with some seeded
// trial data so they aren't empty) and writes PNGs, for visual inspection.
screenshot :: proc() {
	which := "drill"
	for a in os.args {
		if a == "progress" || a == "feedback" || a == "fullscreen" || a == "import" || a == "importdone" || a == "library" || a == "player" || a == "settings" {
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
		// 8 frames, matching shot_frame: TakeScreenshot reads back the buffer the
		// compositor last presented, which lags the draw — with only two warm-up
		// frames the capture comes out all-black.
		for _ in 0 ..< 8 {
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
	case "settings":
		shot_frame(proc() {settings_draw(true, "offset 12 samples (0.25 ms)")}, "gt_settings.png")
		fmt.println("wrote gt_settings.png")
	case "import":
		b: Browser
		browser_open(&b, "assets") // has some .wav files to list
		defer browser_close(&b)
		g_shot_browser = &b
		shot_frame(proc() {browser_draw(g_shot_browser)}, "gt_import.png")
		// Marked rows (the batch-import set), then the Places jump list — the
		// latter reads real mounts, so this doubles as a check that a NAS share
		// or USB stick is actually discovered on this machine.
		browser_toggle_mark(&b)
		browser_move(&b, 1)
		browser_toggle_mark(&b)
		shot_frame(proc() {browser_draw(g_shot_browser)}, "gt_import_marked.png")
		browser_open_places(&b)
		shot_frame(proc() {browser_draw(g_shot_browser)}, "gt_import_places.png")
		fmt.println("wrote gt_import.png gt_import_marked.png gt_import_places.png")
	case "importdone":
		// Fake a finished batch (with one failure) to render the summary screen.
		g_queue.total = 12
		g_queue.done = 12
		g_queue.failed = 1
		g_queue.finished = true
		g_queue.elapsed = 11 * time.Minute + 24 * time.Second
		g_queue.failures = make([dynamic]string)
		// cloned: queue_reset frees every entry, so a literal would be freed too
		append(&g_queue.failures, strings.clone("09 Corrupted Track.mp3"))
		defer queue_reset()
		shot_frame(proc() {importing_draw("")}, "gt_import_done.png")
		fmt.println("wrote gt_import_done.png")
	case "library":
		root := seed_library() // temp dir with a couple finished songs
		defer os.remove_all(root)
		lv: Library_View
		library_view_reload(&lv, root)
		defer library_view_close(&lv)
		g_shot_lib = &lv
		// One capture per drill-down level, descending into the first artist
		// (Black Sabbath) and then its first album (Master of Reality).
		shot_frame(proc() {library_view_draw(g_shot_lib)}, "gt_library.png")
		_, _ = library_view_enter(&lv) // -> Album
		shot_frame(proc() {library_view_draw(g_shot_lib)}, "gt_library_albums.png")
		_, _ = library_view_enter(&lv) // -> Song
		shot_frame(proc() {library_view_draw(g_shot_lib)}, "gt_library_songs.png")
		fmt.println("wrote gt_library.png gt_library_albums.png gt_library_songs.png")
	case "player":
		// A synthetic ~3-min song (frames drive the display; stems are silent so
		// nothing plays during capture): guitar turned down, drums muted.
		sa: Song_Audio
		sa.frames = 197 * int(clock.SAMPLE_RATE)
		for i in 0 ..< 6 {
			sa.ctl[i] = {level = 1}
			sa.stems[i] = make([]f32, 1)
		}
		sa.ctl[3].level = 0.15 // guitar (index 3) down — the play-along move
		sa.ctl[1].mute = true // drums muted
		// load cabs + set a rig so the monitor line is populated
		cab_paths: [len(g_ir_files)]string
		for e, i in g_ir_files do cab_paths[i] = e.path
		audio_monitor_load_cabs(cab_paths[:])
		audio_monitor_enable(true)
		audio_set_monitor_drive(3.5)
		audio_set_monitor_tone(2, 4)
		audio_set_monitor_level(0.6)
		audio_set_monitor_cab(0)

		player_open(sa)
		player_toggle() // pause so nothing sounds during the shot
		player_set_speed(0.75) // show a slowed-down practice speed
		// set an A-B loop (paused, so a seek pins the cursor for marking)
		player_seek(sa.frames / 4)
		time.sleep(20 * time.Millisecond)
		player_loop_mark()
		player_seek(sa.frames * 2 / 3)
		time.sleep(20 * time.Millisecond)
		player_loop_mark()
		player_seek(sa.frames / 3)
		time.sleep(40 * time.Millisecond) // let the producer apply the seek
		shot_frame(proc() {player_view_draw("Sweet Leaf", "Black Sabbath", 3)}, "gt_player.png")
		player_close()
		stems_free(&sa)
		fmt.println("wrote gt_player.png")
	case:
		shot_frame(proc() {drill_draw(g_shot_drill, true, true)}, "gt_drill.png")
		fmt.println("wrote gt_drill.png")
	}
}

@(private = "file")
g_shot_browser: ^Browser
@(private = "file")
g_shot_lib: ^Library_View

// seed_library builds a temp library dir of finished (6-stem) songs so the
// Library screenshots aren't empty. Spans two artists, one of them with two
// albums and out-of-order track numbers, so the grouping and the track sort are
// both visible in the capture. Returns the root path.
@(private = "file")
Shot_Song :: struct {
	slug, artist, album, title: string,
	track, year:                int,
}

@(private = "file")
seed_library :: proc() -> string {
	root :: "/tmp/gt_shotlib"
	os.remove_all(root)
	_ = os.make_directory(root)
	// Deliberately not in display order: library_scan must sort these.
	songs := []Shot_Song {
		{"black-dog", "Led Zeppelin", "Led Zeppelin IV", "Black Dog", 1, 1971},
		{"sweet-leaf", "Black Sabbath", "Master of Reality", "Sweet Leaf", 1, 1971},
		{"rock-and-roll", "Led Zeppelin", "Led Zeppelin IV", "Rock and Roll", 2, 1971},
		{"paranoid", "Black Sabbath", "Paranoid", "Paranoid", 2, 1970},
		{"children-of-the-grave", "Black Sabbath", "Master of Reality", "Children of the Grave", 4, 1971},
		{"war-pigs", "Black Sabbath", "Paranoid", "War Pigs", 1, 1970},
		{"after-forever", "Black Sabbath", "Master of Reality", "After Forever", 3, 1971},
	}
	for song in songs {
		dir := fmt.tprintf("%s/%s", root, song.slug)
		_ = os.make_directory(dir)
		for stem in ([]string{"vocals", "drums", "bass", "guitar", "piano", "other"}) {
			_ = os.write_entire_file(fmt.tprintf("%s/%s.wav", dir, stem), []byte{})
		}
		meta := fmt.tprintf(
			"artist %s\nalbumartist %s\nalbum %s\ntitle %s\ntrack %d\nyear %d\n",
			song.artist,
			song.artist,
			song.album,
			song.title,
			song.track,
			song.year,
		)
		_ = os.write_entire_file(fmt.tprintf("%s/meta.txt", dir), transmute([]u8)meta)
	}
	return root
}

@(private = "file")
g_shot_drill: ^Drill

@(private = "file")
shot_frame :: proc(draw: proc(), file: cstring) {
	// Render several frames before capturing. TakeScreenshot reads back the
	// buffer the compositor last presented, which lags the draw by a swap or
	// two — with only a couple of warm-up frames the capture comes out empty
	// (all-black, not even the ClearBackground colour) on some compositors.
	for _ in 0 ..< 8 {
		rl.BeginDrawing()
		rl.ClearBackground({18, 18, 22, 255})
		draw()
		rl.EndDrawing()
	}
	rl.TakeScreenshot(file)
}
