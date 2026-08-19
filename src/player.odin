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

import "mix"

PLAYER_BLOCK :: 512 // samples mixed per producer iteration

@(private = "file") g_player_song: Song_Audio // set by player_open; read by producer
@(private = "file") g_player_thread: ^thread.Thread
@(private = "file") g_player_stop: u32 // atomic: tell the producer to exit
@(private = "file") g_player_playing: u32 // atomic 0/1: UI play/pause command
@(private = "file") g_player_cursor: u64 // atomic: current frame (producer publishes)
@(private = "file") g_player_seek: i64 // atomic: seek target frame, -1 = none
@(private = "file") g_player_level: [6]u32 // atomic f32 bits
@(private = "file") g_player_mute: [6]u32 // atomic 0/1
@(private = "file") g_player_solo: [6]u32 // atomic 0/1

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
	intrinsics.atomic_store(&g_player_playing, 1)
	intrinsics.atomic_store(&g_player_stop, 0)
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
	for intrinsics.atomic_load(&g_player_stop) == 0 {
		if s := intrinsics.atomic_load(&g_player_seek); s >= 0 {
			intrinsics.atomic_store(&g_player_cursor, u64(s))
			intrinsics.atomic_store(&g_player_seek, -1)
		}
		if intrinsics.atomic_load(&g_player_playing) == 0 {
			time.sleep(5 * time.Millisecond)
			continue
		}
		if audio_pcm_space() < PLAYER_BLOCK { // ring full enough — let it drain
			time.sleep(2 * time.Millisecond)
			continue
		}
		cursor := int(intrinsics.atomic_load(&g_player_cursor))
		if cursor >= g_player_song.frames { // reached the end: pause there
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

		written := audio_pcm_write(block[:n])
		intrinsics.atomic_store(&g_player_cursor, u64(cursor + written))
	}
}
