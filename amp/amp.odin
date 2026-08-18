package amp

// A minimal guitar amp-sim: overdrive (tube-style soft clipping with a little
// asymmetry for even harmonics) into a one-pole "cabinet" lowpass. This is the
// downstream, playback-only path (spec §9.3) — it colours what the user hears
// and never touches the detection signal. Allocation-free, runs per sample in
// the audio callback.

import "core:math"

// soft_clip: smooth, tube-like saturation, bounded to (-1, 1).
soft_clip :: proc(x: f32) -> f32 {
	return math.tanh(x)
}

// One-pole lowpass ("cab"): rolls off the fizzy top of the distortion so it
// sounds like a speaker in a room rather than a buzzer.
Cab :: struct {
	a: f32, // smoothing coefficient
	z: f32, // state (previous output)
}

cab_make :: proc(fc, fs: f32) -> Cab {
	return Cab{a = 1 - math.exp(-2 * math.PI * fc / fs)}
}

cab_process :: proc(c: ^Cab, x: f32) -> f32 {
	c.z += c.a * (x - c.z)
	return c.z
}

Amp :: struct {
	drive: f32, // input gain into the clipper (more = more overdrive)
	bias:  f32, // asymmetry -> even harmonics (warmth)
	level: f32, // output level (compensates for distortion loudness)
	cab:   Cab,
}

// amp_make: a cranked-Marshall-ish medium-high crunch — Iommi/Page territory,
// not modern high-gain (which would mush the cadence's major triads).
amp_make :: proc() -> Amp {
	return Amp{drive = 6.0, bias = 0.15, level = 0.32, cab = cab_make(3800, 48000)}
}

amp_process :: proc(a: ^Amp, x: f32) -> f32 {
	// asymmetric soft clip; subtract the biased DC so silence stays silent
	y := soft_clip(x * a.drive + a.bias) - soft_clip(a.bias)
	return cab_process(&a.cab, y) * a.level
}

// amp_block applies the amp to a whole buffer in place.
amp_block :: proc(a: ^Amp, buf: []f32) {
	for &s in buf {
		s = amp_process(a, s)
	}
}
