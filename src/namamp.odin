package main

// Neural amp stage: a clean DI guitar signal (from a clean SoundFont) run
// through a Neural Amp Modeler capture of a real amp, then into the cab IR.
// This is the "full modeled rig" path. Runs on the render worker thread (or the
// main thread in the headless audition paths) — never both at once; the
// inference loop polls render_aborting() so shutdown doesn't wait it out.

import "core:c"
import "core:strings"

import "nam"

NAM_BLOCK :: 2048 // process in blocks (matches the model's max buffer at reset)

g_nam_handle: rawptr
g_nam_label: string
g_nam_enabled := true
g_nam_scratch: [SAMPLE_BUF_LEN]f32

g_nam_files := [?]Sf_Entry {
	{"assets/amp1.nam", "Laney GH100S"},
	{"assets/amp2.nam", "Marshall JCM2000"},
	{"assets/amp3.nam", "Dirty Shirley"},
}
g_nam_index: int

nam_amp_load_default :: proc() -> bool {
	for e, i in g_nam_files {
		if nam_amp_load(e.path, e.label) {
			g_nam_index = i
			return true
		}
	}
	return false
}

nam_amp_next :: proc() {
	n := len(g_nam_files)
	for _ in 0 ..< n {
		g_nam_index = (g_nam_index + 1) % n
		if nam_amp_load(g_nam_files[g_nam_index].path, g_nam_files[g_nam_index].label) {
			return
		}
	}
}

nam_amp_loaded :: proc() -> bool {
	return g_nam_handle != nil
}

nam_amp_load :: proc(path: string, label: string) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	h := nam.nam_load(cpath)
	if h == nil {
		return false
	}
	nam.nam_reset(h, 48000, NAM_BLOCK)
	if g_nam_handle != nil {
		nam.nam_free(g_nam_handle)
	}
	g_nam_handle = h
	g_nam_label = label
	return true
}

nam_amp_close :: proc() {
	if g_nam_handle != nil {
		nam.nam_free(g_nam_handle)
		g_nam_handle = nil
	}
}

nam_amp_toggle :: proc() {
	g_nam_enabled = !g_nam_enabled
}

nam_amp_active :: proc() -> bool {
	return g_nam_enabled && g_nam_handle != nil
}

nam_amp_status :: proc() -> string {
	if g_nam_handle == nil {
		return "no amp"
	}
	return g_nam_enabled ? g_nam_label : "amp off"
}

// apply_nam runs the (clean) signal through the neural amp and peak-normalizes
// the (typically very hot) output. Returns the input unchanged when inactive.
apply_nam :: proc(pcm: []f32) -> []f32 {
	if !nam_amp_active() {
		return pcm
	}
	n := len(pcm)
	off := 0
	for off < n {
		if render_aborting() {
			break // shutdown requested — stop the (expensive) inference early
		}
		m := min(NAM_BLOCK, n - off)
		nam.nam_process(g_nam_handle, raw_data(pcm[off:]), raw_data(g_nam_scratch[off:]), c.int(m))
		off += m
	}
	out := g_nam_scratch[:off]
	peak: f32 = 0
	for s in out {
		a := s < 0 ? -s : s
		if a > peak {
			peak = a
		}
	}
	if peak > 0 {
		g := f32(0.7) / peak
		for &s in out {
			s *= g
		}
	}
	return out
}
