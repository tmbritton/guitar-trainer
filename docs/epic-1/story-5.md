# Epic 1 / Story 1.5 — Onset Detection

**Goal:** A streaming, allocation-free onset detector that runs in the audio callback on the dry input, emits a sample-timestamped onset per note attack, and does not double-trigger on sustained notes. Timing is scored off this onset (correctness off late pitch, per the physics floor).

**Sequencing note:** Pure DSP, testable with synthetic signals. FFT-free (energy/time-domain flux) per the spec's "v0 DSP needs no FFT."

**Files:**
- Create: `detect/onset.odin` — `package detect`.
- Create: `detect/onset_test.odin`.

**Constraints in play:**
- Runs in the callback: no allocation, no locking, no logging. Fixed-size state struct, operates on a caller-provided sample slice.
- ~5 ms budget. Energy-based detection function is O(n) over the block.
- Onset time is in samples (absolute, via the master clock's block-start position).

**Interfaces (Produces):**
- `Onset_Detector :: struct { prev_rms, floor, rise_ratio, rearm_ratio: f32, refractory: u64, armed, has_fired: bool, last_onset_pos: u64 }`
- `default_onset_detector :: proc() -> Onset_Detector` — floor 0.02, rise_ratio 2.0, rearm_ratio 1.0, refractory = 2400 samples (50 ms), armed=true.
- `rms :: proc(samples: []f32) -> f32`
- `push_block :: proc(d: ^Onset_Detector, samples: []f32, block_start_pos: u64) -> (onset: bool, pos: u64)` — feed one hop; returns whether an onset fired and its absolute sample position.

**Algorithm (per block):**
1. `e = rms(samples)`.
2. `rising := d.armed && e >= d.floor && e >= d.prev_rms * d.rise_ratio`.
3. On `rising`: consume the arm (`armed = false`); emit an onset **only if** past refractory since `last_onset_pos` (or never fired). On emit, set `has_fired`, `last_onset_pos`.
4. Re-arm when the signal falls back to near-silence: `e < d.floor * d.rearm_ratio → armed = true`.
5. `prev_rms = e`.

Re-arm-on-silence is what prevents a held note from retriggering; refractory is a second guard against attacks too close together.

## Steps (TDD)

- [ ] **Step 1 (RED):** `rms` of silence is 0; `rms` of a unit-amplitude ±1 square is 1; of a sine of amplitude A is ≈ A/√2.
- [ ] **Step 2 (GREEN):** implement `rms`.
- [ ] **Step 3 (RED):** silence through `push_block` (many hops) → never an onset.
- [ ] **Step 4 (RED):** a step from silence into a sustained sine → exactly one onset, at the first loud block's start position.
- [ ] **Step 5 (GREEN):** implement `Onset_Detector` + `push_block` to pass 3 & 4.
- [ ] **Step 6 (RED):** two bursts separated by a silence gap longer than refractory → two onsets at the expected positions.
- [ ] **Step 7 (RED):** two attacks closer than refractory (with a brief dip) → only the first onset (refractory suppresses the second).
- [ ] **Step 8 (RED):** low-level noise below `floor` → no onset.
- [ ] **Step 9:** `mise exec -- odin test detect` — all green.

## Verification

`mise exec -- odin test detect` green. Onset positions land in the block where the attack starts (±1 hop). Sustained tones and sub-floor noise never trigger.

## Notes

- Onset position granularity is one hop (128 samples ≈ 2.7 ms), within the <10 ms target. Sub-block localization (argmax of instantaneous energy inside the hop) is a possible later refinement, not needed for v0.
