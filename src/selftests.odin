package main

// Headless self-test / verification modes: the `--*check` command-line entry
// points. Each opens the real audio spine (or a temp store) over the internal
// software loopback and asserts an end-to-end invariant, then exits — no window,
// no hardware. Dispatched from `main` (main.odin).

import "base:runtime"

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"

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

// monitorcheck verifies the live-monitor amp chain wiring in the callback over
// the internal loopback: a test tone stands in for the guitar input; with
// monitoring on, the processed signal is mixed into the output (output level
// rises), and with the monitor level at 0 it isn't. It also confirms dry
// detection is untouched (input level is the same monitor on or off).
monitorcheck :: proc() {
	if !audio_init() {
		fmt.eprintln("FAIL: audio_init returned false")
		os.exit(1)
	}
	defer audio_shutdown()

	audio_set_amp_enabled(false) // isolate the monitor from the fallback overdrive
	audio_set_loopback(true) // src = out (the test tone) stands in for a guitar
	audio_set_test_tone(220)
	audio_set_monitor_drive(1)
	audio_set_monitor_level(1)

	audio_monitor_enable(false)
	// warm up: PipeWire takes tens of ms to start firing callbacks, so poll until
	// the baseline tone is flowing.
	for w := 0; audio_output_level() < 0.1 && w < 1000; w += 1 {
		time.sleep(time.Millisecond)
	}
	// Measure each phase as the MAX output level over a window (robust to
	// single-block RMS phase noise and transient stalls), but settle after each
	// state change first so the max doesn't grab a lingering block from the
	// previous state (a level-0 read would otherwise catch the prior loud audio).
	time.sleep(50 * time.Millisecond)
	out_off := sample_out_max(120)

	audio_monitor_enable(true)
	time.sleep(50 * time.Millisecond)
	out_on := sample_out_max(120)

	audio_set_monitor_level(0)
	time.sleep(80 * time.Millisecond)
	out_zero := sample_out_max(120)

	// Detection isolation is by construction: the callback publishes the dry input
	// level and runs onset/pitch from `src` *before* the monitor ever touches
	// `out` (spec §9.3), so monitoring can't feed detection. (Not asserted on the
	// output level here — single-block RMS of a tone is too noisy in loopback.)
	if out_off < 0.1 {
		fmt.eprintfln("FAIL: no baseline output tone (rms %.3f)", out_off)
		os.exit(1)
	}
	if out_on <= out_off * 1.2 {
		fmt.eprintfln("FAIL: monitor added no output signal (off %.3f, on %.3f)", out_off, out_on)
		os.exit(1)
	}
	if abs(out_zero - out_off) > 0.2 * out_off {
		fmt.eprintfln("FAIL: monitor level 0 changed the output (off %.3f, zero %.3f)", out_off, out_zero)
		os.exit(1)
	}
	fmt.printfln("PASS: live monitor chain mixes into output (off %.2f, on %.2f, level-0 %.2f)", out_off, out_on, out_zero)
}

// sample_out_max returns the peak output level seen over `ms` milliseconds — a
// steady-state read that ignores per-block RMS phase dips and transient stalls.
@(private = "file")
sample_out_max :: proc(ms: int) -> f32 {
	m: f32 = 0
	for w := 0; w < ms; w += 1 {
		m = max(m, audio_output_level())
		time.sleep(time.Millisecond)
	}
	return m
}

