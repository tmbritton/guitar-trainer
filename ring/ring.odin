package ring

// SPSC lock-free ring buffer, audio callback (producer) -> main thread
// (consumer). The producer only writes `head`; the consumer only writes `tail`.
// Each side reads the other's index with acquire ordering and publishes its own
// with release ordering, so no locks are needed. Capacity N must be a power of
// two; the buffer is part of the struct, so nothing allocates after creation.
//
// `head` and `tail` are free-running monotonic counters. The slot index is
// `counter & (N-1)`. Count in flight is `head - tail`: empty when equal, full
// when it equals N. This avoids the classic "one empty slot" ambiguity and
// makes wrap-around fall out of unsigned arithmetic.

import "base:intrinsics"

Event_Kind :: enum u8 {
	Onset,
}

Event :: struct {
	kind:       Event_Kind,
	sample_pos: u64,
	value:      f32,
}

Ring :: struct($N: int) {
	buf:  [N]Event,
	head: u64, // written by producer, read by consumer
	tail: u64, // written by consumer, read by producer
}

// push appends an event. Producer side only. Returns false if the ring is full
// (the event is dropped — the callback must never block). Allocation-free.
push :: proc(r: ^Ring($N), e: Event) -> bool {
	#assert(N > 0 && (N & (N - 1)) == 0) // capacity must be a power of two
	head := intrinsics.atomic_load_explicit(&r.head, .Relaxed) // we are the only writer
	tail := intrinsics.atomic_load_explicit(&r.tail, .Acquire)
	if head - tail >= u64(N) {
		return false
	}
	r.buf[head & u64(N - 1)] = e
	intrinsics.atomic_store_explicit(&r.head, head + 1, .Release)
	return true
}

// pop removes the oldest event. Consumer side only. ok=false if empty.
pop :: proc(r: ^Ring($N)) -> (event: Event, ok: bool) {
	tail := intrinsics.atomic_load_explicit(&r.tail, .Relaxed) // we are the only writer
	head := intrinsics.atomic_load_explicit(&r.head, .Acquire)
	if head == tail {
		return {}, false
	}
	event = r.buf[tail & u64(N - 1)]
	intrinsics.atomic_store_explicit(&r.tail, tail + 1, .Release)
	return event, true
}

// len returns the approximate number of events in flight (diagnostics only).
len :: proc(r: ^Ring($N)) -> int {
	head := intrinsics.atomic_load_explicit(&r.head, .Acquire)
	tail := intrinsics.atomic_load_explicit(&r.tail, .Acquire)
	return int(head - tail)
}
