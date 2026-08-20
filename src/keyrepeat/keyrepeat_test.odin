package keyrepeat

import "core:testing"

// A frame at 60 fps. Tests step in whole frames so the numbers read like the
// real caller's.
FRAME :: f32(1.0 / 60.0)

// hold steps `frames` frames with the key down and returns the total fired.
@(private = "file")
hold :: proc(r: ^Repeat, frames: int, dt: f32 = FRAME) -> int {
	n := 0
	for _ in 0 ..< frames do n += tick(r, false, true, dt)
	return n
}

@(test)
press_fires_once_immediately :: proc(t: ^testing.T) {
	r := FAST
	// The initial press must act on the frame it happened, with no delay — a
	// tap has to feel like a tap.
	testing.expect_value(t, tick(&r, true, true, FRAME), 1)
}

@(test)
short_hold_does_not_repeat :: proc(t: ^testing.T) {
	r := FAST
	tick(&r, true, true, FRAME)
	// Held for less than the delay: still just the one press.
	delay := FAST.delay // via a variable: a constant expression folds at compile
	testing.expect_value(t, hold(&r, int(delay / FRAME) - 2), 0)
}

@(test)
long_hold_repeats_at_the_rate :: proc(t: ^testing.T) {
	r := FAST
	tick(&r, true, true, FRAME)
	// One second of holding: delay, then (1 - delay) / rate repeats.
	delay, rate := FAST.delay, FAST.rate
	want := int((1.0 - delay) / rate)
	got := hold(&r, 60)
	testing.expect(
		t,
		got == want || got == want - 1, // a partial rate window may not have elapsed
		"expected ~the rate's worth of repeats",
	)
	testing.expect(t, got > 0, "a held key must repeat")
}

@(test)
release_stops_and_rearms :: proc(t: ^testing.T) {
	r := FAST
	tick(&r, true, true, FRAME)
	hold(&r, 60)
	// Released: no more repeats, however long we wait.
	testing.expect_value(t, tick(&r, false, false, FRAME), 0)
	testing.expect_value(t, tick(&r, false, false, 10), 0)
	// And the next press starts the whole cycle over rather than resuming
	// mid-repeat, or a re-tap would fire a burst.
	testing.expect_value(t, tick(&r, true, true, FRAME), 1)
	testing.expect_value(t, hold(&r, 2), 0)
}

@(test)
slow_frame_emits_the_missed_repeats :: proc(t: ^testing.T) {
	r := FAST
	tick(&r, true, true, FRAME)
	// One long frame (a stem load, a GC pause) must not swallow the repeats it
	// spans — the count is derived from held time, not from frames elapsed.
	n := tick(&r, false, true, FAST.delay + 5 * FAST.rate)
	testing.expect_value(t, n, 5)
}

@(test)
repeat_count_is_bounded :: proc(t: ^testing.T) {
	r := FAST
	tick(&r, true, true, FRAME)
	// A pathological dt (a debugger pause, a suspended laptop) must not turn
	// into thousands of seeks on one frame.
	testing.expect_value(t, tick(&r, false, true, 3600), MAX_BURST)
}

@(test)
press_while_already_down_restarts :: proc(t: ^testing.T) {
	r := FAST
	tick(&r, true, true, FRAME)
	hold(&r, 40)
	// A press edge always wins over the held state: raylib reports both `down`
	// and `pressed` on a re-press, and the press is the newer fact.
	testing.expect_value(t, tick(&r, true, true, FRAME), 1)
	testing.expect_value(t, hold(&r, 2), 0)
}

@(test)
seek_is_slower_than_nav :: proc(t: ^testing.T) {
	// Seek moves 5 seconds a step, so it must repeat more slowly than a list
	// cursor or holding the key for a moment would cross the whole song.
	testing.expect(t, SEEK.rate > FAST.rate, "seek must repeat slower than nav")
	testing.expect(t, SEEK.delay >= FAST.delay, "seek must not start sooner")
}

@(test)
zero_rate_never_divides_by_zero :: proc(t: ^testing.T) {
	r := Repeat{delay = 0.3, rate = 0}
	tick(&r, true, true, FRAME)
	testing.expect_value(t, tick(&r, false, true, 10), 0)
}

@(test)
clamped_burst_is_dropped_not_deferred :: proc(t: ^testing.T) {
	r := FAST
	tick(&r, true, true, FRAME)
	// The clamp above discards the repeats it refused. Crediting only what was
	// emitted instead would pay the rest out over the following frames, so a
	// one-second stall would leave the list scrolling by itself after the frame
	// rate recovered.
	tick(&r, false, true, 3600)
	testing.expect_value(t, tick(&r, false, true, FRAME), 0)
	testing.expect_value(t, hold(&r, 2), 0)
}

@(test)
hold_without_a_press_edge_still_waits :: proc(t: ^testing.T) {
	r := FAST
	// The window can regain focus with a key already down, so `down` goes true
	// with no press edge ever seen. That must serve the delay like any other
	// hold rather than repeating from the first frame.
	testing.expect_value(t, hold(&r, 2), 0)
	testing.expect(t, hold(&r, 60) > 0, "a key held from focus-in still repeats")
	// Releasing clears the accumulated hold, so re-holding waits again.
	tick(&r, false, false, FRAME)
	testing.expect_value(t, hold(&r, 2), 0)
}

@(test)
a_tap_shorter_than_a_frame_still_acts :: proc(t: ^testing.T) {
	r := FAST
	// raylib can report a press whose release already happened inside the same
	// 16 ms frame, so `pressed` is true while `down` is false. This is the whole
	// reason tick takes both — deriving the edge from `down` alone would drop
	// the keystroke entirely.
	testing.expect_value(t, tick(&r, true, false, FRAME), 1)
	// ...and it must not leave a hold behind that repeats on later frames.
	testing.expect_value(t, tick(&r, false, false, FRAME), 0)
	testing.expect_value(t, tick(&r, false, false, 10), 0)
}
