package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:time"
import rl "vendor:raylib"

import "clock"
import "detect"
import "game"
import "music"
import "store"

WINDOW_W :: 800
WINDOW_H :: 480

main :: proc() {
	for arg in os.args[1:] {
		if arg == "--audiocheck" {
			audiocheck()
			return
		}
		if arg == "--calibcheck" {
			calibcheck()
			return
		}
		if arg == "--pitchcheck" {
			pitchcheck()
			return
		}
		if arg == "--synthcheck" {
			synthcheck()
			return
		}
		if arg == "--drillcheck" {
			drillcheck()
			return
		}
		if arg == "--storecheck" {
			storecheck()
			return
		}
		if arg == "--drillsim" {
			drillsim()
			return
		}
		if arg == "--progresscheck" {
			progresscheck()
			return
		}
		if arg == "--screenshot" {
			screenshot()
			return
		}
		if arg == "--sfplaycheck" {
			sfplaycheck()
			return
		}
	}
	run_app()
}

// sfplaycheck loads a SoundFont, renders a note, plays it over the loopback, and
// confirms audio actually comes out (an onset fires and the level rises).
sfplaycheck :: proc() {
	if !audio_init() {
		fmt.eprintln("FAIL: audio_init")
		os.exit(1)
	}
	defer audio_shutdown()
	audio_set_loopback(true)

	if !sf_load_default() {
		fmt.eprintln("SKIP: no soundfont assets present (assets/*.sf2)")
		return
	}
	defer sf_close()
	fmt.printfln("loaded %s / %s", g_sf.label, sf_preset_name())

	for {
		_, more := audio_poll()
		if !more do break
	}
	start := audio_clock_now() + u64(clock.SAMPLE_RATE / 10)
	sf_play_note(57, start, clock.SAMPLE_RATE / 2, 0.9) // A3

	got_onset := false
	peak: f32
	for d := 0; d < 1500 && !got_onset; d += 1 {
		for {
			_, more := audio_poll()
			if !more do break
			got_onset = true
		}
		peak = max(peak, audio_input_level())
		time.sleep(time.Millisecond)
	}
	fmt.printfln("onset=%v  peak_level=%.4f", got_onset, peak)
	if !got_onset || peak < 0.001 {
		fmt.eprintln("FAIL: soundfont note produced no audible output")
		os.exit(1)
	}
	fmt.println("PASS: soundfont note plays through the sample voices")
}

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
	defer sf_close()

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
		shot_frame(proc() {drill_draw(g_shot_drill, true, true, "offset 4 samples (0.08 ms)")}, "gt_feedback.png")
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
			drill_draw(g_shot_drill, true, true, "offset 4 samples (0.08 ms)")
			rl.EndTextureMode()
			rl.BeginDrawing()
			rl.ClearBackground(rl.BLACK)
			blit_fit(tgt, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()))
			rl.EndDrawing()
		}
		rl.TakeScreenshot("gt_fullscreen.png")
		fmt.println("wrote gt_fullscreen.png")
	case:
		shot_frame(proc() {drill_draw(g_shot_drill, true, true, "offset 4 samples (0.08 ms)")}, "gt_drill.png")
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

// progresscheck seeds a temp trial log across two day-buckets and verifies the
// progress aggregates (overall / practice_days / recent_accuracy). No audio.
progresscheck :: proc() {
	path :: "/tmp/gt_progress.db"
	os.remove(path)
	s, ok := store.open(path)
	if !ok {
		fmt.eprintln("FAIL: store.open")
		os.exit(1)
	}
	defer os.remove(path)
	defer store.close(&s)

	seed :: proc(s: ^store.Store, session, midi: i64, correct: bool) {
		store.insert_trial(s, store.Trial_Row{ts = session, session_id = session, target_midi = midi, detected_midi = midi, correct = correct})
	}
	// day 0 (session 100): 3 trials, 2 correct; day 1 (session 100+86400): 2 wrong.
	seed(&s, 100, 60, true)
	seed(&s, 100, 60, true)
	seed(&s, 100, 60, false)
	seed(&s, 100 + 86400, 62, false)
	seed(&s, 100 + 86400, 62, false)

	att, cor := store.overall(&s)
	days := store.practice_days(&s)
	ra, rc := store.recent_accuracy(&s, 2)
	fmt.printfln("overall=%d/%d  practice_days=%d  recent2=%d/%d", cor, att, days, rc, ra)

	ok_all := att == 5 && cor == 2 && days == 2 && ra == 2 && rc == 0
	if !ok_all {
		fmt.eprintln("FAIL: progress aggregates wrong")
		os.exit(1)
	}
	fmt.println("PASS: progress aggregates derived from the trial log")
}

