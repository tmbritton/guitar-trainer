package rtalloc

import "core:testing"
import "core:mem"

@(test)
alloc_is_rejected_and_counted :: proc(t: ^testing.T) {
	count: u64
	a := guard_allocator(&count)
	data, err := a.procedure(a.data, .Alloc, 64, 8, nil, 0)
	testing.expect_value(t, err, mem.Allocator_Error.Out_Of_Memory)
	testing.expect(t, data == nil, "guard must not return memory")
	testing.expect_value(t, count, u64(1))
}

@(test)
resize_is_rejected_and_counted :: proc(t: ^testing.T) {
	count: u64
	a := guard_allocator(&count)
	_, err := a.procedure(a.data, .Resize, 128, 8, nil, 64)
	testing.expect_value(t, err, mem.Allocator_Error.Out_Of_Memory)
	testing.expect_value(t, count, u64(1))
}

@(test)
free_is_allowed_and_not_counted :: proc(t: ^testing.T) {
	count: u64
	a := guard_allocator(&count)
	_, err1 := a.procedure(a.data, .Free, 0, 0, nil, 0)
	_, err2 := a.procedure(a.data, .Free_All, 0, 0, nil, 0)
	testing.expect_value(t, err1, mem.Allocator_Error.None)
	testing.expect_value(t, err2, mem.Allocator_Error.None)
	testing.expect_value(t, count, u64(0))
}

@(test)
multiple_allocs_accumulate :: proc(t: ^testing.T) {
	count: u64
	a := guard_allocator(&count)
	a.procedure(a.data, .Alloc, 8, 8, nil, 0)
	a.procedure(a.data, .Alloc, 8, 8, nil, 0)
	a.procedure(a.data, .Alloc_Non_Zeroed, 8, 8, nil, 0)
	testing.expect_value(t, count, u64(3))
}

// The package-global counter path (guard_allocator() default + attempts/reset).
// This is the ONLY test that touches g_attempts, so it can't race the others.
@(test)
global_counter_default_path :: proc(t: ^testing.T) {
	reset_attempts()
	testing.expect_value(t, attempts(), u64(0))
	a := guard_allocator()
	a.procedure(a.data, .Alloc, 16, 8, nil, 0)
	testing.expect_value(t, attempts(), u64(1))
	reset_attempts()
	testing.expect_value(t, attempts(), u64(0))
}
