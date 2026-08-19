package main

// Headless self-test / verification modes: the `--*check` command-line entry
// points. Each opens the real audio spine (or a temp store) over the internal
// software loopback and asserts an end-to-end invariant, then exits — no window,
// no hardware. Dispatched from `main` (main.odin).

import "core:fmt"
import "core:os"
import "core:time"

import "core:math"

import "clock"
import "detect"
import "game"
import "music"
import "songlib"
import "store"

// abortcheck verifies that render_stop() aborts an in-flight (slow) NAM render
// promptly instead of waiting the whole ~seconds out (the shutdown-hang fix).
abortcheck :: proc() {
	if !sf_load_default() {
		fmt.eprintln("SKIP: no soundfont assets")
		return
	}
	di_load("assets/clean.sf2")
	nam_amp_load_default()
	ir_load_default()
	defer sf_close()
	defer nam_amp_close()

	// a full cadence clip (the expensive case)
	chords := music.cadence(music.Key{tonic_midi = 45})
	note_store: [4][3]int
	ev: [4]Note_Event
	for ci in 0 ..< 4 {
		note_store[ci] = chords[ci]
		ev[ci] = {notes = note_store[ci][:], hold = CHORD_DUR}
	}

	render_start()
	render_submit(ev[:])
	time.sleep(250 * time.Millisecond) // let it get well into the NAM inference

	t0 := time.tick_now()
	render_stop() // requests abort + joins
	dt := time.duration_milliseconds(time.tick_since(t0))
	fmt.printfln("render_stop() during an in-flight render took %.0f ms", dt)
	if dt > 1000 {
		fmt.eprintln("FAIL: shutdown waited out the whole render (abort not working)")
		os.exit(1)
	}
	fmt.println("PASS: in-flight render aborts promptly on stop")
}

