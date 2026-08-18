package main

// Audio-driving orchestration for the v0 drill. Pure trial logic (generation,
// judging) lives in package `game`; anything that touches the audio engine
// lives here in package main.

import "core:time"

import "clock"
import "detect"
import "game"
import "music"
import "store"

CHORD_DUR :: clock.SAMPLE_RATE * 2 / 5 // 0.4 s per cadence chord
TARGET_DUR :: clock.SAMPLE_RATE / 2 // 0.5 s target tone
GAP :: clock.SAMPLE_RATE / 10 // 0.1 s gap (also lets the onset detector re-arm)

LOW_TONIC :: 45 // A2  — heavy guitar register (Iommi/Page heft); still in YIN's range
HIGH_TONIC :: 55 // G3
LISTEN_TIMEOUT :: clock.SAMPLE_RATE * 6 // 6 s to respond before a trial is a miss
FEEDBACK_DUR :: clock.SAMPLE_RATE * 3 / 4 // 0.75 s feedback window
START_LEAD :: clock.SAMPLE_RATE / 10 + 37 // small, deliberately non-hop-aligned

// play_cadence schedules the four I-IV-V-I triads sequentially starting at
// sample `at`, each lasting `chord_dur` samples. Returns the sample at which the
// cadence ends (where a target tone can follow).
play_cadence :: proc(key: music.Key, at: u64, chord_dur: u64) -> u64 {
	if sf_loaded() {
		sf_play_cadence(key, at, int(chord_dur))
	} else {
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
	}
	return at + 4 * chord_dur
}

// play_degree schedules a single target tone (the scale degree the user must
// find) starting at `at` for `dur` samples. Returns the sample it ends.
play_degree :: proc(target_midi: int, at: u64, dur: u64) -> u64 {
	if sf_loaded() {
		sf_play_note(target_midi, at, int(dur), 0.9)
	} else {
		audio_play_tone(detect.midi_to_freq(target_midi), at, dur, 0.6)
	}
	return at + dur
}

// ---- Frame-stepped drill state machine -----------------------------------
//
// The live drill must never block the render thread, so it advances one step
// per frame instead of using the blocking trial_* helpers (which the self-tests
// still use). Feedback is delayed to trial level and auditory (spec §5.1): a
// correct answer replays the target as confirmation; a wrong one plays a short
// dissonant "stumble". No per-note green/red.

Drill_Phase :: enum {
	Idle, // between trials; next update starts one
	Listen, // cadence+target scheduled; waiting for / capturing the response
	Confirm, // onset seen; waiting for its pitch window
	Feedback, // brief post-answer window
}

Drill :: struct {
	phase:             Drill_Phase,
	trial:             game.Trial,
	listen_start:      u64,
	listen_timeout_at: u64,
	onset_pos:         u64,
	feedback_end:      u64,
	db:                ^store.Store,
	session_id:        i64,
	scratch:           []f32,
	window:            []f32,

	// display / session stats
	total:             int,
	correct_count:     int,
	last_had_result:   bool,
	last_correct:      bool,
	last_detected:     int,
	last_target:       int,
}

drill_init :: proc(db: ^store.Store, session_id: i64) -> Drill {
	return Drill {
		phase = .Idle,
		db = db,
		session_id = session_id,
		scratch = make([]f32, PITCH_WINDOW / 2),
		window = make([]f32, PITCH_WINDOW),
	}
}

drill_destroy :: proc(d: ^Drill) {
	delete(d.scratch)
	delete(d.window)
}

// drill_update advances the state machine by one frame. Non-blocking.
drill_update :: proc(d: ^Drill) {
	switch d.phase {
	case .Idle:
		d.trial = next_trial(d.db, LOW_TONIC, HIGH_TONIC)
		start := audio_clock_now() + u64(START_LEAD)
		d.listen_start = trial_play(d.trial, start)
		d.listen_timeout_at = d.listen_start + u64(LISTEN_TIMEOUT)
		d.phase = .Listen

	case .Listen:
		for {
			ev, more := audio_poll()
			if !more do break
			if ev.sample_pos + PERIOD_FRAMES > d.listen_start {
				d.onset_pos = ev.sample_pos
				d.phase = .Confirm
				break
			}
		}
		if d.phase == .Listen && audio_clock_now() > d.listen_timeout_at {
			drill_record(d, -1) // miss: no note played in time
		}

	case .Confirm:
		if r, avail := audio_try_pitch(d.onset_pos, d.scratch, d.window); avail {
			detected := r.voiced ? detect.freq_to_midi(r.freq) : -1
			drill_record(d, detected)
		} else if audio_clock_now() > d.onset_pos + u64(PITCH_WINDOW) + u64(clock.SAMPLE_RATE) {
			drill_record(d, -1) // window never arrived (shouldn't happen)
		}

	case .Feedback:
		if audio_clock_now() >= d.feedback_end {
			d.phase = .Idle
		}
	}
}

