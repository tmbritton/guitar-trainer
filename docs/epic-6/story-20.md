# Epic 6 / Story 6.20 — SPACE restarts a finished song

**Goal:** when a song reaches the end the player sits on PAUSED and SPACE does
nothing at all.

**Cause:** the producer's end-of-song branch (`player.odin`, `if cursor >=
g_player_song.frames`) stores `g_player_playing = 0` and leaves the cursor parked
at `frames`. `player_toggle` flips the flag back to 1, but the producer's very
next iteration hits the same branch and stores 0 again. So it is a **true no-op**
— the flag really does flicker on and straight back off — not a slow or partial
response.

**Key idea:** the fix belongs on the UI side, not in the producer. "Playing from
the end means starting over" is a transport decision, and putting it in
`player_toggle` keeps the producer's end-of-song branch doing exactly one thing
(stop). `player_restart` seeks to 0 and plays; `player_toggle` calls it when the
song is finished instead of flipping a flag that cannot stick.

**Where restarting goes:** to the armed section's start when one is armed *and
playable*, else to the top of the song.

The first draft restarted unconditionally to 0, on the claim that "the end is
unreachable while a loop is armed". **That claim is false**, and review caught it.
The producer clamps loop *B* to `frames` but not loop *A*, so a span starting at
or past the end makes `loop_b - loop_a` negative, `looping` false — and the song
runs to its end with `loop_on` still true. That is reachable: `sections.txt` is
hand-editable, and `sections.valid` cannot check a span against a song length the
pure package doesn't know. A section saved against a longer file that was later
replaced at the same source path does it too, since the library folder hash is
over the *path*.

So the code now asks the real question instead of asserting an invariant.
`loop_span` is the single definition of "a loop the producer will actually play",
used by both the producer and `player_restart` — and restarting to a *playable* A
is what keeps an unplayable armed span from sending the restart straight back to
the end, i.e. a dead restart key for the second time.

## What changed

- **`src/player.odin`** — `player_finished()` (not playing, cursor at or past the
  end), `player_restart()`, and `loop_span()` — one definition of a playable
  loop, shared with the producer. `player_toggle` restarts rather than toggling
  when finished. The producer's end branch now bails when a seek is pending, and
  `player_close` forgets the song.
- **`src/player_view.odin`** — a finished song reads `ENDED  SPACE restarts`
  rather than `|| PAUSED`, which was indistinguishable from a normal pause.
- **`src/selftests.odin` / `src/main.odin`** — new `--endcheck`.

## Steps

- [x] **Step 1 (test first):** `--endcheck` plays a short synthetic song to the
      end, asserts it stops there and reports finished, then asserts SPACE both
      resumes playback *and* brings the cursor back to the start. Confirmed
      failing before the fix.
- [x] **Step 2:** `player_finished` / `player_restart`, wired into `player_toggle`.
- [x] **Step 3:** the transport readout stops lying about why it is stopped.

## Verification

- `--endcheck` fails before the fix and passes after.
- `./test.sh` and every other `--*check` still pass; `--loopcheck` in particular,
  since it exercises the branch just above the one being changed.

### Review follow-ups

- **A real race, reproduced.** `player_restart` publishes two independent stores
  (the seek, then the play flag) and the producer reads them at two separate
  points. Interleave them as "producer reads seek (none) → restart publishes both
  → producer reads playing (yes) → producer falls through to the end branch" and
  it stores `playing = 0` on top of the restart: the song rewinds to 0:00 and
  sits there **paused**. That is worse than the dead key it replaced, because
  `finished` is then false, so the transport just reads PAUSED with nothing
  explaining it. Fixed by bailing out of the end branch while a seek is pending —
  `continue`, not fall-through, since `frames - cursor` is <= 0 there and a
  negative block length is a panic. Verified by widening the window with a 2 ms
  sleep between the producer's two loads: **15/15 runs fail without the guard,
  0/15 with it**, and the failure prints `cursor 0 ... playing false`, which is
  the clobber rather than a generic timeout.
- **The invariant was false** — see above.
- **Test quality.** A `player_playing()` assertion placed immediately after
  `player_toggle()` was dead: it read the flag nanoseconds after the UI set it,
  before the producer could act, so it could only ever pass. Removed, with the
  reason written down. The restart deadline dropped from 30 s to 3 s — the
  producer settles within one 5 ms iteration, so 30 s only made a certain failure
  slow. And the mid-song resume assertion did not prove resumption: after the
  drain loop stops, the ring is full and the cursor legitimately sits still, so
  it now drains until the cursor actually advances.

## Notes / risks

- `player_restart` is deliberately not "seek to 0 and leave paused" — the only
  caller is the play key, and a play key that leaves you paused is its own bug.
- The end-of-song branch still stores `playing = 0`. That is correct: the song
  should stop at the end. What changes is only what *starting again* means — and
  that it declines to stop a song already on its way somewhere else.
- `player_restart` does not flush the PCM ring, so up to ~341 ms of the old
  song's tail plays over the start of the restarted one. Ordinary seeks have
  always behaved this way, and flushing from the UI thread would break the ring's
  single-producer discipline — but ENDED makes the moment more noticeable than a
  mid-song scrub did.
