package main

// The audio spine: a single duplex ma_device we own directly (raylib's audio
// module is never initialized). The callback is the only producer on the master
// clock and the onset ring; the main thread is the only consumer.

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:mem"
import ma "vendor:miniaudio"

import "clock"
import "detect"
import "ring"

RING_CAP :: 1024
CLICK_LEN :: 64 // samples of full-scale burst emitted for a calibration click
CLICK_DISARMED :: max(u64)
HIST_CAP :: 16384 // rolling input history (~341 ms at 48 kHz); power of two
PITCH_WINDOW :: 2048

g_clock: clock.Clock
g_ring: ring.Ring(RING_CAP)
g_onset: detect.Onset_Detector
g_device: ma.device
g_input_rms_bits: u32 // atomic f32 bits: callback-published input level for the UI meter (display only)

g_click_at: u64 = CLICK_DISARMED // atomic: absolute sample pos to emit a click, or CLICK_DISARMED
g_loopback: bool // when true, onset detection reads the output buffer (internal loopback for calibration self-test)
g_offset_samples: i64 // measured round-trip offset, subtracted from judgments

g_history: [HIST_CAP]f32 // rolling input samples, indexed by absolute pos & (HIST_CAP-1)
g_hist_written: u64 // atomic: total samples written to history

g_tone_bits: u32 // atomic: test-tone frequency as f32 bits (0 = off)
g_tone_phase: f32 // callback-local phase accumulator for the test tone

MAX_VOICES :: 32 // a full cadence holds 12 slots (schedule-time..end); leaves ample headroom for target + overlap

// A scheduled sine voice. Main thread activates one (writes fields, then sets
// `active` with release); the callback owns `phase` and deactivates the voice
// when it ends. Single-activator/single-deactivator => no lock needed.
Voice :: struct {
	freq:   f32,
	start:  u64,
	end:    u64,
	amp:    f32,
	phase:  f32,
	active: u32, // atomic 0/1
}

g_voices: [MAX_VOICES]Voice

// audio_version returns the linked miniaudio C library version. Referencing an
// FFI symbol here forces the linker to pull in vendor:miniaudio's static lib.
audio_version :: proc() -> string {
	return string(ma.version_string())
}

audio_init :: proc() -> bool {
	g_onset = detect.default_onset_detector()

	cfg := ma.device_config_init(.duplex)
	cfg.sampleRate = clock.SAMPLE_RATE
	cfg.periodSizeInFrames = 128
	cfg.capture.format = .f32
	cfg.capture.channels = 1
	cfg.playback.format = .f32
	cfg.playback.channels = 1
	cfg.dataCallback = audio_callback
	cfg.pUserData = nil

	if ma.device_init(nil, &cfg, &g_device) != .SUCCESS {
		return false
	}
	if ma.device_start(&g_device) != .SUCCESS {
		ma.device_uninit(&g_device)
		return false
	}
	return true
}

audio_shutdown :: proc() {
	ma.device_stop(&g_device)
	ma.device_uninit(&g_device)
}

// audio_poll drains one event from the ring on the main thread.
audio_poll :: proc() -> (ring.Event, bool) {
	return ring.pop(&g_ring)
}

audio_clock_now :: proc() -> u64 {
	return clock.now(&g_clock)
}

audio_input_level :: proc() -> f32 {
	return transmute(f32)intrinsics.atomic_load(&g_input_rms_bits)
}

// audio_schedule_click arms a calibration click at absolute sample position `at`.
audio_schedule_click :: proc(at: u64) {
	intrinsics.atomic_store(&g_click_at, at)
}

// audio_set_loopback routes the callback's own output back into onset detection,
// so calibration can be exercised without hardware (measures the internal path).
audio_set_loopback :: proc(on: bool) {
	intrinsics.atomic_store(&g_loopback, on)
}

audio_get_offset :: proc() -> i64 {
	return intrinsics.atomic_load(&g_offset_samples)
}

audio_set_offset :: proc(offset: i64) {
	intrinsics.atomic_store(&g_offset_samples, offset)
}

// audio_set_test_tone makes the callback output a continuous sine at `freq`
// (0 = off). With loopback on, this drives the onset->history->pitch path for
// hardware-free verification.
audio_set_test_tone :: proc(freq: f32) {
	intrinsics.atomic_store(&g_tone_bits, transmute(u32)freq)
}

// audio_play_tone schedules a sine voice at absolute sample `start` for `dur`
// samples. Returns false if the voice pool is full. Called from the main thread.
audio_play_tone :: proc(freq: f32, start, dur: u64, amp: f32) -> bool {
	for i in 0 ..< MAX_VOICES {
		v := &g_voices[i]
		if intrinsics.atomic_load(&v.active) != 0 {
			continue
		}
		v.freq = freq
		v.start = start
		v.end = start + dur
		v.amp = amp
		v.phase = 0
		intrinsics.atomic_store(&v.active, 1) // release: fields above are now visible
		return true
	}
	return false
}