// drillsim drives the frame-stepped drill over loopback, injecting a scripted
// correct/wrong response per trial, and verifies the trials land in SQLite with
// the right `correct` values — proving the live drill loop end to end.
drillsim :: proc() {
	if !audio_init() {
		fmt.eprintln("FAIL: audio_init returned false")
		os.exit(1)
	}
	defer audio_shutdown()
	audio_set_loopback(true)

	path :: "/tmp/gt_drillsim.db"
	os.remove(path)
	db, ok := store.open(path)
	if !ok {
		fmt.eprintln("FAIL: store.open")
		os.exit(1)
	}

	d := drill_init(&db, 123)
	defer drill_destroy(&d)

	want := []bool{true, false, true} // per-trial: inject a correct / wrong note
	last_injected := max(u64)

	for d.total < len(want) {
		drill_update(&d)
		// When a fresh trial reaches Listen, inject the scripted response tone.
		if d.phase == .Listen && d.listen_start != last_injected {
			shift := want[d.total] ? 0 : 1
			resp := d.trial.target_midi + shift
			audio_play_tone(detect.midi_to_freq(resp), d.listen_start, u64(clock.SAMPLE_RATE / 2), 0.6)
			last_injected = d.listen_start
		}
		time.sleep(2 * time.Millisecond)
	}

	store.close(&db)

	// Re-open and verify what was logged.
	db2, ok2 := store.open(path)
	if !ok2 {
		fmt.eprintln("FAIL: reopen")
		os.exit(1)
	}
	defer store.close(&db2)
	n := store.count_trials(&db2)
	if n != i64(len(want)) {
		fmt.eprintfln("FAIL: expected %d trials logged, got %d", len(want), n)
		os.exit(1)
	}
	// Guard against the response_ms unsigned-underflow regression: values must be
	// non-negative and within a sane bound (well under the ~6 s listen timeout).
	lo, hi := store.response_ms_bounds(&db2)
	if lo < 0 || hi > 60_000 {
		fmt.eprintfln("FAIL: response_ms out of range [%d, %d]", lo, hi)
		os.exit(1)
	}
	fmt.printfln("logged %d trials; session correct=%d/%d; response_ms in [%d, %d]", n, d.correct_count, d.total, lo, hi)
	// Two of the three scripted responses were correct.
	if d.correct_count != 2 {
		fmt.eprintfln("FAIL: expected 2 correct, got %d", d.correct_count)
		os.exit(1)
	}
	fmt.println("PASS: live drill loop judges and logs trials over loopback")
	os.remove(path)
}

// storecheck writes a couple of trials to a DB so the result can be
// cross-checked with the `sqlite3` CLI, and confirms the app links sqlite.
storecheck :: proc() {
	path :: "/tmp/gt_storecheck.db"
	os.remove(path)
	s, ok := store.open(path)
	if !ok {
		fmt.eprintln("FAIL: store.open")
		os.exit(1)
	}
	defer store.close(&s)
	store.insert_trial(&s, store.Trial_Row{ts = 1, target_midi = 60, detected_midi = 60, correct = true, session_id = 1})
	store.insert_trial(&s, store.Trial_Row{ts = 2, target_midi = 62, detected_midi = 63, correct = false, session_id = 1})
	fmt.printfln("wrote 2 trials to %s; count_trials=%d", path, store.count_trials(&s))
	fmt.println("cross-check: sqlite3", path, "'select count(*), sum(correct) from trials'")
}

