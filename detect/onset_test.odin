package detect

import "core:testing"
import "core:math"

// --- signal helpers -------------------------------------------------------

fill_sine :: proc(buf: []f32, freq, amp: f32, sample_rate: f32 = 48000) {
	for i in 0 ..< len(buf) {
		buf[i] = amp * math.sin(2 * math.PI * freq * f32(i) / sample_rate)
	}
}

// Feed a whole signal to a detector in fixed hops, collecting onset positions.
run_detector :: proc(d: ^Onset_Detector, signal: []f32, hop: int) -> [dynamic]u64 {
	onsets := make([dynamic]u64)
	pos := 0
	for pos + hop <= len(signal) {
		on, at := push_block(d, signal[pos:pos + hop], u64(pos))
		if on {
			append(&onsets, at)
		}
		pos += hop
	}
	return onsets
}

// --- rms ------------------------------------------------------------------

@(test)
rms_of_silence_is_zero :: proc(t: ^testing.T) {
	buf := make([]f32, 128)
	defer delete(buf)
	testing.expect_value(t, rms(buf), f32(0))
}

@(test)
rms_of_unit_square_is_one :: proc(t: ^testing.T) {
	buf := make([]f32, 128)
	defer delete(buf)
	for i in 0 ..< len(buf) {
		buf[i] = (i % 2 == 0) ? 1 : -1
	}
	testing.expectf(t, math.abs(rms(buf) - 1) < 1e-6, "expected 1, got %v", rms(buf))
}

@(test)
rms_of_sine_is_amp_over_sqrt2 :: proc(t: ^testing.T) {
	buf := make([]f32, 4800) // many periods for a clean estimate
	defer delete(buf)
	fill_sine(buf, 440, 1.0)
	expected := f32(1.0 / math.SQRT_TWO)
	testing.expectf(t, math.abs(rms(buf) - expected) < 0.01, "expected %v, got %v", expected, rms(buf))
}

// --- onset detection ------------------------------------------------------

@(test)
silence_produces_no_onset :: proc(t: ^testing.T) {
	d := default_onset_detector()
	signal := make([]f32, 48000) // 1s of silence
	defer delete(signal)
	onsets := run_detector(&d, signal, 128)
	defer delete(onsets)
	testing.expect_value(t, len(onsets), 0)
}

@(test)
single_attack_produces_one_onset :: proc(t: ^testing.T) {
	d := default_onset_detector()
	signal := make([]f32, 48000)
	defer delete(signal)
	// silence for first 12000 samples, then a sustained loud sine.
	fill_sine(signal[12000:], 440, 0.5)
	onsets := run_detector(&d, signal, 128)
	defer delete(onsets)
	testing.expect_value(t, len(onsets), 1)
	// onset should land in the hop containing sample 12000 (12000/128=93.75 -> hop 94 starts at 12032)
	testing.expectf(t, onsets[0] >= 11900 && onsets[0] <= 12200, "onset at %v, expected ~12000", onsets[0])
}

@(test)
two_separated_attacks_produce_two_onsets :: proc(t: ^testing.T) {
	d := default_onset_detector()
	signal := make([]f32, 96000)
	defer delete(signal)
	// burst 1: samples 5000..15000; silence; burst 2: 60000..70000
	fill_sine(signal[5000:15000], 440, 0.5)
	fill_sine(signal[60000:70000], 440, 0.5)
	onsets := run_detector(&d, signal, 128)
	defer delete(onsets)
	testing.expect_value(t, len(onsets), 2)
	testing.expectf(t, onsets[0] >= 4900 && onsets[0] <= 5200, "first onset at %v", onsets[0])
	testing.expectf(t, onsets[1] >= 59900 && onsets[1] <= 60200, "second onset at %v", onsets[1])
}

@(test)
attacks_within_refractory_yield_one_onset :: proc(t: ^testing.T) {
	d := default_onset_detector()
	signal := make([]f32, 48000)
	defer delete(signal)
	// burst 1 at 5000, brief dip (re-arms), burst 2 only ~20ms later (< 50ms refractory)
	fill_sine(signal[5000:6000], 440, 0.5)
	// dip 6000..6200 (silence), then burst 2
	fill_sine(signal[6200:8000], 440, 0.5)
	onsets := run_detector(&d, signal, 128)
	defer delete(onsets)
	testing.expect_value(t, len(onsets), 1)
	testing.expectf(t, onsets[0] >= 4900 && onsets[0] <= 5200, "onset at %v", onsets[0])
}

@(test)
subfloor_noise_produces_no_onset :: proc(t: ^testing.T) {
	d := default_onset_detector()
	signal := make([]f32, 48000)
	defer delete(signal)
	fill_sine(signal, 440, 0.005) // amplitude well under the 0.02 floor
	onsets := run_detector(&d, signal, 128)
	defer delete(onsets)
	testing.expect_value(t, len(onsets), 0)
}
