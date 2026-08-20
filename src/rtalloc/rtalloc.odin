package rtalloc

// A guard allocator for the audio thread. The audio callback must never touch
// the heap; this allocator makes any attempt observable (an atomic counter) and,
// in -debug builds, fatal (a panic). Outside -debug it refuses with
// Out_Of_Memory rather than returning nil silently.
//
// Note the app only installs this guard *in* -debug builds — release callbacks
// get mem.nil_allocator() instead (see debug.odin), so the Out_Of_Memory path
// here is what a caller passing this allocator explicitly gets, not what the
// shipped audio thread runs.
//
// The attempt counter lives behind the allocator's `data` pointer so each
// allocator instance can point at its own counter. The app uses the package
// global via the default argument; tests pass a local counter (no shared state).

import "base:intrinsics"
import "core:mem"

@(private)
g_attempts: u64

// attempts returns how many allocation attempts the default (global) guard has
// seen. Used by the debug HUD.
attempts :: proc() -> u64 {
	return intrinsics.atomic_load(&g_attempts)
}

reset_attempts :: proc() {
	intrinsics.atomic_store(&g_attempts, 0)
}

// guard_allocator builds a guard bound to `counter` (defaults to the package
// global). Pass a dedicated counter in tests to stay parallel-safe.
guard_allocator :: proc(counter: ^u64 = nil) -> mem.Allocator {
	c := counter
	if c == nil {
		c = &g_attempts
	}
	return mem.Allocator{procedure = guard_proc, data = c}
}

guard_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if counter := (^u64)(allocator_data); counter != nil {
			intrinsics.atomic_add(counter, 1)
		}
		when ODIN_DEBUG {
			panic("allocation attempted on the audio thread", location)
		}
		return nil, .Out_Of_Memory
	case .Free, .Free_All, .Query_Features, .Query_Info:
		return nil, .None
	}
	return nil, .None
}
