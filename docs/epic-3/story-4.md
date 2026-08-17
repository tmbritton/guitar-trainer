# Epic 3 / Story 3.4 — SQLite Trial Log

**Goal:** Persist every trial to a single SQLite file via C bindings. One `trials` table (spec §9.6). Everything else (spacing, ladder levels, progress) is derivable from this log — resist adding tables.

**Files:**
- Create: `store/store.odin` (`package store`) — minimal `foreign import` sqlite3 bindings + open/migrate/insert.
- Create: `store/store_test.odin` — open a temp DB, insert, read back.

**Environment:** no Odin sqlite binding exists. Homebrew provides `libsqlite3.{a,so}` + `sqlite3.h` at `/home/linuxbrew/.linuxbrew`, and the `sqlite3` CLI for verification. The linker already searches that path (`build.sh`), so add `-lsqlite3`.

**Constraints in play:**
- Single SQLite file; one table only. Schema exactly:
  `trials(id INTEGER PRIMARY KEY, ts INTEGER, key INTEGER, target_degree INTEGER, target_midi INTEGER, detected_midi INTEGER, onset_offset_samples INTEGER, correct INTEGER, response_ms INTEGER, session_id INTEGER)`.
- Prepared statements for inserts (no string-built SQL). Store is main-thread only — never touched from the audio callback.

**Interfaces (Produces):**
- Bindings (subset): `sqlite3_open`, `sqlite3_close`, `sqlite3_exec`, `sqlite3_prepare_v2`, `sqlite3_bind_int64`, `sqlite3_step`, `sqlite3_reset`, `sqlite3_finalize`, `sqlite3_errmsg`. `SQLITE_OK/ROW/DONE` constants.
- `Store :: struct { db: ^sqlite3, insert_stmt: ^sqlite3_stmt }`
- `open :: proc(path: cstring) -> (Store, bool)` — opens, runs the `CREATE TABLE IF NOT EXISTS`, prepares the insert.
- `Trial_Row :: struct { ts, key, target_degree, target_midi, detected_midi, onset_offset_samples: i64, correct: bool, response_ms, session_id: i64 }`
- `insert_trial :: proc(s: ^Store, row: Trial_Row) -> bool`
- `count_trials :: proc(s: ^Store) -> i64` (test/diagnostic helper via a prepared/one-off query).
- `close :: proc(s: ^Store)`

## Steps (TDD)

- [ ] **Step 1:** write the `foreign import sqlite3 "system:sqlite3"` bindings (opaque `sqlite3`/`sqlite3_stmt` structs, the procs above).
- [ ] **Step 2 (RED):** test — `open` a temp path (`/tmp/.../gt_test.db`), `count_trials == 0`.
- [ ] **Step 3 (GREEN):** implement `open` (create table), `count_trials`, `close`. Ensure `test.sh`/`odin test store` links `-lsqlite3` — add a `#+build` note or a `@(extra_linker_flags)` on the foreign block if needed, else document a `store` test invocation. Verify link.
- [ ] **Step 4 (RED):** insert one `Trial_Row`, `count_trials == 1`.
- [ ] **Step 5 (GREEN):** implement `insert_trial` (bind all columns, step, reset).
- [ ] **Step 6 (RED):** insert 3 rows across two calls → `count_trials == 3`; reopen the same file → still 3 (persistence).
- [ ] **Step 7:** `odin test store` green. Cross-check with the `sqlite3` CLI: `sqlite3 <file> 'select count(*) from trials'`.

## Verification

`odin test store` green: table created, rows inserted, counts correct, data persists across reopen. `sqlite3` CLI confirms the row count independently.

## Findings (implementation)

- **Bindings:** `foreign import sqlite "system:sqlite3"` with `@(default_calling_convention="c")`; opaque `sqlite3`/`sqlite3_stmt` structs. Only 10 entry points bound. `test.sh` now passes the Homebrew `-L`/rpath to every `odin test` (harmless for pure packages) so `store` links `-lsqlite3`.
- **SQLite lock gotcha:** an insert statement stepped to `DONE` but not `reset` keeps its lock, so the *next* query (count) got `BUSY` and returned my `-1` sentinel. Fix: `sqlite3_reset` immediately after `sqlite3_step` in `insert_trial`.
- **Parallel-test path collision:** Odin's test runner seeds every test's RNG with the *same* value, so `rand.int63()` produced identical temp filenames across the parallel tests → they hammered one shared DB (flaky BUSY / lost writes). Fix: a process-global atomic counter + pid for unique temp paths. Green across repeated runs.
- **Independent cross-check:** `--storecheck` writes 2 rows; `sqlite3` CLI reports `2|1|60,62` and the schema matches spec §9.6 exactly.

## Notes

- `odin test` needs the sqlite lib at link time. `test.sh` supplies the Homebrew `-L`/rpath for all packages.
- Wiring the drill to actually write rows (session_id, response_ms, onset offset) happens in Story 3.6 when the loop is interactive; this story is just the storage layer + its tests.
