package calib

// Pure offset math for round-trip latency calibration. The audio side schedules
// clicks at known sample positions and collects detected onset positions; these
// functions match them up and reduce to a single stored offset (in samples).

import "core:slice"

// median_i64 returns the median of xs (mean of the two middles for even counts,
// rounded). Does not mutate the input. Empty -> 0.
median_i64 :: proc(xs: []i64) -> i64 {
	n := len(xs)
	if n == 0 {
		return 0
	}
	tmp := make([]i64, n, context.temp_allocator)
	copy(tmp, xs)
	slice.sort(tmp)
	if n % 2 == 1 {
		return tmp[n / 2]
	}
	a := tmp[n / 2 - 1]
	b := tmp[n / 2]
	return (a + b) / 2 // mean of the two middle values (offsets are small; no overflow)
}

// match_click returns the signed offset (onset - target) of the onset nearest to
// target, provided some onset lies within +/-window. ok=false otherwise.
match_click :: proc(target: u64, onsets: []u64, window: u64) -> (offset: i64, ok: bool) {
	best_dist := u64(0)
	found := false
	best_offset: i64
	for o in onsets {
		dist := o > target ? o - target : target - o
		if dist <= window {
			if !found || dist < best_dist {
				found = true
				best_dist = dist
				best_offset = i64(o) - i64(target)
			}
		}
	}
	return best_offset, found
}

// aggregate reduces matched offsets to a single stored offset (their median).
aggregate :: proc(offsets: []i64) -> (offset: i64, ok: bool) {
	if len(offsets) == 0 {
		return 0, false
	}
	return median_i64(offsets), true
}
