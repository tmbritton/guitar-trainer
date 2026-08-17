package game

import "core:testing"

import "../music"

@(test)
judge_is_octave_agnostic :: proc(t: ^testing.T) {
	trial := Trial {
		key           = music.Key{tonic_midi = 60},
		target_degree = 1,
		target_midi   = 60,
	}
	testing.expect(t, judge(trial, 72), "C5 matches target C4 by pitch class")
	testing.expect(t, judge(trial, 48), "C3 also matches by pitch class")
	testing.expect(t, !judge(trial, 61), "C#4 must not match C4")
}

@(test)
new_trial_is_a_valid_degree_in_key :: proc(t: ^testing.T) {
	// Fixed single-tonic range so the key is deterministic; degree is random.
	for _ in 0 ..< 50 {
		tr := new_trial(60, 60)
		testing.expect_value(t, tr.key.tonic_midi, 60)
		testing.expect(t, tr.target_degree >= 1 && tr.target_degree <= 7, "degree in 1..7")
		testing.expect_value(t, tr.target_midi, music.degree_to_midi(60, tr.target_degree))
	}
}

@(test)
new_trial_key_within_range :: proc(t: ^testing.T) {
	for _ in 0 ..< 50 {
		tr := new_trial(55, 67) // G3..G4
		testing.expect(t, tr.key.tonic_midi >= 55 && tr.key.tonic_midi <= 67, "tonic in range")
	}
}
