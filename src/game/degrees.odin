package game

// Pure trial logic for the v0 scale-degree drill: generate a trial (key + a
// random scale degree) and judge a detected note against it by pitch class
// (octave-agnostic, per spec §8). No audio here — orchestration lives in the
// main package's drill.odin.

import "core:math/rand"

import "../music"

Trial :: struct {
	key:           music.Key,
	target_degree: int, // 1..7
	target_midi:   int,
}

// new_trial picks a random major key (tonic in [low_tonic, high_tonic]) and a
// random scale degree 1..7, resolving the target MIDI note.
new_trial :: proc(low_tonic, high_tonic: int) -> Trial {
	key := music.random_key(low_tonic, high_tonic)
	degree := 1 + rand.int_max(7)
	return Trial {
		key = key,
		target_degree = degree,
		target_midi = music.degree_to_midi(key.tonic_midi, degree),
	}
}

// judge returns whether the detected note matches the trial's target by pitch
// class (any octave counts, in v0).
judge :: proc(trial: Trial, detected_midi: int) -> bool {
	return music.same_pitch_class(trial.target_midi, detected_midi)
}
