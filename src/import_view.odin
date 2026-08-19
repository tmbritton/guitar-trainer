package main

// UI + small stateful widgets for the song-import flow: a keyboard file browser
// (Import screen), a progress view (Importing screen), and the song list (Play a
// Song / Library screen). Pure view + navigation state; the heavy lifting is in
// import.odin (worker) and library.odin (filesystem scan).

import "core:fmt"
import rl "vendor:raylib"

import "menu"

VISIBLE_ROWS :: 8 // list rows on screen at once (viewport scrolls with selection)

// ---- file browser (Import screen) ----

Browser :: struct {
	dir:      string, // current directory (view into dir_buf)
	dir_buf:  [512]u8,
	path_buf: [512]u8, // scratch for the selected entry's full path
	entries:  []Browse_Entry, // owned; freed by browse_free
	sel:      int,
}

// browser_open points the browser at `dir` and (re)loads its listing.
browser_open :: proc(b: ^Browser, dir: string) {
	if b.entries != nil do browse_free(b.entries)
	n := copy(b.dir_buf[:], dir)
	b.dir = string(b.dir_buf[:n])
	b.entries = browse_dir(b.dir)
	b.sel = 0
}

browser_close :: proc(b: ^Browser) {
	if b.entries != nil do browse_free(b.entries)
	b.entries = nil
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
			label := e.is_dir ? fmt.ctprintf("%s/", e.name) : fmt.ctprintf("%s", e.name)
			ui_text(label, 56, y, 22, e.is_dir ? (i == b.sel ? UI_GOLD : UI_FRAME_DK) : col)
		}
	}
	rl.DrawText("UP/DOWN move   ENTER open/import   BACKSPACE up a folder   ESC menu", 40, 448, 16, {90, 90, 120, 255})
}

// ---- Importing screen (progress) ----

importing_draw :: proc(name: string) {
	ui_text("IMPORTING", 40, 40, 40, UI_FRAME)
	ui_text(fmt.ctprintf("%s", name), 40, 120, 22, UI_INK)

	pct, state := import_progress()
	ui_meter(40, 200, 560, 24, pct, UI_FRAME)
	rl.DrawText(fmt.ctprintf("%d%%", int(pct * 100 + 0.5)), 616, 200, 24, UI_INK)

	switch state {
	case .Idle, .Running:
		ui_text("separating stems — this can take a while", 40, 260, 18, UI_DIM)
	case .Done:
		ui_text("done — added to your library", 40, 260, 20, UI_GOOD)
	case .Error:
		ui_text(fmt.ctprintf("failed: %s", import_message()), 40, 260, 18, UI_BAD)
	}
	rl.DrawText("ESC  back", 40, 448, 16, {90, 90, 120, 255})
}

// ---- Library (Play a Song) ----

Library_View :: struct {
	songs: []Song, // owned; freed by library_free
	sel:   int,
}

library_view_reload :: proc(lv: ^Library_View, root: string) {
	if lv.songs != nil do library_free(lv.songs)
	lv.songs = library_scan(root)
	lv.sel = 0
}

library_view_close :: proc(lv: ^Library_View) {
	if lv.songs != nil do library_free(lv.songs)
	lv.songs = nil
}

library_view_move :: proc(lv: ^Library_View, delta: int) {
	lv.sel = menu.move(lv.sel, len(lv.songs), delta)
}

library_view_draw :: proc(lv: ^Library_View) {
	ui_text("PLAY A SONG", 40, 40, 40, UI_FRAME)
	if len(lv.songs) == 0 {
		ui_text("no songs yet — import one first", 40, 150, 22, UI_DIM)
		rl.DrawText("ESC  back", 40, 448, 16, {90, 90, 120, 255})
		return
	}
	first := viewport_first(lv.sel, len(lv.songs))
	for row in 0 ..< min(VISIBLE_ROWS, len(lv.songs) - first) {
		i := first + row
		y := i32(140 + row * 40)
		if i == lv.sel do ui_panel(36, y - 6, 720, 36, UI_FRAME)
		ui_text(fmt.ctprintf("%s", lv.songs[i].name), 56, y, 22, i == lv.sel ? UI_INK : UI_DIM)
	}
	rl.DrawText("UP/DOWN move   (player coming soon)   ESC menu", 40, 448, 16, {90, 90, 120, 255})
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