// drillcheck runs full trials over loopback, injecting a simulated "user"
// response, to verify cadence -> target -> listen -> judge end to end.
drillcheck :: proc() {
	if !audio_init() {
		fmt.eprintln("FAIL: audio_init returned false")
		os.exit(1)
	}
	defer audio_shutdown()
	audio_set_loopback(true)

	Case :: struct {
		name:          string,
		response_shift: int, // semitones added to the target for the injected note
		want_correct:  bool,
	}
	cases := []Case {
		{"exact match", 0, true},
		{"wrong note (+1 semitone)", 1, false},
		{"octave-shifted match (+12)", 12, true},
	}

	ok_all := true
	for c in cases {
		trial := game.new_trial(60, 60) // C major, random degree
		response_midi := trial.target_midi + c.response_shift

		// Deliberately non-hop-aligned lead (+37) so listen_start lands mid-block,
		// exercising the onset-quantization boundary the filter must tolerate.
		start := audio_clock_now() + u64(clock.SAMPLE_RATE / 10 + 37)
		listen_start := trial_play(trial, start)
		// inject the simulated user's note at the listen point
		audio_play_tone(detect.midi_to_freq(response_midi), listen_start, u64(clock.SAMPLE_RATE / 2), 0.6)

		detected, correct, ok := trial_listen_and_judge(trial, listen_start, u64(clock.SAMPLE_RATE))
		if !ok {
			fmt.eprintfln("FAIL [%s]: no confident response detected", c.name)
			ok_all = false
		} else if correct != c.want_correct {
			fmt.eprintfln(
				"FAIL [%s]: target deg %d (MIDI %d), played MIDI %d, detected %d -> correct=%v, wanted %v",
				c.name, trial.target_degree, trial.target_midi, response_midi, detected, correct, c.want_correct,
			)
			ok_all = false
		} else {
			fmt.printfln(
				"  [%s] target deg %d, played MIDI %d, detected MIDI %d -> correct=%v  OK",
				c.name, trial.target_degree, response_midi, detected, correct,
			)
		}

		// let the injected tone finish so the detector re-arms
		for audio_clock_now() < listen_start + u64(clock.SAMPLE_RATE * 3 / 5) {
			for {
				_, more := audio_poll()
				if !more do break
			}
			time.sleep(5 * time.Millisecond)
		}
	}
	if !ok_all {
		os.exit(1)
	}
	fmt.println("PASS: trial loop (cadence -> target -> listen -> judge) works over loopback")
}

// synthcheck schedules sine voices and confirms them back over loopback,
// verifying the note-playback engine (audio_play_tone + callback mixing).
synthcheck :: proc() {
	if !audio_init() {
		fmt.eprintln("FAIL: audio_init returned false")
		os.exit(1)
	}
	defer audio_shutdown()
	audio_set_loopback(true)

	ok_all := true
	for freq in ([]f32{330, 440}) {
		// drain, brief silence to re-arm the onset detector
		for {
			_, more := audio_poll()
			if !more do break
		}
		time.sleep(60 * time.Millisecond)

		start := audio_clock_now() + u64(clock.SAMPLE_RATE / 10) // +100ms
		dur := u64(clock.SAMPLE_RATE * 2 / 5) // 400ms
		if !audio_play_tone(freq, start, dur, 0.7) {
			fmt.eprintln("FAIL: voice pool full")
			ok_all = false
			continue
		}
		if !confirm_scheduled_tone(freq) {
			ok_all = false
		}
		// Let the tone finish so the detector re-arms in the trailing silence
		// before the next iteration schedules another note.
		for audio_clock_now() < start + dur + u64(clock.SAMPLE_RATE / 10) {
			for {
				_, more := audio_poll()
				if !more do break
			}
			time.sleep(5 * time.Millisecond)
		}
	}
	if !ok_all {
		os.exit(1)
	}
	fmt.println("PASS: synth voice engine plays scheduled tones detected over loopback")
}

