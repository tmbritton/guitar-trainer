package game

import "core:testing"

// stats where every degree is attempted 10x and perfect, except `weak` which is
// attempted 10x with 0 correct.
stats_weak_at :: proc(weak: int) -> Degree_Stats {
	s: Degree_Stats
	for d in 1 ..= 7 {
		s.attempts[d] = 10
		s.correct[d] = d == weak ? 0 : 10
	}
	return s
}

@(test)
unseen_outweighs_perfect :: proc(t: ^testing.T) {
	s: Degree_Stats
	s.attempts[2] = 10
	s.correct[2] = 10 // degree 2 perfect; degree 1 unseen
	testing.expect(t, degree_weight(s, 1) > degree_weight(s, 2), "unseen should outweigh perfect")
}

@(test)
low_accuracy_outweighs_high :: proc(t: ^testing.T) {
	s: Degree_Stats
	s.attempts[1] = 10; s.correct[1] = 0 // 0%
	s.attempts[2] = 10; s.correct[2] = 10 // 100%
	testing.expect(t, degree_weight(s, 1) > degree_weight(s, 2), "0% should outweigh 100%")
}

@(test)
equal_accuracy_equal_weight :: proc(t: ^testing.T) {
	s: Degree_Stats
	s.attempts[1] = 8; s.correct[1] = 4
	s.attempts[2] = 10; s.correct[2] = 5 // both 50%
	testing.expect_value(t, degree_weight(s, 1), degree_weight(s, 2))
}

@(test)
pick_degree_favors_weak_at_midpoint :: proc(t: ^testing.T) {
	s := stats_weak_at(3) // weights: 1,1,4,1,1,1,1 (total 10); deg3 spans [2,6)
	testing.expect_value(t, pick_degree(s, 0.5), 3) // target 5.0 lands in degree 3's band
}

@(test)
pick_degree_favors_unseen :: proc(t: ^testing.T) {
	// degree 4 never played (weight 4); all others perfect (weight 1). deg4
	// spans the cumulative band [3, 7) of total 10, so u=0.5 (target 5.0) picks it.
	s: Degree_Stats
	for d in 1 ..= 7 {
		if d != 4 {
			s.attempts[d] = 10
			s.correct[d] = 10
		}
	}
	testing.expect_value(t, pick_degree(s, 0.5), 4)
}

@(test)
pick_degree_edges :: proc(t: ^testing.T) {
	s := stats_weak_at(3)
	testing.expect_value(t, pick_degree(s, 0.0), 1) // first band
	testing.expect_value(t, pick_degree(s, 0.999), 7) // last band
}

@(test)
pick_degree_always_in_range :: proc(t: ^testing.T) {
	s := stats_weak_at(5)
	for i in 0 ..< 100 {
		u := f32(i) / 100
		d := pick_degree(s, u)
		testing.expect(t, d >= 1 && d <= 7, "pick must be a valid degree")
	}
}

@(test)
select_degree_in_range :: proc(t: ^testing.T) {
	s := stats_weak_at(2)
	for _ in 0 ..< 200 {
		d := select_degree(s)
		testing.expect(t, d >= 1 && d <= 7, "select_degree must be 1..7")
	}
}
