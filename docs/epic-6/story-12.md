# Epic 6 / Story 6.12 — Import completion summary

**Goal:** Tell the user what an import actually did. Raised as "we need a success
message"; code review found the batch case was not merely quiet but **hung**.

**The bug:** `queue_poll` calls `import_reset()` as it retires the last song, so
`import_progress()` returns `Idle` on that very frame and never returns `Done`
again. The screen's condition was
`done := (st == .Done || st == .Error) && !queue_active()` — false forever after.
Result: 0% progress bar, "separating stems — this can take a while", blank title
(a batch clears `import_name`), the "N failed" count gone (it was gated on
`queue_active()`), ENTER dead. Only ESC escaped, and it read as a crash.

**Key idea:** Completion is a fact about the *queue*, not something to infer from
the per-song importer state the queue itself resets. Latch it.

## What changed

- **`src/importqueue.odin`** — `finished` (latched), `started`/`elapsed`,
  `failures` (owned, cloned names); `current` copied into `current_buf` instead
  of being a view into the array entry it pops; `queue_finished`,
  `queue_is_batch`, `queue_summary`.
- **`src/app.odin`** —
  `done := queue_is_batch() ? queue_finished() : (st == .Done || st == .Error)`.
- **`src/import_view.odin`** — `importing_draw_summary`: "N songs added", elapsed,
  failures named (capped at 4 + "and N more"); footer advertises ENTER once
  finished, which always worked but was never shown.
- **`src/screenshot.odin`** — `--screenshot importdone`.

## Verification

- `--queuecheck` extended: asserts `queue_finished()` / `queue_is_batch()` latch
  and that the summary reports 4 added / 0 failed / 0 named with a non-zero
  elapsed. This is the regression guard for the hang.
- Screenshot `gt_import_done.png`: "IMPORT FINISHED · 11 songs added to your
  library · in 11m 24s · 1 failed · 09 Corrupted Track.mp3".

## Notes / risks

- `current` **must** be a copy. It was readable before only because
  `queue_begin_next` leaked the popped strings; freeing them (Story 6.14) without
  copying would have left `importing_draw` rendering a dangling slice every frame.
- Every `failures` entry is heap-owned, since `queue_reset` frees them — the
  screenshot seed initially appended a string *literal* and aborted with
  `free(): invalid pointer` on exit.
