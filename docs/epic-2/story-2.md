# Epic 2 / Story 2.2 — YIN Pitch Detector (+ 2.3 confidence gating)

**Goal:** Given a buffered window of dry samples, return the fundamental frequency, a confidence, and a voiced/unvoiced flag. Runs on the main thread (not the callback). Confidence gating (Story 2.3) is folded in: below threshold → `voiced=false` ("no confident pitch") rather than guessing.

**Files:**
- Create: `detect/pitch.odin` (package `detect`).
- Create: `detect/pitch_test.odin` (reuses `fill_sine` from the onset tests — same package).

**Constraints in play:**
- FFT-free: YIN is autocorrelation-family, ~O(W²/2) over a 2048-window — fine on the main thread. No allocation in the hot path beyond a caller-provided scratch buffer.
- Physics floor: needs 2–3 periods of the fundamental. Low E (82.4 Hz) ⇒ window ≥ ~2048 at 48 kHz; `tau_max = W/2 = 1024` ⇒ lowest detectable f0 ≈ 46.9 Hz.
- Accept a "no confident pitch" state (bends, palm mutes, dead strings).

**Interfaces (Produces):**
- `Pitch_Result :: struct { freq: f32, confidence: f32, voiced: bool }`
- `YIN_THRESHOLD :: 0.15`
- `detect_pitch :: proc(samples: []f32, scratch: []f32, sample_rate: f32 = 48000, threshold: f32 = YIN_THRESHOLD) -> Pitch_Result` — `scratch` holds the CMND function, length ≥ `len(samples)/2`.
- `freq_to_midi_f :: proc(freq: f32) -> f32` — `69 + 12*log2(freq/440)`.
- `freq_to_midi :: proc(freq: f32) -> int` — rounded.
- `midi_to_freq :: proc(midi: int) -> f32` — `440 * 2^((midi-69)/12)`.

**YIN steps:** (1) difference function `d(τ)=Σ (x[j]-x[j+τ])²`; (2) cumulative mean normalized difference `d'(τ)`; (3) absolute threshold — first `τ` with `d'(τ)<threshold` at a local min, else global min; (4) parabolic interpolation around `τ` for sub-sample f0; (5) `confidence = 1 - d'(τ*)`, `voiced = d'(τ*) < threshold`.

## Steps (TDD)

- [ ] **Step 1 (RED):** `midi_to_freq(69)==440`; `freq_to_midi(440)==69`; `freq_to_midi(880)==81`; `freq_to_midi_f(440)≈69.0`.
- [ ] **Step 2 (GREEN):** implement the three conversions.
- [ ] **Step 3 (RED):** `detect_pitch` on a 2048-sample 440 Hz sine → `voiced`, `freq` within 1 Hz, `confidence > 0.9`.
- [ ] **Step 4 (RED):** low E (82.41 Hz) and a high note (~659 Hz, E5) each detected within 1 Hz over a 2048 window.
- [ ] **Step 5 (GREEN):** implement `detect_pitch` (YIN).
- [ ] **Step 6 (RED):** silence → `!voiced`; white-ish noise (deterministic PRNG) → `!voiced` or low confidence.
- [ ] **Step 7 (RED):** octave robustness — 220 Hz sine returns ~220, not 110 or 440.
- [ ] **Step 8:** `mise exec -- odin test detect` — all green (onset + pitch).

## Verification

`odin test detect` green. Pitch within 1 Hz across E2..~E5 on clean synthetic tones; silence/noise reported unvoiced.

## Notes

- Parabolic interpolation matters most at high frequencies where `τ` is small and integer-`τ` error is large in Hz.
- Real-guitar accuracy across the whole neck (plucked/picked) is Story 2.4's harness; this story proves the algorithm on synthetic tones.
