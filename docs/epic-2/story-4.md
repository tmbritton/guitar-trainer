# Epic 2 / Story 2.4 — Fretboard Accuracy Harness

**Goal:** Verify pitch detection identifies **every note on the neck**, not just a few test tones. Standard tuning, 24 frets ⇒ MIDI 40 (E2, 82.41 Hz) through MIDI 88 (E6, 1318.5 Hz). The harness sweeps that whole range and asserts the detected frequency rounds to the correct MIDI note.

**Files:**
- Modify: `detect/pitch_test.odin` — a sweep test over MIDI 40..88 (synthetic tones).

**Constraints in play:**
- The spec's bar is "every note on the neck, plucked and picked, clean signal." Synthetic sines prove the **algorithm** covers the frequency range and octave band; real plucked/picked timbre (harmonics, inharmonicity, decay) is the hardware-gated part of M1, alongside the real loopback path already exercised by `--pitchcheck`.

## Steps (TDD)

- [ ] **Step 1 (RED/GREEN):** loop `midi` in 40..=88: synthesize `midi_to_freq(midi)` into a 2048 window, `detect_pitch`, assert `voiced` and `freq_to_midi(result.freq) == midi`. (The detector already exists, so this is a coverage assertion; if any note fails, tune window/threshold.)
- [ ] **Step 2:** `mise exec -- odin test detect` green.

## Verification

`odin test detect` green including the full-neck sweep: all 49 semitones E2..E6 identified to the correct MIDI note on clean synthetic tones. `--pitchcheck` covers the same detector over the real audio loopback path at representative frequencies.

## Notes

- If the top octave misses by a cent-scale amount, parabolic interpolation (already in `detect_pitch`) is what keeps `freq_to_midi` on the right note; the sweep is the regression guard.
- Real-instrument accuracy (plucked/picked, whole neck) is completed with the USB interface — same M1 deferral as calibration's acoustic offset.
