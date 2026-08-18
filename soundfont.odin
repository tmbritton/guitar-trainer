package main

// SoundFont playback: render the drill's notes (cadence, target, feedback) with
// TinySoundFont on the main thread into a PCM buffer, then hand it to the audio
// callback's sample voices. Real sampled guitar tone; the amp-sim is bypassed
// while a font is active. When no font is loaded the drill falls back to the KS
// synth, so headless tests are unaffected.

import "core:c"
import "core:strings"

import "clock"
import "music"
import "tsf"

SF_VEL :: 1.0
SF_TAIL :: clock.SAMPLE_RATE // 1 s release ring-out rendered after the notes

Soundfont :: struct {
	handle:       ^tsf.TSF,
	label:        string,
	preset:       int,
	preset_count: int,
}

Sf_Entry :: struct {
	path, label: string,
}

g_sf_files := [?]Sf_Entry {
	{"assets/electric.sf2", "Electric"},
	{"assets/rock60s.sf2", "60s Rock"},
	{"assets/power.sf2", "Power"},
	{"assets/dethmetal.sf2", "Dethmetal"},
}
g_sf_index: int
g_sf: Soundfont
g_di: ^tsf.TSF // clean-guitar DI source, used as the neural-amp input
g_sf_render: [SAMPLE_BUF_LEN]f32 // main-thread render scratch

sf_loaded :: proc() -> bool {
	return g_sf.handle != nil
}

sf_close :: proc() {
	if g_sf.handle != nil {
		tsf.close(g_sf.handle)
		g_sf.handle = nil
	}
	if g_di != nil {
		tsf.close(g_di)
		g_di = nil
	}
}

// di_load opens a clean-guitar SoundFont to use as the neural-amp DI source.
di_load :: proc(path: string) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	d := tsf.load_filename(cpath)
	if d == nil {
		return false
	}
	tsf.set_output(d, .MONO, clock.SAMPLE_RATE, 0)
	if g_di != nil {
		tsf.close(g_di)
	}
	g_di = d
	return true
}

// sf_load opens a SoundFont file and makes it the active playback voice.
sf_load :: proc(path: string, label: string) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	h := tsf.load_filename(cpath)
	if h == nil {
		return false
	}
	tsf.set_output(h, .MONO, clock.SAMPLE_RATE, 0)
	if g_sf.handle != nil {
		tsf.close(g_sf.handle)
	}
	g_sf = Soundfont {
		handle       = h,
		label        = label,
		preset       = 0,
		preset_count = int(tsf.get_presetcount(h)),
	}
	audio_set_amp_enabled(false) // the font already carries the tone
	return true
}

// sf_load_default tries each bundled font in order; returns true if one loaded.
sf_load_default :: proc() -> bool {
	for e, i in g_sf_files {
		if sf_load(e.path, e.label) {
			g_sf_index = i
			return true
		}
	}
	return false
}

sf_next_font :: proc() {
	n := len(g_sf_files)
	for _ in 0 ..< n {
		g_sf_index = (g_sf_index + 1) % n
		if sf_load(g_sf_files[g_sf_index].path, g_sf_files[g_sf_index].label) {
			return
		}
	}
}

sf_next_preset :: proc() {
	if g_sf.handle != nil && g_sf.preset_count > 0 {
		g_sf.preset = (g_sf.preset + 1) % g_sf.preset_count
	}
}

sf_preset_name :: proc() -> string {
	if g_sf.handle == nil {
		return "-"
	}
	return string(tsf.get_presetname(g_sf.handle, c.int(g_sf.preset)))
}

// sf_render renders a sequence of note groups (each held for `dur` samples, in
// order) plus a release tail, into the scratch buffer; returns the filled slice.
sf_render :: proc(groups: [][]int, dur: int) -> []f32 {
	// With the neural amp active, render from the CLEAN DI font so the amp model
	// gets a clean input; otherwise render from the (sampled-amp) font.
	h := g_sf.handle
	preset := c.int(g_sf.preset)
	if nam_amp_active() && g_di != nil {
		h = g_di
		preset = 0
	}
	cursor := 0
	render :: proc(h: ^tsf.TSF, at: int, n: int) -> int {
		m := min(n, SAMPLE_BUF_LEN - at)
		if m <= 0 {
			return 0
		}
		tsf.render_float(h, raw_data(g_sf_render[at:]), c.int(m), 0)
		return m
	}
	for g in groups {
		tsf.note_off_all(h)
		for note in g {
			tsf.note_on(h, preset, c.int(note), SF_VEL)
		}
		cursor += render(h, cursor, dur)
	}
	tsf.note_off_all(h)
	cursor += render(h, cursor, SF_TAIL)
	// Full rig: clean DI -> neural amp -> cabinet IR (each is a no-op if inactive).
	pcm := apply_nam(g_sf_render[:cursor])
	return apply_ir(pcm)
}

// sf_play_cadence renders the I-IV-V-I cadence and schedules it at `at`.
sf_play_cadence :: proc(key: music.Key, at: u64, chord_dur: int) {
	chords := music.cadence(key)
	groups: [4][]int
	for i in 0 ..< 4 {
		groups[i] = chords[i][:]
	}
	pcm := sf_render(groups[:], chord_dur)
	audio_play_samples(pcm, at, 0.9)
}

// sf_play_note renders a single note and schedules it at `at`.
sf_play_note :: proc(midi: int, at: u64, dur: int, gain: f32 = 0.9) {
	one := [1]int{midi}
	groups := [1][]int{one[:]}
	pcm := sf_render(groups[:], dur)
	audio_play_samples(pcm, at, gain)
}
