package main

// The audio spine: a single duplex ma_device we own directly (raylib's audio
// module is never initialized). The callback is the only producer on the master
// clock and the onset ring; the main thread is the only consumer.

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:mem"
import "core:strings"
import ma "vendor:miniaudio"

import "amp"
import "ampchain"
import "clock"
import "conv"
import "detect"
import "pcmring"
import "ring"

RING_CAP :: 1024
PERIOD_FRAMES :: 128 // audio callback period; also the onset-timestamp quantization (a hop)
CLICK_LEN :: 64 // samples of full-scale burst emitted for a calibration click
CLICK_DISARMED :: max(u64)
HIST_CAP :: 16384 // rolling input history (~341 ms at 48 kHz); power of two
PITCH_WINDOW :: 2048

g_clock: clock.Clock
g_ring: ring.Ring(RING_CAP)
g_onset: detect.Onset_Detector
g_device: ma.device
g_input_rms_bits: u32 // atomic f32 bits: callback-published input level for the UI meter (display only)

g_click_at: u64 = CLICK_DISARMED // atomic: absolute sample pos to emit a click, or CLICK_DISARMED
g_loopback: bool // when true, onset detection reads the output buffer (internal loopback for calibration self-test)
g_offset_samples: i64 // measured round-trip offset, subtracted from judgments

g_history: [HIST_CAP]f32 // rolling input samples, indexed by absolute pos & (HIST_CAP-1)
g_hist_written: u64 // atomic: total samples written to history

g_tone_bits: u32 // atomic: test-tone frequency as f32 bits (0 = off)
g_tone_phase: f32 // callback-local phase accumulator for the test tone

MAX_VOICES :: 32 // a full cadence holds 12 slots (schedule-time..end); leaves ample headroom for target + overlap
KS_MAX :: 1024 // max delay-line length (supports fundamentals down to ~47 Hz)
KS_DAMP :: 0.9999 // Karplus-Strong loop gain per sample: ~1 s guitar-like sustain

// A scheduled plucked-string voice (Karplus-Strong). Main thread activates one
// (writes fields, then sets `active` with release); the callback owns the delay
// line and deactivates the voice when it ends. Single-activator /
// single-deactivator => no lock needed.
Voice :: struct {
	freq:    f32,
	start:   u64,
	end:     u64,
	amp:     f32,
	active:  u32, // atomic 0/1
	ks_init: bool, // callback: delay line seeded?
	ks_len:  int, // delay-line length = round(sample_rate/freq)
	ks_idx:  int, // read/write cursor
	ks_buf:  [KS_MAX]f32,
}

g_voices: [MAX_VOICES]Voice
g_ks_rng: u32 = 0x1234_5678 // xorshift state; audio thread only
g_amp: amp.Amp // downstream, playback-only overdrive (never touches detection)
g_amp_enabled: u32 = 1 // atomic; disabled when a (pre-distorted) soundfont is in use

// Sample-playback voices: PCM rendered on the main thread (e.g. by the
// SoundFont synth) and mixed here. Fixed buffers, no allocation in the callback.
SAMPLE_VOICES :: 6
SAMPLE_BUF_LEN :: 360000 // ~7.5 s at 48 kHz (fits a cadence, or a full riff + tail)

Sample_Voice :: struct {
	len:    int,
	start:  u64,
	pos:    int,
	gain:   f32,
	active: u32, // atomic 0/1
	buf:    [SAMPLE_BUF_LEN]f32,
}

g_svoices: [SAMPLE_VOICES]Sample_Voice

// Song-player output: the player's producer thread mixes stems into this PCM
// ring; the callback drains it to `out` when player mode is active (song
// play-along, a separate mode from the drill). SPSC: producer writes, callback
// reads. ~341 ms at 48 kHz, so the producer has ample slack against underrun.
PCM_RING_CAP :: 16384
g_pcm_ring: pcmring.Ring(PCM_RING_CAP)
g_player_active: u32 // atomic: callback drains g_pcm_ring into out when set

