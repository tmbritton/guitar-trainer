package main

// Batch import: turn a set of marked browser entries (albums, artist folders,
// individual files) into a queue of source files and feed them through the
// single-file importer in import.odin one at a time.
//
// Demucs holds a model on the GPU and is the slow part of an import (roughly
// realtime/5 on a GPU, far slower on CPU), so the queue is strictly sequential —
// running separations concurrently would contend for the same device and finish
// no sooner. The UI polls queue_poll() each frame; nothing here blocks.

import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import "songlib"

// Cap on how deep a marked folder is walked. An artist folder is
// artist/album/disc, so 6 is generous; it exists only to stop a symlink cycle
// on a network share from walking forever.
QUEUE_MAX_DEPTH :: 6

Import_Queue :: struct {
	files:   [dynamic]string, // absolute source paths still to import (owned)
	names:   [dynamic]string, // display names, parallel to files (owned)
	total:   int, // files at start, for "3 / 12"
	done:    int, // finished (or skipped) so far
	failed:  int,
	active:  bool, // a queue run is in progress
	// Latched when a run completes. Completion CANNOT be inferred from the
	// per-song state: queue_poll calls import_reset() as it retires the last
	// song, so import_progress() reports Idle on that very frame and never
	// reports Done again — which left the Importing screen stuck reading
	// "separating stems" forever, with ENTER dead.
	finished: bool,
	// current names the song being imported. It is a copy, not a view into
	// `names`: the entry is removed from that array (and freed) as the import
	// starts, so a view would dangle while importing_draw renders it each frame.
	current:     string,
	current_buf: [512]u8,
	failures:    [dynamic]string, // display names that failed (owned)
	started:     time.Time,
	elapsed:     time.Duration,
	out_buf:     [512]u8,
	stub:        bool, // run the separator in --stub mode (self-tests only)
}

g_queue: Import_Queue

// queue_expand turns marked paths into the list of audio files to import.
// Directories are walked recursively; files already present in the library are
// skipped, so re-marking an album you partly imported only does the remainder.
// Returns the number of files queued.
queue_expand :: proc(marks: []string) -> int {
	queue_reset()
	g_queue.files = make([dynamic]string)
	g_queue.names = make([dynamic]string)
	g_queue.failures = make([dynamic]string)
	for m in marks {
		if is_dir(m) {
			collect_audio(m, 0)
		} else if songlib.is_supported_audio(m) {
			queue_add(m)
		}
	}
	// Stable, predictable order: album folders import in path order, which for
	// a well-named library means track order.
	if len(g_queue.files) > 1 {
		idx := make([]int, len(g_queue.files), context.temp_allocator)
		for i in 0 ..< len(idx) do idx[i] = i
		slice.sort_by(idx, proc(a, b: int) -> bool {
			return g_queue.files[a] < g_queue.files[b]
		})
		files := make([dynamic]string)
		names := make([dynamic]string)
		for i in idx {
			append(&files, g_queue.files[i])
			append(&names, g_queue.names[i])
		}
		delete(g_queue.files)
		delete(g_queue.names)
		g_queue.files = files
		g_queue.names = names
	}
	g_queue.total = len(g_queue.files)
	return g_queue.total
}

// queue_start begins importing the expanded queue. Returns false when there is
// nothing to do (everything marked was already in the library).
queue_start :: proc(stub := false) -> bool {
	if len(g_queue.files) == 0 do return false
	g_queue.stub = stub
	g_queue.active = true
	g_queue.finished = false
	g_queue.done = 0
	g_queue.failed = 0
	g_queue.started = time.now()
	queue_begin_next()
	return true
}

// queue_poll advances the queue: when the running import finishes, start the
// next one. Called once per frame from the Importing screen. Returns true while
// the queue still has work.
queue_poll :: proc() -> bool {
	if !g_queue.active do return false
	_, st := import_progress()
	switch st {
	case .Idle, .Running:
		return true
	case .Done, .Error:
		if st == .Error {
			g_queue.failed += 1
			append(&g_queue.failures, strings.clone(g_queue.current))
		}
		g_queue.done += 1
		import_reset()
		if len(g_queue.files) == 0 {
			g_queue.active = false
			g_queue.finished = true // latched; survives active going false
			g_queue.elapsed = time.since(g_queue.started)
			return false
		}
		queue_begin_next()
		return true
	}
	return true
}

