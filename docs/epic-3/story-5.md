# Epic 3 / Story 3.5 — Naive Trial Scheduling

**Goal:** Choose the next trial's scale degree with a simple, log-informed policy: uniform to start, lightly weighted toward degrees the user gets wrong or hasn't seen. Instrument via the trial log; defer the SM-2-vs-Kellman decision to data (spec §12.2). Keep the selection pure and testable; derive stats from the SQLite log.

**Files:**
- Create: `game/schedule.odin` (`package game`) + `game/schedule_test.odin`.
- Modify: `store/store.odin` — `degree_stats` query (attempts + correct per degree).
- Modify: `store/store_test.odin` — test the aggregation.
- Modify: `game/degrees.odin` — `new_trial_weighted(low, high, stats)` using the scheduler.

**Constraints in play:**
- Start naive; the weighting is a gentle nudge, not an adaptive-mastery engine. All policy derivable from the one `trials` table (no new tables).
- Pure selection logic separated from RNG so it's deterministically testable.

**Interfaces (Produces):**
- `game.Degree_Stats :: struct { attempts: [8]int, correct: [8]int }` (index 1..7; 0 unused).
- `game.degree_weight :: proc(stats: Degree_Stats, degree: int) -> f32` — unseen degree → max weight (exploration); otherwise `1 + (1 - accuracy) * K` where `accuracy = correct/attempts`. Monotonically decreasing in accuracy.
- `game.pick_degree :: proc(stats: Degree_Stats, u: f32) -> int` — deterministic weighted pick given a uniform sample `u ∈ [0,1)`; walks the cumulative weight of degrees 1..7.
- `game.select_degree :: proc(stats: Degree_Stats) -> int` — wraps `pick_degree` with `rand.float32()`.
- `game.new_trial_weighted :: proc(low_tonic, high_tonic: int, stats: Degree_Stats) -> Trial`.
- `store.degree_stats :: proc(s: ^Store) -> [8]DegreeStat` (or fills a `game`-shaped struct) — `SELECT target_degree, count(*), sum(correct) FROM trials GROUP BY target_degree`.

## Steps (TDD — game/schedule)

- [ ] **Step 1 (RED):** `degree_weight` — an unseen degree (0 attempts) outweighs a perfectly-played one; a 0%-accuracy degree outweighs a 100%-accuracy degree; equal accuracy → equal weight.
- [ ] **Step 2 (GREEN):** implement `degree_weight`.
- [ ] **Step 3 (RED):** `pick_degree` deterministic — with weights concentrated on degree 3 (only degree 3 has low accuracy, others perfect), `u=0.5` returns 3; `u=0.0` returns the first degree; `u` just under 1 returns the last. Always returns 1..7.
- [ ] **Step 4 (GREEN):** implement `pick_degree` (cumulative walk; guard the `u==` upper edge).
- [ ] **Step 5 (RED):** `select_degree` always in 1..7 over many draws.
- [ ] **Step 6:** `mise exec -- odin test game` green.

## Steps (store aggregation)

- [ ] **Step 7 (RED):** insert rows for degrees 1 and 2 with known correct/attempts; `degree_stats` returns matching attempts/correct arrays; unseen degrees are 0.
- [ ] **Step 8 (GREEN):** implement `degree_stats` (grouped query, finalize the statement).
- [ ] **Step 9:** `odin test store` green.

## Verification

`odin test game` and `odin test store` green: weighting favors weak/unseen degrees, deterministic pick is correct, and the log aggregation matches inserted data. The drill (Story 3.6) will feed `degree_stats` into `new_trial_weighted`.

## Notes

- Keep `K` small (e.g. 2–3) so early sessions stay close to uniform; the whole point is to instrument first and tune from the trial log later, not to over-fit a policy now.
- `new_trial` (uniform) stays available; weighting is opt-in via `new_trial_weighted`.
