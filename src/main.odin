package main

// Entry point + command-line dispatch. Each `--*check` flag routes to a headless
// self-test (selftests.odin); `--riff`/`--riff-wav` audition the tone (riff.odin);
// `--screenshot` captures PNGs (screenshot.odin). With no flag we run the
// interactive app (app.odin: run_app).

import "core:os"

WINDOW_W :: 800
WINDOW_H :: 480

main :: proc() {
	for arg in os.args[1:] {
		switch arg {
		case "--audiocheck":
			audiocheck()
			return
		case "--calibcheck":
			calibcheck()
			return
		case "--pitchcheck":
			pitchcheck()
			return
		case "--synthcheck":
			synthcheck()
			return
		case "--drillcheck":
			drillcheck()
			return
		case "--storecheck":
			storecheck()
			return
		case "--drillsim":
			drillsim()
			return
		case "--drillabandoncheck":
			drillabandoncheck()
			return
		case "--importcheck":
			importcheck()
			return
		case "--playercheck":
			playercheck()
			return
		case "--speedcheck":
			speedcheck()
			return
		case "--monitorcheck":
			monitorcheck()
			return
		case "--devicecheck":
			devicecheck()
			return
		case "--loopcheck":
			loopcheck()
			return
		case "--progresscheck":
			progresscheck()
			return
		case "--screenshot":
			screenshot()
			return
		case "--sfplaycheck":
			sfplaycheck()
			return
		case "--riff":
			riff()
			return
		case "--riff-wav":
			riff_wav()
			return
		case "--rigdrillcheck":
			rigdrillcheck()
			return
		case "--abortcheck":
			abortcheck()
			return
		}
	}
	run_app()
}
