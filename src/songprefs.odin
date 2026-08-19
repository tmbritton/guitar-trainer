package main

// Per-song persistence: remember each stem's level/mute/solo, plus the rig
// (monitor amp settings) and playback speed, between sessions. Stored as a small
// text file `mixer.txt` in the song's library folder — six stem lines in
// songlib.STEMS order ("<level> <mute> <solo>"), then one rig line
// ("rig <monitor> <drive> <bass> <treble> <level> <cab> <speed>"). Tolerant of a
// missing/short/old file: unset stems keep defaults, a missing rig line yields the
// default rig (so pre-rig mixer.txt files still load).

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "mix"

// Rig is the per-song monitor amp + speed state.
Rig :: struct {
	monitor:   bool, // live input monitoring on?
	drive:     f32, // waveshaper drive
	bass_db:   f32, // tone: bass shelf (dB)
	treble_db: f32, // tone: treble shelf (dB)
	level:     f32, // monitor mix level
	cab:       int, // monitor cab index
	speed:     f32, // playback speed
}

default_rig :: proc() -> Rig {
	return Rig{monitor = false, drive = 2, bass_db = 0, treble_db = 0, level = 0.5, cab = 0, speed = 1}
}

@(private = "file")
prefs_path :: proc(dir: string) -> string {
	return fmt.tprintf("%s/mixer.txt", dir)
}

// prefs_save writes the mixer + rig state for the song at `dir`.
prefs_save :: proc(dir: string, ctl: [6]mix.Stem_Ctl, rig: Rig) -> bool {
	b := strings.builder_make(context.temp_allocator)
	for c in ctl {
		fmt.sbprintf(&b, "%.4f %d %d\n", c.level, int(c.mute), int(c.solo))
	}
	fmt.sbprintf(
		&b,
		"rig %d %.4f %.4f %.4f %.4f %d %.4f\n",
		int(rig.monitor),
		rig.drive,
		rig.bass_db,
		rig.treble_db,
		rig.level,
		rig.cab,
		rig.speed,
	)
	return os.write_entire_file(prefs_path(dir), transmute([]u8)strings.to_string(b)) == nil
}

// prefs_load reads the mixer + rig state for the song at `dir`. Returns defaults
// (full level / default rig) and ok=false when no readable prefs file is present.
prefs_load :: proc(dir: string) -> (ctl: [6]mix.Stem_Ctl, rig: Rig, ok: bool) {
	for i in 0 ..< 6 do ctl[i] = mix.Stem_Ctl{level = 1}
	rig = default_rig()
	data, rerr := os.read_entire_file(prefs_path(dir), context.temp_allocator)
	if rerr != nil do return ctl, rig, false

	stem := 0
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) == 0 do continue
		if fields[0] == "rig" {
			parse_rig(fields, &rig)
			continue
		}
		if stem < 6 && len(fields) >= 3 {
			lvl, _ := strconv.parse_f32(fields[0])
			mute, _ := strconv.parse_int(fields[1])
			solo, _ := strconv.parse_int(fields[2])
			ctl[stem] = mix.Stem_Ctl {
				level = clamp(lvl, 0, 1),
				mute  = mute != 0,
				solo  = solo != 0,
			}
			stem += 1
		}
	}
	return ctl, rig, stem > 0
}

// parse_rig fills `rig` from a "rig <monitor> <drive> <bass> <treble> <level>
// <cab> <speed>" line (fields[0] == "rig"). Missing/short fields keep defaults.
@(private = "file")
parse_rig :: proc(fields: []string, rig: ^Rig) {
	f :: proc(fields: []string, i: int, def: f32) -> f32 {
		if i >= len(fields) do return def
		v, ok := strconv.parse_f32(fields[i])
		return ok ? v : def
	}
	n :: proc(fields: []string, i: int, def: int) -> int {
		if i >= len(fields) do return def
		v, ok := strconv.parse_int(fields[i])
		return ok ? v : def
	}
	rig.monitor = n(fields, 1, 0) != 0
	rig.drive = f(fields, 2, rig.drive)
	rig.bass_db = f(fields, 3, rig.bass_db)
	rig.treble_db = f(fields, 4, rig.treble_db)
	rig.level = f(fields, 5, rig.level)
	rig.cab = n(fields, 6, rig.cab)
	rig.speed = f(fields, 7, rig.speed)
}
