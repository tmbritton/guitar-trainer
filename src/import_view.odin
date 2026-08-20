package main

// UI + small stateful widgets for the song-import flow: a keyboard file browser
// (Import screen), a progress view (Importing screen), and the song list (Play a
// Song / Library screen). Pure view + navigation state; the heavy lifting is in
// import.odin (worker) and library.odin (filesystem scan).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

import "menu"

VISIBLE_ROWS :: 8 // list rows on screen at once (viewport scrolls with selection)

// ---- file browser (Import screen) ----

// The Import screen has three modes on one screen: the file listing, a Places
// jump list (so a NAS share or USB stick is one keypress away instead of a walk
// up to / and back down), and a path entry field for anything not listed.
Browse_Mode :: enum {
	Browse,
	Places,
	Path,
}

Browser :: struct {
	dir:       string, // current directory (view into dir_buf)
	dir_buf:   [512]u8,
	path_buf:  [512]u8, // scratch for the selected entry's full path
	entries:   []Browse_Entry, // owned; freed by browse_free
	sel:       int,
	mode:      Browse_Mode,
	places:    []Place, // owned while mode == .Places; rebuilt on open
	place_sel: int,
	input:     [512]u8, // path-entry text
	input_len: int,
	marks:     [dynamic]string, // absolute paths marked for batch import (owned)
	status:    string, // transient message (e.g. "already imported"); view into status_buf
	status_buf: [128]u8,
}

// browser_set_status posts a one-line message under the listing. Cleared by the
// next mark/navigation so it never goes stale.
browser_set_status :: proc(b: ^Browser, msg: string) {
	b.status = string(b.status_buf[:copy(b.status_buf[:], msg)])
}

// browser_open points the browser at `dir` and (re)loads its listing.
browser_open :: proc(b: ^Browser, dir: string) {
	b.status = ""
	if b.entries != nil do browse_free(b.entries)
	n := copy(b.dir_buf[:], dir)
	b.dir = string(b.dir_buf[:n])
	b.entries = browse_dir(b.dir)
	b.sel = 0
}

browser_close :: proc(b: ^Browser) {
	if b.entries != nil do browse_free(b.entries)
	b.entries = nil
	if b.places != nil do places_free(b.places)
	b.places = nil
	browser_clear_marks(b)
	if b.marks != nil do delete(b.marks)
	b.marks = nil
}

// ---- marking (batch import) ----

// browser_toggle_mark adds or removes the selected entry from the import set.
// Both files and directories can be marked; a marked directory is expanded
// recursively when the import starts (queue_expand), which is how you pick a
// whole album or artist.
browser_toggle_mark :: proc(b: ^Browser) {
	b.status = ""
	if len(b.entries) == 0 do return
	buf: [512]u8
	full := join_path(buf[:], b.dir, b.entries[b.sel].name)
	if b.marks == nil do b.marks = make([dynamic]string)
	for m, i in b.marks {
		if m == full {
			delete(b.marks[i])
			ordered_remove(&b.marks, i)
			return
		}
	}
	append(&b.marks, strings.clone(full))
}

browser_is_marked :: proc(b: ^Browser, name: string) -> bool {
	if b.marks == nil do return false
	buf: [512]u8
	full := join_path(buf[:], b.dir, name)
	for m in b.marks do if m == full do return true
	return false
}

browser_clear_marks :: proc(b: ^Browser) {
	if b.marks == nil do return
	for m in b.marks do delete(m)
	clear(&b.marks)
}

browser_mark_count :: proc(b: ^Browser) -> int {
	return b.marks == nil ? 0 : len(b.marks)
}

// ---- places + path entry ----

browser_open_places :: proc(b: ^Browser) {
	if b.places != nil do places_free(b.places)
	b.places = places_list() // rebuilt each time: mounts come and go
	b.place_sel = 0
	b.mode = .Places
}

browser_places_enter :: proc(b: ^Browser) {
	if len(b.places) > 0 do browser_open(b, b.places[b.place_sel].path)
	b.mode = .Browse
}

// browser_path_begin opens the path field seeded with the current directory, so
// it doubles as "edit where I am" rather than always typing from scratch.
browser_path_begin :: proc(b: ^Browser) {
	b.input_len = copy(b.input[:], b.dir)
	b.mode = .Path
}

browser_path_char :: proc(b: ^Browser, c: rune) {
	// Printable ASCII only; paths from a text field never need more, and this
	// keeps the buffer a simple byte array.
	if c < 32 || c > 126 do return
	if b.input_len >= len(b.input) do return
	b.input[b.input_len] = u8(c)
	b.input_len += 1
}