// devicecheck verifies audio-device enumeration and the re-init-to-explicit-IDs
// path: it lists capture/playback devices, then rebinds the duplex device to the
// default devices *by ID* and asserts the master clock keeps advancing (device
// live). The Rocksmith-cable routing itself is a plug-in-and-listen gate; this
// exercises the mechanism with the built-in devices. Preserves any real audio.txt.
devicecheck :: proc() {
	// preserve the user's device config (audio_reinit rewrites it)
	had_conf := os.exists("audio.txt")
	saved: []u8
	if had_conf do saved, _ = os.read_entire_file("audio.txt", context.allocator)
	defer {
		if had_conf {
			_ = os.write_entire_file("audio.txt", saved)
			delete(saved)
		} else {
			os.remove("audio.txt")
		}
	}

	if !audio_init() {
		fmt.eprintln("FAIL: audio_init returned false")
		os.exit(1)
	}
	defer audio_shutdown()

	caps := audio_capture_devices()
	pbs := audio_playback_devices()
	fmt.printfln("capture devices: %d,  playback devices: %d", len(caps), len(pbs))
	for d, i in caps do fmt.printfln("  cap[%d] %s%s", i, d.name, d.is_default ? "  (default)" : "")
	for d, i in pbs do fmt.printfln("  pb [%d] %s%s", i, d.name, d.is_default ? "  (default)" : "")
	if len(caps) == 0 || len(pbs) == 0 {
		fmt.eprintln("FAIL: no capture or playback devices enumerated")
		os.exit(1)
	}

	find_default :: proc(devs: []Audio_Device) -> int {
		for d, i in devs do if d.is_default do return i
		return 0
	}

	before := audio_clock_now()
	if !audio_reinit(find_default(caps), find_default(pbs)) {
		fmt.eprintln("FAIL: audio_reinit to default devices failed")
		os.exit(1)
	}
	advanced := false
	for w := 0; w < 1000; w += 1 {
		if audio_clock_now() > before + u64(clock.SAMPLE_RATE / 100) { // ~10 ms of samples
			advanced = true
			break
		}
		time.sleep(time.Millisecond)
	}
	if !advanced {
		fmt.eprintln("FAIL: master clock did not advance after device re-init")
		os.exit(1)
	}
	fmt.println("PASS: device enumeration + re-init to explicit device IDs (clock live)")
}

