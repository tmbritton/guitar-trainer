# Epic 4 / Story 4.1 — Session & Progress Instrumentation

**Goal:** A minimal progress view derived entirely from the trial log (no new tables) so the M3 daily-use phase can answer "did I practice today" and "am I improving." Every trial already carries `session_id` (per-launch unix time) and `ts`.

**Files:**
- Modify: `store/store.odin` — read-only aggregate queries.
- Modify: `store/store_test.odin` — test the aggregates.
- Modify: `main.odin` / `drill.odin` — a togglable progress panel (`P`) in the drill screen; `--progresscheck` headless verify.

**Constraints in play:**
- Derive everything from the single `trials` table; add no tables (spec §9.6).
- Read-only, main-thread only. Panel must not disturb the running drill.

**Interfaces (Produces) — all in `store`:**
- `overall :: proc(s: ^Store) -> (attempts: i64, correct: i64)`
- `recent_accuracy :: proc(s: ^Store, n: int) -> (attempts: i64, correct: i64)` — over the last `n` trials by id.
- `practice_days :: proc(s: ^Store) -> i64` — distinct calendar-day buckets (`session_id / 86400`).
- (reuse `degree_stats` for per-degree accuracy)

## Steps (TDD — store)

- [ ] **Step 1 (RED):** insert a known mix (e.g. 5 trials, 3 correct); `overall` → `(5, 3)`.
- [ ] **Step 2 (GREEN):** implement `overall`.
- [ ] **Step 3 (RED):** `recent_accuracy(s, 2)` over the last 2 inserted → matches those 2 rows' correctness (order by id desc, limit n).
- [ ] **Step 4 (GREEN):** implement `recent_accuracy`.
- [ ] **Step 5 (RED):** rows across two `session_id`s a day apart (e.g. `100` and `100 + 86400`) → `practice_days == 2`; same-day sessions → `1`.
- [ ] **Step 6 (GREEN):** implement `practice_days`.
- [ ] **Step 7:** `odin test store` green.

## Steps (UI + verify)

- [ ] **Step 8:** progress panel drawn when toggled (`P`): practice days, total trials, overall accuracy, recent-20 accuracy with an "improving / steady / dipping" hint (recent vs overall), and per-degree accuracy bars (from `degree_stats`). Minimal, legible; no per-note coloring.
- [ ] **Step 9:** `--progresscheck` — seed a temp DB with a scripted mix across two day-buckets, then assert `overall`, `practice_days`, and `recent_accuracy` return the expected numbers (independent of the CLI).
- [ ] **Step 10:** build; run `--progresscheck`; brief live GUI check that `P` toggles the panel.

## Verification

`odin test store` green (overall / recent_accuracy / practice_days). `--progresscheck` confirms the aggregates on a seeded log. The drill screen toggles a progress panel with `P`.

## Findings (implementation)

- `store`: `overall`, `recent_accuracy(n)` (subquery `ORDER BY id DESC LIMIT ?`), `practice_days` (`COUNT(DISTINCT session_id/86400)`), plus a shared `query_two_i64` helper. 3 new tests (store now 8).
- Progress panel in `main.odin` (`drill_draw_progress`), toggled with `P`; shows practice days, totals, a naive recent-20 vs overall trend (improving/steady/dipping/warming up), and per-degree accuracy bars from `degree_stats`. Drill keeps updating underneath; panel is read-only.
- **`--progresscheck` PASS:** seeded 5 trials across two day-buckets → `overall=2/5, practice_days=2, recent2=0/2`, all as expected. No audio needed (pure store).
- 70 unit tests across 8 packages; live GUI toggles the panel cleanly.

## Notes

- "Am I improving" is intentionally naive (recent-N vs overall); the spec (§12.2) says instrument first and decide the real progression model from data. This just surfaces the numbers.
- This is the only Epic 4 story that is code; Story 4.2 is three weeks of actual daily use (the real M3 gate) and needs the hardware + the user.
