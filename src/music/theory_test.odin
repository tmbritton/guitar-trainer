package music

import "core:testing"

@(test)
pitch_class_wraps_octaves :: proc(t: ^testing.T) {
	testing.expect_value(t, pitch_class(60), 0) // C4
	testing.expect_value(t, pitch_class(72), 0) // C5
	testing.expect_value(t, pitch_class(61), 1) // C#4
	testing.expect_value(t, pitch_class(-1), 11) // B, robust to negatives
}

@(test)
same_pitch_class_is_octave_agnostic :: proc(t: ^testing.T) {
	testing.expect(t, same_pitch_class(60, 72), "C4 and C5 are the same pitch class")
	testing.expect(t, !same_pitch_class(60, 61), "C and C# differ")
}

@(test)
degrees_map_to_major_scale :: proc(t: ^testing.T) {
	// C major from C4 (MIDI 60): C D E F G A B C
	testing.expect_value(t, degree_to_midi(60, 1), 60)
	testing.expect_value(t, degree_to_midi(60, 2), 62)
	testing.expect_value(t, degree_to_midi(60, 3), 64)
	testing.expect_value(t, degree_to_midi(60, 4), 65)
	testing.expect_value(t, degree_to_midi(60, 5), 67)
	testing.expect_value(t, degree_to_midi(60, 6), 69)
	testing.expect_value(t, degree_to_midi(60, 7), 71)
	testing.expect_value(t, degree_to_midi(60, 8), 72) // octave up
}

@(test)
major_triad_stacks_thirds :: proc(t: ^testing.T) {
	tri := major_triad(60)
	testing.expect_value(t, tri[0], 60)
	testing.expect_value(t, tri[1], 64)
	testing.expect_value(t, tri[2], 67)
}

@(test)
cadence_is_I_IV_V_I :: proc(t: ^testing.T) {
	c := cadence(Key{tonic_midi = 60}) // C major
	expected := [4][3]int {
		{60, 64, 67}, // I  : C E G
		{65, 69, 72}, // IV : F A C
		{67, 71, 74}, // V  : G B D
		{72, 76, 79}, // I  : C E G (octave up)
	}
	testing.expect_value(t, c, expected)
}

@(test)
note_names :: proc(t: ^testing.T) {
	testing.expect_value(t, note_name(60), "C")
	testing.expect_value(t, note_name(69), "A")
	testing.expect_value(t, note_name(61), "C#")
	testing.expect_value(t, note_name(70), "A#")
	testing.expect_value(t, note_name(71), "B")
}
