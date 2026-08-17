package calib

import "core:testing"

@(test)
median_of_odd_count :: proc(t: ^testing.T) {
	testing.expect_value(t, median_i64([]i64{5, 1, 3}), i64(3))
}

@(test)
median_of_even_count_is_mean_of_middles :: proc(t: ^testing.T) {
	testing.expect_value(t, median_i64([]i64{4, 2}), i64(3))
	testing.expect_value(t, median_i64([]i64{2, 4, 6, 8}), i64(5))
}

@(test)
median_of_single_and_empty :: proc(t: ^testing.T) {
	testing.expect_value(t, median_i64([]i64{10}), i64(10))
	testing.expect_value(t, median_i64([]i64{}), i64(0))
}

@(test)
median_does_not_mutate_input :: proc(t: ^testing.T) {
	xs := []i64{5, 1, 3}
	_ = median_i64(xs)
	testing.expect_value(t, xs[0], i64(5)) // original order preserved
}

@(test)
match_click_picks_nearest_within_window :: proc(t: ^testing.T) {
	offset, ok := match_click(1000, []u64{900, 1010, 2000}, 200)
	testing.expect(t, ok, "should match")
	testing.expect_value(t, offset, i64(10)) // 1010 is nearer than 900
}

@(test)
match_click_returns_signed_offset :: proc(t: ^testing.T) {
	offset, ok := match_click(1000, []u64{950}, 200)
	testing.expect(t, ok, "should match within window")
	testing.expect_value(t, offset, i64(-50))
}

@(test)
match_click_no_onset_in_window :: proc(t: ^testing.T) {
	_, ok := match_click(1000, []u64{500, 2000}, 100)
	testing.expect(t, !ok, "nothing within +/-100 of 1000")
}

@(test)
match_click_empty :: proc(t: ^testing.T) {
	_, ok := match_click(1000, []u64{}, 100)
	testing.expect(t, !ok, "no onsets at all")
}

@(test)
aggregate_empty_is_not_ok :: proc(t: ^testing.T) {
	_, ok := aggregate([]i64{})
	testing.expect(t, !ok, "no offsets to aggregate")
}

@(test)
aggregate_takes_median :: proc(t: ^testing.T) {
	offset, ok := aggregate([]i64{8, 12, 10})
	testing.expect(t, ok, "should aggregate")
	testing.expect_value(t, offset, i64(10))
}
