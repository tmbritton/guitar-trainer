# Epic 6 / Story 6.18 — Song loading must not block the UI

**Goal:** Selecting a song froze the app for ~2 s before the player appeared,
which reads as a hang rather than as work.

**Cause (measured, not guessed):** `app.odin` called `stems_load(s.dir)`
*synchronously on the main thread* inside the Library screen's ENTER handler,
and only set `screen = .Player` once all six stems had decoded. Nothing could
redraw meanwhile, so the last Library frame stayed on screen with no indication
anything was happening.

Timed with `--stemcheck` on a real 380-second song (41 MB of mono FLAC):

```
./guitar-trainer --stemcheck .../01-black-sabbath
2.08s user  0.21s system  99% cpu  2.308 total
```

**99% of a single CPU on a 12-core machine.** It is also not the mono-FLAC
change from Story 6.10 — the one remaining WAV song takes 1.9 s, so the codec is
nearly free. The cost is decoding and resampling six files to mono f32 @ 48 kHz.

**Key idea:** two independent fixes, and the second is what actually removes the
wait. Getting the decode off the main thread makes the app *honest* (it can draw
a loading state); decoding the six stems *in parallel* makes it *fast*, because
they are six independent files and eleven cores were sitting idle.

## What changed

- **`src/stemload.odin`** (new) — an async stem loader. `stems_load_begin` spawns
  one worker per stem; each decodes its own file and publishes completion with an
  atomic. The main thread polls `stems_load_poll()` and takes the finished
  `Song_Audio` with `stems_load_take()`. Follows the existing worker idiom
  (`render.odin`, `import.odin`, `player.odin`): workers publish through atomics,
  the main thread polls, no locks.
- **`src/app.odin`** — ENTER on a song starts the load and switches to a new
  `.Loading` screen immediately; the frame loop polls and enters `.Player` when
  the stems are ready. ESC during the load cancels.
- **`src/import_view.odin`** — `loading_draw`: the song title and a "N / 6 stems"
  progress bar.
- **`src/selftests.odin` / `src/main.odin`** — new `--loadcheck`.

## Cancellation, and why it is not a join

ESC during a load must not block either — on a network-backed library a single
stem decode can take seconds, and joining the workers on the main thread would
reintroduce exactly the freeze this story removes.

Instead the job is **orphaned**: the main thread marks it cancelled and returns
to the Library immediately, and the *last worker to finish* frees the partial
PCM and the job. Nothing is leaked and nothing blocks. The load slot stays busy
until that happens, so `stems_load_begin` refuses a new load for those few
frames — a cancel followed within ~400 ms by opening another song ignores the
keypress rather than starting a second decode. That is deliberate: it is also
what keeps peak memory to one song.

## Memory

A decoded song is **~340 MB** resident (6 mono f32 stems @ 48 kHz for 5 minutes).
That rules out preloading or keeping several songs in memory, and it is why the
loader is a single global that permits exactly one job at a time: if a new song
began decoding while the previous one was still resident, peak would double.

## Steps

- [x] **Step 1 (test first):** `--loadcheck` asserts the async loader returns the
      same PCM as the synchronous path, that `stems_load_begin` returns in a
      fraction of the decode time, and that a cancelled load drains *and frees*.
- [x] **Step 2:** the loader (`stemload.odin`), one worker per stem.
- [x] **Step 3:** `.Loading` screen + router wiring; ESC cancels.
- [x] **Step 4:** measure before/after on a real song.

## Verification

- `--loadcheck` passes; `./test.sh` (16 packages) and every other `--*check`
  still pass.
- Before: 2.31 s of frozen UI. After: the player appears immediately and the
  stems are ready in well under a second (numbers in the plan.md entry).
- `-debug` `--audiocheck` / `--playercheck`: the audio-thread allocation guard
  still reports 0 attempts.

### Review follow-ups

The concurrency held up — every path to `.Idle` joins first, so a worker can
never write into a `Song_Audio` the main thread has freed or reused. Four things
did need fixing:

- **The speed assertion was flaky.** `--loadcheck` asserted "parallel beat
  sequential", which on synthetic WAV has only ~10 ms of margin — and the
  sequential run warms the page cache for the parallel one, so it was not even a
  fair comparison. It failed 1 in 6 under load. Wall clock is now reported and
  never asserted; the real assertion is that `stems_load_begin` returns in a
  fraction of the decode time (0.4 ms against 25 ms), which is what "does not
  block" actually means.
- **ENTER was silently swallowed** for the whole drain window after a cancel,
  because `stems_load_begin` refuses while `.Cancelling` and nothing handled the
  `false`. Worst precisely on the network share the non-join was designed for.
  Now a **pending open** is latched and retried each frame, with the screen
  saying "finishing the previous song".
- **A failed thread spawn wedged the loader permanently.** `remaining` is
  pre-set to six, so a `nil` from `create_and_start` meant one decrement never
  arrived — `.Loading` forever, and every later `stems_load_begin` refused, so no
  song could be opened again for the life of the process. Now the spawn failure
  decrements.
- **The view drove the state machine.** `loading_draw` called `stems_load_poll`,
  which joins threads and frees memory, from a file CLAUDE.md calls a pure view —
  and the screenshot path depended on that side effect to advance at all. Added a
  read-only `stems_load_state()`.

## Notes / risks

- Six threads for six files is not obviously the fastest split — at some point
  the disk, not the CPU, is the limit, and on a network-backed library it will be.
  It is the right shape anyway: the work is embarrassingly parallel, and the
  loading state exists precisely for the case where I/O dominates.
- `stems_load_take` transfers ownership to the caller, which then frees with
  `stems_free` exactly as before, so the player and the screenshot path are
  unchanged.
- The progress bar counts stems *attempted*, not decoded, so a song missing a
  stem still reaches 6 / 6 instead of stalling at 5 / 6 and jumping to the player.
