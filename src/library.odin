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
	meta: songlib.Meta, // tags from meta.txt; all-empty when the file is absent
}

// song_artist / song_album / song_title are the display strings for a Song,
// falling back to "Unknown ..." / the folder slug when it carries no tags (an
// import from before meta.txt existed, or a source file with no tags).
song_artist :: proc(s: Song) -> string {return songlib.group_artist(s.meta)}
song_album :: proc(s: Song) -> string {return songlib.group_album(s.meta)}
song_title :: proc(s: Song) -> string {return songlib.display_title(s.meta, s.name)}

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
		if is_finished_song_dir(dir) {
			append(
				&songs,
				Song {
					name = strings.clone(e.name, allocator),
					dir = strings.clone(dir, allocator),
					meta = read_meta(dir, allocator),
				},
			)
		}
	}
	// Artist -> album -> disc -> track, so the drill-down levels and the track
	// order within an album both fall out of one sort.
	slice.sort_by(songs[:], proc(a, b: Song) -> bool {
		return songlib.meta_less(a.meta, b.meta, a.name, b.name)
	})
	return songs[:]
}

library_free :: proc(songs: []Song, allocator := context.allocator) {
	for s in songs {
		delete(s.name, allocator)
		delete(s.dir, allocator)
		free_meta(s.meta, allocator)
	}
	delete(songs, allocator)
}

// read_meta loads and parses `dir`/meta.txt. songlib.parse_meta returns slices
// into the file buffer, which is temp — so each field is cloned into `allocator`
// (owned by the Song, released by free_meta). A missing file yields a zero Meta,
// which the song_* accessors render as the "Unknown" fallbacks.
@(private = "file")
read_meta :: proc(dir: string, allocator := context.allocator) -> songlib.Meta {
	path := strings.concatenate({dir, "/meta.txt"}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return {}
	m := songlib.parse_meta(string(data))
	m.artist = strings.clone(m.artist, allocator)
	m.albumartist = strings.clone(m.albumartist, allocator)
	m.album = strings.clone(m.album, allocator)
	m.title = strings.clone(m.title, allocator)
	m.source = strings.clone(m.source, allocator)
	return m
}

@(private = "file")
free_meta :: proc(m: songlib.Meta, allocator := context.allocator) {
	delete(m.artist, allocator)
	delete(m.albumartist, allocator)
	delete(m.album, allocator)
	delete(m.title, allocator)
	delete(m.source, allocator)
}

// is_finished_song_dir reports whether `dir` holds a complete separation (all 6
// stems, either extension). Shared with the import queue's already-imported
// check — there is exactly one definition of "finished".
is_finished_song_dir :: proc(dir: string) -> bool {
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
