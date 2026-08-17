package ring

import "core:testing"

@(test)
pop_on_empty_returns_not_ok :: proc(t: ^testing.T) {
	r: Ring(4)
	_, ok := pop(&r)
	testing.expect(t, !ok, "pop on empty ring must return ok=false")
}

@(test)
push_then_pop_returns_same_event :: proc(t: ^testing.T) {
	r: Ring(4)
	e := Event{kind = .Onset, sample_pos = 1234, value = 0.5}
	testing.expect(t, push(&r, e), "push into empty ring must succeed")
	got, ok := pop(&r)
	testing.expect(t, ok, "pop after push must return ok=true")
	testing.expect_value(t, got.sample_pos, u64(1234))
	testing.expect_value(t, got.value, f32(0.5))
	testing.expect_value(t, got.kind, Event_Kind.Onset)
}

@(test)
fifo_order_preserved :: proc(t: ^testing.T) {
	r: Ring(4)
	for i in 0 ..< 3 {
		testing.expect(t, push(&r, Event{sample_pos = u64(i)}), "push should succeed")
	}
	for i in 0 ..< 3 {
		got, ok := pop(&r)
		testing.expect(t, ok, "pop should succeed")
		testing.expect_value(t, got.sample_pos, u64(i))
	}
}

@(test)
push_when_full_returns_false_and_preserves_data :: proc(t: ^testing.T) {
	r: Ring(4)
	// capacity is N (4). Fill it.
	for i in 0 ..< 4 {
		testing.expect(t, push(&r, Event{sample_pos = u64(i)}), "fill should succeed")
	}
	// next push must fail without overwriting.
	testing.expect(t, !push(&r, Event{sample_pos = 999}), "push on full must return false")
	// the four originals must still be intact and in order.
	for i in 0 ..< 4 {
		got, ok := pop(&r)
		testing.expect(t, ok, "pop should succeed")
		testing.expect_value(t, got.sample_pos, u64(i))
	}
}

@(test)
wraps_around_past_capacity :: proc(t: ^testing.T) {
	r: Ring(4)
	// Push/pop 20 events one-at-a-time; indices wrap past N repeatedly.
	for i in 0 ..< 20 {
		testing.expect(t, push(&r, Event{sample_pos = u64(i)}), "push should succeed")
		got, ok := pop(&r)
		testing.expect(t, ok, "pop should succeed")
		testing.expect_value(t, got.sample_pos, u64(i))
	}
	_, ok := pop(&r)
	testing.expect(t, !ok, "ring should be empty at the end")
}

@(test)
interleaved_burst_preserves_fifo :: proc(t: ^testing.T) {
	r: Ring(8)
	produced := 0
	consumed := 0
	next_expected := 0
	// Bursty producer/consumer over more than N total events.
	for round in 0 ..< 30 {
		// produce up to 3
		for _ in 0 ..< 3 {
			if push(&r, Event{sample_pos = u64(produced)}) {
				produced += 1
			}
		}
		// consume up to 2
		for _ in 0 ..< 2 {
			got, ok := pop(&r)
			if !ok do break
			testing.expect_value(t, got.sample_pos, u64(next_expected))
			next_expected += 1
			consumed += 1
		}
	}
	// drain the rest
	for {
		got, ok := pop(&r)
		if !ok do break
		testing.expect_value(t, got.sample_pos, u64(next_expected))
		next_expected += 1
		consumed += 1
	}
	testing.expect_value(t, consumed, produced)
	testing.expect(t, produced > 8, "should have moved more than one ring's worth")
}