// drill_record judges the detected note (detected < 0 means "no confident
// note"), logs the trial, plays auditory feedback, and enters Feedback.
drill_record :: proc(d: ^Drill, detected_midi: int) {
	correct := detected_midi >= 0 && game.judge(d.trial, detected_midi)

	response_ms: i64 = 0
	onset_offset: i64 = 0
	if detected_midi >= 0 {
		// onset_pos can be up to one period BEFORE listen_start (the onset filter
		// accepts hop-quantized attacks), so compute the delta signed and clamp:
		// an unsigned subtraction here would underflow to a garbage response time.
		delta := i64(d.onset_pos) - i64(d.listen_start)
		if delta < 0 {
			delta = 0
		}
		response_ms = i64(clock.samples_to_ms(u64(delta)))
		onset_offset = i64(d.onset_pos) - i64(d.listen_start) - audio_get_offset()
	}
	store.insert_trial(
		d.db,
		store.Trial_Row {
			ts = d.session_id,
			key = i64(d.trial.key.tonic_midi),
			target_degree = i64(d.trial.target_degree),
			target_midi = i64(d.trial.target_midi),
			detected_midi = i64(detected_midi),
			onset_offset_samples = onset_offset,
			correct = correct,
			response_ms = response_ms,
			session_id = d.session_id,
		},
	)

	d.total += 1
	if correct do d.correct_count += 1
	d.last_had_result = true
	d.last_correct = correct
	d.last_detected = detected_midi
	d.last_target = d.trial.target_midi

	at := audio_clock_now() + u64(clock.SAMPLE_RATE / 50) // +20 ms
	drill_feedback(correct, d.trial.target_midi, at)
	d.feedback_end = at + u64(FEEDBACK_DUR)
	d.phase = .Feedback
}

// drill_feedback: correct replays the target as a confirming "lock in"; wrong
// plays a brief dissonant minor-second beat — a stumble, not a red X.
drill_feedback :: proc(correct: bool, target_midi: int, at: u64) {
	if sf_loaded() {
		if correct {
			sf_play_note(target_midi, at, int(clock.SAMPLE_RATE / 3), 0.9) // confirm the note
		} else {
			sf_play_note(target_midi - 1, at, int(clock.SAMPLE_RATE / 5), 0.7) // a semitone-off "stumble"
		}
	} else if correct {
		audio_play_tone(detect.midi_to_freq(target_midi), at, u64(clock.SAMPLE_RATE / 3), 0.4)
	} else {
		audio_play_tone(220, at, u64(clock.SAMPLE_RATE / 5), 0.3)
		audio_play_tone(233, at, u64(clock.SAMPLE_RATE / 5), 0.3) // ~minor second -> beating
	}
}

// next_trial builds the next trial, weighting the scale-degree choice by the
// per-degree accuracy in the trial log (weak/unseen degrees favored).
next_trial :: proc(s: ^store.Store, low_tonic, high_tonic: int) -> game.Trial {
	attempts, correct := store.degree_stats(s)
	stats: game.Degree_Stats
	for d in 1 ..= 7 {
		stats.attempts[d] = int(attempts[d])
		stats.correct[d] = int(correct[d])
	}
	return game.new_trial_weighted(low_tonic, high_tonic, stats)
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
			// Onset timestamps are quantized to the start of the callback hop, so
			// a real attack landing right at listen_start reports up to one period
			// early. Quantization only ever rounds down, so back the boundary off
			// by one period; stale cadence/target onsets are thousands of samples
			// earlier and still excluded.
			if ev.sample_pos + PERIOD_FRAMES > listen_start {
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
