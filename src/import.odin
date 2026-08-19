package main

// Song-import worker. Spawns the external separator (assets/separate.py, Demucs
// htdemucs_6s) as a subprocess with its stdout wired to a pipe, then reads that
// pipe line-by-line on a worker thread, parsing PROGRESS/DONE/ERROR (songlib) so
// the UI can show a live progress bar. Modeled on render.odin's atomic handoff:
// the worker publishes results into atomics/buffers that the main thread polls.
// Nothing here touches the audio callback.

import "base:intrinsics"
import "core:os"
import "core:thread"

import "songlib"

Import_State :: enum u32 {
	Idle,
	Running,
	Done,
	Error,
}

@(private = "file") g_import_thread: ^thread.Thread
@(private = "file") g_import_state: u32 // atomic Import_State
@(private = "file") g_import_pct: u32 // atomic 0..100
@(private = "file") g_import_child: os.Process // the running separator (valid while below == 1)
@(private = "file") g_import_child_valid: u32 // atomic: g_import_child is a live process
@(private = "file") g_import_msg: [256]u8 // DONE path / ERROR text; published before state
@(private = "file") g_import_msg_len: int

// Inputs captured for the worker (copied so the caller's slices needn't outlive
// the call). One import runs at a time.
@(private = "file") g_import_input_buf: [512]u8
@(private = "file") g_import_out_buf: [512]u8
@(private = "file") g_import_input: string
@(private = "file") g_import_out: string
@(private = "file") g_import_stub: bool

// import_start spawns the separator for `input_path` into `out_dir` and returns
// immediately; poll import_progress() for the result. `stub` runs the separator's
// hermetic stub mode (no Demucs) — used by --importcheck.
import_start :: proc(input_path, out_dir: string, stub := false) {
	ni := copy(g_import_input_buf[:], input_path)
	g_import_input = string(g_import_input_buf[:ni])
	no := copy(g_import_out_buf[:], out_dir)
	g_import_out = string(g_import_out_buf[:no])
	g_import_stub = stub
	g_import_msg_len = 0
	intrinsics.atomic_store(&g_import_pct, 0)
	intrinsics.atomic_store(&g_import_state, u32(Import_State.Running))
	g_import_thread = thread.create_and_start(import_worker)
}

// import_progress returns the fraction done [0,1] and the current state.
import_progress :: proc() -> (pct: f32, state: Import_State) {
	p := intrinsics.atomic_load(&g_import_pct)
	s := Import_State(intrinsics.atomic_load(&g_import_state))
	return f32(p) / 100.0, s
}

// import_message returns the DONE path or ERROR text. Meaningful only once the
// state is terminal (Done/Error); the buffer is published before that store.
import_message :: proc() -> string {
	return string(g_import_msg[:g_import_msg_len])
}

// import_cancel kills the running separator (if any) so a still-running import
// stops promptly instead of blocking import_reset's join for the whole (minutes-
// long) Demucs run. A no-op once the child has finished.
import_cancel :: proc() {
	if intrinsics.atomic_load(&g_import_child_valid) == 1 {
		_ = os.process_kill(g_import_child) // child dies -> stdout EOF -> worker exits
	}
}

// import_reset joins the finished worker and returns to Idle. Pair with
// import_cancel when leaving mid-import so the join returns promptly.
import_reset :: proc() {
	if g_import_thread != nil {
		thread.join(g_import_thread)
		thread.destroy(g_import_thread)
		g_import_thread = nil
	}
	intrinsics.atomic_store(&g_import_state, u32(Import_State.Idle))
	intrinsics.atomic_store(&g_import_pct, 0)
	g_import_msg_len = 0
}

@(private = "file")
set_msg :: proc(s: string) {
	g_import_msg_len = copy(g_import_msg[:], s)
}

@(private = "file")
finish :: proc(state: Import_State, msg: string) {
	set_msg(msg) // publish text before the state store (seq_cst) so the reader sees it
	intrinsics.atomic_store(&g_import_state, u32(state))
}

@(private = "file")
handle_line :: proc(line: string) {
	m := songlib.parse_line(line)
	switch m.kind {
	case .Progress:
		intrinsics.atomic_store(&g_import_pct, u32(m.pct))
	case .Done:
		intrinsics.atomic_store(&g_import_pct, 100)
		finish(.Done, m.text)
	case .Error:
		finish(.Error, m.text)
	case .Unknown:
	// non-protocol chatter (e.g. model-loading logs) — ignore
	}
}

@(private = "file")
import_worker :: proc() {
	r, w, perr := os.pipe()
	if perr != nil {
		finish(.Error, "could not create pipe")
		return
	}

	argv: [5]string = {"python3", "assets/separate.py", g_import_input, g_import_out, "--stub"}
	n := g_import_stub ? 5 : 4
	child, serr := os.process_start({command = argv[:n], stdout = w})
	os.close(w) // parent drops its write end so read() sees EOF when the child exits
	if serr != nil {
		os.close(r)
		finish(.Error, "could not start separate.py (is python3 on PATH?)")
		return
	}
	g_import_child = child // published before the valid flag so import_cancel sees it
	intrinsics.atomic_store(&g_import_child_valid, 1)

	// Read the child's stdout, assembling lines. read() blocks until data or EOF.
	acc: [1024]u8
	acc_len := 0
	buf: [512]u8
	for {
		nread, rerr := os.read(r, buf[:])
		// core:os read() does not retry on EINTR — a signal interrupting the
		// blocking read surfaces as (0, EINTR). Retrying (not breaking) is
		// essential: a real Demucs run takes minutes, and breaking here would
		// close the read end mid-run, SIGPIPE the child, and false-report failure.
		if rerr == os.Platform_Error.EINTR do continue
		if nread <= 0 || rerr != nil do break // real EOF or error: child finished
		for i in 0 ..< nread {
			c := buf[i]
			if c == '\n' {
				handle_line(string(acc[:acc_len]))
				acc_len = 0
			} else if acc_len < len(acc) {
				acc[acc_len] = c
				acc_len += 1
			}
		}
	}
	if acc_len > 0 do handle_line(string(acc[:acc_len])) // trailing unterminated line

	os.close(r)
	state, _ := os.process_wait(child)
	intrinsics.atomic_store(&g_import_child_valid, 0) // reaped: import_cancel is now a no-op

	// If the child never emitted DONE/ERROR, decide from its exit status.
	if Import_State(intrinsics.atomic_load(&g_import_state)) == .Running {
		if state.exited && state.exit_code == 0 {
			finish(.Done, g_import_out)
		} else {
			finish(.Error, "separator exited without result")
		}
	}
}
