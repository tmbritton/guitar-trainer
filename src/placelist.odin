package main

// Builds the import browser's "Places" jump list — the shortcuts that make a
// media library reachable without walking up to / and back down. Home and Music
// always appear; every mounted external disk / USB stick / network share is
// discovered from /proc/mounts (parsed by the pure `places` package).
//
// Rebuilt each time the panel opens, so a share that autofs mounted (or a stick
// plugged in) since launch shows up without restarting.

import "base:runtime"
import "core:os"
import "core:strings"

import "places"

Place :: struct {
	label: string, // short name shown in the list
	path:  string, // absolute path to jump to
}

MOUNTS_FILE :: "/proc/mounts"

// places_list returns the jump list. Allocates into `allocator`; free with
// places_free. Entries whose path doesn't exist are dropped, so a stale mount
// never leads the browser somewhere empty.
places_list :: proc(allocator := context.allocator) -> []Place {
	out := make([dynamic]Place, allocator)

	// verify=false skips the existence check for automounts: stat'ing a direct
	// autofs mount point triggers the mount, which blocks the UI until an
	// unreachable server times out. The directory is known to exist anyway.
	add :: proc(out: ^[dynamic]Place, label, path: string, allocator: runtime.Allocator, verify := true) {
		if path == "" do return
		if verify && !os.exists(path) do return
		for p in out do if p.path == path do return // de-dupe
		append(out, Place{label = strings.clone(label, allocator), path = strings.clone(path, allocator)})
	}

	home_buf: [512]u8
	if home := os.get_env(home_buf[:], "HOME"); home != "" {
		add(&out, "Home", home, allocator)
		add(&out, "Music", strings.concatenate({home, "/Music"}, context.temp_allocator), allocator)
	}

	// Mounted volumes. A missing /proc/mounts (or a platform without it) simply
	// yields no mount shortcuts rather than an error.
	if data, err := os.read_entire_file(MOUNTS_FILE, context.temp_allocator); err == nil {
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			m, ok := places.parse_line(line)
			if !ok || !places.is_interesting(m.dir, m.fstype) do continue
			buf := make([]u8, len(m.dir), context.temp_allocator)
			dir := places.unescape(m.dir, buf)
			add(&out, places.label(dir), dir, allocator, !places.is_automount(m.fstype))
		}
	}
	return out[:]
}

places_free :: proc(list: []Place, allocator := context.allocator) {
	for p in list {
		delete(p.label, allocator)
		delete(p.path, allocator)
	}
	delete(list, allocator)
}