// mix_voices adds all active voices into `out` for the block [start, start+n).
@(private = "file")
mix_voices :: proc(out: []f32, start: u64) {
	n := len(out)
	for i in 0 ..< MAX_VOICES {
		v := &g_voices[i]
		if intrinsics.atomic_load(&v.active) == 0 {
			continue
		}
		step := 2 * math.PI * v.freq / clock.SAMPLE_RATE
		for j in 0 ..< n {
			t := start + u64(j)
			if t >= v.start && t < v.end {
				out[j] += v.amp * math.sin(v.phase)
				v.phase += step
				if v.phase > 2 * math.PI {
					v.phase -= 2 * math.PI
				}
			}
		}
		if start + u64(n) >= v.end {
			intrinsics.atomic_store(&v.active, 0)
		}
	}
	// soft clip
	for j in 0 ..< n {
		out[j] = clamp(out[j], -1, 1)
	}
}

// audio_copy_window copies len(out) samples beginning at absolute start_pos from
// the input history. Returns false if those samples haven't been written yet or
// have already been overwritten.
audio_copy_window :: proc(start_pos: u64, out: []f32) -> bool {
	written := intrinsics.atomic_load(&g_hist_written)
	end := start_pos + u64(len(out))
	if end > written {
		return false // not captured yet
	}
	if written > HIST_CAP && start_pos < written - HIST_CAP {
		return false // already overwritten
	}
	for i in 0 ..< len(out) {
		out[i] = g_history[(start_pos + u64(i)) & (HIST_CAP - 1)]
	}
	// Re-check that the callback didn't lap us mid-copy (TOCTOU guard). With
	// HIST_CAP (~341ms) >> window this never fires in practice, but it makes a
	// long main-thread preemption fail cleanly rather than return torn samples.
	if now2 := intrinsics.atomic_load(&g_hist_written); now2 > HIST_CAP && start_pos < now2 - HIST_CAP {
		return false
	}
	return true
}

// audio_try_pitch confirms the pitch of an onset once its window is available.
audio_try_pitch :: proc(
	onset_pos: u64,
	scratch: []f32,
	window: []f32,
) -> (
	detect.Pitch_Result,
	bool,
) {
	if !audio_copy_window(onset_pos, window) {
		return {}, false
	}
	return detect.detect_pitch(window, scratch), true
}

// The realtime audio callback. Runs on the audio thread: no allocation, no
// locking, no logging. Establishes a context with a non-heap allocator per the
// Odin gotcha (see debug.odin for the debug-build asserting allocator).
audio_callback :: proc "c" (pDevice: ^ma.device, pOutput, pInput: rawptr, frameCount: u32) {
	context = runtime.default_context()
	context.allocator = callback_allocator()

	n := int(frameCount)
	in_samples := ([^]f32)(pInput)[:n]
	out := ([^]f32)(pOutput)[:n]

	start := clock.now(&g_clock)

	// Output: a continuous test tone if set, else silence; plus a calibration
	// click burst if one is scheduled in this block. Backing audio will layer
	// in here in a later story.
	mem.zero_slice(out)
	tone_freq := transmute(f32)intrinsics.atomic_load(&g_tone_bits)
	if tone_freq > 0 {
		step := 2 * math.PI * tone_freq / clock.SAMPLE_RATE
		for i in 0 ..< n {
			out[i] = 0.7 * math.sin(g_tone_phase)
			g_tone_phase += step
			if g_tone_phase > 2 * math.PI {
				g_tone_phase -= 2 * math.PI
			}
		}
	}
	click_at := intrinsics.atomic_load(&g_click_at)
	if click_at >= start && click_at < start + u64(n) {
		off := int(click_at - start)
		end := min(off + CLICK_LEN, n)
		for i in off ..< end {
			out[i] = 1.0
		}
		intrinsics.atomic_store(&g_click_at, CLICK_DISARMED) // one-shot
	}

	// Mix any scheduled note voices (cadence, target tone, backing) into out.
	mix_voices(out, start)

	// Onset detection reads the mic, or (loopback) the output we just wrote —
	// the latter lets calibration/pitch self-tests run with no hardware.
	src := intrinsics.atomic_load(&g_loopback) ? out : in_samples
	on, pos := detect.push_block(&g_onset, src, start)
	if on {
		_ = ring.push(&g_ring, ring.Event{kind = .Onset, sample_pos = pos})
	}

	// Append this block to the input history, then publish the new write count.
	for i in 0 ..< n {
		g_history[(start + u64(i)) & (HIST_CAP - 1)] = src[i]
	}
	intrinsics.atomic_store(&g_hist_written, start + u64(n))

	clock.advance(&g_clock, u64(frameCount))

	// Publish an approximate input level for the UI meter (display only).
	intrinsics.atomic_store(&g_input_rms_bits, transmute(u32)detect.rms(src))
}
