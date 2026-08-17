package main

// Audio-driving orchestration for the v0 drill. Pure trial logic (generation,
// judging) lives in package `game`; anything that touches the audio engine
// lives here in package main.

import "core:time"

import "clock"
import "detect"
import "game"
import "music"

CHORD_DUR :: clock.SAMPLE_RATE * 2 / 5 // 0.4 s per cadence chord
TARGET_DUR :: clock.SAMPLE_RATE / 2 // 0.5 s target tone
GAP :: clock.SAMPLE_RATE / 10 // 0.1 s gap (also lets the onset detector re-arm)

// play_cadence schedules the four I-IV-V-I triads sequentially starting at
// sample `at`, each lasting `chord_dur` samples. Returns the sample at which the
// cadence ends (where a target tone can follow).
play_cadence :: proc(key: music.Key, at: u64, chord_dur: u64) -> u64 {
	chords := music.cadence(key)
	t := at
	for chord in chords {
		for note in chord {
			freq := detect.midi_to_freq(note)
			// slightly detached: 90% sounding, 10% gap, so chords are distinct
			audio_play_tone(freq, t, chord_dur * 9 / 10, 0.25)
		}
		t += chord_dur
	}
	return t
}

// play_degree schedules a single target tone (the scale degree the user must
// find) starting at `at` for `dur` samples. Returns the sample it ends.
play_degree :: proc(target_midi: int, at: u64, dur: u64) -> u64 {
	freq := detect.midi_to_freq(target_midi)
	audio_play_tone(freq, at, dur, 0.6)
	return at + dur
}

// trial_play schedules a trial's audio — cadence to establish the key, then the
// target tone — starting at sample `at`. Returns `listen_start`, the sample from
// which the user's response should be captured (after the target plus a gap so
// the onset detector re-arms and the target's own onset isn't counted).
trial_play :: proc(trial: game.Trial, at: u64) -> (listen_start: u64) {
	cadence_end := play_cadence(trial.key, at, CHORD_DUR)
	target_start := cadence_end + GAP
	target_end := play_degree(trial.target_midi, target_start, TARGET_DUR)
	return target_end + GAP
}

// trial_listen_and_judge waits for the first onset at/after `listen_start`,
// confirms its pitch, and judges it against the trial. `ok=false` if no
// confident pitch arrives before `timeout` samples elapse past `listen_start`.
trial_listen_and_judge :: proc(
	trial: game.Trial,
	listen_start: u64,
	timeout: u64,
) -> (
	detected_midi: int,
	correct: bool,
	ok: bool,
) {
	scratch := make([]f32, PITCH_WINDOW / 2)
	defer delete(scratch)
	window := make([]f32, PITCH_WINDOW)
	defer delete(window)

	// Find the first onset at/after listen_start (discard cadence/target onsets).
	onset_pos: u64
	got_onset := false
	for audio_clock_now() < listen_start + timeout && !got_onset {
		for {
			ev, more := audio_poll()
			if !more do break
			if ev.sample_pos >= listen_start {
				onset_pos = ev.sample_pos
				got_onset = true
				break
			}
		}
		time.sleep(time.Millisecond)
	}
	if !got_onset {
		return 0, false, false
	}

	// Confirm the pitch once its window is captured.
	for audio_clock_now() < onset_pos + u64(PITCH_WINDOW) + u64(clock.SAMPLE_RATE / 2) {
		if r, avail := audio_try_pitch(onset_pos, scratch, window); avail {
			if !r.voiced {
				return 0, false, false
			}
			detected_midi = detect.freq_to_midi(r.freq)
			return detected_midi, game.judge(trial, detected_midi), true
		}
		time.sleep(time.Millisecond)
	}
	return 0, false, false
}
