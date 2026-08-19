package pcmring

import "core:testing"

@(test)
write_then_read_roundtrips :: proc(t: ^testing.T) {
	r: Ring(8)
	src := []f32{1, 2, 3}
	testing.expect_value(t, write(&r, src), 3)
	testing.expect_value(t, available(&r), 3)

	dst: [3]f32
	testing.expect_value(t, read(&r, dst[:]), 3)
	testing.expect_value(t, dst[0], f32(1))
	testing.expect_value(t, dst[1], f32(2))
	testing.expect_value(t, dst[2], f32(3))
	testing.expect_value(t, available(&r), 0)
}

@(test)
write_saturates_at_capacity :: proc(t: ^testing.T) {
	r: Ring(4)
	// only 4 fit; the extra two are refused (producer must not block).
	testing.expect_value(t, write(&r, []f32{1, 2, 3, 4, 5, 6}), 4)
	testing.expect_value(t, space(&r), 0)
	testing.expect_value(t, write(&r, []f32{9}), 0) // full: nothing accepted
}

@(test)
read_underruns_short :: proc(t: ^testing.T) {
	r: Ring(4)
	write(&r, []f32{7, 8})
	dst: [5]f32
	testing.expect_value(t, read(&r, dst[:]), 2) // only 2 available
	testing.expect_value(t, dst[0], f32(7))
	testing.expect_value(t, dst[1], f32(8))
}

@(test)
read_empty_returns_zero :: proc(t: ^testing.T) {
	r: Ring(4)
	dst: [3]f32
	testing.expect_value(t, read(&r, dst[:]), 0)
}

@(test)
wraps_around_preserving_order :: proc(t: ^testing.T) {
	r: Ring(4)
	write(&r, []f32{1, 2, 3}) // head=3
	d2: [2]f32
	read(&r, d2[:]) // tail=2, consumed 1,2
	testing.expect_value(t, write(&r, []f32{4, 5, 6}), 3) // wraps: slots 3,0,1
	testing.expect_value(t, available(&r), 4) // had 1 (the 3), added 3

	got: [4]f32
	testing.expect_value(t, read(&r, got[:]), 4)
	testing.expect_value(t, got[0], f32(3))
	testing.expect_value(t, got[1], f32(4))
	testing.expect_value(t, got[2], f32(5))
	testing.expect_value(t, got[3], f32(6))
}
