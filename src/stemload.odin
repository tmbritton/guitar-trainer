package main

// Async stem loading. Decoding a song's six stems takes ~2.3 s for a 6-minute
// song and used to run synchronously on the main thread, so the UI could not
// redraw and selecting a song looked like a hang (Story 6.18).
//
// Two things fix that, and only the second makes it fast:
//   1. Decode off the main thread, so a loading screen can be drawn.
//   2. Decode the six stems in parallel. They are six independent files and the
//      old path used 99% of a single core on a 12-core machine.
//
// Follows the worker idiom used by render.odin / import.odin / player.odin:
// workers publish through atomics, the main thread polls, nothing locks.
//
// Ownership is deliberately one-sided: **only the main thread ever frees.**
// Workers write their own stem slot and decrement a counter, nothing else. A
// cancelled load is therefore not joined on the spot (a stem on a network share
// can take seconds, which would reintroduce the very freeze this removes) — it
// is left running and reaped by a later poll, once the workers have drained.

import "base:intrinsics"
import "base:runtime"

import "core:thread"

import "songlib"

Stem_Load_State :: enum {
	Idle,
	Loading,
	Ready, // decoded; waiting for the main thread to take it
	Failed, // not one stem decoded
	Cancelling, // abandoned; waiting for the workers to drain so it can be freed
}

@(private = "file")
Stem_Loader :: struct {
	state:     Stem_Load_State, // main thread only — never read by a worker
	dir_buf:   [512]u8,
	dir:       string, // copy: the caller's Song may be freed while we decode
	sa:        Song_Audio,
	threads:   [len(songlib.STEMS)]^thread.Thread,
	remaining: u32, // atomic, worker -> main: workers still running
	loaded:    u32, // atomic, worker -> main: stems *attempted*, for progress
}

@(private = "file")
g_loader: Stem_Loader

// stems_load_begin starts decoding the song in `dir`. Returns false if a load is
// already in flight or still draining after a cancel — the caller should treat
// that as "not yet" and try again on a later frame. Only one song decodes at a
// time on purpose: a decoded song is ~340 MB, so overlapping two would double
// peak memory.
stems_load_begin :: proc(dir: string) -> bool {
	stems_load_poll() // reap a finished cancel first, so a retry can proceed
	if g_loader.state != .Idle do return false
	// A truncated path would decode the wrong folder — or more likely none, and
	// surface as an unexplained .Failed. Refuse it instead.
	if len(dir) >= len(g_loader.dir_buf) do return false

	g_loader.sa = {}
	for i in 0 ..< len(songlib.STEMS) do g_loader.sa.ctl[i] = {level = 1}
	g_loader.dir = string(g_loader.dir_buf[:copy(g_loader.dir_buf[:], dir)])
	intrinsics.atomic_store(&g_loader.loaded, 0)
	intrinsics.atomic_store(&g_loader.remaining, u32(len(songlib.STEMS)))
	g_loader.state = .Loading
	for i in 0 ..< len(songlib.STEMS) {
		t := thread.create_and_start_with_poly_data(i, stem_worker)
		g_loader.threads[i] = t
		if t == nil {
			// The spawn failed (OOM, RLIMIT_NPROC). `remaining` was pre-set to
			// the full count, so without this its decrement never arrives and
			// the loader sits in .Loading forever — after which every future
			// stems_load_begin refuses and no song can be opened again.
			intrinsics.atomic_sub(&g_loader.remaining, 1)
		}
	}
	return true
}

// stems_load_poll advances the loader. Safe (and cheap) to call every frame from
// anywhere — it is what reaps a cancelled load, so the frame loop calls it
// unconditionally rather than only on the loading screen.
stems_load_poll :: proc() -> Stem_Load_State {
	#partial switch g_loader.state {
	case .Loading:
		if intrinsics.atomic_load(&g_loader.remaining) == 0 {
			join_workers()
			// Safe to read sa now: join_workers is a full barrier, and every
			// worker has exited.
			for s in g_loader.sa.stems do g_loader.sa.frames = max(g_loader.sa.frames, len(s))
			g_loader.state = g_loader.sa.frames > 0 ? .Ready : .Failed
		}
	case .Cancelling:
		if intrinsics.atomic_load(&g_loader.remaining) == 0 {
			join_workers()
			stems_free(&g_loader.sa)
			g_loader.state = .Idle
		}
	}
	return g_loader.state
}

// stems_load_progress reports decoded stems out of the total, for the loading
// screen's "N / 6 stems".
stems_load_progress :: proc() -> (done, total: int) {
	return int(intrinsics.atomic_load(&g_loader.loaded)), len(songlib.STEMS)
}

// stems_load_state reads the loader without advancing it — what view code
// wants. Only stems_load_poll may drive the state machine, and only the frame
// loop calls that.
stems_load_state :: proc() -> Stem_Load_State {return g_loader.state}

// stems_load_held reports how many stem samples the loader is currently holding.
// It exists for --loadcheck: proving that a cancelled load frees its partial
// decode means observing the loader's own memory, and 0 after it drains is that
// proof.
stems_load_held :: proc() -> int {
	n := 0
	for s in g_loader.sa.stems do n += len(s)
	return n
}

// stems_load_take hands the decoded song to the caller, which owns it from then
// on and frees it with stems_free — exactly as it did with the synchronous
// stems_load. Only valid once the state is .Ready.
stems_load_take :: proc() -> (Song_Audio, bool) {
	if g_loader.state != .Ready do return {}, false
	sa := g_loader.sa
	g_loader.sa = {}
	g_loader.state = .Idle
	return sa, true
}

// stems_load_cancel abandons a load. It does not block: the workers keep running
// and a later stems_load_poll frees whatever they decoded. A .Failed load is
// also cleared by this (nothing to free, but the slot must return to Idle).
stems_load_cancel :: proc() {
	#partial switch g_loader.state {
	case .Loading:
		g_loader.state = .Cancelling
		stems_load_poll() // in case they already finished
	case .Ready, .Failed:
		join_workers()
		stems_free(&g_loader.sa)
		g_loader.state = .Idle
	}
}

// stems_load_shutdown blocks until any in-flight load has drained, then frees
// it. Only for process teardown, where blocking is fine and leaving threads
// running is not.
stems_load_shutdown :: proc() {
	if g_loader.state == .Idle do return
	join_workers()
	stems_free(&g_loader.sa)
	g_loader.state = .Idle
}

// join_workers reaps the thread objects. Callers must first observe
// `remaining == 0` (or be shutting down), so these joins do not block.
@(private = "file")
join_workers :: proc() {
	for &t in g_loader.threads {
		if t == nil do continue
		thread.join(t)
		thread.destroy(t)
		t = nil
	}
}

// stem_worker decodes one stem. It touches only its own slot in sa.stems and the
// two atomics — never the loader's state, and never anything the main thread
// frees.
@(private = "file")
stem_worker :: proc(i: int) {
	// This thread has its own temp arena (the main thread's per-frame free_all
	// cannot reach it), destroyed when the thread exits — so this guard is not
	// about leaks. It bounds peak usage while the worker runs, and keeps the
	// habit uniform across the codebase.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if pcm, ok := decode_stem(g_loader.dir, i); ok {
		g_loader.sa.stems[i] = pcm
	}
	// Counts attempts, not successes: a song missing one stem would otherwise
	// stall the bar at 5 / 6 and then jump to the player.
	intrinsics.atomic_add(&g_loader.loaded, 1)
	// Last: seq_cst, so it publishes the write above to whichever thread next
	// observes remaining == 0.
	intrinsics.atomic_sub(&g_loader.remaining, 1)
}
