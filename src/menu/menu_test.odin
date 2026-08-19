package menu

import "core:testing"

@(test)
move_advances_and_wraps :: proc(t: ^testing.T) {
	testing.expect_value(t, move(2, 5, 1), 3)
	testing.expect_value(t, move(0, 5, -1), 4) // wrap up past the top
	testing.expect_value(t, move(4, 5, 1), 0) // wrap down past the bottom
}

@(test)
move_handles_empty_and_single :: proc(t: ^testing.T) {
	testing.expect_value(t, move(0, 0, 1), 0) // no items
	testing.expect_value(t, move(0, 1, 1), 0) // single item stays put
	testing.expect_value(t, move(0, 1, -1), 0)
}
