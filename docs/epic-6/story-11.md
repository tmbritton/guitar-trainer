# Epic 6 / Story 6.11 — Browse anywhere + batch album import

**Goal:** Import wasn't limited to `~/Music` in principle — `browser_up` walks to
`/` — but reaching a media library on a NAS meant six keypresses up and a long
walk back down. And each song had to be picked one at a time. Make arbitrary
locations reachable, and let a set of albums be imported in one run.

**Key idea:** Two separable pieces. *Reaching* a location is a navigation
problem (a jump list built from real mounts, plus a path field). *Importing many*
is a queue problem: expand marked folders into a file list, then drive the
existing single-file importer sequentially.

## What changed

- **`src/places/`** (new pure pkg) — `parse_line` (a `/proc/mounts` line),
  `is_interesting` (media-bearing mount points only), `is_automount`, `unescape`
  (octal `\040` escapes), `label` (last path component).
- **`src/placelist.odin`** (new) — I/O shell: Home, Music, and every interesting
  mount, de-duped by path, rebuilt each time the panel opens so a share mounted
  since launch appears.
- **`src/importqueue.odin`** (new) — `queue_expand` (recursive, depth-capped),
  `queue_start`, `queue_poll`, `queue_cancel`, `queue_status`.
- **`src/import_view.odin`** — `Browse_Mode` (Browse / Places / Path); marking
  (`browser_toggle_mark`, `browser_is_marked`, `browser_clear_marks`,
  `browser_mark_count`); path entry; three-mode `browser_draw`; batch progress in
  `importing_draw`.
- **`src/app.odin`** — per-mode key handling; `I` starts a run.
- **`src/selftests.odin` / `src/main.odin`** — `--queuecheck`.

## Controls

`P` places · `L` path (typing or CTRL+V) · `SPACE` mark · `I` import marked ·
`C` clear · `BACKSPACE` up · `ENTER` open/import one.

A marked **folder** means everything under it — that is how an album or a whole
artist gets picked.

## Steps

- [x] **Step 1:** `places` pkg + 7 unit tests; registered in `test.sh`.
- [x] **Step 2:** `places_list` I/O shell.
- [x] **Step 3:** browser modes, marking, path entry, drawing.
- [x] **Step 4:** `importqueue.odin`; key handling.
- [x] **Step 5:** `--queuecheck`, incl. driving a 3-song stub run to completion.

## Verification

- 7 `places` tests; `--queuecheck` PASS — recursive expansion (3 files found,
  non-audio ignored), already-imported skipping, path ordering, single-file
  marking, and a 3-song stub run driven to completion with all three landing in
  the library.
- Screenshots: the Places panel lists **Home, Music, RAID, Backups** (the real
  CIFS share); the marked browser shows `*` bullets and `2 marked  I import
  C clear`.

## Notes / risks

- **autofs is the important finding.** An idle automounted NAS share appears in
  `/proc/mounts` **only** as an `autofs` entry — the CIFS/NFS mount exists just
  while something holds it open. The first filter skipped autofs as "noise" and
  so hid exactly the shares Places exists to reach, whenever they were idle.
  Corollary: such paths must **not** be `stat`ed to test liveness, because on a
  direct automount that triggers the mount and blocks the UI until an unreachable
  server times out — hence `add(..., verify = !is_automount(...))`.
- The queue is **sequential on purpose**: Demucs holds one model on the GPU, so
  concurrent separations contend and finish no sooner.
- `QUEUE_MAX_DEPTH` exists to stop a symlink cycle on a network share from
  walking forever.
- Storage/compute at scale, measured: the source library here is 1728 files;
  at ~39 MB and ~60 s per song that is ~67 GB and many hours — which is why the
  design settled on *selecting* albums rather than importing everything.
- **Known defects (code review, tracked as Story 6.14):** filename-only slugs
  collide so same-named tracks in different albums overwrite each other
  (confirmed by experiment — one song silently lost); overlapping marks queue
  files twice; the separator paths are still cwd-relative; `queue_begin_next`
  leaks the popped strings, and `g_queue.current` is only readable *because* of
  that leak; `I` is a silent no-op when everything marked is already imported.
  Plus Story 6.12 — the Importing screen hangs after a batch finishes.
