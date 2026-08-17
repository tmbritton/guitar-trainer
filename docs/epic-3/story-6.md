# Epic 3 / Story 3.6 — Drill UI & Gamefeel

**Goal:** Make the v0 loop playable end to end as an actual on-screen drill (Milestone M2): run trials continuously, show minimal state, give **delayed, phrase-level, auditory-where-possible** feedback (not per-note green/red), and log every trial. This is the story that turns the pieces into "playable end to end."

**Files:**
- Modify: `main.odin` — replace the current diagnostic `run_app` HUD with the drill screen + a non-blocking trial state machine.
- Modify: `drill.odin` — a frame-driven `Drill` state machine (so the UI stays responsive; no blocking loops on the render thread) and trial logging.
- Reuse: `next_trial`, `trial_play`, and the pitch-confirm path; `store` for logging; `game.judge`.

**Constraints in play (spec §5.1, §8):**
- **No real-time per-note correctness feedback.** Feedback is delayed to phrase/trial level and auditory where possible (right → a confirming tone/backing "locks"; wrong → a subtle stumble). Keep the *visual* reward minimal — the drill is a training tool, not a game with a learning veneer.
- Judge by pitch class (octave-agnostic) in v0. Score the sound.
- Everything in sample time; the render loop must not block (calibration/self-tests could block; the live drill cannot).
- Log every trial to the SQLite `trials` table (ts, key, target_degree, target_midi, detected_midi, onset_offset_samples, correct, response_ms, session_id). One `session_id` per app launch.

**Design — a frame-stepped state machine** (replaces blocking `trial_*` helpers for live use):
- `Drill_Phase :: enum { Idle, Cadence, Target, Listen, Feedback }`
- `Drill :: struct { phase, trial, phase_end_sample, listen_start, onset_pos, session_id, last_result..., store: ^store.Store, scratch, window: []f32 }`
- `drill_init(store, session_id)`; `drill_update(d)` called once per frame:
  - `Idle` → build `next_trial`, schedule cadence via `trial_play`-style scheduling, set `phase_end` = listen_start, go `Listen` (cadence+target already scheduled to play).
  - `Listen` → each frame drain onsets; first onset with `+PERIOD_FRAMES > listen_start` → confirm pitch (non-blocking `audio_try_pitch`; retry frames until the window is ready); on confident pitch → judge, play auditory feedback (locking tone if correct, detuned "stumble" if wrong), log the trial, set a short `Feedback` timer.
  - `Listen` timeout (no confident note within N seconds) → log as a miss (detected_midi = -1) and move on.
  - `Feedback` → after the timer, back to `Idle` for the next trial.
- `drill_draw(d)` — key/degree, a subtle "listening…" indicator, the running session accuracy (from `store.count_trials` + a correct counter), last result shown briefly. No per-note coloring.

## Steps

- [ ] **Step 1:** `Drill` state machine + `drill_update`/`drill_draw` in `drill.odin` (frame-stepped; reuses cadence/target scheduling and the onset-boundary-safe filter from 3.3).
- [ ] **Step 2:** auditory feedback: a short confirming tone (correct) vs. a detuned/short "stumble" (wrong), scheduled via `audio_play_tone`.
- [ ] **Step 3:** per-launch `session_id`; open the store at a fixed path (e.g. `~/.local/share/guitar-trainer/trials.db` or `./trials.db`); log each trial with response_ms (onset − listen_start, converted) and onset_offset (offset-corrected via `audio_get_offset`).
- [ ] **Step 4:** rewire `run_app` to `drill_init` + per-frame `drill_update`/`drill_draw`; keep `C` = calibrate.
- [ ] **Step 5 (verify — automated):** a `--drillsim` headless mode that runs the state machine over loopback with an injected correct/wrong response per trial for a couple of trials, asserting rows land in a temp DB with the right `correct` values. (The blocking `--drillcheck` stays as the pure trial-loop proof.)
- [ ] **Step 6 (verify — live):** build and run the window; confirm the drill advances through cadence→target→listen and reacts to input. (Full "feels good to fail at" gamefeel judgement is the M3 daily-use gate, with hardware.)

## Verification

`--drillsim` drives the frame-stepped drill over loopback and shows trials being judged and written to SQLite with correct/incorrect recorded. The app runs the drill screen live. Unit tests still green.

## Findings (implementation)

- **Frame-stepped `Drill` state machine** (`drill.odin`): `Idle → Listen → Confirm → Feedback`. `drill_update` is non-blocking (drains onsets / retries `audio_try_pitch` one frame at a time), so the render loop never stalls. Reuses `trial_play` for scheduling and the 3.3 onset-boundary filter.
- **Delayed, auditory feedback** (spec §5.1): correct → the target pitch replays as a "lock-in"; wrong → a brief ~minor-second beat (220/233 Hz) "stumble". Visual is minimal; the target note is hidden until revealed in the Feedback line. No per-note green/red.
- **Logging:** one `session_id` per launch (unix time); every trial written to `trials.db` (cwd) including a miss (`detected_midi=-1`) on listen timeout; `onset_offset_samples` is offset-corrected via `audio_get_offset()`.
- **`--drillsim` PASS:** drives the live state machine over loopback, injecting a scripted correct/wrong response per trial → 3 trials logged, `correct=2/3`, verified by reopening the DB. Proves the whole live loop (schedule → listen → confirm → judge → log) end to end.
- **Live GUI:** runs cleanly on the display, initializes `trials.db`; a short smoke logs 0 trials (a trial takes ~2.3 s cadence+target then waits for a note) — correct behavior, no crash.

## Notes

- The blocking `trial_play`/`trial_listen_and_judge` remain for the `--drillcheck` self-test; the live path is the non-blocking state machine so the window never freezes waiting for input.
- Full "feels good to fail at" gamefeel is judged during M3 daily use with the real interface, not by adding juice now.
- Gamefeel is deliberately minimal here; the open question (does the drill stay engaging past day 10) is answered by M3 daily use, not by adding juice now.
