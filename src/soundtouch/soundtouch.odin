package soundtouch

// Odin binding for the SoundTouch time-stretch shim (st_shim.cpp) compiled into
// libsoundtouch.a by build.sh. Mono float samples; tempo is a multiplier
// (1.0 = normal, 0.5 = half speed, pitch preserved). The producer thread in the
// player owns one instance; see src/player.odin.

import "core:c"

foreign import lib "libsoundtouch.a"

@(default_calling_convention = "c")
foreign lib {
	st_create :: proc(sample_rate, channels: c.uint) -> rawptr ---
	st_destroy :: proc(h: rawptr) ---
	st_set_tempo :: proc(h: rawptr, tempo: c.double) ---
	st_put :: proc(h: rawptr, data: [^]f32, num_frames: c.uint) ---
	st_receive :: proc(h: rawptr, data: [^]f32, max_frames: c.uint) -> c.uint ---
	st_available :: proc(h: rawptr) -> c.uint ---
	st_clear :: proc(h: rawptr) ---
	st_flush :: proc(h: rawptr) ---
}
