package main

// Cabinet impulse-response (IR) processing. A real speaker+mic+room recording,
// convolved with the rendered guitar signal, is the biggest realism lever for
// electric guitar (replaces the samples' baked-in fizz with a real cab). Done
// offline in the render step, so we can convolve directly (no realtime budget).

import "core:strings"

import ma "vendor:miniaudio"

import "conv"

IR_MAX :: 2048 // truncate IRs to this many taps (~43 ms) — captures the cab, stays fast

g_ir_buf: [IR_MAX]f32
g_ir: []f32 // active IR (nil if none)
g_ir_label: string
g_ir_enabled := true
g_conv_scratch: [SAMPLE_BUF_LEN]f32

g_ir_files := [?]Sf_Entry {
	{"assets/cab1.wav", "Cab A"},
	{"assets/cab2.wav", "Cab B"},
	{"assets/cab3.wav", "Cab C"},
}
g_ir_index: int

// ir_load decodes a WAV (any format) to mono f32 @ 48 kHz, truncates to IR_MAX
// taps, and L2-normalizes it so convolution roughly preserves loudness.
ir_load :: proc(path: string, label: string) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	cfg := ma.decoder_config_init(.f32, 1, 48000)
	dec: ma.decoder
	if ma.decoder_init_file(cpath, &cfg, &dec) != .SUCCESS {
		return false
	}
	defer ma.decoder_uninit(&dec)

	read: u64
	ma.decoder_read_pcm_frames(&dec, raw_data(g_ir_buf[:]), IR_MAX, &read)
	n := int(read)
	if n == 0 {
		return false
	}
	g_ir = g_ir_buf[:n]
	conv.normalize_l2(g_ir)
	g_ir_label = label
	return true
}

ir_load_default :: proc() -> bool {
	for e, i in g_ir_files {
		if ir_load(e.path, e.label) {
			g_ir_index = i
			return true
		}
	}
	return false
}

ir_next :: proc() {
	n := len(g_ir_files)
	for _ in 0 ..< n {
		g_ir_index = (g_ir_index + 1) % n
		if ir_load(g_ir_files[g_ir_index].path, g_ir_files[g_ir_index].label) {
			return
		}
	}
}

ir_toggle :: proc() {
	g_ir_enabled = !g_ir_enabled
}

ir_active :: proc() -> bool {
	return g_ir_enabled && g_ir != nil
}

ir_status :: proc() -> string {
	if g_ir == nil {
		return "no cab"
	}
	return g_ir_enabled ? g_ir_label : "cab off"
}

// apply_ir convolves `pcm` with the active cab IR (into a scratch buffer, then
// peak-limited), or returns `pcm` unchanged when no cab is active.
apply_ir :: proc(pcm: []f32) -> []f32 {
	if !ir_active() || render_aborting() {
		return pcm // no cab, or shutting down — skip the (heavy) convolution
	}
	n := conv.convolve(pcm, g_ir, g_conv_scratch[:])
	out := g_conv_scratch[:n]
	// keep it inside [-1, 1] (convolution can push transients past unity)
	peak: f32 = 0
	for s in out {
		a := s < 0 ? -s : s
		if a > peak {
			peak = a
		}
	}
	if peak > 1 {
		inv := 1 / peak
		for &s in out {
			s *= inv
		}
	}
	return out
}
