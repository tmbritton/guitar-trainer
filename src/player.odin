package main

// Song player: a producer thread mixes the loaded stems (per-stem level/mute/
// solo) from a shared cursor into the PCM ring that the audio callback drains.
// The UI thread only issues commands (play/pause, seek, mixer) through atomics;
// it never touches the stem PCM or the ring. This keeps the ring strictly SPSC
// (producer -> callback) and the callback allocation/lock-free.
//
// Threads: UI --atomics--> producer --PCM ring--> callback; producer --atomic
// cursor--> UI (position readout). No locks.

import "base:intrinsics"
import "core:thread"
import "core:time"

import "clock"
import "mix"
import "soundtouch"

PLAYER_BLOCK :: 512 // samples mixed per producer iteration
SPEED_MIN :: 0.5 // slowest (SoundTouch quality falls off past this)
SPEED_MAX :: 1.25 // fastest

@(private = "file") g_player_song: Song_Audio // set by player_open; read by producer
@(private = "file") g_player_thread: ^thread.Thread
@(private = "file") g_player_stop: u32 // atomic: tell the producer to exit
@(private = "file") g_player_playing: u32 // atomic 0/1: UI play/pause command
@(private = "file") g_player_cursor: u64 // atomic: current frame (producer publishes)
@(private = "file") g_player_seek: i64 // atomic: seek target frame, -1 = none
@(private = "file") g_player_level: [6]u32 // atomic f32 bits
@(private = "file") g_player_mute: [6]u32 // atomic 0/1
@(private = "file") g_player_solo: [6]u32 // atomic 0/1
@(private = "file") g_player_speed: u32 // atomic f32 bits: playback speed (1.0 = normal)
@(private = "file") g_stretch: rawptr // SoundTouch handle; producer-owned once open
@(private = "file") g_loop_a: i64 = -1 // atomic: A-B loop start frame (-1 = unset)
@(private = "file") g_loop_b: i64 = -1 // atomic: A-B loop end frame (-1 = unset)
@(private = "file") g_loop_on: u32 // atomic 0/1: loop active

// player_open takes ownership of playback for `sa` (the caller still owns the
// PCM and frees it with stems_free after player_close). Autostarts playing.
player_open :: proc(sa: Song_Audio) {
	g_player_song = sa
	for i in 0 ..< 6 {
		intrinsics.atomic_store(&g_player_level[i], transmute(u32)sa.ctl[i].level)
		intrinsics.atomic_store(&g_player_mute[i], sa.ctl[i].mute ? 1 : 0)
		intrinsics.atomic_store(&g_player_solo[i], sa.ctl[i].solo ? 1 : 0)
	}
	intrinsics.atomic_store(&g_player_cursor, 0)
	intrinsics.atomic_store(&g_player_seek, -1)
	player_loop_clear() // loop points are transient — start fresh per song
	intrinsics.atomic_store(&g_player_speed, transmute(u32)f32(1))
	intrinsics.atomic_store(&g_player_playing, 1)
	intrinsics.atomic_store(&g_player_stop, 0)
	g_stretch = soundtouch.st_create(u32(clock.SAMPLE_RATE), 1)
	audio_pcm_reset() // safe: no producer yet, callback not draining
	audio_player_activate(true)
	g_player_thread = thread.create_and_start(player_loop)
}

player_close :: proc() {
	intrinsics.atomic_store(&g_player_stop, 1)
	if g_player_thread != nil {
		thread.join(g_player_thread)
		thread.destroy(g_player_thread)
		g_player_thread = nil
	}
	audio_player_activate(false)
	if g_stretch != nil { // safe: producer (its only user) is joined
		soundtouch.st_destroy(g_stretch)
		g_stretch = nil
	}
}

// ---- UI commands (main thread) ----

player_toggle :: proc() {
	intrinsics.atomic_store(&g_player_playing, intrinsics.atomic_load(&g_player_playing) == 0 ? 1 : 0)
}

player_playing :: proc() -> bool {
	return intrinsics.atomic_load(&g_player_playing) != 0
}

