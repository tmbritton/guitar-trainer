package main

// SoundFont playback: render the drill's notes (cadence, target, feedback) with
// TinySoundFont on the main thread into a PCM buffer, then hand it to the audio
// callback's sample voices. Real sampled guitar tone; the amp-sim is bypassed
// while a font is active. When no font is loaded the drill falls back to the KS
// synth, so headless tests are unaffected.

import "core:c"
import "core:math/rand"
import "core:strings"

import "clock"
import "music"
import "tsf"

SF_TAIL :: clock.SAMPLE_RATE // 1 s release ring-out rendered after the notes
STRUM_GAP :: clock.SAMPLE_RATE / 60 // ~17 ms between strummed chord notes

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

// A timed musical event: play `notes` (a chord; empty = a rest) held for `hold`
// samples. Feeds sf_render_seq for arbitrary rhythms.
Note_Event :: struct {
	notes: []int,
	hold:  int,
}

// sf_source picks the render font: the clean DI when the neural amp is active
// (so it gets a clean input), else the selected sampled-amp font.
@(private)
sf_source :: proc() -> (^tsf.TSF, c.int) {
	if nam_amp_active() && g_di != nil {
		return g_di, 0
	}
	return g_sf.handle, c.int(g_sf.preset)
}

@(private)
sf_chunk :: proc(h: ^tsf.TSF, at, n: int) -> int {
	m := min(n, SAMPLE_BUF_LEN - at)
	if m <= 0 {
		return 0
	}
	tsf.render_float(h, raw_data(g_sf_render[at:]), c.int(m), 0)
	return m
}

// sf_group plays one chord into g_sf_render at `at`, held for `hold` samples.
// Humanized: the chord is strummed (notes staggered by STRUM_GAP, taken out of
// the hold so the group still lasts `hold`), and each note gets a random pick
// velocity. Empty `notes` renders a rest.
@(private)
sf_group :: proc(h: ^tsf.TSF, preset: c.int, notes: []int, hold, at: int) -> int {
	tsf.note_off_all(h)
	played := 0
	strum := len(notes) > 1 ? STRUM_GAP : 0
	for note, ni in notes {
		if ni > 0 {
			played += sf_chunk(h, at + played, strum)
		}
		tsf.note_on(h, preset, c.int(note), rand.float32_range(0.72, 1.0))
	}
	if remain := hold - played; remain > 0 {
		played += sf_chunk(h, at + played, remain)
	}
	return played
}

@(private)
sf_finish :: proc(h: ^tsf.TSF, cursor: int) -> []f32 {
	tsf.note_off_all(h)
	c2 := cursor + sf_chunk(h, cursor, SF_TAIL)
	// Full rig: clean DI -> neural amp -> cabinet IR (each is a no-op if inactive).
	return apply_ir(apply_nam(g_sf_render[:c2]))
}

// sf_render plays each group for the same `dur` (used by the drill: steady
// cadence + target). Returns the finished (amped, cab'd) PCM.
sf_render :: proc(groups: [][]int, dur: int) -> []f32 {
	h, preset := sf_source()
	cursor := 0
	for g in groups {
		cursor += sf_group(h, preset, g, dur, cursor)
	}
	return sf_finish(h, cursor)
}

// sf_render_seq plays a rhythm — events with individual hold times (and rests).
sf_render_seq :: proc(events: []Note_Event) -> []f32 {
	h, preset := sf_source()
	cursor := 0
	for ev in events {
		cursor += sf_group(h, preset, ev.notes, ev.hold, cursor)
	}
	return sf_finish(h, cursor)
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
