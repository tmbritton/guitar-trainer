package conv

import "core:math"
import "core:testing"

@(test)
delta_ir_is_identity :: proc(t: ^testing.T) {
	input := []f32{1, 2, 3, 4}
	ir := []f32{1}
	out := make([]f32, 8)
	defer delete(out)
	n := convolve(input, ir, out)
	testing.expect_value(t, n, 4)
	for i in 0 ..< 4 {
		testing.expect_value(t, out[i], input[i])
	}
}

@(test)
unit_delay_ir_shifts :: proc(t: ^testing.T) {
	input := []f32{1, 2, 3}
	ir := []f32{0, 1} // delay by one sample
	out := make([]f32, 8)
	defer delete(out)
	n := convolve(input, ir, out)
	testing.expect_value(t, n, 4) // 3 + 2 - 1
	testing.expect_value(t, out[0], f32(0))
	testing.expect_value(t, out[1], f32(1))
	testing.expect_value(t, out[2], f32(2))
	testing.expect_value(t, out[3], f32(3))
}

@(test)
box_ir_is_moving_average :: proc(t: ^testing.T) {
	input := []f32{4, 8, 0}
	ir := []f32{0.5, 0.5}
	out := make([]f32, 8)
	defer delete(out)
	convolve(input, ir, out)
	testing.expect_value(t, out[0], f32(2)) // 0.5*4
	testing.expect_value(t, out[1], f32(6)) // 0.5*4 + 0.5*8
	testing.expect_value(t, out[2], f32(4)) // 0.5*8 + 0.5*0
	testing.expect_value(t, out[3], f32(0))
}

@(test)
respects_output_capacity :: proc(t: ^testing.T) {
	input := []f32{1, 1, 1, 1}
	ir := []f32{1, 1, 1}
	out := make([]f32, 3) // smaller than full 6
	defer delete(out)
	n := convolve(input, ir, out)
	testing.expect_value(t, n, 3)
}

@(test)
l2_normalize_gives_unit_energy :: proc(t: ^testing.T) {
	ir := []f32{3, 4} // L2 norm = 5
	normalize_l2(ir)
	energy: f32 = 0
	for s in ir {
		energy += s * s
	}
	testing.expectf(t, math.abs(energy - 1) < 1e-6, "energy %v should be 1", energy)
}
