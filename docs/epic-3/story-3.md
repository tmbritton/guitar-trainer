# Epic 3 / Story 3.3 — Trial Loop

**Goal:** The v0 loop: establish a key with the cadence, play a random scale-degree target tone, listen for the user's note, judge by pitch class (octave-agnostic), advance. Pure trial logic in `game`; audio orchestration in `main`, verified over loopback by injecting a simulated "user" note.

**Files:**
- Create: `game/degrees.odin` (`package game`, imports `../music`) + `game/degrees_test.odin`.
- Modify: `drill.odin` (package main) — `trial_play`, `trial_listen_and_judge`.
- Modify: `main.odin` — `--drillcheck` (inject a correct then a wrong response).

**Constraints in play:**
- Judge by **pitch class** (octave-agnostic) in v0.
- Score the sound: judging uses detected MIDI (from pitch), not fingering.
- All timing in samples off the master clock.

**Interfaces (Produces):**
- `game.Trial :: struct { key: music.Key, target_degree: int, target_midi: int }`
- `game.new_trial :: proc(low_tonic, high_tonic: int) -> Trial` — random key + random degree 1..7.
- `game.judge :: proc(trial: Trial, detected_midi: int) -> bool` — `same_pitch_class(target, detected)`.
- `trial_play :: proc(trial: game.Trial, at: u64) -> (listen_start: u64)` (main) — schedule cadence then target; return when listening begins (after the target ends + a gap).
- `trial_listen_and_judge :: proc(trial: game.Trial, listen_start: u64, timeout: u64) -> (detected_midi: int, correct: bool, ok: bool)` (main) — wait for the first onset ≥ `listen_start`, confirm its pitch, judge.

## Steps (TDD — game)

- [ ] **Step 1 (RED):** `judge(Trial{target_midi=60}, 72)` true (octave-agnostic); `judge(.., 61)` false.
- [ ] **Step 2 (GREEN):** implement `judge`.
- [ ] **Step 3 (RED):** `new_trial(60,60)` → key.tonic 60, degree in 1..7, `target_midi == degree_to_midi(60, degree)`.
- [ ] **Step 4 (GREEN):** implement `new_trial`.
- [ ] **Step 5:** `mise exec -- odin test game` green.

## Steps (integration)

- [ ] **Step 6:** `trial_play` + `trial_listen_and_judge` in `drill.odin`.
- [ ] **Step 7:** `--drillcheck`: loopback on; build a trial; `trial_play`; inject a tone at the **target** pitch at `listen_start` → expect `correct=true`; then a second trial injecting a **wrong** pitch (target+1 semitone) → expect `correct=false`. Also inject an **octave-shifted** correct pitch → expect `correct=true` (proves octave-agnostic judging end to end).
- [ ] **Step 8:** build; run `--drillcheck`.

## Verification

`odin test game` green. `--drillcheck` runs full trials over loopback: a correct injected note (incl. octave-shifted) judges correct; a wrong note judges incorrect — proving cadence → target → listen → judge works end to end.

## Notes

- The cadence and target tones also generate onsets; `trial_listen_and_judge` only considers onsets at/after `listen_start`, which is set past the target's end.