// audio_player_activate switches the callback between drill mixing (off) and
// draining the song-player PCM ring (on).
audio_player_activate :: proc(on: bool) {
	intrinsics.atomic_store(&g_player_active, on ? 1 : 0)
}

// audio_pcm_write enqueues mixed player samples (producer thread). Returns the
// count accepted (short if the ring is full).
audio_pcm_write :: proc(src: []f32) -> int {
	return pcmring.write(&g_pcm_ring, src)
}

// audio_pcm_space is the ring's free capacity (producer thread).
audio_pcm_space :: proc() -> int {
	return pcmring.space(&g_pcm_ring)
}

// audio_pcm_read drains up to len(dst) player samples (consumer side). In the
// running app the callback is the consumer; this is used by --playercheck, where
// no device runs, to stand in for the callback and verify the producer/mix path.
audio_pcm_read :: proc(dst: []f32) -> int {
	return pcmring.read(&g_pcm_ring, dst)
}

// audio_pcm_reset empties the ring. Only safe when neither the producer nor the
// draining callback is active (player_open calls it before activating).
audio_pcm_reset :: proc() {
	intrinsics.atomic_store(&g_pcm_ring.head, 0)
	intrinsics.atomic_store(&g_pcm_ring.tail, 0)
}

// ---- live input monitoring (realtime amp chain) ----
//
// The callback runs the dry interface input through g_monitor (an ampchain.Chain)
// and mixes it into the output, so you hear your own guitar in a good tone while
// playing along. The chain is owned by the callback; the UI issues parameter
// changes via atomics, which the callback applies (monitor_apply_config). Cab IRs
// are preloaded into fixed buffers so switching is just an atomic index (no race).
// Detection still reads the dry signal upstream — monitoring never feeds it.

MON_CABS :: 3
g_monitor: ampchain.Chain
g_mon_on: u32 // atomic 0/1
g_mon_drive: u32 // atomic f32 bits
g_mon_bass: u32 // atomic f32 bits (dB)
g_mon_treble: u32 // atomic f32 bits (dB)
g_mon_level: u32 // atomic f32 bits
g_mon_cab_idx: u32 // atomic: cab to use; >= g_mon_cab_count means "no cab"
g_output_rms_bits: u32 // atomic f32 bits: post-mix output level (for tests/UI)

// preloaded monitor cab IRs (fixed buffers; the callback reads by index).
// g_mon_cab_count is the release/acquire fence: audio_monitor_load_cabs writes
// the data+len arrays then atomic-stores the count; the callback atomic-loads the
// count before reading them. So a (re)load stays safe even if monitoring is
// enabled concurrently (e.g. a device re-init in a later story).
g_mon_cab_data: [MON_CABS][ampchain.CAB_MAX]f32
g_mon_cab_len: [MON_CABS]int
g_mon_cab_count: u32 // atomic

// callback-only "last applied" trackers (audio thread touches these, no atomics)
g_mon_bass_applied: f32 = 1e9
g_mon_treble_applied: f32 = 1e9
g_mon_cab_applied: int = -1

audio_monitor_enable :: proc(on: bool) {intrinsics.atomic_store(&g_mon_on, on ? 1 : 0)}
audio_monitor_on :: proc() -> bool {return intrinsics.atomic_load(&g_mon_on) != 0}
audio_set_monitor_drive :: proc(d: f32) {intrinsics.atomic_store(&g_mon_drive, transmute(u32)d)}
audio_set_monitor_level :: proc(l: f32) {intrinsics.atomic_store(&g_mon_level, transmute(u32)l)}
audio_monitor_drive :: proc() -> f32 {return transmute(f32)intrinsics.atomic_load(&g_mon_drive)}
audio_monitor_level :: proc() -> f32 {return transmute(f32)intrinsics.atomic_load(&g_mon_level)}

audio_set_monitor_tone :: proc(bass_db, treble_db: f32) {
	intrinsics.atomic_store(&g_mon_bass, transmute(u32)bass_db)
	intrinsics.atomic_store(&g_mon_treble, transmute(u32)treble_db)
}
audio_monitor_tone :: proc() -> (bass_db, treble_db: f32) {
	return transmute(f32)intrinsics.atomic_load(&g_mon_bass), transmute(f32)intrinsics.atomic_load(&g_mon_treble)
}