confirm_scheduled_tone :: proc(freq: f32) -> bool {
	scratch := make([]f32, PITCH_WINDOW / 2)
	defer delete(scratch)
	window := make([]f32, PITCH_WINDOW)
	defer delete(window)

	onset_pos: u64
	got_onset := false
	for d := 0; d < 800 && !got_onset; d += 1 {
		for {
			ev, more := audio_poll()
			if !more do break
			onset_pos = ev.sample_pos
			got_onset = true
		}
		time.sleep(time.Millisecond)
	}
	if !got_onset {
		fmt.eprintfln("FAIL @ %.0f Hz: scheduled tone produced no onset", freq)
		return false
	}
	for d := 0; d < 800; d += 1 {
		if r, ok := audio_try_pitch(onset_pos, scratch, window); ok {
			// Assert at the note level: the plucked-string timbre gives YIN a
			// ~10-cent sharp bias (well within a semitone); v0 judges pitch class.
			if !r.voiced || detect.freq_to_midi(r.freq) != detect.freq_to_midi(freq) {
				fmt.eprintfln("FAIL @ %.0f Hz: detected %.2f Hz (midi %d vs %d, voiced=%v)", freq, r.freq, detect.freq_to_midi(r.freq), detect.freq_to_midi(freq), r.voiced)
				return false
			}
			fmt.printfln("  scheduled %.0f Hz -> detected %.2f Hz (note %d)  OK", freq, r.freq, detect.freq_to_midi(r.freq))
			return true
		}
		time.sleep(time.Millisecond)
	}
	fmt.eprintfln("FAIL @ %.0f Hz: window never available", freq)
	return false
}

// pitchcheck drives a continuous test tone over the internal loopback, catches
// the onset, copies the window from history, and confirms the detected pitch —
// verifying onset -> history -> windowed pitch end to end without hardware.
pitchcheck :: proc() {
	if !audio_init() {
		fmt.eprintln("FAIL: audio_init returned false")
		os.exit(1)
	}
	defer audio_shutdown()
	audio_set_loopback(true)

	ok_all := true
	for freq in ([]f32{220, 330, 440}) {
		if !check_one_pitch(freq) {
			ok_all = false
		}
	}
	if !ok_all {
		os.exit(1)
	}
	fmt.println("PASS: onset -> history -> windowed pitch works over loopback")
}

check_one_pitch :: proc(freq: f32) -> bool {
	scratch := make([]f32, PITCH_WINDOW / 2)
	defer delete(scratch)
	window := make([]f32, PITCH_WINDOW)
	defer delete(window)

	// flush stale onsets, silence, let the detector re-arm
	for {
		_, more := audio_poll()
		if !more do break
	}
	audio_set_test_tone(0)
	time.sleep(60 * time.Millisecond)

	audio_set_test_tone(freq)

	// wait for the onset the tone's attack produces
	onset_pos: u64
	got_onset := false
	deadline := 0
	for deadline < 500 && !got_onset {
		for {
			ev, more := audio_poll()
			if !more do break
			onset_pos = ev.sample_pos
			got_onset = true
		}
		time.sleep(time.Millisecond)
		deadline += 1
	}
	if !got_onset {
		fmt.eprintfln("FAIL @ %.0f Hz: no onset from tone attack", freq)
		return false
	}

	// confirm pitch once the window past the onset has been captured
	result: detect.Pitch_Result
	got_pitch := false
	deadline = 0
	for deadline < 500 && !got_pitch {
		if r, ok := audio_try_pitch(onset_pos, scratch, window); ok {
			result = r
			got_pitch = true
		} else {
			time.sleep(time.Millisecond)
			deadline += 1
		}
	}
	audio_set_test_tone(0)

	if !got_pitch {
		fmt.eprintfln("FAIL @ %.0f Hz: window never became available", freq)
		return false
	}
	if !result.voiced || abs(result.freq - freq) > 1.5 {
		fmt.eprintfln("FAIL @ %.0f Hz: detected %.2f Hz (voiced=%v, conf=%.2f)", freq, result.freq, result.voiced, result.confidence)
		return false
	}
	fmt.printfln("  %.0f Hz -> detected %.2f Hz (conf %.2f)  OK", freq, result.freq, result.confidence)
	return true
}

// calibcheck runs calibration over the internal software loopback (no hardware)
// to verify the click-schedule -> detect -> match -> aggregate path end to end.
calibcheck :: proc() {
	if !audio_init() {
		fmt.eprintln("FAIL: audio_init returned false")
		os.exit(1)
	}
	defer audio_shutdown()

	audio_set_loopback(true)
	offset, ok := run_calibration(5)
	if !ok {
		fmt.eprintln("FAIL: calibration produced no matched clicks")
		os.exit(1)
	}
	fmt.printfln("measured round-trip offset: %d samples (%.2f ms) over internal loopback", offset, clock.samples_to_ms(u64(abs(offset))))
	// Software loopback has ~no real latency; offset should be within a couple
	// of blocks of zero. Real acoustic offset (hardware) will be larger/positive.
	if abs(offset) > 256 {
		fmt.eprintln("FAIL: loopback offset implausibly large:", offset)
		os.exit(1)
	}
	fmt.println("PASS: calibration path works (click -> detect -> match -> aggregate)")
}

