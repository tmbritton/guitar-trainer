package main

// sfcheck — load a SoundFont, list its presets, render a note, and report the
// RMS. Non-zero RMS proves TinySoundFont + the font produce audio (a sanity
// check we can run without being able to hear it).

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"

import "../../tsf"

main :: proc() {
	path: cstring = "assets/electric.sf2"
	if len(os.args) > 1 {
		path = cstring(raw_data(os.args[1]))
	}

	f := tsf.load_filename(path)
	if f == nil {
		fmt.eprintfln("FAIL: could not load %s", path)
		os.exit(1)
	}
	defer tsf.close(f)
	tsf.set_output(f, .MONO, 48000, 0)

	n := int(tsf.get_presetcount(f))
	fmt.printfln("loaded %s — %d presets:", path, n)
	for i in 0 ..< min(n, 24) {
		fmt.printfln("  [%d] %s", i, tsf.get_presetname(f, c.int(i)))
	}

	// Play middle-ish note on preset 0 and render 0.5 s.
	preset: c.int = 0
	tsf.note_on(f, preset, 57, 1.0) // A3
	samples := 24000
	buf := make([]f32, samples)
	defer delete(buf)
	tsf.render_float(f, raw_data(buf), c.int(samples), 0)

	sum: f32 = 0
	peak: f32 = 0
	for s in buf {
		sum += s * s
		peak = max(peak, abs(s))
	}
	rms := math.sqrt(sum / f32(samples))
	fmt.printfln("rendered note: rms=%.4f peak=%.4f", rms, peak)
	if rms < 1e-4 {
		fmt.eprintln("FAIL: rendered silence")
		os.exit(1)
	}
	fmt.println("PASS: soundfont renders audio")
}
