package amp

import "core:math"
import "core:testing"

@(test)
soft_clip_is_bounded_and_odd :: proc(t: ^testing.T) {
	testing.expect_value(t, soft_clip(0), f32(0))
	testing.expect(t, soft_clip(100) <= 1 && soft_clip(100) > 0.99, "saturates near +1")
	testing.expect(t, soft_clip(-100) >= -1 && soft_clip(-100) < -0.99, "saturates near -1")
	testing.expect(t, math.abs(soft_clip(2) + soft_clip(-2)) < 1e-6, "odd symmetric")
}

@(test)
cab_passes_dc_attenuates_nyquist :: proc(t: ^testing.T) {
	c := cab_make(3800, 48000)
	// steady input settles toward the input value (DC gain ~1)
	out: f32
	for _ in 0 ..< 2000 {
		out = cab_process(&c, 1.0)
	}
	testing.expectf(t, math.abs(out - 1.0) < 0.05, "DC should pass, got %v", out)

	// a Nyquist-rate alternating signal is strongly attenuated
	c2 := cab_make(3800, 48000)
	peak: f32
	for i in 0 ..< 2000 {
		v: f32 = i % 2 == 0 ? 1 : -1
		o := cab_process(&c2, v)
		if i > 1000 && math.abs(o) > peak {
			peak = math.abs(o)
		}
	}
	testing.expectf(t, peak < 0.5, "nyquist should be attenuated, peak %v", peak)
}

@(test)
amp_silence_is_silence :: proc(t: ^testing.T) {
	a := amp_make()
	out: f32
	for _ in 0 ..< 100 {
		out = amp_process(&a, 0)
	}
	testing.expectf(t, math.abs(out) < 1e-4, "silence in -> silence out, got %v", out)
}

@(test)
amp_output_is_bounded :: proc(t: ^testing.T) {
	a := amp_make()
	for x in ([]f32{0.5, 1, 5, -5, 100, -100}) {
		o := amp_process(&a, x)
		testing.expectf(t, math.abs(o) <= a.level * 1.2, "output %v exceeds level bound for x=%v", o, x)
	}
}

@(test)
amp_drives_small_signal :: proc(t: ^testing.T) {
	a := amp_make()
	// a small positive input yields a positive output well above the clean value
	// (overdrive gain), and sign is preserved.
	o := amp_process(&a, 0.05)
	testing.expect(t, o > 0, "sign preserved")
	testing.expect(t, o > 0.05 * a.level, "small signal is driven up, not just scaled down")
}
