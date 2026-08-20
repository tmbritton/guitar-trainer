package main

// Per-song practice sections: the I/O shell around the pure `sections` package.
// Stored as `library/<song>/sections.txt`, a sibling of mixer.txt rather than
// part of it — mixer.txt is a fixed-shape positional record (six stem lines plus
// a rig line) and sections are a variable-length list, so keeping them apart
// means a corrupt section line cannot cost you your mixer.

import "core:os"
import "core:strings"

import "sections"

SECTIONS_FILE :: "sections.txt"

@(private = "file")
sections_path :: proc(dir: string) -> string {
	return strings.concatenate({dir, "/", SECTIONS_FILE}, context.temp_allocator)
}

// sections_load reads a song's sections. Names come back as heap clones (the
// parse returns subslices of a temp buffer), so free the list with
// sections_free. A missing file is not an error — it means no sections yet.
sections_load :: proc(dir: string) -> [dynamic]sections.Section {
	out := make([dynamic]sections.Section)
	data, err := os.read_entire_file(sections_path(dir), context.temp_allocator)
	if err != nil do return out
	buf: [sections.MAX]sections.Section
	n := sections.parse(string(data), buf[:])
	for i in 0 ..< n {
		s := buf[i]
		s.name = strings.clone(s.name) // the parse buffer is temp
		append(&out, s)
	}
	return out
}

sections_save :: proc(dir: string, list: []sections.Section) -> bool {
	b := strings.builder_make(context.temp_allocator)
	sections.format(&b, list)
	return os.write_entire_file(sections_path(dir), transmute([]u8)strings.to_string(b)) == nil
}

sections_free :: proc(list: ^[dynamic]sections.Section) {
	for s in list do delete(s.name)
	if list^ != nil do delete(list^)
	list^ = nil
}

// section_speed is the speed a section should play at after `passes` completed
// repetitions: the speed it was saved at, unless its ladder is switched on.
//
// This is where "the ladder is opt-in" actually lives — a single place, so the
// UI cannot accidentally advance the tempo of a section that never asked for it.
section_speed :: proc(s: sections.Section, passes: int) -> f32 {
	if !s.ladder do return sections.clamp_speed(s.speed)
	return sections.ladder_speed(s.speed, passes)
}