audio_set_monitor_cab :: proc(idx: int) {intrinsics.atomic_store(&g_mon_cab_idx, u32(idx))}
audio_monitor_cab :: proc() -> int {return int(intrinsics.atomic_load(&g_mon_cab_idx))}
audio_monitor_cab_count :: proc() -> int {return int(intrinsics.atomic_load(&g_mon_cab_count))}

audio_output_level :: proc() -> f32 {return transmute(f32)intrinsics.atomic_load(&g_output_rms_bits)}

// monitor_apply_config syncs g_monitor from the UI atomics. Callback-only (it
// owns g_monitor). Cheap params (drive/level) apply every block; tone (biquad
// recompute) and cab (coeff copy) apply only on change.
@(private = "file")
monitor_apply_config :: proc() {
	ampchain.chain_set_drive(&g_monitor, transmute(f32)intrinsics.atomic_load(&g_mon_drive))
	ampchain.chain_set_level(&g_monitor, transmute(f32)intrinsics.atomic_load(&g_mon_level))

	b := transmute(f32)intrinsics.atomic_load(&g_mon_bass)
	tr := transmute(f32)intrinsics.atomic_load(&g_mon_treble)
	if b != g_mon_bass_applied || tr != g_mon_treble_applied {
		ampchain.chain_set_tone(&g_monitor, b, tr)
		g_mon_bass_applied, g_mon_treble_applied = b, tr
	}

	ci := int(intrinsics.atomic_load(&g_mon_cab_idx))
	if ci != g_mon_cab_applied {
		if ci < int(intrinsics.atomic_load(&g_mon_cab_count)) { // acquire: publishes the data arrays
			ampchain.chain_set_cab(&g_monitor, g_mon_cab_data[ci][:g_mon_cab_len[ci]])
		} else {
			ampchain.chain_set_cab(&g_monitor, nil) // no cab -> passthrough
		}
		g_mon_cab_applied = ci
	}
}

// audio_monitor_load_cabs decodes the cab IR files into the monitor's fixed
// buffers (main thread, at startup). Truncated to the realtime tap budget.
audio_monitor_load_cabs :: proc(paths: []string) {
	intrinsics.atomic_store(&g_mon_cab_count, 0) // hide the buffers while we rewrite them
	count := 0
	for p in paths {
		if count >= MON_CABS do break
		cpath := strings.clone_to_cstring(p, context.temp_allocator)
		cfg := ma.decoder_config_init(.f32, 1, 48000)
		dec: ma.decoder
		if ma.decoder_init_file(cpath, &cfg, &dec) != .SUCCESS do continue
		read: u64
		ma.decoder_read_pcm_frames(&dec, raw_data(g_mon_cab_data[count][:]), ampchain.CAB_MAX, &read)
		ma.decoder_uninit(&dec)
		if read == 0 do continue
		ir := g_mon_cab_data[count][:int(read)]
		conv.normalize_l2(ir) // match the offline cab loudness handling
		g_mon_cab_len[count] = int(read)
		count += 1
	}
	intrinsics.atomic_store(&g_mon_cab_count, u32(count)) // release: publishes the data arrays
}

@(private = "file")
ks_noise :: proc() -> f32 {
	x := g_ks_rng
	x = x ~ (x << 13)
	x = x ~ (x >> 17)
	x = x ~ (x << 5)
	g_ks_rng = x
	return f32(x) / f32(max(u32)) * 2 - 1 // -1..1
}

// audio_version returns the linked miniaudio C library version. Referencing an
// FFI symbol here forces the linker to pull in vendor:miniaudio's static lib.
audio_version :: proc() -> string {
	return string(ma.version_string())
}