player_cursor :: proc() -> int {
	return int(intrinsics.atomic_load(&g_player_cursor))
}

player_frames :: proc() -> int {
	return g_player_song.frames // read-only after open
}

player_seek :: proc(frame: int) {
	intrinsics.atomic_store(&g_player_seek, i64(clamp(frame, 0, g_player_song.frames)))
}

player_set_level :: proc(i: int, level: f32) {
	intrinsics.atomic_store(&g_player_level[i], transmute(u32)clamp(level, 0, 1))
}

player_toggle_mute :: proc(i: int) {
	intrinsics.atomic_store(&g_player_mute[i], intrinsics.atomic_load(&g_player_mute[i]) == 0 ? 1 : 0)
}

player_toggle_solo :: proc(i: int) {
	intrinsics.atomic_store(&g_player_solo[i], intrinsics.atomic_load(&g_player_solo[i]) == 0 ? 1 : 0)
}

player_set_speed :: proc(x: f32) {
	s := clamp(x, SPEED_MIN, SPEED_MAX)
	if abs(s - 1) < 0.001 do s = 1 // snap to exact 1.0 so returning here re-enters true bypass
	intrinsics.atomic_store(&g_player_speed, transmute(u32)s)
}

player_speed :: proc() -> f32 {
	return transmute(f32)intrinsics.atomic_load(&g_player_speed)
}

// player_loop_mark cycles the A-B loop with one key: unset -> set A (at cursor)
// -> set B (at cursor; ordered so A<B) + enable -> clear.
player_loop_mark :: proc() {
	a := intrinsics.atomic_load(&g_loop_a)
	b := intrinsics.atomic_load(&g_loop_b)
	cur := i64(player_cursor())
	switch {
	case a < 0:
		intrinsics.atomic_store(&g_loop_a, cur)
	case b < 0:
		lo, hi := min(a, cur), max(a, cur)
		if hi <= lo do hi = lo + 1 // degenerate: keep a non-empty span
		intrinsics.atomic_store(&g_loop_a, lo)
		intrinsics.atomic_store(&g_loop_b, hi)
		intrinsics.atomic_store(&g_loop_on, 1) // enable last: A and B are published
	case:
		player_loop_clear()
	}
}

player_loop_clear :: proc() {
	intrinsics.atomic_store(&g_loop_on, 0)
	intrinsics.atomic_store(&g_loop_a, -1)
	intrinsics.atomic_store(&g_loop_b, -1)
}

player_loop_on :: proc() -> bool {return intrinsics.atomic_load(&g_loop_on) != 0}
player_loop_a :: proc() -> int {return int(intrinsics.atomic_load(&g_loop_a))}
player_loop_b :: proc() -> int {return int(intrinsics.atomic_load(&g_loop_b))}

// player_ctl reads back a stem's current mixer state (for the UI and for saving).
player_ctl :: proc(i: int) -> mix.Stem_Ctl {
	return mix.Stem_Ctl {
		level = transmute(f32)intrinsics.atomic_load(&g_player_level[i]),
		mute = intrinsics.atomic_load(&g_player_mute[i]) != 0,
		solo = intrinsics.atomic_load(&g_player_solo[i]) != 0,
	}
}

player_snapshot_ctl :: proc() -> (out: [6]mix.Stem_Ctl) {
	for i in 0 ..< 6 do out[i] = player_ctl(i)
	return
}

// ---- producer thread ----

