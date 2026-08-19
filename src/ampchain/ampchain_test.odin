package ampchain

import "core:math"
import "core:testing"

// ---- streaming FIR cabinet ----

@(test)
cab_impulse_response_is_the_coeffs :: proc(t: ^testing.T) {
	c: Cab_FIR
	cab_set(&c, []f32{0.5, -0.25, 0.1})
	testing.expect_value(t, cab_process(&c, 1), f32(0.5)) // impulse
	testing.expect_value(t, cab_process(&c, 0), f32(-0.25))
	testing.expect_value(t, cab_process(&c, 0), f32(0.1))
	testing.expect_value(t, cab_process(&c, 0), f32(0))
}

@(test)
cab_without_ir_passes_through :: proc(t: ^testing.T) {
	c: Cab_FIR
	testing.expect_value(t, cab_process(&c, 0.7), f32(0.7))
}

// ---- oversampled waveshaper ----

@(test)
waveshaper_small_signal_is_near_linear :: proc(t: ^testing.T) {
	w: Waveshaper
	waveshaper_init(&w, 1)
	out: f32
	for _ in 0 ..< 96 do out = ws_process(&w, 0.1) // settle the FIRs
	// at drive 1, a small DC input passes ~ tanh(x) ~= x
	testing.expectf(t, abs(out - math.tanh(f32(0.1))) < 0.02, "expected ~%.4f, got %.4f", math.tanh(f32(0.1)), out)
}

@(test)
waveshaper_saturates_and_is_monotonic :: proc(t: ^testing.T) {
	settle :: proc(drive, x: f32) -> f32 {
		w: Waveshaper
		waveshaper_init(&w, drive)
		out: f32
		for _ in 0 ..< 96 do out = ws_process(&w, x)
		return out
	}
	hot := settle(4, 1.0)
	soft := settle(4, 0.2)
	testing.expectf(t, hot < 1.0 && hot > 0.85, "hot drive should saturate below 1, got %.4f", hot)
	testing.expectf(t, soft < hot, "louder input should map higher (%.4f !< %.4f)", soft, hot)
}

// ---- tone stack ----

@(test)
tone_flat_is_identity :: proc(t: ^testing.T) {
	tn: Tone
	tone_set(&tn, 0, 0)
	for x in ([]f32{0.3, -0.5, 0.9, -0.1, 0.4}) {
		testing.expectf(t, abs(tone_process(&tn, x) - x) < 1e-4, "flat tone should pass %.3f unchanged", x)
	}
}

@(test)
tone_treble_boost_raises_high_frequencies :: proc(t: ^testing.T) {
	amp_alt :: proc(bass_db, treble_db: f32) -> f32 {
		tn: Tone
		tone_set(&tn, bass_db, treble_db)
		out: f32
		for i in 0 ..< 64 do out = tone_process(&tn, i % 2 == 0 ? 0.5 : -0.5) // Nyquist tone
		return abs(out)
	}
	flat := amp_alt(0, 0)
	boosted := amp_alt(0, 12)
	testing.expectf(t, boosted > flat*1.2, "treble boost should raise HF (%.3f vs %.3f)", boosted, flat)
}

// ---- full chain ----

@(test)
chain_level_scales_output :: proc(t: ^testing.T) {
	c: Chain
	chain_init(&c)
	chain_set_level(&c, 0)
	for _ in 0 ..< 32 do testing.expect_value(t, process(&c, 0.5), f32(0)) // level 0 -> silence
}

@(test)
chain_reset_clears_state :: proc(t: ^testing.T) {
	c: Chain
	chain_init(&c)
	chain_set_cab(&c, []f32{0.5, 0.25})
	for _ in 0 ..< 50 do process(&c, 0.8) // dirty the state
	chain_reset(&c)
	// after reset the cab's first output for an impulse is coeff[0] again (state cleared);
	// with drive 1 and a small impulse the chain shouldn't blow up
	y := process(&c, 0)
	testing.expectf(t, abs(y) < 1e-3, "reset chain fed silence should be ~0, got %.5f", y)
}
