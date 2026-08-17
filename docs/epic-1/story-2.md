# Epic 1 / Story 1.2 — Sample Clock (master clock)

**Goal:** A monotonic sample counter, incremented in the audio callback and readable from any thread, plus pure sample↔time conversion. This is the master clock — every scheduling and scoring decision uses sample positions.

**Sequencing note:** Implemented before Story 1.1 (device) because the device callback consumes this. Pure logic → unit-testable with no hardware.

**Files:**
- Create: `clock/clock.odin` — `package clock`.
- Create: `clock/clock_test.odin` — `@(test)` procs.

**Constraints in play:**
- The audio clock is master; never derive musical time from frames. Conversions go samples → seconds/ms for display only.
- The counter is written by exactly one thread (audio callback) and read by others → atomics, no locks.

**Interfaces (Produces):**
- `SAMPLE_RATE :: 48000`
- `Clock :: struct { samples: u64 }`
- `advance :: proc(c: ^Clock, frames: u64) -> u64` — atomically add, return new total (audio-thread only).
- `now :: proc(c: ^Clock) -> u64` — atomic load (any thread).
- `samples_to_ms :: proc(samples: u64, rate: u32 = SAMPLE_RATE) -> f64`
- `ms_to_samples :: proc(ms: f64, rate: u32 = SAMPLE_RATE) -> u64` — rounds to nearest.
- `samples_to_seconds :: proc(samples: u64, rate: u32 = SAMPLE_RATE) -> f64`

## Steps (TDD)

- [ ] **Step 1 (RED):** Test `advance` accumulates and returns the running total; `now` reads it.
- [ ] **Step 2:** Watch it fail (undefined proc).
- [ ] **Step 3 (GREEN):** Implement `Clock`, `advance` (`intrinsics.atomic_add` returns old value → add frames for new total), `now` (`intrinsics.atomic_load`).
- [ ] **Step 4:** Watch pass.
- [ ] **Step 5 (RED):** Test conversions — `ms_to_samples(1000)==48000`, `samples_to_ms(48000)==1000`, `ms_to_samples` rounds to nearest (e.g. `ms_to_samples(1.0/48.0 * 1000)` ≈ 1 sample), `samples_to_ms(128)` ≈ 2.667.
- [ ] **Step 6:** Watch fail.
- [ ] **Step 7 (GREEN):** Implement the three conversions.
- [ ] **Step 8:** Watch pass. `mise exec -- odin test clock`.

## Verification

`mise exec -- odin test clock` — all green. 128 samples ≈ 2.667 ms confirms the buffer-latency arithmetic the spec quotes.