// rigdrillcheck runs the live drill through the FULL rig + background render
// worker (Idle->Prep->Listen->Confirm->Fb_Prep->Feedback), injecting scripted
// responses over loopback — verifying the async render path end to end.
rigdrillcheck :: proc() {
	if !audio_init() {
		fmt.eprintln("FAIL: audio_init")
		os.exit(1)
	}
	defer audio_shutdown()
	audio_set_loopback(true)

	if !sf_load_default() {
		fmt.eprintln("SKIP: no soundfont assets")
		return
	}
	di_load("assets/clean.sf2")
	nam_amp_load_default()
	ir_load_default()
	defer sf_close()
	defer nam_amp_close()
	fmt.printfln("rig: clean DI -> %s -> cab %s", nam_amp_status(), ir_status())

	path :: "/tmp/gt_rigdrill.db"
	os.remove(path)
	db, _ := store.open(path)
	d := drill_init(&db, 1)
	defer drill_destroy(&d)

	want := []bool{true, false}
	last_injected := max(u64)
	deadline := 0
	for d.total < len(want) && deadline < 20000 {
		drill_update(&d)
		if d.phase == .Listen && d.listen_start != last_injected {
			resp := d.trial.target_midi + (want[d.total] ? 0 : 1)
			audio_play_tone(detect.midi_to_freq(resp), d.listen_start, u64(clock.SAMPLE_RATE / 2), 0.7)
			last_injected = d.listen_start
		}
		time.sleep(2 * time.Millisecond)
		deadline += 1
	}
	store.close(&db)

	db2, _ := store.open(path)
	defer store.close(&db2)
	defer os.remove(path)
	n := store.count_trials(&db2)
	fmt.printfln("logged %d trials; correct=%d/%d", n, d.correct_count, d.total)
	if n != i64(len(want)) || d.correct_count != 1 {
		fmt.eprintln("FAIL: rig drill did not judge/log as expected")
		os.exit(1)
	}
	fmt.println("PASS: async rig drill (worker render) works end to end")
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
	di_load("assets/clean.sf2")
	nam_amp_load_default()
	defer nam_amp_close()
	ir_load_default()
	fmt.printfln("rig: clean DI -> %s -> cab %s", nam_amp_status(), ir_status())

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

// drillabandoncheck verifies that leaving the drill mid-trial (ESC to the menu)
// abandons the trial cleanly: the state machine resets to Idle (so no timeout
// "miss" is logged for an unplayed trial), no trial is written, and a stray
// onset captured during the trial is drained so it can't be misattributed to
// the next trial.
drillabandoncheck :: proc() {
	if !audio_init() {
		fmt.eprintln("FAIL: audio_init returned false")
		os.exit(1)
	}
	defer audio_shutdown()
	audio_set_loopback(true)

	path :: "/tmp/gt_abandon.db"
	os.remove(path)
	db, ok := store.open(path)
	if !ok {
		fmt.eprintln("FAIL: store.open")
		os.exit(1)
	}
	defer store.close(&db)
	defer os.remove(path)

	d := drill_init(&db, 1)
	defer drill_destroy(&d)

	// advance to Listen (KS fallback path — no soundfont needed)
	deadline := 0
	for d.phase != .Listen && deadline < 5000 {
		drill_update(&d)
		time.sleep(time.Millisecond)
		deadline += 1
	}
	if d.phase != .Listen {
		fmt.eprintln("FAIL: drill never reached Listen")
		os.exit(1)
	}

	// a stray onset arrives during the trial (ambient noise / a stray pick tap);
	// with no drill_update between here and the abandon it sits in the ring.
	audio_play_tone(220, audio_clock_now() + u64(clock.SAMPLE_RATE / 50), u64(clock.SAMPLE_RATE / 4), 0.6)
	time.sleep(80 * time.Millisecond) // let its onset land in the ring

	// user hits ESC -> leaves the Drill screen mid-trial
	drill_abandon(&d)

	if d.phase != .Idle {
		fmt.eprintfln("FAIL: abandon left phase=%v, expected Idle", d.phase)
		os.exit(1)
	}
	if n := store.count_trials(&db); n != 0 || d.total != 0 {
		fmt.eprintfln("FAIL: abandon logged a trial (db count=%d, session total=%d)", n, d.total)
		os.exit(1)
	}
	if _, more := audio_poll(); more {
		fmt.eprintln("FAIL: abandon left a stray onset in the ring (misattribution risk)")
		os.exit(1)
	}
	fmt.println("PASS: leaving the drill mid-trial abandons cleanly (no log, ring drained)")
}

// importcheck drives the real import worker (spawn -> stdout pipe -> parse) end
// to end against the separator's hermetic --stub mode: no Demucs, no GPU. It
// asserts progress advanced past 0, the state reached Done, and all 6 stem WAVs
// were written — verifying the subprocess/pipe integration without ML deps.
importcheck :: proc() {
	out :: "/tmp/gt_importcheck"
	os.remove_all(out) // clean slate so stale stems can't fake a pass
	defer os.remove_all(out)

	import_start("dummy.wav", out, stub = true)

	saw_progress := false
	final := Import_State.Idle
	for deadline := 0; deadline < 5000; deadline += 1 {
		pct, state := import_progress()
		if pct > 0 && pct < 1 do saw_progress = true
		final = state
		if state == .Done || state == .Error do break
		time.sleep(time.Millisecond)
	}
	import_reset()

	if final != .Done {
		fmt.eprintfln("FAIL: import ended in %v, expected Done", final)
		os.exit(1)
	}
	if !saw_progress {
		fmt.eprintln("FAIL: import never reported intermediate progress")
		os.exit(1)
	}
	for stem in songlib.STEMS {
		path := fmt.tprintf("%s/%s.wav", out, stem)
		if !os.exists(path) {
			fmt.eprintfln("FAIL: import did not write %s", path)
			os.exit(1)
		}
	}
	fmt.println("PASS: song import (stub separator) spawns, reports progress, writes 6 stems")
}

// playercheck drives the song player's producer thread + PCM ring + mixer over
// synthetic in-memory stems (no device: the test stands in as the ring consumer
// via audio_pcm_read). It asserts the mixer math flows through the real DSP path
// — mute-all is silent, solo isolates a stem's energy, pause halts the cursor —
// then covers the decode path by loading 6 tone WAVs from disk.
playercheck :: proc() {
	L :: 48000 // 1 s of mono @ 48 kHz per stem
	// each stem is a distinct constant, so a solo'd stem's RMS equals its value
	amps := [6]f32{0.05, 0.10, 0.15, 0.20, 0.25, 0.30}

	make_synth :: proc(amps: [6]f32, n: int) -> Song_Audio {
		sa: Song_Audio
		sa.frames = n
		for i in 0 ..< 6 {
			sa.ctl[i] = {level = 1}
			s := make([]f32, n)
			for j in 0 ..< n do s[j] = amps[i]
			sa.stems[i] = s
		}
		return sa
	}

	// --- mute all -> silence ---
	a := make_synth(amps, L)
	for i in 0 ..< 6 do a.ctl[i].mute = true
	player_open(a)
	rms_muted := drain_rms(24000)
	player_close()
	stems_free(&a)
	if rms_muted > 1e-4 {
		fmt.eprintfln("FAIL: mute-all should be silent, got RMS %.5f", rms_muted)
		os.exit(1)
	}

	// --- solo one stem -> only its energy ---
	b := make_synth(amps, L)
	b.ctl[3].solo = true // "guitar" is index 3 (songlib.STEMS order)
	player_open(b)
	rms_solo := drain_rms(24000)
	cursor_after := player_cursor()
	player_close()
	stems_free(&b)
	if abs(rms_solo - amps[3]) > 0.01 {
		fmt.eprintfln("FAIL: solo RMS %.4f, expected ~%.4f", rms_solo, amps[3])
		os.exit(1)
	}
	if cursor_after <= 0 {
		fmt.eprintln("FAIL: cursor did not advance during playback")
		os.exit(1)
	}

	// --- pause halts the cursor ---
	c := make_synth(amps, L)
	player_open(c)
	for drain_rms(2000) == 0 {} // let it produce a bit
	player_toggle() // playing -> paused
	time.sleep(20 * time.Millisecond)
	c1 := player_cursor()
	time.sleep(60 * time.Millisecond)
	c2 := player_cursor()
	player_close()
	stems_free(&c)
	if c1 != c2 {
		fmt.eprintfln("FAIL: cursor advanced while paused (%d -> %d)", c1, c2)
		os.exit(1)
	}

	// --- decode path: write 6 tone WAVs, load them ---
	dir :: "/tmp/gt_playerdec"
	os.remove_all(dir)
	os.make_directory(dir)
	defer os.remove_all(dir)
	tone: [L]f32
	for j in 0 ..< L do tone[j] = 0.3 * math.sin(2 * math.PI * 220 * f32(j) / clock.SAMPLE_RATE)
	for stem in songlib.STEMS {
		if !write_wav(fmt.tprintf("%s/%s.wav", dir, stem), tone[:]) {
			fmt.eprintfln("FAIL: could not write %s.wav", stem)
			os.exit(1)
		}
	}
	sa, ok := stems_load(dir)
	defer stems_free(&sa)
	if !ok || sa.frames == 0 {
		fmt.eprintln("FAIL: stems_load produced no audio")
		os.exit(1)
	}
	sumsq: f64 = 0
	for v in sa.stems[0] do sumsq += f64(v) * f64(v)
	if math.sqrt(sumsq / f64(len(sa.stems[0]))) < 0.1 {
		fmt.eprintln("FAIL: decoded stem is unexpectedly quiet")
		os.exit(1)
	}

	fmt.println("PASS: song player mixes stems (mute/solo/pause) and decodes stem files")
}

// drain_rms reads up to `count` player samples from the ring (standing in for the
// callback) and returns their RMS. Sleeps briefly while the producer catches up.
@(private = "file")
drain_rms :: proc(count: int) -> f32 {
	buf: [4096]f32
	sumsq: f64 = 0
	got := 0
	for waited := 0; got < count && waited < 2000; {
		n := audio_pcm_read(buf[:])
		if n == 0 {
			time.sleep(time.Millisecond)
			waited += 1
			continue
		}
		for i in 0 ..< n do sumsq += f64(buf[i]) * f64(buf[i])
		got += n
	}
	return got == 0 ? 0 : f32(math.sqrt(sumsq / f64(got)))
}

// speedcheck drives the player through SoundTouch and verifies the time-stretch
// ratio: in steady state, output-samples-per-input-frame is 1/speed. It samples
// the input cursor across a measurement window (after a warmup) so SoundTouch's
// constant buffering cancels out. Speed 1.0 exercises the bypass path (ratio 1),
// 0.5 the stretch path (ratio ~2).
speedcheck :: proc() {
	// The measurement window must be >> the PCM ring capacity: cursor counts input
	// PUT, drained counts output TAKEN, and they differ by the (bounded) ring fill,
	// so a window many times PCM_RING_CAP makes that fill variance negligible.
	WARMUP :: 48000
	WINDOW :: 600000 // ~37x the ring capacity -> <3% fill-variance error

	ratio_at :: proc(speed: f32) -> f32 {
		sa: Song_Audio
		sa.frames = 1_400_000 // enough input for warmup + window at 0.5x
		for i in 0 ..< 6 {
			sa.ctl[i] = {level = 1}
			sa.stems[i] = make([]f32, i == 0 ? sa.frames : 1)
		}
		for j in 0 ..< sa.frames { // a 220 Hz tone in stem 0 (real content for WSOLA)
			sa.stems[0][j] = 0.4 * math.sin(2 * math.PI * 220 * f32(j) / clock.SAMPLE_RATE)
		}
		player_open(sa)
		player_set_speed(speed)
		drain_n(WARMUP) // warmup: let the stretcher reach steady state at this tempo
		c0 := player_cursor()
		drained := drain_n(WINDOW) // measurement window (output samples)
		c1 := player_cursor()
		player_close()
		stems_free(&sa)
		if c1 <= c0 do return 0
		return f32(drained) / f32(c1 - c0) // output / input = 1/speed
	}

	r1 := ratio_at(1.0)
	if abs(r1 - 1.0) > 0.05 {
		fmt.eprintfln("FAIL: speed 1.0 (bypass) ratio %.3f, expected ~1.0", r1)
		os.exit(1)
	}
	r_half := ratio_at(0.5)
	if abs(r_half - 2.0) > 0.1 {
		fmt.eprintfln("FAIL: speed 0.5 stretch ratio %.3f, expected ~2.0", r_half)
		os.exit(1)
	}
	fmt.printfln("PASS: playback speed time-stretches (1.0x ratio %.2f, 0.5x ratio %.2f)", r1, r_half)
}

// drain_n reads exactly `count` player samples from the ring (blocking while the
// producer catches up); returns the number actually drained.
@(private = "file")
drain_n :: proc(count: int) -> int {
	buf: [4096]f32
	got := 0
	for waited := 0; got < count && waited < 20000; {
		n := audio_pcm_read(buf[:min(len(buf), count - got)])
		if n == 0 {
			time.sleep(time.Millisecond)
			waited += 1
			continue
		}
		got += n
	}
	return got
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