// queue_begin_next pops the head of the queue and starts its import.
@(private = "file")
queue_begin_next :: proc() {
	src := g_queue.files[0]
	name := g_queue.names[0]
	// Copy the display name before the array entry is freed (see `current`).
	g_queue.current = string(g_queue.current_buf[:copy(g_queue.current_buf[:], name)])
	out := song_out_dir(g_queue.out_buf[:], src)
	import_start(src, out, g_queue.stub)
	delete(src)
	delete(name)
	ordered_remove(&g_queue.files, 0)
	ordered_remove(&g_queue.names, 0)
}

queue_cancel :: proc() {
	import_cancel()
	import_reset()
	queue_reset()
}

queue_reset :: proc() {
	for f in g_queue.files do delete(f)
	for n in g_queue.names do delete(n)
	for f in g_queue.failures do delete(f)
	if g_queue.files != nil do delete(g_queue.files)
	if g_queue.names != nil do delete(g_queue.names)
	if g_queue.failures != nil do delete(g_queue.failures)
	g_queue = {}
}

// queue_active reports whether a batch run is in progress.
queue_active :: proc() -> bool {return g_queue.active}

// queue_finished reports a completed batch run, and stays true until the queue
// is reset — this is what the Importing screen keys its "done" state off.
queue_finished :: proc() -> bool {return g_queue.finished}

// queue_is_batch reports that a batch run is in progress or has just finished,
// so the Importing screen knows whether to use the queue's completion state or
// the single-import one.
queue_is_batch :: proc() -> bool {return g_queue.active || g_queue.finished}

// queue_summary reports a finished run for display.
queue_summary :: proc() -> (added, failed: int, elapsed: time.Duration, failures: []string) {
	return g_queue.done - g_queue.failed, g_queue.failed, g_queue.elapsed, g_queue.failures[:]
}

// queue_status is what the Importing screen renders.
queue_status :: proc() -> (done, total, failed: int, current: string) {
	return g_queue.done, g_queue.total, g_queue.failed, g_queue.current
}

// ---- helpers ----

@(private = "file")
queue_add :: proc(path: string) {
	// Already separated? Skip — re-importing costs minutes of GPU for nothing.
	if already_imported(path) do return
	// Overlapping marks (say `Artist/` and `Artist/Album A/`) walk the same
	// files twice; without this the song is separated twice and the second run
	// overwrites the first.
	for f in g_queue.files do if f == path do return
	append(&g_queue.files, strings.clone(path))
	append(&g_queue.names, strings.clone(base_name(path)))
}

// already_imported reports whether `src` is present in the library, checking
// both the current collision-safe folder name and the legacy filename-only one.
// The legacy hit only counts when that folder's meta.txt names this same source
// file — otherwise a *different* song that merely shares a filename would be
// wrongly treated as already imported.
already_imported :: proc(src: string) -> bool {
	buf: [512]u8
	if is_finished_song_dir(song_out_dir(buf[:], src)) do return true
	legacy_buf: [512]u8
	legacy := song_out_dir_legacy(legacy_buf[:], src)
	if !is_finished_song_dir(legacy) do return false
	return meta_source(legacy) == src
}

// meta_source reads just the `source` line of a song folder's meta.txt.
// Returns "" when the file is missing (a pre-metadata import) or has no source.
@(private = "file")
meta_source :: proc(dir: string) -> string {
	path := strings.concatenate({dir, "/meta.txt"}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return ""
	return songlib.parse_meta(string(data)).source
}

// collect_audio walks `dir` for supported audio files, depth-limited.
@(private = "file")
collect_audio :: proc(dir: string, depth: int) {
	if depth > QUEUE_MAX_DEPTH do return
	entries, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return
	// Copy the names we need before recursing: the temp allocator backing
	// `entries` is reused by the nested call.
	names := make([dynamic]string, context.temp_allocator)
	dirs := make([dynamic]string, context.temp_allocator)
	for e in entries {
		if len(e.name) > 0 && e.name[0] == '.' do continue
		full := strings.concatenate({dir, "/", e.name}, context.temp_allocator)
		if e.type == .Directory {
			append(&dirs, strings.clone(full))
		} else if songlib.is_supported_audio(e.name) {
			append(&names, strings.clone(full))
		}
	}
	for n in names {
		queue_add(n)
		delete(n)
	}
	for d in dirs {
		collect_audio(d, depth + 1)
		delete(d)
	}
}

@(private = "file")
is_dir :: proc(path: string) -> bool {
	st, err := os.stat(path, context.temp_allocator)
	return err == nil && st.type == .Directory
}