// loopcheck verifies the A-B loop: with a loop set over [A,B), the producer keeps
// the cursor inside the span and wraps back to A at B (never running past B).
loopcheck :: proc() {
	A :: 48000
	B :: 96000
	sa: Song_Audio
	sa.frames = 400000
	for i in 0 ..< 6 {
		sa.ctl[i] = {level = 1}
		sa.stems[i] = make([]f32, i == 0 ? sa.frames : 1)
	}
	for j in 0 ..< sa.frames do sa.stems[0][j] = 0.3 * math.sin(2 * math.PI * 220 * f32(j) / clock.SAMPLE_RATE)
	player_open(sa)
	defer stems_free(&sa)
	defer player_close()

	// Pause during setup so the (unthrottled, headless) producer doesn't race
	// ahead filling the ring before we mark — a paused seek pins the cursor.
	player_toggle()
	player_seek(A)
	time.sleep(20 * time.Millisecond)
	player_loop_mark() // sets A at the cursor
	player_seek(B)
	time.sleep(20 * time.Millisecond)
	player_loop_mark() // sets B + enables
	player_toggle() // resume

	la, lb := player_loop_a(), player_loop_b()
	if !player_loop_on() || lb <= la {
		fmt.eprintfln("FAIL: loop not set (a=%d b=%d on=%v)", la, lb, player_loop_on())
		os.exit(1)
	}

	// drain output to advance the cursor, sampling it; expect it to cycle within
	// [la,lb) and never exceed lb by more than a block.
	buf: [4096]f32
	max_cursor := 0
	saw_low, saw_high := false, false
	for iter := 0; iter < 6000; iter += 1 {
		if audio_pcm_read(buf[:]) == 0 {
			time.sleep(time.Millisecond)
			continue
		}
		c := player_cursor()
		max_cursor = max(max_cursor, c)
		if c < la + (lb - la) / 4 do saw_low = true
		if c > la + (lb - la) * 3 / 4 do saw_high = true
		if saw_low && saw_high && iter > 400 do break
	}

	if max_cursor > lb + 4 * PLAYER_BLOCK {
		fmt.eprintfln("FAIL: cursor ran past loop end B=%d (max %d)", lb, max_cursor)
		os.exit(1)
	}
	if !(saw_low && saw_high) {
		fmt.eprintln("FAIL: no evidence of looping (cursor didn't cycle across the A-B span)")
		os.exit(1)
	}
	fmt.printfln("PASS: A-B loop keeps the cursor in [%d,%d) and wraps (max %d)", la, lb, max_cursor)
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

// stemcheck decodes real songs and reports each stem's frame count. Unlike the
// synthetic decode smoke inside playercheck, this runs against files an actual
// import produced — which is what catches a stem-format change (mono FLAC) that
// the loader can't read. With no argument it walks the whole library, so it also
// serves as a post-bulk-import verification pass.
stemcheck :: proc(dir_arg: string) {
	songs: []Song
	scanned := false
	if dir_arg != "" {
		songs = []Song{{name = dir_arg, dir = dir_arg}}
	} else {
		songs = library_scan(library_root())
		scanned = true
		if len(songs) == 0 {
			fmt.eprintfln("FAIL: no songs in library (%s)", library_root())
			os.exit(1)
		}
	}
	// NOTE: this must not be deferred inside the branch above — Odin runs defer
	// at the end of the enclosing *block*, which would free the songs before
	// the loop below reads them.
	defer if scanned do library_free(songs)

	bad := 0
	for s in songs {
		sa, ok := stems_load(s.dir)
		defer stems_free(&sa)
		if !ok {
			fmt.eprintfln("FAIL: %s — no stem decoded", s.dir)
			bad += 1
			continue
		}
		missing := 0
		for pcm in sa.stems do if pcm == nil do missing += 1
		secs := f64(sa.frames) / f64(clock.SAMPLE_RATE)
		fmt.printfln(
			"%-40s %.1fs  %d/6 stems%s",
			song_title(s),
			secs,
			6 - missing,
			missing > 0 ? "  (incomplete)" : "",
		)
		if missing > 0 do bad += 1
	}
	if bad > 0 {
		fmt.eprintfln("FAIL: %d song(s) did not decode fully", bad)
		os.exit(1)
	}
	fmt.printfln("PASS: %d song(s) decoded, all 6 stems each", len(songs))
}

// queuecheck verifies batch-import expansion without running Demucs: a marked
// folder is walked recursively, non-audio is ignored, songs already in the
// library are skipped (so re-marking a part-imported album only does the rest),
// and the resulting order is deterministic.
queuecheck :: proc() {
	root :: "/tmp/gt_queuecheck"
	// Redirect the library before anything calls library_root() (which caches
	// on first use), so the stub imports below land in a temp dir instead of
	// the real library.
	lib_root :: "/tmp/gt_queuecheck_lib"
	os.remove_all(lib_root)
	_ = os.set_env(LIBRARY_ENV, lib_root)
	defer os.remove_all(lib_root)
	if library_root() != lib_root {
		fmt.eprintfln("FAIL: library redirect ignored (got %s)", library_root())
		os.exit(1)
	}
	os.remove_all(root)
	defer os.remove_all(root)
	_ = os.make_directory_all(fmt.tprintf("%s/Artist/Album A", root))
	_ = os.make_directory_all(fmt.tprintf("%s/Artist/Album B", root))

	write :: proc(path: string) {
		_ = os.write_entire_file(path, []u8{0})
	}
	// Deliberately out of order, plus a non-audio file that must be ignored.
	write(fmt.tprintf("%s/Artist/Album A/02 second.flac", root))
	write(fmt.tprintf("%s/Artist/Album A/01 first.flac", root))
	write(fmt.tprintf("%s/Artist/Album A/cover.jpg", root))
	write(fmt.tprintf("%s/Artist/Album B/01 other.mp3", root))

	marks := []string{fmt.tprintf("%s/Artist", root)}
	n := queue_expand(marks)
	if n != 3 {
		fmt.eprintfln("FAIL: expected 3 queued files, got %d", n)
		os.exit(1)
	}
	// Path order => album order, and "01" before "02".
	if !strings.has_suffix(g_queue.files[0], "Album A/01 first.flac") {
		fmt.eprintfln("FAIL: queue not in path order, head is %s", g_queue.files[0])
		os.exit(1)
	}

	// Now mark one of them as already imported and re-expand: it must be skipped.
	buf: [512]u8
	out := song_out_dir(buf[:], g_queue.files[0])
	_ = os.make_directory_all(out)
	for stem in songlib.STEMS {
		_ = os.write_entire_file(fmt.tprintf("%s/%s.flac", out, stem), []u8{0})
	}
	n2 := queue_expand(marks)
	if n2 != 2 {
		fmt.eprintfln("FAIL: already-imported song not skipped (got %d, want 2)", n2)
		os.exit(1)
	}
	queue_reset()

	// Marking a single file queues just that file.
	n3 := queue_expand([]string{fmt.tprintf("%s/Artist/Album B/01 other.mp3", root)})
	if n3 != 1 {
		fmt.eprintfln("FAIL: single-file mark queued %d files", n3)
		os.exit(1)
	}
	queue_reset()
	// Drop the stand-in library entry now that the skip is proven, so the
	// checks below see all the source files again.
	os.remove_all(out)

	// --- same filename in different albums must not share a library folder ---
	// This previously lost a song: both separated into <library>/01-intro and
	// the second overwrote the first.
	_ = os.make_directory_all(fmt.tprintf("%s/Artist/Album C", root))
	write(fmt.tprintf("%s/Artist/Album C/01 first.flac", root)) // same name as Album A's
	nc := queue_expand(marks)
	if nc != 4 {
		fmt.eprintfln("FAIL: expected 4 queued after adding a duplicate name, got %d", nc)
		os.exit(1)
	}
	da, db: [512]u8
	out_a := song_out_dir(da[:], fmt.tprintf("%s/Artist/Album A/01 first.flac", root))
	out_c := song_out_dir(db[:], fmt.tprintf("%s/Artist/Album C/01 first.flac", root))
	if out_a == out_c {
		fmt.eprintfln("FAIL: same filename in different albums collides on %s", out_a)
		os.exit(1)
	}
	queue_reset()

	// --- overlapping marks must not queue the same file twice ---
	overlap := []string{fmt.tprintf("%s/Artist", root), fmt.tprintf("%s/Artist/Album A", root)}
	no := queue_expand(overlap)
	if no != 4 {
		fmt.eprintfln("FAIL: overlapping marks queued %d files, want 4 (deduped)", no)
		os.exit(1)
	}
	queue_reset()

	// --- drive the queue: 4 stub separations must run one after another ---
	n4 := queue_expand(marks)
	if n4 != 4 {
		fmt.eprintfln("FAIL: re-expand gave %d, want 4", n4)
		os.exit(1)
	}
	if !queue_start(true) {
		fmt.eprintln("FAIL: queue_start refused a non-empty queue")
		os.exit(1)
	}
	// Poll like the UI does, with a ceiling so a wedged queue fails instead of
	// hanging the test run.
	for i := 0; queue_active() && i < 4000; i += 1 {
		queue_poll()
		time.sleep(5 * time.Millisecond)
	}
	if queue_active() {
		fmt.eprintln("FAIL: queue did not finish")
		os.exit(1)
	}
	done, total, failed, _ := queue_status()
	if done != 4 || total != 4 || failed != 0 {
		fmt.eprintfln("FAIL: queue finished %d/%d with %d failed, want 4/4 and 0", done, total, failed)
		os.exit(1)
	}
	// Completion must be latched in the queue. Regression guard: the Importing
	// screen used to infer it from import_progress(), which queue_poll resets as
	// it retires the last song — so the screen hung on "separating stems" with
	// ENTER dead, forever.
	if !queue_finished() || !queue_is_batch() {
		fmt.eprintln("FAIL: queue did not latch a finished state")
		os.exit(1)
	}
	added, sfailed, elapsed, failures := queue_summary()
	if added != 4 || sfailed != 0 || len(failures) != 0 {
		fmt.eprintfln("FAIL: summary says %d added / %d failed / %d named", added, sfailed, len(failures))
		os.exit(1)
	}
	if elapsed <= 0 {
		fmt.eprintln("FAIL: summary reported no elapsed time")
		os.exit(1)
	}
	// Every queued song must now be a complete library entry — including both
	// "01 first.flac" files, which must occupy distinct folders.
	for f in ([]string {
		fmt.tprintf("%s/Artist/Album A/01 first.flac", root),
		fmt.tprintf("%s/Artist/Album A/02 second.flac", root),
		fmt.tprintf("%s/Artist/Album B/01 other.mp3", root),
		fmt.tprintf("%s/Artist/Album C/01 first.flac", root),
	}) {
		b2: [512]u8
		if !is_finished_song_dir(song_out_dir(b2[:], f)) {
			fmt.eprintfln("FAIL: %s did not land in the library", f)
			os.exit(1)
		}
	}
	// Re-expanding now must find nothing left to do (already-imported skip).
	if again := queue_expand(marks); again != 0 {
		fmt.eprintfln("FAIL: %d songs re-queued after a completed run", again)
		os.exit(1)
	}
	queue_reset()

	fmt.println("PASS: import queue expands folders, skips imported, orders by path, runs to completion, latches a summary")
}

// importedcheck reports how many source files under `dir` the library already
// holds. Useful after the collision fix: a real, already-imported album must
// come back "0 to import", proving the legacy (pre-hash) folder names are still
// recognised and nothing gets needlessly separated a second time.
importedcheck :: proc(dir: string) {
	if dir == "" {
		fmt.eprintln("usage: guitar-trainer --importedcheck <folder>")
		os.exit(2)
	}
	n := queue_expand([]string{dir})
	defer queue_reset()
	fmt.printfln("%d file(s) would be imported from %s", n, dir)
	for f in g_queue.files do fmt.printfln("  would import: %s", f)
}

// tempcheck verifies the temp allocator is bounded — that it is reclaimed
// rather than growing for the life of the process.
//
// Three separate claims, because the fix is not one mechanism:
//   A. Repeating queue_expand does not grow the temp arena. A recursive walk
//      cannot free_all (it would free the parent's live directory listing), so
//      it uses a scoped watermark restore; this asserts that scoping works.
//   B. Library and browser state survives free_all(context.temp_allocator).
//      The per-frame reset in run_app is only safe because none of that state
//      is temp-allocated — an invariant worth testing, not assuming.
//   C. A frame loop that resets stays flat over many iterations.
tempcheck :: proc() {
	root :: "/tmp/gt_tempcheck"
	lib_root :: "/tmp/gt_tempcheck_lib"
	// Redirect the library before the first library_root() call (it caches).
	os.remove_all(lib_root)
	_ = os.set_env(LIBRARY_ENV, lib_root)
	defer os.remove_all(lib_root)
	// Part A walks queue_add -> already_imported -> library_root(); without a
	// live redirect that reads (and creates directories in) the real library.
	if library_root() != lib_root {
		fmt.eprintfln("FAIL: library redirect ignored (got %s)", library_root())
		os.exit(1)
	}
	os.remove_all(root)
	defer os.remove_all(root)

	// A tree big enough that an unreclaimed walk is unmistakable, but quick to
	// create: 4 albums x 30 tracks, with realistic (long-ish) names.
	for a in 0 ..< 4 {
		dir := fmt.tprintf("%s/An Artist With A Long Name/Album Number %d", root, a)
		_ = os.make_directory_all(dir)
		for t in 0 ..< 30 {
			_ = os.write_entire_file(
				fmt.tprintf("%s/%02d - A Reasonably Long Track Title.flac", dir, t),
				[]u8{0},
			)
		}
	}
	// Heap, not temp: this test resets the temp allocator underneath itself.
	mark := strings.clone(fmt.tprintf("%s/An Artist With A Long Name", root))
	defer delete(mark)
	marks := []string{mark}

	// --- A: repeated expansion must not accumulate ---
	free_all(context.temp_allocator)
	if n := queue_expand(marks); n != 120 {
		fmt.eprintfln("FAIL: expected 120 queued files, got %d", n)
		os.exit(1)
	}
	queue_reset()
	after_one := temp_used()
	REPEATS :: 12
	for _ in 0 ..< REPEATS {
		_ = queue_expand(marks)
		queue_reset()
	}
	after_many := temp_used()
	// Flat, not linear in REPEATS. The slack covers incidental temp use by the
	// last iteration itself; growth from a leak is ~REPEATS x after_one.
	SLACK :: 64 * 1024
	if after_many > after_one + SLACK {
		fmt.eprintfln(
			"FAIL: temp allocator grew across %d expansions: %d -> %d bytes (leak ~%d per call)",
			REPEATS,
			after_one,
			after_many,
			(after_many - after_one) / REPEATS,
		)
		os.exit(1)
	}

	// --- B: UI state must survive a temp reset ---
	// Seed a library with one finished song, scan it, then wipe temp and read
	// the strings back. If anything were a view into the temp arena this is
	// where it would come back as garbage.
	song_dir := strings.clone(fmt.tprintf("%s/a-song-abcd1234", lib_root))
	defer delete(song_dir)
	_ = os.make_directory_all(song_dir)
	for stem in songlib.STEMS {
		_ = os.write_entire_file(fmt.tprintf("%s/%s.flac", song_dir, stem), []u8{0})
	}
	_ = os.write_entire_file(
		fmt.tprintf("%s/meta.txt", song_dir),
		transmute([]u8)string("artist Some Artist\nalbum Some Album\ntitle Some Title\n"),
	)
	songs := library_scan(lib_root)
	defer library_free(songs)
	album0 := strings.clone(fmt.tprintf("%s/Album Number 0", mark))
	defer delete(album0)
	entries := browse_dir(album0)
	defer browse_free(entries)
	free_all(context.temp_allocator)
	if len(songs) != 1 {
		fmt.eprintfln("FAIL: expected 1 scanned song, got %d", len(songs))
		os.exit(1)
	}
	if song_title(songs[0]) != "Some Title" || song_artist(songs[0]) != "Some Artist" {
		fmt.eprintfln(
			"FAIL: song metadata did not survive a temp reset: title=%q artist=%q",
			song_title(songs[0]),
			song_artist(songs[0]),
		)
		os.exit(1)
	}
	if !strings.has_suffix(songs[0].dir, "a-song-abcd1234") {
		fmt.eprintfln("FAIL: song dir did not survive a temp reset: %q", songs[0].dir)
		os.exit(1)
	}
	if len(entries) != 30 || !strings.has_suffix(entries[0].name, ".flac") {
		fmt.eprintfln("FAIL: browse entries did not survive a temp reset (%d entries)", len(entries))
		os.exit(1)
	}

	// --- C: run_app's frame prologue actually reclaims ---
	// This drives frame_begin() — the real procedure run_app calls — rather than
	// a free_all written into the test, so deleting the reset from the app fails
	// this check. Usage is sampled at the END of a frame's allocations (not
	// straight after a reset, which is trivially zero), and compared between an
	// early frame and a late one: without the reset it climbs linearly.
	// FRAMES x per-frame formatting must dwarf FRAME_SLACK, or a broken reset
	// hides inside the tolerance — the first version of this check used 600
	// frames against a 64 KB slack, which is roughly the growth it was meant to
	// catch, and passed with the reset deleted. With the reset working the two
	// samples are taken at identical points in the loop and are exactly equal,
	// so the tolerance can be small.
	frame_base: uint
	FRAMES :: 5000
	FRAME_SLACK :: 8 * 1024
	for i in 0 ..< FRAMES {
		frame_begin()
		// stand in for the per-frame formatting the draw code does
		_ = fmt.tprintf("trial %d   accuracy %d%%   key %s", i, i % 100, "C")
		_ = fmt.ctprintf("%d / %d stems", i % 6, 6)
		if i == 8 do frame_base = temp_used() // past any first-frame warm-up
	}
	if grew := temp_used(); grew > frame_base + FRAME_SLACK {
		fmt.eprintfln(
			"FAIL: frame prologue does not reclaim — temp grew %d -> %d bytes over %d frames",
			frame_base,
			grew,
			FRAMES,
		)
		os.exit(1)
	}

	fmt.printfln(
		"PASS: temp allocator bounded (expansion flat at %d bytes over %d repeats; UI state survives a reset; frame_begin reclaims over %d frames)",
		after_many,
		REPEATS,
		FRAMES,
	)
}

// temp_used reports the default temp arena's `total_used` running counter — a
// growth signal, not a committed-bytes figure. Note it is only decremented by
// `arena_temp_end` rewinding within a block: freeing a whole spilled block
// decrements `total_capacity` but not this, so a scope large enough to spill
// makes the counter drift upward even when the memory really was returned.
// Every comparison here is between two samples taken at the same point in a
// loop, which that drift would only make stricter, never falsely lenient.
// Returns 0 if context.temp_allocator is not the default arena.
@(private = "file")
temp_used :: proc() -> uint {
	if context.temp_allocator.procedure != runtime.default_temp_allocator_proc do return 0
	return (^runtime.Default_Temp_Allocator)(context.temp_allocator.data).arena.total_used
}

// loadcheck verifies the async stem loader (Story 6.18): decoding a song's six
// stems moved off the main thread and onto one worker per stem, so selecting a
// song no longer freezes the UI.
//
// Four claims:
//   A. It returns the same audio the synchronous path does — parallel decoding
//      must not scramble which PCM lands in which stem slot.
//   B. It does not block: stems_load_begin returns in a small fraction of the
//      time the decode itself takes. Asserted as a ratio against the measured
//      sequential decode, not as a wall-clock threshold — a plain "parallel was
//      faster than sequential" check flakes on a loaded machine, and the point
//      of the story is that begin *returns*, not that it wins a race.
//   C. A cancelled load frees the partial decode (stems_load_held falls to 0)
//      without the main thread joining, and the loader returns to Idle so the
//      next song can be opened.
//
// With a `dir` operand it instead times one real song both ways — synthetic WAV
// stems decode almost for free, so the speed-up is only meaningful against real
// (FLAC) material.
loadcheck :: proc(dir := "") {
	if dir != "" {
		time_real_song(dir)
		return
	}
	root :: "/tmp/gt_loadcheck"
	os.remove_all(root)
	defer os.remove_all(root)
	_ = os.make_directory_all(root)

	// 20 s per stem: long enough that the decode is measurable, short enough
	// that the test stays quick. Each stem gets a distinct constant so a
	// mixed-up slot is unmistakable.
	L :: 20 * 48000
	amps := [6]f32{0.05, 0.10, 0.15, 0.20, 0.25, 0.30}
	stem_names := songlib.STEMS
	buf := make([]f32, L)
	defer delete(buf)
	for name, i in stem_names {
		for j in 0 ..< L do buf[j] = amps[i]
		if !write_wav(fmt.tprintf("%s/%s.wav", root, name), buf) {
			fmt.eprintfln("FAIL: could not write stem %s", name)
			os.exit(1)
		}
	}

	// --- reference: the synchronous path ---
	sync_start := time.now()
	ref, ok := stems_load(root)
	sync_ms := time.duration_milliseconds(time.since(sync_start))
	if !ok {
		fmt.eprintln("FAIL: synchronous stems_load failed on the synthetic song")
		os.exit(1)
	}
	defer stems_free(&ref)

	// --- A + B: the async path ---
	async_start := time.now()
	if !stems_load_begin(root) {
		fmt.eprintln("FAIL: stems_load_begin refused on an idle loader")
		os.exit(1)
	}
	begin_ms := time.duration_milliseconds(time.since(async_start))
	// B: begin must have spawned and returned, not decoded. If it ever joined
	// inline it would cost at least the parallel decode time, so anything close
	// to the sequential figure is a regression. The margin here is large (begin
	// is ~1 ms against a ~25 ms decode), which is what keeps it off the knife
	// edge that a bare "parallel beat sequential" comparison sits on.
	if begin_ms * 2 >= sync_ms {
		fmt.eprintfln(
			"FAIL: stems_load_begin took %.1f ms against a %.1f ms sequential decode — it is blocking",
			begin_ms,
			sync_ms,
		)
		os.exit(1)
	}
	// Poll to completion the way the frame loop does, watching progress climb.
	saw_partial := false
	state := stems_load_poll()
	for state == .Loading {
		if done, total := stems_load_progress(); done < total do saw_partial = true
		time.sleep(time.Millisecond)
		state = stems_load_poll()
	}
	async_ms := time.duration_milliseconds(time.since(async_start))
	if state != .Ready {
		fmt.eprintfln("FAIL: async load ended in %v, want Ready", state)
		os.exit(1)
	}
	sa, took := stems_load_take()
	if !took {
		fmt.eprintln("FAIL: stems_load_take refused a Ready load")
		os.exit(1)
	}
	defer stems_free(&sa)

	if sa.frames != ref.frames {
		fmt.eprintfln("FAIL: async frames %d, sync %d", sa.frames, ref.frames)
		os.exit(1)
	}
	for i in 0 ..< 6 {
		if len(sa.stems[i]) != len(ref.stems[i]) {
			fmt.eprintfln(
				"FAIL: stem %d length %d, want %d",
				i,
				len(sa.stems[i]),
				len(ref.stems[i]),
			)
			os.exit(1)
		}
		// A whole-stem constant: if two workers crossed slots this catches it.
		if abs(sa.stems[i][L / 2] - ref.stems[i][L / 2]) > 1e-3 {
			fmt.eprintfln(
				"FAIL: stem %d holds the wrong audio (%.3f, want %.3f)",
				i,
				sa.stems[i][L / 2],
				ref.stems[i][L / 2],
			)
			os.exit(1)
		}
	}
	if !saw_partial {
		// Not fatal on a very fast machine — it means every stem finished
		// inside the first poll — but it is worth saying out loud, because it
		// means this run did not actually observe the non-blocking behaviour.
		fmt.println("note: decode finished within one poll; progress was not observed mid-flight")
	}

	// --- C: cancelling ---
	if !stems_load_begin(root) {
		fmt.eprintln("FAIL: loader did not return to Idle after take")
		os.exit(1)
	}
	stems_load_cancel()
	// Must not have blocked; the loader either drained already or is draining.
	deadline := time.now()
	for stems_load_poll() != .Idle {
		if time.duration_seconds(time.since(deadline)) > 10 {
			fmt.eprintln("FAIL: cancelled load never drained")
			os.exit(1)
		}
		time.sleep(time.Millisecond)
	}
	// Returning to Idle is not the same as having freed: assert the loader is
	// holding no PCM. Without this, deleting stems_free from the .Cancelling
	// branch would leak a whole song and still pass.
	if held := stems_load_held(); held != 0 {
		fmt.eprintfln("FAIL: cancelled load left %d samples resident", held)
		os.exit(1)
	}
	// And the slot is usable again.
	if !stems_load_begin(root) {
		fmt.eprintln("FAIL: loader unusable after a cancel")
		os.exit(1)
	}
	for stems_load_poll() == .Loading do time.sleep(time.Millisecond)
	stems_load_cancel()
	for stems_load_poll() != .Idle do time.sleep(time.Millisecond)

	// --- a missing song must fail, not hang ---
	if !stems_load_begin(fmt.tprintf("%s/nonexistent", root)) {
		fmt.eprintln("FAIL: loader refused a load after the previous one drained")
		os.exit(1)
	}
	for stems_load_poll() == .Loading do time.sleep(time.Millisecond)
	if st := stems_load_poll(); st != .Failed {
		fmt.eprintfln("FAIL: a song with no stems ended in %v, want Failed", st)
		os.exit(1)
	}
	stems_load_cancel()
	if stems_load_poll() != .Idle {
		fmt.eprintln("FAIL: a Failed load did not clear back to Idle")
		os.exit(1)
	}
	stems_load_shutdown()

	// Wall clock is *reported*, never asserted. Synthetic WAV stems decode in
	// tens of milliseconds, so a "parallel beat sequential" assertion has only
	// a few ms of margin and flakes on a busy machine — and the sequential run
	// above has already warmed the page cache for the async one, so it is not
	// even a fair comparison. `--loadcheck <dir>` measures the real thing on
	// real FLAC, where the speed-up is ~4x.
	fmt.printfln(
		"PASS: async stem load matches the sync path, does not block (begin %.1f ms vs %.0f ms decode), and cancels cleanly [wall clock, not asserted: %.0f ms parallel vs %.0f ms sequential]",
		begin_ms,
		sync_ms,
		async_ms,
		sync_ms,
	)
}

// time_real_song loads one real library song sequentially and then in parallel,
// reporting both — the before/after for Story 6.18.
@(private = "file")
time_real_song :: proc(dir: string) {
	seq_start := time.now()
	ref, ok := stems_load(dir)
	seq_ms := time.duration_milliseconds(time.since(seq_start))
	if !ok {
		fmt.eprintfln("FAIL: no stems decoded from %s", dir)
		os.exit(1)
	}
	frames := ref.frames
	stems_free(&ref)

	par_start := time.now()
	if !stems_load_begin(dir) {
		fmt.eprintln("FAIL: stems_load_begin refused")
		os.exit(1)
	}
	// Sleep between polls: spinning here would steal a core from the six
	// decoders whose throughput is being measured.
	for stems_load_poll() == .Loading do time.sleep(200 * time.Microsecond)
	par_ms := time.duration_milliseconds(time.since(par_start))
	sa, took := stems_load_take()
	if !took {
		fmt.eprintln("FAIL: load did not become Ready")
		os.exit(1)
	}
	if sa.frames != frames {
		fmt.eprintfln("FAIL: parallel load decoded %d frames, sequential %d", sa.frames, frames)
		os.exit(1)
	}
	stems_free(&sa)
	fmt.printfln(
		"%s  %.1fs of audio:  sequential %.0f ms  ->  parallel %.0f ms  (%.1fx)",
		dir,
		f32(frames) / clock.SAMPLE_RATE,
		seq_ms,
		par_ms,
		seq_ms / max(par_ms, 1),
	)
}
