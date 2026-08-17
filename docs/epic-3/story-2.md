# Epic 3 / Story 3.2 — Cadence Generation & Playback

**Goal:** Generate a I–IV–V–I cadence in a key and synthesize it through the duplex output, so the drill can establish tonality before asking for a scale degree. Also the note-playback engine the whole game uses (cadence, target tone, later backing).

**Files:**
- Modify: `music/theory.odin` — `major_triad`, `cadence` (pure).
- Modify: `music/theory_test.odin` — cadence note tests.
- Modify: `audio.odin` — a lock-free voice pool + `audio_play_tone`; the callback mixes active voices into the output.
- Modify: `main.odin` — `--synthcheck` (schedule a tone, detect it back over loopback).

**Constraints in play:**
- Callback stays realtime-safe: voices are a fixed pool, no allocation. Main **activates** a voice (writes fields, then an atomic `active=1` with release); the callback **deactivates** it when it finishes — single-activator / single-deactivator, so no lock needed.
- All scheduling in absolute sample positions from the master clock.

**Interfaces (Produces):**
- `music.major_triad :: proc(root_midi: int) -> [3]int` → `{root, root+4, root+7}`.
- `music.cadence :: proc(key: Key) -> [4][3]int` — I, IV, V, I triads (roots at degrees 1,4,5,8).
- `audio_play_tone :: proc(freq: f32, start, dur: u64, amp: f32) -> bool` — schedule a sine voice; false if the pool is full.
- `MAX_VOICES :: 16`; `Voice :: struct { freq: f32, start, end: u64, amp, phase: f32, active: b32 }`.
- `play_cadence :: proc(key: music.Key, at: u64, chord_dur: u64) -> u64` (in `game`/main) — schedules the 4 chords sequentially; returns the sample the cadence ends.

**Callback mixing:** for each active voice, for each sample `t` in the block: if `v.start ≤ t < v.end`, add `v.amp * sin(phase)`, advance phase; when `t ≥ v.end`, `atomic_store(&v.active, 0)`. Sum then soft-clip to [-1, 1].

## Steps (TDD — pure)

- [ ] **Step 1 (RED):** `major_triad(60) == {60,64,67}`.
- [ ] **Step 2 (RED):** `cadence(Key{60})` roots are `C(60) F(65) G(67) C(72)`, each a major triad: `[[60,64,67],[65,69,72],[67,71,74],[72,76,79]]`.
- [ ] **Step 3 (GREEN):** implement `major_triad`, `cadence`. `mise exec -- odin test music` green.

## Steps (integration)

- [ ] **Step 4:** voice pool + `audio_play_tone` + callback mixing; build.
- [ ] **Step 5:** `--synthcheck`: loopback on, `audio_play_tone(330, now+lead, 0.4s, 0.7)`, wait, catch onset, `audio_try_pitch` → assert ≈330 Hz. Repeat at 440.
- [ ] **Step 6:** `play_cadence` helper (used by the trial loop next story).

## Verification

`odin test music` green (cadence notes). `--synthcheck` plays scheduled tones that the pitch path detects at the right frequency over loopback — proving the synth/voice engine works end to end.

## Notes

- YIN on a full triad tracks one partial, so playback is **verified with single tones**; the cadence's correctness is covered by the pure note test.
