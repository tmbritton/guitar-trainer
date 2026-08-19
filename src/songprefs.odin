package main

// Per-song mixer persistence: remember each stem's level/mute/solo between
// sessions. Stored as a small text file `mixer.txt` in the song's library folder
// — one line per stem in songlib.STEMS order: "<level> <mute> <solo>". Tolerant
// of a missing/short file (unset stems keep the default: full level, unmuted).

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "mix"

@(private = "file")
prefs_path :: proc(dir: string) -> string {
	return fmt.tprintf("%s/mixer.txt", dir)
}

// prefs_save writes the mixer state for the song at `dir`.
prefs_save :: proc(dir: string, ctl: [6]mix.Stem_Ctl) -> bool {
	b := strings.builder_make(context.temp_allocator)
	for c in ctl {
		fmt.sbprintf(&b, "%.4f %d %d\n", c.level, int(c.mute), int(c.solo))
	}
	return os.write_entire_file(prefs_path(dir), transmute([]u8)strings.to_string(b)) == nil
}

// prefs_load reads the mixer state for the song at `dir`. Returns defaults (full
// level, unmuted) and ok=false when no readable prefs file is present.
prefs_load :: proc(dir: string) -> (ctl: [6]mix.Stem_Ctl, ok: bool) {
	for i in 0 ..< 6 do ctl[i] = mix.Stem_Ctl{level = 1} // defaults
	data, rerr := os.read_entire_file(prefs_path(dir), context.temp_allocator)
	if rerr != nil do return ctl, false

	i := 0
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if i >= 6 do break
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) < 3 do continue
		lvl, _ := strconv.parse_f32(fields[0])
		mute, _ := strconv.parse_int(fields[1])
		solo, _ := strconv.parse_int(fields[2])
		ctl[i] = mix.Stem_Ctl {
			level = clamp(lvl, 0, 1),
			mute  = mute != 0,
			solo  = solo != 0,
		}
		i += 1
	}
	return ctl, i > 0
}
