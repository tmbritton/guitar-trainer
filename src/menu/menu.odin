package menu

// Pure keyboard-menu navigation. UI/drawing lives in the main package (raylib);
// this is just the wrapping selection math so it can be unit-tested.

// move returns the selection index after moving `delta` steps among `n` items,
// wrapping around the ends. Empty list -> 0.
move :: proc(sel, n, delta: int) -> int {
	if n <= 0 {
		return 0
	}
	return ((sel + delta) % n + n) % n
}
