# Epic 2 / Story 2.1 — Windowed Pitch Buffer

**Goal:** Capture a window of samples starting at each onset so the main thread can run `detect_pitch` a few tens of ms later (the physics floor: a low note can't be confirmed until 2–3 periods have arrived). The callback maintains a rolling history of recent input; the main thread, on an onset, waits until enough samples past the onset exist, copies the window, and detects pitch.

**Files:**
- Modify: `audio.odin` — history ring + `audio_copy_window` + a continuous test-tone generator (for hardware-free verification).
- Modify: `main.odin` — `--pitchcheck` headless self-test; a `pitch_poll`-style helper.

**Constraints in play:**
- Onset timing came from the callback; pitch is confirmed later on the main thread from this buffered window. Never in the callback.
- History must outlast the detection delay: `HIST_CAP` (16384 ≈ 341 ms) ≫ window (2048) + latency, so a window is never overwritten before the main thread reads it.
- Callback stays realtime-safe (writes samples + publishes an atomic write-count; no alloc/lock/log).

**Interfaces (Produces):**
- `PITCH_WINDOW :: 2048`
- History: `g_history: [HIST_CAP]f32`, `g_hist_written: u64` (atomic, total samples written).
- `audio_copy_window :: proc(start_pos: u64, out: []f32) -> bool` — copies `len(out)` samples beginning at absolute `start_pos`; false if not yet written or already overwritten.
- `audio_try_pitch :: proc(onset_pos: u64, scratch: []f32, window: []f32) -> (detect.Pitch_Result, bool)` — if `g_hist_written >= onset_pos + len(window)`, copy + `detect_pitch`; else false (retry next frame).
- Test tone: `audio_set_test_tone :: proc(freq: f32)` — callback outputs a continuous sine (0 = off); with loopback on, this drives the whole onset→history→pitch path deterministically.

**Callback additions:** after producing `out`, write the chosen source (`src`) into `g_history[(start+i) & (HIST_CAP-1)]`, then `atomic_store(&g_hist_written, start + n)`. When a test tone is set, fill `out` with a phase-continuous sine before the history write.

## Steps

- [ ] **Step 1:** history ring + `audio_copy_window` (bounds: `start_pos + len ≤ written` and `start_pos ≥ written − HIST_CAP`).
- [ ] **Step 2:** test-tone generator (phase accumulator; atomic freq via transmuted bits).
- [ ] **Step 3:** `audio_try_pitch`.
- [ ] **Step 4:** `--pitchcheck`: loopback on, set a 220 Hz test tone, wait for the onset, `audio_try_pitch` until ready, assert detected freq ≈ 220 Hz and voiced.
- [ ] **Step 5:** build; run `--pitchcheck`.
- [ ] **Step 6:** repeat the check for a second frequency (e.g. 330 Hz) to be sure it's not hard-coded-lucky.

## Verification

`./guitar-trainer --pitchcheck` drives a test tone over the internal loopback, catches the onset, copies the window, and reports the detected pitch within ~1 Hz of the tone — proving onset→history→windowed pitch works end to end with no hardware.

## Notes

- With hardware, the same path runs on the real mic/pickup: `audio_try_pitch(onset_pos, …)` is called each frame after draining an onset until it returns a result.

## Findings (implementation)

- **`--pitchcheck` PASS:** 220 → 220.00, 330 → 330.00, 440 → 440.02 Hz, confidence 1.00 each, over the internal loopback. Proves onset → history ring → main-thread window copy → YIN end to end.
- History ring is 16384 samples (~341 ms); `audio_copy_window` guards both "not yet written" and "already overwritten". The callback publishes `g_hist_written` after writing, so the main thread only ever reads completed samples.
- Test-tone frequency is stored as f32 **bits** in an atomic u32 (`transmute`), since atomics want integer types; the callback keeps a phase accumulator for click-free continuity.