audio_init :: proc() -> bool {
	g_onset = detect.default_onset_detector()
	g_amp = amp.amp_make()

	// live-monitor amp chain (dry input -> tone -> cab -> monitor level)
	ampchain.chain_init(&g_monitor)
	intrinsics.atomic_store(&g_mon_drive, transmute(u32)f32(1))
	intrinsics.atomic_store(&g_mon_level, transmute(u32)f32(1))
	intrinsics.atomic_store(&g_mon_bass, transmute(u32)f32(0))
	intrinsics.atomic_store(&g_mon_treble, transmute(u32)f32(0))
	intrinsics.atomic_store(&g_mon_cab_idx, 0)

	// Own an enumeration context so we can bind capture/playback to specific
	// devices (the Rocksmith cable is input-only — see audiodev.odin). Best-effort:
	// if it fails, device_open falls back to the system default (nil context).
	audiodev_init_context()
	audio_resolve_selection()
	if device_open() do return true

	// The resolved (saved/auto-detected) device wouldn't open — fall back to the
	// system default so a stale audio.txt can't leave the app with no audio (and
	// the in-app device picker stays reachable).
	g_sel_capture, g_sel_playback = -1, -1
	return device_open()
}

audio_shutdown :: proc() {
	ma.device_stop(&g_device)
	ma.device_uninit(&g_device)
	audiodev_uninit_context()
}

// audio_poll drains one event from the ring on the main thread.
audio_poll :: proc() -> (ring.Event, bool) {
	return ring.pop(&g_ring)
}

audio_clock_now :: proc() -> u64 {
	return clock.now(&g_clock)
}

audio_input_level :: proc() -> f32 {
	return transmute(f32)intrinsics.atomic_load(&g_input_rms_bits)
}

// audio_schedule_click arms a calibration click at absolute sample position `at`.
audio_schedule_click :: proc(at: u64) {
	intrinsics.atomic_store(&g_click_at, at)
}

// audio_set_loopback routes the callback's own output back into onset detection,
// so calibration can be exercised without hardware (measures the internal path).
audio_set_loopback :: proc(on: bool) {
	intrinsics.atomic_store(&g_loopback, on)
}

audio_get_offset :: proc() -> i64 {
	return intrinsics.atomic_load(&g_offset_samples)
}

audio_set_offset :: proc(offset: i64) {
	intrinsics.atomic_store(&g_offset_samples, offset)
}

// audio_set_test_tone makes the callback output a continuous sine at `freq`
// (0 = off). With loopback on, this drives the onset->history->pitch path for
// hardware-free verification.
audio_set_test_tone :: proc(freq: f32) {
	intrinsics.atomic_store(&g_tone_bits, transmute(u32)freq)
}

// audio_play_tone schedules a sine voice at absolute sample `start` for `dur`
// samples. Returns false if the voice pool is full. Called from the main thread.
audio_play_tone :: proc(freq: f32, start, dur: u64, amp: f32) -> bool {
	for i in 0 ..< MAX_VOICES {
		v := &g_voices[i]
		if intrinsics.atomic_load(&v.active) != 0 {
			continue
		}
		v.freq = freq
		v.start = start
		v.end = start + dur
		v.amp = amp
		v.ks_init = false // callback seeds the delay line when the note starts
		intrinsics.atomic_store(&v.active, 1) // release: fields above are now visible
		return true
	}
	return false
}

// audio_play_samples schedules a PCM buffer to play starting at absolute sample
// `start`. The PCM is copied into a fixed voice buffer (no shared lifetime).
// Returns false if the pool is full. Called from the main thread.
audio_play_samples :: proc(pcm: []f32, start: u64, gain: f32) -> bool {
	for i in 0 ..< SAMPLE_VOICES {
		v := &g_svoices[i]
		if intrinsics.atomic_load(&v.active) != 0 {
			continue
		}
		n := min(len(pcm), SAMPLE_BUF_LEN)
		copy(v.buf[:n], pcm[:n])
		v.len = n
		v.start = start
		v.pos = 0
		v.gain = gain
		intrinsics.atomic_store(&v.active, 1) // release
		return true
	}
	return false
}

audio_set_amp_enabled :: proc(on: bool) {
	intrinsics.atomic_store(&g_amp_enabled, on ? 1 : 0)
}

