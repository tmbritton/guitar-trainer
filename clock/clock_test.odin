package clock

import "core:testing"
import "core:math"

@(test)
advance_accumulates_and_returns_total :: proc(t: ^testing.T) {
	c: Clock
	testing.expect_value(t, advance(&c, 128), 128)
	testing.expect_value(t, advance(&c, 128), 256)
	testing.expect_value(t, advance(&c, 100), 356)
	testing.expect_value(t, now(&c), 356)
}

@(test)
now_reads_zero_before_advance :: proc(t: ^testing.T) {
	c: Clock
	testing.expect_value(t, now(&c), 0)
}

@(test)
ms_and_samples_round_trip_whole_second :: proc(t: ^testing.T) {
	testing.expect_value(t, ms_to_samples(1000), 48000)
	testing.expect_value(t, samples_to_ms(48000), 1000.0)
}

@(test)
buffer_128_samples_is_2_667_ms :: proc(t: ^testing.T) {
	ms := samples_to_ms(128)
	testing.expectf(t, math.abs(ms - 2.6666) < 0.001, "expected ~2.667ms, got %v", ms)
}

@(test)
ms_to_samples_rounds_to_nearest :: proc(t: ^testing.T) {
	// one sample period in ms = 1000/48000 = 0.020833..; that many ms -> 1 sample
	one_sample_ms := 1000.0 / 48000.0
	testing.expect_value(t, ms_to_samples(one_sample_ms), 1)
	// 0.4 of a sample rounds down to 0
	testing.expect_value(t, ms_to_samples(one_sample_ms * 0.4), 0)
	// 0.6 of a sample rounds up to 1
	testing.expect_value(t, ms_to_samples(one_sample_ms * 0.6), 1)
}

@(test)
samples_to_seconds_matches :: proc(t: ^testing.T) {
	testing.expect_value(t, samples_to_seconds(24000), 0.5)
}
