package main

// namcheck — load a .nam model, run a clean sine through it, and report that it
// processes audio without crashing and produces finite, bounded output. A quick
// sanity check (we can't hear it) that the neural-amp pipeline works.

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"

import "../../nam"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: namcheck <model.nam>")
		os.exit(2)
	}
	path := cstring(raw_data(os.args[1]))

	h := nam.nam_load(path)
	if h == nil {
		fmt.eprintfln("FAIL: could not load %s", os.args[1])
		os.exit(1)
	}
	defer nam.nam_free(h)

	MAXBUF :: 2048
	nam.nam_reset(h, 48000, MAXBUF)
	fmt.printfln("loaded %s  has_loudness=%v loudness=%.1f dB", os.args[1], nam.nam_has_loudness(h) != 0, nam.nam_loudness(h))

	// clean DI sine at a realistic instrument level
	N :: 48000
	input := make([]f32, N)
	output := make([]f32, N)
	defer delete(input)
	defer delete(output)
	for i in 0 ..< N {
		input[i] = 0.2 * math.sin(2 * math.PI * 220 * f32(i) / 48000)
	}

	// process in blocks <= MAXBUF
	off := 0
	for off < N {
		n := min(MAXBUF, N - off)
		nam.nam_process(h, raw_data(input[off:]), raw_data(output[off:]), c.int(n))
		off += n
	}

	in_rms, out_rms, out_peak: f32
	finite := true
	for i in 0 ..< N {
		in_rms += input[i] * input[i]
		o := output[i]
		if o != o || o > 1e6 || o < -1e6 {finite = false}
		out_rms += o * o
		out_peak = max(out_peak, abs(o))
	}
	in_rms = math.sqrt(in_rms / N)
	out_rms = math.sqrt(out_rms / N)
	fmt.printfln("in_rms=%.4f  out_rms=%.4f  out_peak=%.4f  finite=%v", in_rms, out_rms, out_peak, finite)

	if !finite || out_rms < 1e-6 {
		fmt.eprintln("FAIL: model produced silence or non-finite output")
		os.exit(1)
	}
	fmt.println("PASS: neural amp model processes audio")
}