// mix_samples mixes active sample-playback voices into `out`.
@(private = "file")
mix_samples :: proc(out: []f32, start: u64) {
	n := len(out)
	for i in 0 ..< SAMPLE_VOICES {
		v := &g_svoices[i]
		if intrinsics.atomic_load(&v.active) == 0 {
			continue
		}
		for j in 0 ..< n {
			t := start + u64(j)
			if t < v.start {
				continue
			}
			if v.pos >= v.len {
				break
			}
			out[j] += v.buf[v.pos] * v.gain
			v.pos += 1
		}
		if v.pos >= v.len {
			intrinsics.atomic_store(&v.active, 0)
		}
	}
}

// mix_voices adds all active voices into `out` for the block [start, start+n).
@(private = "file")
mix_voices :: proc(out: []f32, start: u64) {
	n := len(out)
	for i in 0 ..< MAX_VOICES {
		v := &g_voices[i]
		if intrinsics.atomic_load(&v.active) == 0 {
			continue
		}
		for j in 0 ..< n {
			t := start + u64(j)
			if t < v.start || t >= v.end {
				continue
			}
			// Seed the delay line with a noise burst on the pluck.
			if !v.ks_init {
				N := int(math.round(clock.SAMPLE_RATE / v.freq))
				v.ks_len = clamp(N, 2, KS_MAX)
				for k in 0 ..< v.ks_len {
					v.ks_buf[k] = ks_noise()
				}
				v.ks_idx = 0
				v.ks_init = true
			}
			// Karplus-Strong: emit the current sample, then replace it with the
			// damped average of it and its neighbour (a one-pole lowpass in the
			// feedback loop -> a decaying, string-like tone).
			cur := v.ks_buf[v.ks_idx]
			nxt := v.ks_buf[(v.ks_idx + 1) % v.ks_len]
			v.ks_buf[v.ks_idx] = KS_DAMP * 0.5 * (cur + nxt)
			out[j] += v.amp * cur
			v.ks_idx = (v.ks_idx + 1) % v.ks_len
		}
		if start + u64(n) >= v.end {
			intrinsics.atomic_store(&v.active, 0)
		}
	}
	// soft clip
	for j in 0 ..< n {
		out[j] = clamp(out[j], -1, 1)
	}
}

// audio_copy_window copies len(out) samples beginning at absolute start_pos from
// the input history. Returns false if those samples haven't been written yet or
// have already been overwritten.
audio_copy_window :: proc(start_pos: u64, out: []f32) -> bool {
	written := intrinsics.atomic_load(&g_hist_written)
	end := start_pos + u64(len(out))
	if end > written {
		return false // not captured yet
	}
	if written > HIST_CAP && start_pos < written - HIST_CAP {
		return false // already overwritten
	}
	for i in 0 ..< len(out) {
		out[i] = g_history[(start_pos + u64(i)) & (HIST_CAP - 1)]
	}
	// Re-check that the callback didn't lap us mid-copy (TOCTOU guard). With
	// HIST_CAP (~341ms) >> window this never fires in practice, but it makes a
	// long main-thread preemption fail cleanly rather than return torn samples.
	if now2 := intrinsics.atomic_load(&g_hist_written); now2 > HIST_CAP && start_pos < now2 - HIST_CAP {
		return false
	}
	return true
}

PITCH_ATTACK_SKIP :: 256 // skip the noisy pluck transient (and any sub-hop silence prefix) before analysis

// audio_try_pitch confirms the pitch of an onset once its window is available.
// The analysis window starts a little after the onset so the plucked-string
// attack transient (a noise burst) and the hop-quantized silence prefix don't
// skew the pitch estimate.
audio_try_pitch :: proc(
	onset_pos: u64,
	scratch: []f32,
	window: []f32,
) -> (
	detect.Pitch_Result,
	bool,
) {
	if !audio_copy_window(onset_pos + PITCH_ATTACK_SKIP, window) {
		return {}, false
	}
	return detect.detect_pitch(window, scratch), true
}

