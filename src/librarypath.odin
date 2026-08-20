package main

// Where separated songs are stored. This used to be the relative literal
// "library", which meant the library depended on the working directory the
// binary happened to be launched from — a different cwd silently produced a
// different (empty) library, and imports landed inside the source repo.
//
// Resolution order, resolved once and cached (the path must not change under a
// running session, or the library screen and the importer would disagree):
//
//   1. $GUITAR_TRAINER_LIBRARY — explicit override, so the library can live on
//      a big disk without touching the code. Stems are large: a 5-minute song
//      is ~90 MB across its six mono FLACs.
//   2. $XDG_DATA_HOME/guitar-trainer/library
//   3. $HOME/.local/share/guitar-trainer/library
//   4. ./library — last resort when there is no HOME (a bare test environment).

import "core:os"
import "core:strings"

LIBRARY_ENV :: "GUITAR_TRAINER_LIBRARY"

@(private = "file")
g_library_root_buf: [1024]u8
@(private = "file")
g_library_root: string

// library_root returns the library directory, creating it if needed. The
// returned string is stable for the process lifetime.
library_root :: proc() -> string {
	if g_library_root != "" do return g_library_root

	env_buf: [512]u8
	if v := os.get_env(env_buf[:], LIBRARY_ENV); v != "" {
		g_library_root = set_root(v)
	} else if v := os.get_env(env_buf[:], "XDG_DATA_HOME"); v != "" {
		g_library_root = set_root(join2(v, "guitar-trainer/library"))
	} else if v := os.get_env(env_buf[:], "HOME"); v != "" {
		g_library_root = set_root(join2(v, ".local/share/guitar-trainer/library"))
	} else {
		g_library_root = set_root("library")
	}
	// Best-effort: a library dir that can't be created shows as an empty
	// library rather than taking down the app.
	_ = os.make_directory_all(g_library_root)
	return g_library_root
}

// set_root copies `path` into the cached buffer (stripping any trailing '/')
// and returns the stored slice.
@(private = "file")
set_root :: proc(path: string) -> string {
	p := path
	for len(p) > 1 && p[len(p) - 1] == '/' do p = p[:len(p) - 1]
	n := copy(g_library_root_buf[:], p)
	return string(g_library_root_buf[:n])
}

@(private = "file")
join2 :: proc(a, b: string) -> string {
	return strings.concatenate({a, "/", b}, context.temp_allocator)
}