browser_path_backspace :: proc(b: ^Browser) {
	if b.input_len > 0 do b.input_len -= 1
}

// browser_path_commit navigates to the typed path. A path that doesn't exist
// leaves the browser where it was rather than showing an empty listing.
browser_path_commit :: proc(b: ^Browser) -> bool {
	p := strings.trim_space(string(b.input[:b.input_len]))
	b.mode = .Browse
	if len(p) == 0 || !os.exists(p) do return false
	browser_open(b, p)
	return true
}

browser_move :: proc(b: ^Browser, delta: int) {
	b.sel = menu.move(b.sel, len(b.entries), delta)
}

// browser_up navigates to the parent directory.
browser_up :: proc(b: ^Browser) {
	buf: [512]u8
	browser_open(b, parent_dir(buf[:], b.dir))
}

Browse_Action :: enum {
	None,
	Navigated,
	Import,
}

// browser_enter acts on the selected entry: descend into a directory (Navigated)
// or choose an audio file to import (Import, with its full path). The returned
// path is a view into b.path_buf — valid until the next browser call; import_start
// copies it immediately.
browser_enter :: proc(b: ^Browser) -> (action: Browse_Action, path: string) {
	if len(b.entries) == 0 do return .None, ""
	e := b.entries[b.sel]
	full := join_path(b.path_buf[:], b.dir, e.name)
	if e.is_dir {
		browser_open(b, full)
		return .Navigated, ""
	}
	return .Import, full
}

browser_draw :: proc(b: ^Browser) {
	ui_text("IMPORT SONG", 40, 40, 40, UI_FRAME)

	switch b.mode {
	case .Places:
		browser_draw_places(b)
		return
	case .Path:
		browser_draw_path(b)
		return
	case .Browse:
	}

	rl.DrawText(fmt.ctprintf("%s", b.dir), 40, 92, 16, UI_DIM)

	if len(b.entries) == 0 {
		ui_text("no audio files or folders here", 40, 150, 20, UI_DIM)
	} else {
		first := viewport_first(b.sel, len(b.entries))
		for row in 0 ..< min(VISIBLE_ROWS, len(b.entries) - first) {
			i := first + row
			e := b.entries[i]
			y := i32(140 + row * 40)
			if i == b.sel do ui_panel(36, y - 6, 720, 36, UI_FRAME)
			col := i == b.sel ? UI_INK : UI_DIM
			// A marked row gets a bullet: this is the album/file batch set.
			if browser_is_marked(b, e.name) {
				ui_text("*", 40, y, 22, UI_GOLD)
			}
			label := e.is_dir ? fmt.ctprintf("%s/", e.name) : fmt.ctprintf("%s", e.name)
			ui_text(label, 56, y, 22, e.is_dir ? (i == b.sel ? UI_GOLD : UI_FRAME_DK) : col)
		}
	}

	if n := browser_mark_count(b); n > 0 {
		ui_text(fmt.ctprintf("%d marked   I import   C clear", n), 40, 420, 18, UI_GOLD)
	}
	if len(b.status) > 0 {
		ui_text(fmt.ctprintf("%s", b.status), 40, 396, 18, UI_DIM)
	}
	rl.DrawText(
		"UP/DOWN move  ENTER open  SPACE mark  BACKSPACE up  P places  L path  ESC menu",
		40,
		448,
		16,
		{90, 90, 120, 255},
	)
}

@(private = "file")
browser_draw_places :: proc(b: ^Browser) {
	ui_text("go to", 40, 92, 16, UI_DIM)
	if len(b.places) == 0 {
		ui_text("no places found", 40, 150, 20, UI_DIM)
	}
	first := viewport_first(b.place_sel, len(b.places))
	for row in 0 ..< min(VISIBLE_ROWS, len(b.places) - first) {
		i := first + row
		y := i32(140 + row * 40)
		if i == b.place_sel do ui_panel(36, y - 6, 720, 36, UI_FRAME)
		ui_text(fmt.ctprintf("%s", b.places[i].label), 56, y, 22, i == b.place_sel ? UI_INK : UI_DIM)
		rl.DrawText(fmt.ctprintf("%s", b.places[i].path), 260, y + 4, 16, UI_FRAME_DK)
	}
	rl.DrawText("UP/DOWN move   ENTER go   ESC back", 40, 448, 16, {90, 90, 120, 255})
}

