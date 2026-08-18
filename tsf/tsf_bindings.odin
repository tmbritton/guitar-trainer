package tsf

// Odin bindings to TinySoundFont (vendored tsf.h, compiled to libtsf.a). A
// single-file C SoundFont2 synth — used to render real sampled guitar tones for
// playback. Main-thread only in this app (we pre-render notes to PCM buffers).

import "core:c"

foreign import lib "libtsf.a"

TSF :: struct {} // opaque handle

Output_Mode :: enum c.int {
	STEREO_INTERLEAVED = 0,
	STEREO_UNWEAVED    = 1,
	MONO               = 2,
}

@(default_calling_convention = "c", link_prefix = "tsf_")
foreign lib {
	load_filename :: proc(filename: cstring) -> ^TSF ---
	close :: proc(f: ^TSF) ---
	reset :: proc(f: ^TSF) ---
	get_presetcount :: proc(f: ^TSF) -> c.int ---
	get_presetname :: proc(f: ^TSF, preset_index: c.int) -> cstring ---
	set_output :: proc(f: ^TSF, mode: Output_Mode, samplerate: c.int, global_gain_db: f32) ---
	set_max_voices :: proc(f: ^TSF, max_voices: c.int) -> c.int ---
	note_on :: proc(f: ^TSF, preset_index: c.int, key: c.int, vel: f32) -> c.int ---
	note_off :: proc(f: ^TSF, preset_index: c.int, key: c.int) ---
	note_off_all :: proc(f: ^TSF) ---
	render_float :: proc(f: ^TSF, buffer: [^]f32, samples: c.int, flag_mixing: c.int) ---
}
