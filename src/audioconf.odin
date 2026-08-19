package main

// Global audio-device config (distinct from per-song prefs): remembers the
// chosen capture/playback devices by name across runs. Stored at `audio.txt` in
// the repo root as two lines: "capture <name>" / "playback <name>" (an empty
// name means "system default"). Device names can contain spaces, so the name is
// the whole rest of the line.

import "core:os"
import "core:strings"

AUDIO_CONF_PATH :: "audio.txt"

audioconf_save :: proc(capture, playback: string) -> bool {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "capture ")
	strings.write_string(&b, capture)
	strings.write_string(&b, "\nplayback ")
	strings.write_string(&b, playback)
	strings.write_string(&b, "\n")
	return os.write_entire_file(AUDIO_CONF_PATH, transmute([]u8)strings.to_string(b)) == nil
}

// audioconf_load returns the saved capture/playback device names ("" if unset or
// no file). The returned strings are views into a temp-allocated buffer — valid
// for the current call chain (audio_resolve_selection uses them immediately).
audioconf_load :: proc() -> (capture, playback: string) {
	data, err := os.read_entire_file(AUDIO_CONF_PATH, context.temp_allocator)
	if err != nil do return "", ""
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "capture ") {
			capture = strings.trim_space(line[len("capture "):])
		} else if strings.has_prefix(line, "playback ") {
			playback = strings.trim_space(line[len("playback "):])
		}
	}
	return capture, playback
}
