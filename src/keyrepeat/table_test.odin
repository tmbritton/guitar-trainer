package keyrepeat

import "core:testing"

// A key here is any small integer; the app passes raylib's KeyboardKey.
LEFT :: i32(1)
RIGHT :: i32(2)

@(test)
table_tracks_keys_independently :: proc(t: ^testing.T) {
	tab: Table
	next_frame(&tab)
	testing.expect_value(t, query(&tab, LEFT, FAST, true, true, FRAME), 1)
	testing.expect_value(t, query(&tab, RIGHT, FAST, false, false, FRAME), 0)
	// Holding LEFT past the delay must not repeat RIGHT.
	for _ in 0 ..< 60 {
		next_frame(&tab)
		query(&tab, LEFT, FAST, false, true, FRAME)
		testing.expect_value(t, query(&tab, RIGHT, FAST, false, false, FRAME), 0)
	}
}

@(test)
query_is_idempotent_within_a_frame :: proc(t: ^testing.T) {
	tab: Table
	next_frame(&tab)
	query(&tab, LEFT, FAST, true, true, FRAME)
	// Two call sites may need the same key's count in one frame. Asking twice
	// must report the same answer and, crucially, must not advance the hold
	// clock twice — which would make the key repeat at double speed for as long
	// as both sites ran.
	//
	// The loop must run well past the 0.35 s delay: an earlier version stopped
	// inside it, so every count was 0 and the three assertions below compared
	// zero against zero on every iteration. `saw_repeat` is what stops it
	// silently drifting back into that state.
	saw_repeat := false
	for _ in 0 ..< 120 {
		next_frame(&tab)
		a := query(&tab, LEFT, FAST, false, true, FRAME)
		b := query(&tab, LEFT, FAST, false, true, FRAME)
		c := query(&tab, LEFT, FAST, false, true, FRAME)
		testing.expect_value(t, b, a)
		testing.expect_value(t, c, a)
		saw_repeat ||= a > 0
	}
	testing.expect(t, saw_repeat, "the hold must actually reach the repeating state")
}

@(test)
double_query_does_not_double_the_rate :: proc(t: ^testing.T) {
	single, double: Table
	total_s, total_d := 0, 0
	for _ in 0 ..< 120 {
		next_frame(&single)
		next_frame(&double)
		total_s += query(&single, LEFT, FAST, false, true, FRAME)
		d := query(&double, LEFT, FAST, false, true, FRAME)
		query(&double, LEFT, FAST, false, true, FRAME) // a second call site
		total_d += d
	}
	testing.expect_value(t, total_d, total_s)
	testing.expect(t, total_s > 0, "two seconds of holding must repeat")
}

@(test)
table_reuses_slots_and_survives_overflow :: proc(t: ^testing.T) {
	tab: Table
	next_frame(&tab)
	for k in 0 ..< i32(len(tab.slots)) {
		query(&tab, k, FAST, true, true, FRAME)
	}
	testing.expect_value(t, tab.n, len(tab.slots))
	// Asking about a key that fits reuses its slot rather than adding one.
	next_frame(&tab)
	query(&tab, 0, FAST, false, true, FRAME)
	testing.expect_value(t, tab.n, len(tab.slots))
	// One past capacity still reports the press — it just cannot repeat. Losing
	// the keypress entirely would be far worse than losing its auto-repeat.
	over := i32(len(tab.slots)) + 1
	next_frame(&tab)
	testing.expect_value(t, query(&tab, over, FAST, true, true, FRAME), 1)
	// ...on later frames too, not just the one that overflowed.
	next_frame(&tab)
	testing.expect_value(t, query(&tab, over, FAST, false, true, 10), 0)
	next_frame(&tab)
	testing.expect_value(t, query(&tab, over, FAST, true, true, FRAME), 1)
}

@(test)
profile_change_keeps_the_hold :: proc(t: ^testing.T) {
	tab: Table
	next_frame(&tab)
	query(&tab, LEFT, FAST, true, true, FRAME)
	// The same key can carry different profiles on different screens. Switching
	// must retime the repeat, not reset the hold to zero — otherwise a key held
	// across the change would silently stop repeating.
	held := f32(0)
	for _ in 0 ..< 30 {
		next_frame(&tab)
		query(&tab, LEFT, SEEK, false, true, FRAME)
		held += FRAME
	}
	testing.expect(t, tab.slots[0].rep.held >= held - 0.001, "hold time carried over")
	testing.expect_value(t, tab.slots[0].rep.rate, SEEK.rate)
}

@(test)
profile_change_does_not_wedge_the_key :: proc(t: ^testing.T) {
	tab: Table
	next_frame(&tab)
	query(&tab, LEFT, FAST, true, true, FRAME)
	// Two seconds on the fast profile credits ~32 repeats at 0.05 s each.
	for _ in 0 ..< 120 {
		next_frame(&tab)
		query(&tab, LEFT, FAST, false, true, FRAME)
	}
	// Swapping to a 3x slower rate must re-derive that credit. Carrying it over
	// leaves the key owing far more repeats than the new rate has earned, and it
	// goes completely dead for seconds — which is what asserting on `held` and
	// `rate` alone failed to notice.
	n := 0
	for _ in 0 ..< 180 {
		next_frame(&tab)
		n += query(&tab, LEFT, SEEK, false, true, FRAME)
	}
	want := int(3.0 / SEEK.rate) // 3 seconds' worth at the new rate
	testing.expect(t, n >= want - 2, "the key keeps repeating across a profile swap")
}

@(test)
query_works_before_the_first_next_frame :: proc(t: ^testing.T) {
	// A zero-valued Table sits at frame 0, and so does a slot that has never
	// been answered. If the within-frame cache keyed on that alone it would hit
	// on the query that created the slot and swallow the keypress — so any
	// caller that forgot next_frame would see a key that simply does not work.
	tab: Table
	testing.expect_value(t, query(&tab, LEFT, FAST, true, true, FRAME), 1)
}

@(test)
reset_forgets_holds_at_a_screen_change :: proc(t: ^testing.T) {
	tab: Table
	next_frame(&tab)
	query(&tab, LEFT, FAST, true, true, FRAME)
	stepped := 0
	for _ in 0 ..< 60 {
		next_frame(&tab)
		stepped += query(&tab, LEFT, FAST, false, true, FRAME)
	}
	testing.expect(t, stepped > 0, "a second of holding repeats")

	// ENTER opens another screen with the key still down. Without the reset the
	// new screen inherits a hold already past its delay and starts scrolling
	// immediately — several rows before the user can lift a finger.
	reset(&tab)
	after := 0
	for _ in 0 ..< 10 {
		next_frame(&tab)
		after += query(&tab, LEFT, FAST, false, true, FRAME)
	}
	testing.expect_value(t, after, 0)
	// And it is a reset, not a mute: the delay is served and the key works again.
	more := 0
	for _ in 0 ..< 60 {
		next_frame(&tab)
		more += query(&tab, LEFT, FAST, false, true, FRAME)
	}
	testing.expect(t, more > 0, "the key repeats again once the new delay elapses")
}
