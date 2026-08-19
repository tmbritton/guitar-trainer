package main

// Filesystem helpers for the import/library screens: scan the library dir for
// finished separations (Song list for "Play a Song"), and list a source folder
// for the import file browser (subdirs to navigate + supported audio files).
// Display-only, main-thread; allocates (never on the audio path).

import "core:os"
import "core:slice"
import "core:strings"

import "songlib"

Song :: struct {
	name: string, // library folder name (slug)
	dir:  string, // full path to the song's stem folder
}

// library_scan lists finished separations under `root`: each subdirectory whose
// contents contain all 6 stems (songlib.is_song_dir). Allocates; free with
// library_free. A missing/unreadable root yields an empty list (not an error).
library_scan :: proc(root: string, allocator := context.allocator) -> []Song {
	entries, err := os.read_directory_by_path(root, -1, context.temp_allocator)
	if err != nil do return {}
	songs := make([dynamic]Song, allocator)
	for e in entries {
		if e.type != .Directory do continue
		dir := strings.concatenate({root, "/", e.name}, context.temp_allocator)
		if is_finished_song(dir) {
			append(&songs, Song{name = strings.clone(e.name, allocator), dir = strings.clone(dir, allocator)})
		}
	}
	slice.sort_by(songs[:], proc(a, b: Song) -> bool {return a.name < b.name})
	return songs[:]
}

library_free :: proc(songs: []Song, allocator := context.allocator) {
	for s in songs {
		delete(s.name, allocator)
		delete(s.dir, allocator)
	}
	delete(songs, allocator)
}

@(private = "file")
is_finished_song :: proc(dir: string) -> bool {
	entries, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return false
	names := make([]string, len(entries), context.temp_allocator)
	for e, i in entries do names[i] = e.name
	return songlib.is_song_dir(names)
}

// ---- import file browser ----

Browse_Entry :: struct {
	name:   string,
	is_dir: bool,
}

// browse_dir lists `dir` for the import file browser: subdirectories first (to
// navigate into), then supported audio files, each group sorted by name. Hidden
// entries (leading '.') are skipped. Allocates; free with browse_free.
browse_dir :: proc(dir: string, allocator := context.allocator) -> []Browse_Entry {
	entries, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return {}
	out := make([dynamic]Browse_Entry, allocator)
	for e in entries {
		if len(e.name) > 0 && e.name[0] == '.' do continue // hidden
		if e.type == .Directory {
			append(&out, Browse_Entry{name = strings.clone(e.name, allocator), is_dir = true})
		} else if songlib.is_supported_audio(e.name) {
			append(&out, Browse_Entry{name = strings.clone(e.name, allocator), is_dir = false})
		}
	}
	// dirs before files, each alphabetical
	slice.sort_by(out[:], proc(a, b: Browse_Entry) -> bool {
		if a.is_dir != b.is_dir do return a.is_dir
		return a.name < b.name
	})
	return out[:]
}

browse_free :: proc(entries: []Browse_Entry, allocator := context.allocator) {
	for e in entries do delete(e.name, allocator)
	delete(entries, allocator)
}