@(private = "file")
browser_draw_path :: proc(b: ^Browser) {
	ui_text("go to path", 40, 92, 16, UI_DIM)
	ui_panel(36, 140, 720, 44, UI_GOLD)
	// A trailing block stands in for a caret.
	ui_text(fmt.ctprintf("%s_", string(b.input[:b.input_len])), 52, 152, 20, UI_INK)
	ui_text("type or paste a path (CTRL+V)", 40, 210, 18, UI_DIM)
	rl.DrawText("ENTER go   ESC cancel", 40, 448, 16, {90, 90, 120, 255})
}

// ---- Importing screen (progress) ----

importing_draw :: proc(name: string) {
	// A finished batch replaces the whole screen with its summary — the
	// per-song bar and status are meaningless once there is no song running.
	if queue_finished() {
		importing_draw_summary()
		return
	}

	ui_text("IMPORTING", 40, 40, 40, UI_FRAME)

	// During a batch run the queue owns the name and supplies the overall
	// position; a single import just shows its own filename.
	label := name
	if queue_active() {
		done, total, failed, current := queue_status()
		label = current
		ui_text(fmt.ctprintf("song %d of %d", min(done + 1, total), total), 40, 84, 18, UI_GOLD)
		if failed > 0 do ui_text(fmt.ctprintf("%d failed", failed), 300, 84, 18, UI_BAD)
		// Overall queue progress under the per-song bar.
		ui_meter(40, 300, 560, 12, total > 0 ? f32(done) / f32(total) : 0, UI_GOLD)
		ui_text("overall", 616, 296, 16, UI_DIM)
	}
	ui_text(fmt.ctprintf("%s", label), 40, 120, 22, UI_INK)

	pct, state := import_progress()
	ui_meter(40, 200, 560, 24, pct, UI_FRAME)
	rl.DrawText(fmt.ctprintf("%d%%", int(pct * 100 + 0.5)), 616, 200, 24, UI_INK)

	switch state {
	case .Idle, .Running:
		ui_text("separating stems - this can take a while", 40, 260, 18, UI_DIM)
	case .Done:
		ui_text(
			queue_active() ? "added - starting the next one" : "done - added to your library",
			40,
			260,
			20,
			UI_GOOD,
		)
	case .Error:
		ui_text(fmt.ctprintf("failed: %s", import_message()), 40, 260, 18, UI_BAD)
	}
	// ENTER already worked once a single import finished; say so.
	finished := state == .Done || state == .Error
	rl.DrawText(
		finished ? "ENTER  continue      ESC  back" : "ESC  cancel",
		40,
		448,
		16,
		{90, 90, 120, 255},
	)
}

// importing_draw_summary is the end-of-batch screen: what landed, what didn't,
// and how long it took.
@(private = "file")
importing_draw_summary :: proc() {
	added, failed, elapsed, failures := queue_summary()
	ui_text(failed > 0 ? "IMPORT FINISHED" : "IMPORT COMPLETE", 40, 40, 40, UI_FRAME)

	ui_text(
		fmt.ctprintf("%d song%s added to your library", added, added == 1 ? "" : "s"),
		40,
		120,
		26,
		UI_GOOD,
	)
	mins := int(time.duration_minutes(elapsed))
	secs := int(time.duration_seconds(elapsed)) % 60
	ui_text(fmt.ctprintf("in %dm %02ds", mins, secs), 40, 158, 18, UI_DIM)

	if failed > 0 {
		ui_text(fmt.ctprintf("%d failed", failed), 40, 200, 22, UI_BAD)
		// Name the failures — a bad file is only actionable if you know which.
		for f, i in failures {
			if i >= 4 {
				ui_text(fmt.ctprintf("and %d more", len(failures) - 4), 56, i32(232 + i * 26), 18, UI_DIM)
				break
			}
			ui_text(fmt.ctprintf("%s", f), 56, i32(232 + i * 26), 18, UI_DIM)
		}
	}
	rl.DrawText("ENTER  go to your library      ESC  back", 40, 448, 16, {90, 90, 120, 255})
}

// ---- Library (Play a Song) ----

// The library is browsed as a drill-down: Artist -> Album -> Song. `rows` holds
// the song indices backing the level currently on screen (for Artist/Album, the
// first song of each group — enough to read the group's name from). It is
// rebuilt only on a level change, never per frame.
Lib_Level :: enum {
	Artist,
	Album,
	Song,
}

Library_View :: struct {
	songs:  []Song, // all songs, sorted artist/album/disc/track; freed by library_free
	rows:   [dynamic]int, // song indices for the level on screen
	level:  Lib_Level,
	sel:    int, // selection within rows
	artist: string, // chosen at the Artist level; slices into songs[].meta
	album:  string, // chosen at the Album level
}

