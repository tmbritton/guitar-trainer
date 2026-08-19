package main

// Tone-audition modes: render a short rock riff through the current rig so the
// guitar tone can be judged directly (`--riff` plays it, `--riff-wav` exports a
// WAV + prints the onset rhythm). No window, no drill. Dispatched from `main`.

import "core:fmt"
import "core:os"
import "core:time"

import "clock"
import "detect"

// riff plays a short rock riff (Smoke on the Water, power chords) through the
// current rig so the tone can be auditioned directly — no window, no drill.
riff :: proc() {
	if !audio_init() {
		fmt.eprintln("FAIL: audio_init")
		os.exit(1)
	}
	defer audio_shutdown()
	sf_load_default()
	di_load("assets/clean.sf2")
	nam_amp_load_default()
	ir_load_default()
	defer sf_close()
	defer nam_amp_close()

	if nam_amp_active() {
		fmt.printfln("rig: clean DI -> %s -> cab %s", nam_amp_status(), ir_status())
	} else {
		fmt.printfln("tone: %s / %s -> cab %s", g_sf.label, sf_preset_name(), ir_status())
	}

	events, dyads := sotw_events()
	defer delete(events)
	defer delete(dyads)

	fmt.println("rendering Smoke on the Water through the rig...")
	pcm := sf_render_seq(events)
	start := audio_clock_now() + u64(clock.SAMPLE_RATE / 10)
	audio_play_samples(pcm, start, 0.9)

	end := start + u64(len(pcm))
	for audio_clock_now() < end + u64(clock.SAMPLE_RATE / 4) {
		time.sleep(20 * time.Millisecond)
	}
	fmt.println("done")
}

// The riff, as data — easy to edit. Roots in G (G2=43); each non-rest note is a
// parallel fourth (root + 5). hold_ms is how long that note sounds; rests are
// silence. Caller deletes both returned slices.
Riff_Beat :: struct {
	root:    int,
	hold_ms: int,
	rest:    bool,
}

sotw_events :: proc() -> (events: []Note_Event, dyads: [][2]int) {
	beats := []Riff_Beat {
		{43, 220, false}, {46, 220, false}, {48, 700, false}, {0, 180, true}, // G  Bb  C..
		{43, 220, false}, {46, 220, false}, {49, 220, false}, {48, 700, false}, {0, 180, true}, // G Bb Db C..
		{43, 220, false}, {46, 220, false}, {48, 700, false}, {0, 180, true}, // G  Bb  C..
		{46, 220, false}, {43, 900, false}, // Bb  G..
	}
	events = make([]Note_Event, len(beats))
	dyads = make([][2]int, len(beats))
	for b, i in beats {
		hold := int(clock.ms_to_samples(f64(b.hold_ms)))
		if b.rest {
			events[i] = {notes = {}, hold = hold}
		} else {
			dyads[i] = {b.root, b.root + 5}
			events[i] = {notes = dyads[i][:], hold = hold}
		}
	}
	return
}

// riff_wav renders the riff to a WAV file and prints the actual note-onset
// rhythm (via the onset detector) — a way to verify timing without hearing it,
// and to audition the tone outside the app.
riff_wav :: proc() {
	path := "riff.wav"
	if len(os.args) > 2 {
		path = os.args[2]
	}
	sf_load_default()
	di_load("assets/clean.sf2")
	nam_amp_load_default()
	ir_load_default()
	defer sf_close()
	defer nam_amp_close()

	events, dyads := sotw_events()
	defer delete(events)
	defer delete(dyads)
	pcm := sf_render_seq(events)

	if !write_wav(path, pcm) {
		fmt.eprintfln("FAIL: could not write %s", path)
		os.exit(1)
	}
	fmt.printfln("wrote %s (%.2f s)", path, clock.samples_to_seconds(u64(len(pcm))))

	// Verify note timing on a CLEAN render (distortion sustain hides individual
	// notes from the onset detector; clean plucks re-arm it cleanly).
	nam_was, ir_was := g_nam_enabled, g_ir_enabled
	g_nam_enabled, g_ir_enabled = false, false
	clean := sf_render_seq(events)
	g_nam_enabled, g_ir_enabled = nam_was, ir_was

	d := detect.default_onset_detector()
	fmt.println("note rhythm (from the clean signal — onset time, gap from previous):")
	pos := 0
	prev: u64
	first := true
	n := 0
	for pos + 128 <= len(clean) {
		on, at := detect.push_block(&d, clean[pos:pos + 128], u64(pos))
		if on {
			gap := first ? 0.0 : clock.samples_to_ms(at - prev)
			fmt.printfln("  note %2d  @ %6.0f ms   (gap +%.0f ms)", n, clock.samples_to_ms(at), gap)
			prev = at
			first = false
			n += 1
		}
		pos += 128
	}
	fmt.printfln("%d notes detected", n)
}
