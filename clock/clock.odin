package clock

// The master clock. A monotonic counter of audio frames (samples per channel
// for mono) advanced once per audio callback and read from any thread. Musical
// time is derived from this — never from render frames or wall clock.

import "base:intrinsics"

SAMPLE_RATE :: 48000

Clock :: struct {
	samples: u64,
}

// advance atomically adds `frames` and returns the new running total.
// Called only from the audio thread (single producer).
advance :: proc(c: ^Clock, frames: u64) -> u64 {
	old := intrinsics.atomic_add(&c.samples, frames)
	return old + frames
}

// now atomically reads the current sample count. Safe from any thread.
now :: proc(c: ^Clock) -> u64 {
	return intrinsics.atomic_load(&c.samples)
}

samples_to_ms :: proc(samples: u64, rate: u32 = SAMPLE_RATE) -> f64 {
	return f64(samples) * 1000.0 / f64(rate)
}

samples_to_seconds :: proc(samples: u64, rate: u32 = SAMPLE_RATE) -> f64 {
	return f64(samples) / f64(rate)
}

// ms_to_samples rounds to the nearest whole sample.
ms_to_samples :: proc(ms: f64, rate: u32 = SAMPLE_RATE) -> u64 {
	return u64(ms * f64(rate) / 1000.0 + 0.5)
}