// The realtime audio callback. Runs on the audio thread: no allocation, no
// locking, no logging. Establishes a context with a non-heap allocator per the
// Odin gotcha (see debug.odin for the debug-build asserting allocator).
audio_callback :: proc "c" (pDevice: ^ma.device, pOutput, pInput: rawptr, frameCount: u32) {
	context = runtime.default_context()
	context.allocator = callback_allocator()

	n := int(frameCount)
	in_samples := ([^]f32)(pInput)[:n]
	out := ([^]f32)(pOutput)[:n]

	start := clock.now(&g_clock)

	// Output: a continuous test tone if set, else silence; plus a calibration
	// click burst if one is scheduled in this block. Backing audio will layer
	// in here in a later story.
	mem.zero_slice(out)
	tone_freq := transmute(f32)intrinsics.atomic_load(&g_tone_bits)
	if tone_freq > 0 {
		step := 2 * math.PI * tone_freq / clock.SAMPLE_RATE
		for i in 0 ..< n {
			out[i] = 0.7 * math.sin(g_tone_phase)
			g_tone_phase += step
			if g_tone_phase > 2 * math.PI {
				g_tone_phase -= 2 * math.PI
			}
		}
	}
	click_at := intrinsics.atomic_load(&g_click_at)
	if click_at >= start && click_at < start + u64(n) {
		off := int(click_at - start)
		end := min(off + CLICK_LEN, n)
		for i in off ..< end {
			out[i] = 1.0
		}
		intrinsics.atomic_store(&g_click_at, CLICK_DISARMED) // one-shot
	}

	// Player mode drains the song-player PCM ring straight to out (the drill
	// isn't running); otherwise mix the drill's synth (KS) + sample (SoundFont)
	// voices. The two modes are mutually exclusive (different screens).
	if intrinsics.atomic_load(&g_player_active) != 0 {
		got := pcmring.read(&g_pcm_ring, out)
		for i in got ..< n do out[i] = 0 // underrun -> silence
	} else {
		mix_voices(out, start)
		mix_samples(out, start)
	}

	// Onset detection reads the mic, or (loopback) the output we just wrote —
	// the latter lets calibration/pitch self-tests run with no hardware.
	src := intrinsics.atomic_load(&g_loopback) ? out : in_samples
	on, pos := detect.push_block(&g_onset, src, start)
	if on {
		_ = ring.push(&g_ring, ring.Event{kind = .Onset, sample_pos = pos})
	}

	// Append this block to the input history, then publish the new write count.
	for i in 0 ..< n {
		g_history[(start + u64(i)) & (HIST_CAP - 1)] = src[i]
	}
	intrinsics.atomic_store(&g_hist_written, start + u64(n))

	clock.advance(&g_clock, u64(frameCount))

	// Publish an approximate input level for the UI meter (display only).
	intrinsics.atomic_store(&g_input_rms_bits, transmute(u32)detect.rms(src))

	// Live monitoring: run the dry input through the amp chain and mix it into the
	// output at the monitor level, so you hear your own guitar in a good tone while
	// playing along. Detection already consumed the dry `src` above (spec §9.3), so
	// monitoring never feeds it. Callback owns g_monitor; it applies UI changes here.
	if intrinsics.atomic_load(&g_mon_on) != 0 {
		monitor_apply_config()
		for i in 0 ..< n {
			out[i] = clamp(out[i] + ampchain.process(&g_monitor, src[i]), -1, 1)
		}
	}

	// Amp-sim is downstream of detection (spec §9.3): overdrive the *playback*
	// only, after the dry signal has been captured. Bypassed when a SoundFont
	// supplies the (already amped) guitar tone, and in player mode (the backing
	// track must not be overdriven).
	if intrinsics.atomic_load(&g_player_active) == 0 && intrinsics.atomic_load(&g_amp_enabled) != 0 {
		amp.amp_block(&g_amp, out)
	}

	// Publish the post-mix output level (for --monitorcheck / UI).
	intrinsics.atomic_store(&g_output_rms_bits, transmute(u32)detect.rms(out))
}