// audiocheck opens the real duplex device headlessly, runs ~2s, and reports
// whether the master clock advances in real time. This verifies the device +
// callback are genuinely live without needing a window or a human to clap.
audiocheck :: proc() {
	if !audio_init() {
		fmt.eprintln("FAIL: audio_init returned false")
		os.exit(1)
	}
	defer audio_shutdown()

	t0 := audio_clock_now()
	time.sleep(2 * time.Second)
	t1 := audio_clock_now()

	advanced := t1 - t0
	elapsed_s := clock.samples_to_seconds(advanced)
	onsets := 0
	for {
		_, ok := audio_poll()
		if !ok do break
		onsets += 1
	}
	fmt.printfln("clock advanced %d samples in ~2s (=%.3f s of audio)", advanced, elapsed_s)
	fmt.printfln("onsets observed: %d", onsets)
	fmt.printfln("audio-thread alloc attempts: %d (guard armed only under -debug)", audio_alloc_attempts())
	// At 48kHz, ~2s wall should advance ~96000 samples. Accept a wide band to
	// tolerate sleep jitter and device startup; the point is that it moved.
	if advanced < 48000 {
		fmt.eprintln("FAIL: clock did not advance as expected (device/callback not running)")
		os.exit(1)
	}
	fmt.println("PASS: duplex device + master clock are live")
}

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
	}
	defer sf_close()

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
	calib_status := "not calibrated — press C (when idle)"
	show_progress := false

	for !rl.WindowShouldClose() {
		// Calibrate only between trials so it doesn't fight the drill's audio.
		if audio_ok && d.phase == .Idle && rl.IsKeyPressed(.C) {
			if offset, ok := run_calibration(5); ok {
				calib_status = fmt.bprintf(calib_buf[:], "offset %d samples (%.2f ms)", offset, clock.samples_to_ms(u64(abs(offset))))
			} else {
				calib_status = "no click detected (need input)"
			}
		}

		if audio_ok && store_ok {
			drill_update(&d)
		}
		if store_ok && rl.IsKeyPressed(.P) {
			show_progress = !show_progress
		}
		// F cycles the guitar SoundFont, V its preset (voice).
		if rl.IsKeyPressed(.F) {
			sf_next_font()
		}
		if rl.IsKeyPressed(.V) {
			sf_next_preset()
		}

		// draw the 800x480 scene into the offscreen texture
		rl.BeginTextureMode(target)
		rl.ClearBackground(UI_BG)
		if show_progress && store_ok {
			drill_draw_progress(&d)
		} else {
			drill_draw(&d, audio_ok, store_ok, calib_status)
		}
		rl.EndTextureMode()

		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		blit_fit(target, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()))
		rl.EndDrawing()
	}
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

// drill_draw_progress renders the progress view (toggle with P), derived entirely
// from the trial log: practice days, totals, a naive recent-vs-overall trend, and
// per-degree accuracy bars.
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

	rl.DrawText("P back to drill  ·  ESC quit", 22, 452, 16, {90, 90, 120, 255})
}

// drill_draw renders the minimal training HUD. Deliberately spare: no per-note
// green/red, the target degree stays hidden until the answer is revealed.
drill_draw :: proc(d: ^Drill, audio_ok, store_ok: bool, calib_status: string) {
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
	case .Listen:
		phase_label = "LISTEN"
	case .Feedback:
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

	// --- footer ---
	tone := sf_loaded() ? fmt.ctprintf("TONE  %s / %s", g_sf.label, sf_preset_name()) : cstring("TONE  chip synth (no soundfont)")
	rl.DrawText(tone, 22, 410, 16, UI_GOLD)
	rl.DrawText(fmt.ctprintf("calib: %s", calib_status), 22, 430, 16, UI_DIM)
	rl.DrawText("F guitar  ·  V preset  ·  C calibrate  ·  P progress  ·  ESC", 22, 452, 16, {90, 90, 120, 255})
}