library_view_reload :: proc(lv: ^Library_View, root: string) {
	if lv.songs != nil do library_free(lv.songs)
	lv.songs = library_scan(root)
	// artist/album point into the songs we just freed, so drop them with it.
	lv.artist, lv.album = "", ""
	lv.level = .Artist
	lv.sel = 0
	library_rebuild_rows(lv)
}

// library_rebuild_rows refills `rows` for the current level. Songs are sorted by
// artist then album, so each group is a contiguous run: a row starts wherever
// the group name differs from the previous song's.
library_rebuild_rows :: proc(lv: ^Library_View) {
	if lv.rows == nil do lv.rows = make([dynamic]int)
	clear(&lv.rows)
	prev := ""
	for s, i in lv.songs {
		switch lv.level {
		case .Artist:
			if len(lv.rows) == 0 || !strings.equal_fold(song_artist(s), prev) {
				append(&lv.rows, i)
				prev = song_artist(s)
			}
		case .Album:
			if !strings.equal_fold(song_artist(s), lv.artist) do continue
			if len(lv.rows) == 0 || !strings.equal_fold(song_album(s), prev) {
				append(&lv.rows, i)
				prev = song_album(s)
			}
		case .Song:
			if !strings.equal_fold(song_artist(s), lv.artist) do continue
			if !strings.equal_fold(song_album(s), lv.album) do continue
			append(&lv.rows, i)
		}
	}
	lv.sel = clamp(lv.sel, 0, max(0, len(lv.rows) - 1))
}

// library_view_enter descends one level, returning the chosen Song once the
// selection is an actual song (Song level) — the caller then loads it.
library_view_enter :: proc(lv: ^Library_View) -> (song: Song, chosen: bool) {
	if len(lv.rows) == 0 do return {}, false
	s := lv.songs[lv.rows[lv.sel]]
	switch lv.level {
	case .Artist:
		lv.artist = song_artist(s)
		lv.level = .Album
	case .Album:
		lv.album = song_album(s)
		lv.level = .Song
	case .Song:
		return s, true
	}
	lv.sel = 0
	library_rebuild_rows(lv)
	return {}, false
}

// library_view_back ascends one level, reporting false at the top so the caller
// knows ESC should leave the screen for the main menu instead.
library_view_back :: proc(lv: ^Library_View) -> bool {
	switch lv.level {
	case .Artist:
		return false
	case .Album:
		lv.level = .Artist
	case .Song:
		lv.level = .Album
	}
	lv.sel = 0
	library_rebuild_rows(lv)
	return true
}

library_view_close :: proc(lv: ^Library_View) {
	if lv.songs != nil do library_free(lv.songs)
	lv.songs = nil
	if lv.rows != nil do delete(lv.rows)
	lv.rows = nil
}

library_view_move :: proc(lv: ^Library_View, delta: int) {
	lv.sel = menu.move(lv.sel, len(lv.rows), delta)
}

library_view_draw :: proc(lv: ^Library_View) {
	ui_text("PLAY A SONG", 40, 40, 40, UI_FRAME)
	if len(lv.songs) == 0 {
		ui_text("no songs yet - import one first", 40, 150, 22, UI_DIM)
		rl.DrawText("ESC  back", 40, 448, 16, {90, 90, 120, 255})
		return
	}

	// Breadcrumb: where we are in Artist -> Album -> Song.
	switch lv.level {
	case .Artist:
		ui_text("artists", 40, 96, 20, UI_DIM)
	case .Album:
		ui_text(fmt.ctprintf("%s", lv.artist), 40, 96, 20, UI_DIM)
	case .Song:
		ui_text(fmt.ctprintf("%s  >  %s", lv.artist, lv.album), 40, 96, 20, UI_DIM)
	}

	first := viewport_first(lv.sel, len(lv.rows))
	for row in 0 ..< min(VISIBLE_ROWS, len(lv.rows) - first) {
		i := first + row
		y := i32(140 + row * 40)
		sel := i == lv.sel
		if sel do ui_panel(36, y - 6, 720, 36, UI_FRAME)
		colour := sel ? UI_INK : UI_DIM
		song := lv.songs[lv.rows[i]]

		switch lv.level {
		case .Artist:
			n := count_in_group(lv, song, .Artist)
			ui_text(fmt.ctprintf("%s", song_artist(song)), 56, y, 22, colour)
			ui_text(fmt.ctprintf("%d", n), 700, y + 2, 18, UI_DIM)
		case .Album:
			n := count_in_group(lv, song, .Album)
			ui_text(fmt.ctprintf("%s", song_album(song)), 56, y, 22, colour)
			// Year (when tagged) then track count, right-aligned-ish.
			if song.meta.year > 0 {
				ui_text(fmt.ctprintf("%d", song.meta.year), 620, y + 2, 18, UI_DIM)
			}
			ui_text(fmt.ctprintf("%d", n), 700, y + 2, 18, UI_DIM)
		case .Song:
			// Track number when tagged, so album order is visible at a glance.
			if song.meta.track > 0 {
				ui_text(fmt.ctprintf("%2d", song.meta.track), 56, y, 22, UI_DIM)
			}
			ui_text(fmt.ctprintf("%s", song_title(song)), 100, y, 22, colour)
		}
	}

	hint := lv.level == .Song \
	? "UP/DOWN move   ENTER play   ESC albums" \
	: (lv.level == .Album ? "UP/DOWN move   ENTER open   ESC artists" : "UP/DOWN move   ENTER open   ESC menu")
	rl.DrawText(strings.clone_to_cstring(hint, context.temp_allocator), 40, 448, 16, {90, 90, 120, 255})
}

