package pcmring

// SPSC lock-free ring of raw f32 audio samples: producer (the player's mixing
// worker) -> consumer (the audio callback). The sibling `ring` pkg carries
// discrete Events; this one carries a continuous sample stream, so it exposes
// bulk write/read instead of push/pop. Same discipline: the producer only writes
// `head`, the consumer only writes `tail`, each reads the other with acquire and
// publishes its own with release — no locks. Capacity N must be a power of two;
// the buffer is inline, so nothing allocates after creation.
//
// `head`/`tail` are free-running monotonic sample counters; slot = counter &
// (N-1); in flight = head - tail (empty when equal, full at N).

import "base:intrinsics"

Ring :: struct($N: int) {
	buf:  [N]f32,
	head: u64, // written by producer, read by consumer
	tail: u64, // written by consumer, read by producer
}

// write copies as many of `src` as fit and returns the count written. Producer
// side only. A short return (including 0) means the ring is full — the producer
// never blocks. Allocation-free.
write :: proc(r: ^Ring($N), src: []f32) -> int {
	#assert(N > 0 && (N & (N - 1)) == 0) // capacity must be a power of two
	head := intrinsics.atomic_load_explicit(&r.head, .Relaxed) // we are the only writer
	tail := intrinsics.atomic_load_explicit(&r.tail, .Acquire)
	free := int(u64(N) - (head - tail))
	n := min(len(src), free)
	for i in 0 ..< n {
		r.buf[(head + u64(i)) & u64(N - 1)] = src[i]
	}
	intrinsics.atomic_store_explicit(&r.head, head + u64(n), .Release)
	return n
}

// read fills up to len(dst) samples and returns the count read. Consumer side
// only. A short return (including 0) is an underrun — the caller zero-fills the
// remainder of dst (silence). Allocation-free.
read :: proc(r: ^Ring($N), dst: []f32) -> int {
	tail := intrinsics.atomic_load_explicit(&r.tail, .Relaxed) // we are the only writer
	head := intrinsics.atomic_load_explicit(&r.head, .Acquire)
	avail := int(head - tail)
	n := min(len(dst), avail)
	for i in 0 ..< n {
		dst[i] = r.buf[(tail + u64(i)) & u64(N - 1)]
	}
	intrinsics.atomic_store_explicit(&r.tail, tail + u64(n), .Release)
	return n
}

// available is the number of samples ready to read (consumer's view).
available :: proc(r: ^Ring($N)) -> int {
	head := intrinsics.atomic_load_explicit(&r.head, .Acquire)
	tail := intrinsics.atomic_load_explicit(&r.tail, .Acquire)
	return int(head - tail)
}

// space is the number of samples that can still be written (producer's view).
space :: proc(r: ^Ring($N)) -> int {
	head := intrinsics.atomic_load_explicit(&r.head, .Acquire)
	tail := intrinsics.atomic_load_explicit(&r.tail, .Acquire)
	return N - int(head - tail)
}
