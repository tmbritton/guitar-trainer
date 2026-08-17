package main

// Audio-driving orchestration for the v0 drill. Pure trial logic (generation,
// judging) lives in package `game`; anything that touches the audio engine
// lives here in package main.

import "clock"
import "detect"
import "music"

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
