# Epic 1 / Story 1.6 — Calibration (round-trip offset)

**Goal:** Measure the round-trip latency — emit a click, detect it back, store the delta in samples — and subtract it from every future judgment. Per the spec this is a v0 feature, not polish: without it, early "detection feels wrong" is just an uncorrected offset.

**Files:**
- Create: `calib/calib.odin` + `calib/calib_test.odin` — `package calib`, pure offset math.
- Modify: `audio.odin` — a click generator in the callback (writes a short burst at a scheduled sample position) + an internal software-loopback switch for hardware-free verification + a stored offset.
- Modify: `main.odin` — `--calibcheck` headless self-test; calibration key in the app screen.

**Constraints in play:**
- Sample-domain throughout. Click is scheduled at an absolute sample position; detected onset position comes from the existing onset→ring path; offset is their difference.
- Callback stays realtime-safe: the click generator writes into the output buffer with no allocation; scheduling is an atomic target position.
- The real acoustic offset (DAC→amp→speaker/pickup→ADC) requires the USB interface + a loopback; that measurement is deferred with the rest of M0. The **machinery** is verified now via software loopback (feed the generated output back into the detector).

**Interfaces (Produces):**
- `calib.median_i64 :: proc(xs: []i64) -> i64` — median (mean of two middles, rounded).
- `calib.match_click :: proc(target: u64, onsets: []u64, window: u64) -> (offset: i64, ok: bool)` — nearest onset within ±window; `offset = i64(onset) - i64(target)`.
- `calib.aggregate :: proc(offsets: []i64) -> (offset: i64, ok: bool)` — median of matched offsets; ok=false if empty.
- `audio_schedule_click :: proc(at: u64)` / `audio_set_loopback :: proc(on: bool)` / `audio_get_offset` / `audio_set_offset`.
- `run_calibration :: proc(n: int) -> (offset: i64, ok: bool)` — main-thread driver: schedule N spaced clicks, match each against drained onsets, aggregate.

**Click generator (callback):** an atomic `g_click_at` (`max(u64)` = disarmed). Each block, if `g_click_at` falls in `[start, start+frames)`, write a 64-sample full-scale burst into the output at the in-block offset, then disarm. In loopback mode the onset detector reads the output buffer (which now contains the burst) instead of the mic.

**Driver (`run_calibration`):** for each of N trials: pick `target = clock_now + lead` (lead ~0.2 s, > refractory apart), `audio_schedule_click(target)`, spin draining onsets until `clock_now > target + window`, collect the matched offset. `aggregate` the results. Store via `audio_set_offset`.

## Steps (TDD — calib package)

- [ ] **Step 1 (RED):** `median_i64([5,1,3])==3`, `([4,2])==3`, `([10])==10`, `([])==0`.
- [ ] **Step 2 (GREEN):** implement (sort a copy; mean of middles).
- [ ] **Step 3 (RED):** `match_click(1000, [900,1010,2000], 200)` → offset `+10`, ok; nearest wins over the -100 candidate. Empty/none-in-window → ok=false.
- [ ] **Step 4 (GREEN):** implement nearest-within-window.
- [ ] **Step 5 (RED):** `aggregate([])` → ok=false; `aggregate([8,10,12])` → `(10, true)`.
- [ ] **Step 6 (GREEN):** implement.
- [ ] **Step 7:** `mise exec -- odin test calib` green.

## Steps (integration)

- [ ] **Step 8:** click generator + loopback + offset storage in `audio.odin`; build.
- [ ] **Step 9:** `run_calibration` driver + `--calibcheck` headless mode (loopback on).
- [ ] **Step 10 (verify):** `./build.sh && ./guitar-trainer --calibcheck` reports an ok offset within a couple of blocks of zero (software loopback has ~no real latency), proving click-schedule → detect → match → aggregate works end to end.
- [ ] **Step 11:** app calibration screen — press `C` to run calibration, show measured offset.

## Verification

`odin test calib` green. `--calibcheck` measures a plausible small offset over the internal loopback with `ok=true`. Real acoustic offset is captured when the interface arrives (same deferral as the M0 <10 ms bar).

## Notes

- Block granularity makes the detected onset land at the block start, so the software-loopback offset is a small sub-block value (possibly slightly negative). That's expected; real hardware latency dwarfs it and is positive.

## Findings (implementation)

- `calib` package: 10 tests green (median incl. even/empty/no-mutation, nearest-within-window matching with signed offset, aggregate).
- **`--calibcheck` PASS:** over the internal software loopback the driver scheduled 5 clicks and measured **0 samples** — click and detection align at block granularity, matched every time. This proves click-schedule → callback burst → onset detect → ring → main drain → match → median aggregate works end to end with no hardware.
- The click generator writes a 64-sample full-scale burst into the output buffer in the callback (one-shot via an atomic `g_click_at`), allocation-free. Loopback routes that output back into the onset detector.
- App screen: `C` runs `run_calibration(5)` on the **real** input path (loopback off) and shows the offset; with no interface/no input it reports "no click detected" — which is the correct real-hardware flow for when the Scarlett/MOTU arrives.
- **Deferred to hardware:** the actual acoustic round-trip offset (and the formal M0 <10 ms offset-corrected pick-attack acceptance). The stored-offset plumbing (`audio_get_offset`/`audio_set_offset`) is ready for judgments to subtract it.
