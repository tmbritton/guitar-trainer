package music

// Music theory for the v0 scale-degree drill: major keys, scale degrees, and
// pitch-class helpers for octave-agnostic judging (spec §8 — score the sound).

import "core:math/rand"

MAJOR_SCALE := [7]int{0, 2, 4, 5, 7, 9, 11}

@(private)
NOTE_NAMES := [12]string{"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}

Key :: struct {
	tonic_midi: int,
}

// pitch_class returns 0..11, robust to negative MIDI values.
pitch_class :: proc(midi: int) -> int {
	return ((midi % 12) + 12) % 12
}

same_pitch_class :: proc(a, b: int) -> bool {
	return pitch_class(a) == pitch_class(b)
}

// degree_to_midi maps a 1-based scale degree to a MIDI note in the major key
// rooted at tonic_midi. Degrees above 7 wrap into higher octaves (8 == octave).
degree_to_midi :: proc(tonic_midi: int, degree: int) -> int {
	d := degree - 1
	octave := d / 7
	step := ((d % 7) + 7) % 7
	if d < 0 && step != 0 {
		octave -= 1 // floor division for negative degrees
	}
	return tonic_midi + 12 * octave + MAJOR_SCALE[step]
}

note_name :: proc(midi: int) -> string {
	return NOTE_NAMES[pitch_class(midi)]
}

// major_triad stacks a major third and perfect fifth on the root.
major_triad :: proc(root_midi: int) -> [3]int {
	return {root_midi, root_midi + 4, root_midi + 7}
}

// cadence returns the four triads of a I-IV-V-I cadence in the major key,
// with the final I an octave above the first for a sense of resolution.
cadence :: proc(key: Key) -> [4][3]int {
	return {
		major_triad(degree_to_midi(key.tonic_midi, 1)), // I
		major_triad(degree_to_midi(key.tonic_midi, 4)), // IV
		major_triad(degree_to_midi(key.tonic_midi, 5)), // V
		major_triad(degree_to_midi(key.tonic_midi, 8)), // I (octave)
	}
}

// random_key picks a major key whose tonic sits in [low, high] (MIDI).
random_key :: proc(low, high: int) -> Key {
	span := high - low + 1
	return Key{tonic_midi = low + rand.int_max(span)}
}
