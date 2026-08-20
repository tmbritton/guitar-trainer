# Epic 6 / Story 6.15 — Bound the temp allocator

**Goal:** Nothing in `src/*.odin` ever called `free_all(context.temp_allocator)`.
Odin's default temp allocator is a *growing arena* — it never reclaims until
something frees it — so every `fmt.ctprintf` in draw code and every path joined
while walking a folder accumulated for the life of the process. Two concrete
consequences:

- **Per frame.** The draw path formats a dozen strings a frame at 60 fps. Small,
  but strictly monotonic: leave the app open and it grows forever.
- **Per import expansion.** `queue_expand` reads a directory listing *and* joins
  a path per entry, recursively. Marking a large NAS folder walks tens of
  thousands of entries in one call, and none of that was reclaimed — the worst
  case is bounded only by the size of the share.

**Key idea:** the two need *different* fixes, and conflating them breaks things.

The frame loop can simply `free_all` at the top of each iteration, because every
piece of state that outlives a frame (`Browser.entries`, `Library_View`'s songs,
`Song.meta`) is already cloned into the heap allocator — verified, not assumed;
see the test below.

`queue_expand` **cannot** `free_all`, because it recurses: a nested call would
free the parent's still-live directory listing out from under it. It needs a
*scoped* reclaim instead — `runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD`, which
snapshots the arena watermark on entry and restores it on scope exit. Nested
scopes then unwind correctly, and peak temp usage falls from "the whole tree" to
"one path from the root", i.e. O(depth) rather than O(files).

## What changed

- **`src/app.odin`** — `free_all(context.temp_allocator)` at the top of the
  `run_app` frame loop, before any screen update or draw.
- **`src/importqueue.odin`** — `runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()` in
  both `collect_audio` (per directory, so the walk is O(depth)) and
  `queue_expand` (so the whole expansion leaves nothing behind).
- **`src/audio.odin`** — the callback set `context.allocator` to the guard but
  left `context.temp_allocator` as the audio thread's own arena, so a stray
  *temp* allocation on the audio thread would have been invisible to the guard
  that exists to catch exactly that. Now both are set.
- **`src/selftests.odin` / `src/main.odin`** — new `--tempcheck`.

## Steps

- [x] **Step 1 (test first):** `--tempcheck` asserts (a) repeated `queue_expand`
      calls do not grow the temp arena, (b) library/browser state survives a
      `free_all(context.temp_allocator)`, (c) `frame_begin` reclaims. (a) was
      confirmed failing on the pre-fix build (41 KB retained per expansion);
      (c) fails if the reset is deleted from `frame_begin`.
- [x] **Step 2:** scope the temp arena in `collect_audio` / `queue_expand`.
- [x] **Step 3:** per-frame `free_all` in `run_app`.
- [x] **Step 4:** guard the callback's temp allocator too.
- [x] **Step 5:** re-run the full suite, including `--audiocheck` on a `-debug`
      build so the callback allocation guard is live.

## Verification

- `--tempcheck` fails before the fix and passes after (numbers in the notes).
- `./test.sh` (16 packages) and every `--*check` still pass.
- `./build.sh -debug && ./guitar-trainer --audiocheck` — the guard allocator is
  installed on both `allocator` and `temp_allocator` and does not fire.

### Review follow-ups

The first version of (c) was **vacuous**: it sampled usage immediately after a
`free_all`, where `total_used` is unconditionally 0, so the assertion was
`0 > 65536` and could never fail — and it drove a `free_all` written in the test
rather than the app's, so deleting the fix from `run_app` left it passing. Both
are fixed: `run_app`'s prologue is now the named `frame_begin`, which the test
calls, and usage is sampled at the end of a frame's allocations and compared
between an early and a late frame.

## Notes / risks

- The per-frame `free_all` is only safe because no UI state is temp-allocated.
  That is a real invariant this story now depends on, so `--tempcheck` asserts it
  directly rather than leaving it to review: it scans a seeded library, resets
  the temp allocator, and then reads the strings back.
- `DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD` is a no-op if `context.temp_allocator` has
  been swapped for something else — correct behaviour (it will not free an arena
  it does not own), and worth knowing if a caller ever runs `queue_expand` under
  a custom allocator. It is *also* a no-op for the first guarded scope on a
  thread whose arena has no block yet: `arena_temp_begin` captures a nil
  `curr_block` and `arena_temp_end` then skips the restore entirely. Harmless
  here (the main thread has been formatting strings for many frames before
  anyone can press `I`), but it means "the first scope on a thread reclaims
  nothing".
- Worker threads (import, render, player producer) each have their own temp
  arena; `free_all` on the main thread does not touch them. None of them format
  in a loop, so they are not a growth source today.
