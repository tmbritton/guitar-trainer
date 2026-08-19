package main

import "core:time"

import "calib"
import "clock"

// run_calibration schedules N spaced clicks, matches each against detected
// onsets, and stores the aggregated (median) round-trip offset in samples.
// Runs on the main thread; safe to call from a calibration screen or headless.
run_calibration :: proc(n: int) -> (offset: i64, ok: bool) {
	lead := u64(clock.SAMPLE_RATE / 5) // 0.2 s ahead — well past the onset refractory
	window := u64(clock.SAMPLE_RATE / 20) // 50 ms match window

	// Flush any stale onsets first.
	for {
		_, more := audio_poll()
		if !more do break
	}

	offsets := make([dynamic]i64, 0, n)
	defer delete(offsets)
	collected := make([dynamic]u64, 0, 16)
	defer delete(collected)

	for _ in 0 ..< n {
		clear(&collected)
		target := audio_clock_now() + lead
		audio_schedule_click(target)

		for audio_clock_now() <= target + window {
			for {
				ev, more := audio_poll()
				if !more do break
				append(&collected, ev.sample_pos)
			}
			time.sleep(time.Millisecond)
		}
		// final drain after the window closes
		for {
			ev, more := audio_poll()
			if !more do break
			append(&collected, ev.sample_pos)
		}

		if off, matched := calib.match_click(target, collected[:], window); matched {
			append(&offsets, off)
		}
	}

	offset, ok = calib.aggregate(offsets[:])
	if ok {
		audio_set_offset(offset)
	}
	return
}
