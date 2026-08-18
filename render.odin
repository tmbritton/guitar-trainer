package main

// Background render worker. Neural-amp inference is slow (seconds per cadence),
// so rig audio is rendered off the main thread: the drill publishes a clip (a
// list of Note_Events), the worker renders it into g_job_pcm, and the main
// thread schedules the finished PCM when ready — keeping the UI responsive.
// One job at a time (the drill's clips are strictly sequential).

import "base:intrinsics"
import "core:thread"
import "core:time"

g_render_thread: ^thread.Thread
g_render_stop: u32 // atomic
g_job_events: []Note_Event // published by main before g_job_pending
g_job_pending: u32 // atomic: main -> worker
g_job_done: u32 // atomic: worker -> main
g_job_busy: u32 // atomic: a job is in flight or its result is unconsumed
g_job_pcm: [SAMPLE_BUF_LEN]f32
g_job_pcm_len: int

render_start :: proc() {
	intrinsics.atomic_store(&g_render_stop, 0)
	g_render_thread = thread.create_and_start(render_loop)
}

render_stop :: proc() {
	intrinsics.atomic_store(&g_render_stop, 1)
	if g_render_thread != nil {
		thread.join(g_render_thread)
		thread.destroy(g_render_thread)
		g_render_thread = nil
	}
}

// render_submit publishes a clip to render. `events` (and any slices it points
// to) must stay valid until render_ready(); the drill keeps them in fixed
// per-instance storage, so that holds until the next submit.
render_submit :: proc(events: []Note_Event) {
	g_job_events = events
	intrinsics.atomic_store(&g_job_done, 0)
	intrinsics.atomic_store(&g_job_busy, 1)
	intrinsics.atomic_store(&g_job_pending, 1) // release last: publishes g_job_events
}

render_ready :: proc() -> bool {
	return intrinsics.atomic_load(&g_job_done) != 0
}

// render_busy reports whether the worker holds/renders a job (used to gate tone
// switches so they don't race the worker's reads of g_sf / g_nam / g_ir).
render_busy :: proc() -> bool {
	return intrinsics.atomic_load(&g_job_busy) != 0
}

// render_take returns the finished PCM and marks the job consumed.
render_take :: proc() -> []f32 {
	n := g_job_pcm_len
	intrinsics.atomic_store(&g_job_busy, 0)
	return g_job_pcm[:n]
}

@(private = "file")
render_loop :: proc() {
	for intrinsics.atomic_load(&g_render_stop) == 0 {
		if intrinsics.atomic_load(&g_job_pending) != 0 {
			intrinsics.atomic_store(&g_job_pending, 0)
			pcm := sf_render_seq(g_job_events) // heavy: TSF -> NAM -> cab IR
			n := min(len(pcm), SAMPLE_BUF_LEN)
			copy(g_job_pcm[:n], pcm[:n])
			g_job_pcm_len = n
			intrinsics.atomic_store(&g_job_done, 1) // release: publishes g_job_pcm
		} else {
			time.sleep(time.Millisecond)
		}
	}
}