@(private = "file")
player_loop :: proc() {
	block: [PLAYER_BLOCK]f32
	out: [PLAYER_BLOCK * 4]f32 // stretched-output scratch (slowdown expands the block)
	cur_tempo: f64 = 1.0 // tempo currently applied to the stretcher

	for intrinsics.atomic_load(&g_player_stop) == 0 {
		if s := intrinsics.atomic_load(&g_player_seek); s >= 0 {
			intrinsics.atomic_store(&g_player_cursor, u64(s))
			intrinsics.atomic_store(&g_player_seek, -1)
			soundtouch.st_clear(g_stretch) // drop buffered audio from the old position
		}
		if intrinsics.atomic_load(&g_player_playing) == 0 {
			time.sleep(5 * time.Millisecond)
			continue
		}

		// apply a speed change: reset the stretcher so no stale audio bleeds
		// across the ratio change (and when entering/leaving bypass).
		speed := f64(player_speed())
		if speed != cur_tempo {
			soundtouch.st_clear(g_stretch)
			soundtouch.st_set_tempo(g_stretch, speed)
			cur_tempo = speed
		}
		bypass := cur_tempo == 1.0

		if !bypass do drain_stretch(out[:]) // push any pending stretched output first

		if audio_pcm_space() < PLAYER_BLOCK { // ring full enough — let it drain
			time.sleep(2 * time.Millisecond)
			continue
		}
		// keep the stretcher's own backlog bounded so the cursor doesn't race ahead
		if !bypass && int(soundtouch.st_available(g_stretch)) > PLAYER_BLOCK {
			time.sleep(2 * time.Millisecond)
			continue
		}

		cursor := int(intrinsics.atomic_load(&g_player_cursor))

		// A-B loop: wrap back to A when the cursor reaches B (like a seek).
		loop_on := intrinsics.atomic_load(&g_loop_on) != 0
		loop_a := int(intrinsics.atomic_load(&g_loop_a))
		loop_b := min(int(intrinsics.atomic_load(&g_loop_b)), g_player_song.frames)
		looping := loop_on && loop_b > loop_a && loop_a >= 0
		if looping && cursor >= loop_b {
			cursor = loop_a
			intrinsics.atomic_store(&g_player_cursor, u64(cursor))
			soundtouch.st_clear(g_stretch) // drop buffered audio from the old position
		}

		if cursor >= g_player_song.frames { // reached the end
			if !bypass { // flush the stretcher tail before pausing
				soundtouch.st_flush(g_stretch)
				drain_stretch(out[:])
			}
			intrinsics.atomic_store(&g_player_playing, 0)
			continue
		}

		// snapshot the mixer controls for this block
		ctls: [6]mix.Stem_Ctl
		for i in 0 ..< 6 {
			ctls[i] = mix.Stem_Ctl {
				level = transmute(f32)intrinsics.atomic_load(&g_player_level[i]),
				mute  = intrinsics.atomic_load(&g_player_mute[i]) != 0,
				solo  = intrinsics.atomic_load(&g_player_solo[i]) != 0,
			}
		}
		any_solo := mix.any_solo(ctls[:])

		n := min(PLAYER_BLOCK, g_player_song.frames - cursor)
		if looping && cursor < loop_b do n = min(n, loop_b - cursor) // don't cross B
		for j in 0 ..< n do block[j] = 0
		for i in 0 ..< 6 {
			g := mix.stem_gain(ctls[i], any_solo)
			if g == 0 do continue
			s := g_player_song.stems[i]
			for j in 0 ..< n {
				if idx := cursor + j; idx < len(s) do block[j] += s[idx] * g
			}
		}
		for j in 0 ..< n do block[j] = clamp(block[j], -1, 1) // soft clip the mix

		if bypass {
			written := audio_pcm_write(block[:n])
			intrinsics.atomic_store(&g_player_cursor, u64(cursor + written))
		} else {
			soundtouch.st_put(g_stretch, raw_data(block[:]), u32(n)) // consumes n input frames
			intrinsics.atomic_store(&g_player_cursor, u64(cursor + n))
			drain_stretch(out[:])
		}
	}
}

// drain_stretch moves available stretched output from SoundTouch into the PCM
// ring, up to the ring's free space (producer side).
@(private = "file")
drain_stretch :: proc(out: []f32) {
	for {
		avail := int(soundtouch.st_available(g_stretch))
		space := audio_pcm_space()
		if avail == 0 || space == 0 do break
		want := min(len(out), min(avail, space))
		got := int(soundtouch.st_receive(g_stretch, raw_data(out), u32(want)))
		if got == 0 do break
		audio_pcm_write(out[:got])
	}
}
