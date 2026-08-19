package main

import "core:mem"

import "rtalloc"

// callback_allocator returns the allocator installed in the audio callback's
// context. The audio thread must never allocate.
//
//   -debug:   a guard allocator that panics on any allocation attempt, so a
//             stray alloc crashes loudly in development.
//   release:  mem.nil_allocator() — safe, no heap, no overhead.
callback_allocator :: proc() -> mem.Allocator {
	when ODIN_DEBUG {
		return rtalloc.guard_allocator()
	} else {
		return mem.nil_allocator()
	}
}

// audio_alloc_attempts exposes the guard's counter for a debug HUD (0 in
// release, where the guard isn't installed).
audio_alloc_attempts :: proc() -> u64 {
	return rtalloc.attempts()
}