// count_in_group counts the songs sharing `song`'s artist (Artist level) or its
// artist+album (Album level) — the "8 tracks" style figure on each row.
@(private = "file")
count_in_group :: proc(lv: ^Library_View, song: Song, level: Lib_Level) -> int {
	n := 0
	for s in lv.songs {
		if !strings.equal_fold(song_artist(s), song_artist(song)) do continue
		if level == .Album && !strings.equal_fold(song_album(s), song_album(song)) do continue
		n += 1
	}
	return n
}

// ---- helpers ----

// viewport_first returns the first visible row so the selection stays on screen.
@(private = "file")
viewport_first :: proc(sel, n: int) -> int {
	if n <= VISIBLE_ROWS do return 0
	first := sel - VISIBLE_ROWS / 2
	return clamp(first, 0, n - VISIBLE_ROWS)
}

// join_path writes "a/b" into buf (inserting a single '/') and returns the slice.
@(private = "file")
join_path :: proc(buf: []u8, a, b: string) -> string {
	n := copy(buf, a)
	if n > 0 && buf[n - 1] != '/' && n < len(buf) {
		buf[n] = '/'
		n += 1
	}
	n += copy(buf[n:], b)
	return string(buf[:n])
}

// parent_dir writes the parent of `dir` into buf (root "/" stays root).
@(private = "file")
parent_dir :: proc(buf: []u8, dir: string) -> string {
	end := len(dir)
	for end > 1 && dir[end - 1] == '/' do end -= 1 // drop trailing slashes
	slash := -1
	for i := end - 1; i >= 0; i -= 1 {
		if dir[i] == '/' {
			slash = i
			break
		}
	}
	if slash <= 0 { // parent is root (or no slash at all)
		n := copy(buf, "/")
		return string(buf[:n])
	}
	n := copy(buf, dir[:slash])
	return string(buf[:n])
}

// ---- loading screen (decoding a song's stems) ----

// loading_draw is what stands between picking a song and hearing it. Stem
// decoding used to run on the main thread, so this moment was a ~2 s frozen
// frame of the library list; it is now a worker per stem (stemload.odin) and
// this screen, which is drawn from the first frame after ENTER.
// `waiting` means the previous (cancelled) load has not finished draining yet,
// so this one has not started — say so rather than showing a stalled 0 / 6.
loading_draw :: proc(title, artist: string, waiting := false) {
	ui_text("LOADING", 40, 40, 40, UI_FRAME)
	ui_text(fmt.ctprintf("%s", title), 40, 120, 26, UI_INK)
	if len(artist) > 0 do ui_text(fmt.ctprintf("%s", artist), 40, 156, 18, UI_DIM)

	done, total := stems_load_progress()
	if waiting do done = 0
	ui_meter(40, 220, 560, 24, total > 0 ? f32(done) / f32(total) : 0, UI_FRAME)
	rl.DrawText(fmt.ctprintf("%d / %d stems", done, total), 616, 220, 20, UI_INK)

	// Read-only: only the frame loop's stems_load_poll may advance the loader.
	failed := !waiting && stems_load_state() == .Failed
	switch {
	case waiting:
		ui_text("finishing the previous song", 40, 280, 18, UI_DIM)
	case failed:
		ui_text("could not read this song's stems", 40, 280, 18, UI_BAD)
	case:
		ui_text("decoding stems", 40, 280, 18, UI_DIM)
	}
	rl.DrawText(failed ? "ESC  back" : "ESC  cancel", 40, 448, 16, {90, 90, 120, 255})
}
