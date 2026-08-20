package main

// Entry point + command-line dispatch. Each `--*check` flag routes to a headless
// self-test (selftests.odin); `--riff`/`--riff-wav` audition the tone (riff.odin);
// `--screenshot` captures PNGs (screenshot.odin). With no flag we run the
// interactive app (app.odin: run_app).

import "core:fmt"
import "core:os"

WINDOW_W :: 800
WINDOW_H :: 480

main :: proc() {
	for arg, i in os.args[1:] {
		switch arg {
		case "--meta":
			// --meta <song-dir> <source-file>: re-read tags for an already
			// separated song (see import.odin). i indexes os.args[1:], so the
			// two operands are at i+2 and i+3 in os.args.
			if i + 3 >= len(os.args) {
				fmt.eprintfln("usage: guitar-trainer --meta <song-dir> <source-file>")
				os.exit(2)
			}
			meta_backfill(os.args[i + 2], os.args[i + 3])
			return
		case "--importedcheck":
			importedcheck(i + 2 < len(os.args) ? os.args[i + 2] : "")
			return
		case "--queuecheck":
			queuecheck()
			return
		case "--stemcheck":
			// Optional dir operand: --stemcheck [song-dir]. With none, the
			// whole library is checked.
			stemcheck(i + 2 < len(os.args) ? os.args[i + 2] : "")
			return
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
