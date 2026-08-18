package nam

// Odin bindings to NeuralAmpModelerCore via our C shim (libnam.a). A neural
// model of a real guitar amp: feed a clean DI signal, get an amped signal.
// Main-thread only (we pre-render notes offline).

import "core:c"

foreign import lib "libnam.a"

@(default_calling_convention = "c")
foreign lib {
	nam_load :: proc(path: cstring) -> rawptr ---
	nam_reset :: proc(h: rawptr, sample_rate: f64, max_buffer: c.int) ---
	nam_has_loudness :: proc(h: rawptr) -> c.int ---
	nam_loudness :: proc(h: rawptr) -> f64 ---
	nam_process :: proc(h: rawptr, input: [^]f32, output: [^]f32, n: c.int) ---
	nam_free :: proc(h: rawptr) ---
}
