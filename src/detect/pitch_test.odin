package detect

import "core:testing"
import "core:math"
import "core:math/rand"

// note: fill_sine lives in onset_test.odin (same package, test build).

WIN :: 2048

detect_freq :: proc(freq: f32) -> Pitch_Result {
	buf := make([]f32, WIN)
	defer delete(buf)
	scratch := make([]f32, WIN / 2)
	defer delete(scratch)
	fill_sine(buf, freq, 0.7)
	return detect_pitch(buf, scratch)
}

// --- conversions ----------------------------------------------------------

@(test)
midi_to_freq_a4 :: proc(t: ^testing.T) {
	testing.expectf(t, math.abs(midi_to_freq(69) - 440) < 1e-3, "got %v", midi_to_freq(69))
}

@(test)
freq_to_midi_rounds :: proc(t: ^testing.T) {
	testing.expect_value(t, freq_to_midi(440), 69) // A4
	testing.expect_value(t, freq_to_midi(880), 81) // A5
	testing.expect_value(t, freq_to_midi(82.41), 40) // E2
}

@(test)
freq_to_midi_f_is_continuous :: proc(t: ^testing.T) {
	testing.expectf(t, math.abs(freq_to_midi_f(440) - 69) < 1e-3, "got %v", freq_to_midi_f(440))
}

// --- pitch detection ------------------------------------------------------

@(test)
detects_a440 :: proc(t: ^testing.T) {
	r := detect_freq(440)
	testing.expect(t, r.voiced, "440Hz sine should be voiced")
	testing.expectf(t, math.abs(r.freq - 440) < 1.0, "freq %v not within 1Hz of 440", r.freq)
	testing.expectf(t, r.confidence > 0.9, "confidence %v too low", r.confidence)
}

@(test)
detects_low_e :: proc(t: ^testing.T) {
	r := detect_freq(82.41) // E2, lowest guitar string
	testing.expect(t, r.voiced, "low E should be voiced")
	testing.expectf(t, math.abs(r.freq - 82.41) < 1.0, "freq %v not within 1Hz of 82.41", r.freq)
}

@(test)
detects_high_e5 :: proc(t: ^testing.T) {
	r := detect_freq(659.25) // E5
	testing.expect(t, r.voiced, "E5 should be voiced")
	testing.expectf(t, math.abs(r.freq - 659.25) < 1.5, "freq %v not within 1.5Hz of 659.25", r.freq)
}

@(test)
silence_is_unvoiced :: proc(t: ^testing.T) {
	buf := make([]f32, WIN)
	defer delete(buf)
	scratch := make([]f32, WIN / 2)
	defer delete(scratch)
	r := detect_pitch(buf, scratch)
	testing.expect(t, !r.voiced, "silence must be unvoiced")
}

@(test)
noise_is_unvoiced :: proc(t: ^testing.T) {
	buf := make([]f32, WIN)
	defer delete(buf)
	scratch := make([]f32, WIN / 2)
	defer delete(scratch)
	for i in 0 ..< len(buf) {
		buf[i] = rand.float32_range(-1, 1)
	}
	r := detect_pitch(buf, scratch)
	testing.expect(t, !r.voiced, "white noise should not be a confident pitch")
}

@(test)
octave_not_confused :: proc(t: ^testing.T) {
	r := detect_freq(220) // A3
	testing.expect(t, r.voiced, "220Hz should be voiced")
	testing.expectf(t, math.abs(r.freq - 220) < 1.5, "freq %v should be ~220 (not 110/440)", r.freq)
}

// The whole fretboard: standard tuning, 24 frets => MIDI 40 (E2) .. 88 (E6).
// Every semitone must be identified to the correct note on a clean tone.
@(test)
identifies_every_note_on_the_neck :: proc(t: ^testing.T) {
	for midi in 40 ..= 88 {
		freq := midi_to_freq(midi)
		r := detect_freq(freq)
		testing.expectf(t, r.voiced, "MIDI %d (%.1f Hz) should be voiced", midi, freq)
		got := freq_to_midi(r.freq)
		testing.expectf(
			t,
			got == midi,
			"MIDI %d (%.1f Hz) detected as MIDI %d (%.2f Hz)",
			midi,
			freq,
			got,
			r.freq,
		)
	}
}
