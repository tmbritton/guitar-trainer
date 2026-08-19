package game

// Naive, log-informed trial scheduling. Start close to uniform; nudge selection
// toward scale degrees the user gets wrong or hasn't seen. The policy is a
// gentle weighting, deliberately simple — instrument the trial log first, tune
// (or move to SM-2 / Kellman) from data later (spec §12.2).

import "core:math/rand"

import "../music"

// Degree_Stats holds per-degree play counts, indexed 1..7 (index 0 unused).
Degree_Stats :: struct {
	attempts: [8]int,
	correct:  [8]int,
}

UNSEEN_WEIGHT :: 4.0 // exploration weight for a never-played degree
WEIGHT_K :: 3.0 // how strongly low accuracy raises weight

// degree_weight: unseen degrees get max weight; otherwise weight rises as
// accuracy falls. Perfect play -> 1.0, 0% -> 1 + K.
degree_weight :: proc(stats: Degree_Stats, degree: int) -> f32 {
	a := stats.attempts[degree]
	if a == 0 {
		return UNSEEN_WEIGHT
	}
	accuracy := f32(stats.correct[degree]) / f32(a)
	return 1 + (1 - accuracy) * WEIGHT_K
}

// pick_degree deterministically maps a uniform sample u in [0,1) to a degree,
// weighted by degree_weight (cumulative-walk). Exposed for testing.
pick_degree :: proc(stats: Degree_Stats, u: f32) -> int {
	total: f32
	w: [8]f32
	for d in 1 ..= 7 {
		w[d] = degree_weight(stats, d)
		total += w[d]
	}
	if total <= 0 {
		return 1
	}
	target := clamp(u, 0, 0.999999) * total
	acc: f32
	for d in 1 ..= 7 {
		acc += w[d]
		if target < acc {
			return d
		}
	}
	return 7
}

// select_degree draws a weighted-random degree using the default RNG.
select_degree :: proc(stats: Degree_Stats) -> int {
	return pick_degree(stats, rand.float32())
}

// new_trial_weighted builds a trial whose degree is chosen by the scheduler.
new_trial_weighted :: proc(low_tonic, high_tonic: int, stats: Degree_Stats) -> Trial {
	key := music.random_key(low_tonic, high_tonic)
	degree := select_degree(stats)
	return Trial {
		key = key,
		target_degree = degree,
		target_midi = music.degree_to_midi(key.tonic_midi, degree),
	}
}
