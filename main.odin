package main

import "core:fmt"
import "core:os"
import "core:time"
import rl "vendor:raylib"

import "clock"
import "detect"
import "game"

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
	}
	run_app()
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
			if !r.voiced || abs(r.freq - freq) > 1.5 {
				fmt.eprintfln("FAIL @ %.0f Hz: detected %.2f Hz (voiced=%v)", freq, r.freq, r.voiced)
				return false
			}
			fmt.printfln("  scheduled %.0f Hz -> detected %.2f Hz  OK", freq, r.freq)
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
	rl.SetTargetFPS(60)

	audio_ok := audio_init()
	defer if audio_ok do audio_shutdown()

	onset_count := 0
	last_onset_ms := 0.0
	calib_buf: [96]u8
	calib_status := "not calibrated — press C"

	for !rl.WindowShouldClose() {
		// Press C to calibrate the round-trip offset from real input (emit
		// clicks, hear them back through the pickup/mic). Blocks ~1s.
		if audio_ok && rl.IsKeyPressed(.C) {
			if offset, ok := run_calibration(5); ok {
				calib_status = fmt.bprintf(
					calib_buf[:],
					"offset %d samples (%.2f ms)",
					offset,
					clock.samples_to_ms(u64(abs(offset))),
				)
			} else {
				calib_status = "calibration failed — no click detected (need input)"
			}
		}

		// Drain every onset event the audio thread produced this frame.
		for {
			ev, ok := audio_poll()
			if !ok do break
			onset_count += 1
			last_onset_ms = clock.samples_to_ms(ev.sample_pos)
		}

		rl.BeginDrawing()
		rl.ClearBackground({18, 18, 22, 255})

		title := fmt.ctprintf("Guitar Trainer  ·  miniaudio %s", audio_version())
		rl.DrawText(title, 24, 24, 20, {230, 230, 235, 255})

		if audio_ok {
			clock_ms := clock.samples_to_ms(audio_clock_now())
			rl.DrawText(fmt.ctprintf("audio clock: %.2f s", clock_ms / 1000), 24, 64, 18, {150, 200, 150, 255})
			rl.DrawText(fmt.ctprintf("onsets: %d", onset_count), 24, 92, 18, {200, 200, 150, 255})
			rl.DrawText(fmt.ctprintf("last onset @ %.0f ms", last_onset_ms), 24, 120, 18, {180, 180, 180, 255})

			// input level meter
			lvl := audio_input_level()
			bar_w := i32(clamp(lvl * 4, 0, 1) * 400)
			rl.DrawText("input", 24, 160, 16, {150, 150, 160, 255})
			rl.DrawRectangleLines(90, 158, 400, 20, {80, 80, 90, 255})
			rl.DrawRectangle(90, 158, bar_w, 20, {120, 200, 120, 255})

			rl.DrawText(fmt.ctprintf("calibration: %s", calib_status), 24, 200, 18, {180, 180, 220, 255})
		} else {
			rl.DrawText("audio device failed to initialize", 24, 64, 18, {220, 120, 120, 255})
		}

		rl.DrawText("clap/pluck to trigger an onset  ·  ESC to quit", 24, 440, 16, {110, 110, 120, 255})
		rl.EndDrawing()
	}
}
