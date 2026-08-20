# Epic 6 / Story 6.16 — Saved riff sections (practice a passage)

**Goal:** Story 6.7 already loops a span — `L` cycles mark-A → mark-B → clear and
the producer wraps at B. What was missing is everything *around* it. The loop is
explicitly transient (`player_open` calls `player_loop_clear()`, and nothing in
`songprefs.odin` stores it), so the passage you set up vanishes the moment you
leave the song, and there is only ever one anonymous region.

**Key idea:** the loop machinery does not change at all. What this story adds is
*identity* (a name), *persistence* (it survives leaving the song), *plurality*
(more than one passage per song), and *feedback while drilling* (how many passes,
and an optional nudge upward in tempo). Everything new that can be pure is pure:
the `sections` package does parsing, serializing and the ladder arithmetic, and
knows nothing about the player.

## What changed

- **`src/sections/`** (new pure package, 11 tests) — `Section {name, a, b, speed,
  ladder}`, a line format, allocation-free `parse` (names are subslices, as in
  `songlib.parse_meta`), `format`, and `ladder_speed`.
- **`src/sections.odin`** — the I/O shell: load/save `library/<song>/sections.txt`,
  cloning names off the parse buffer.
- **`src/player.odin`** — a pass counter incremented by the producer when it wraps
  at B; `player_loop_set(a, b)` to arm a span directly; optional pre-roll.
- **`src/player_view.odin`** — the section list, markers for every section on the
  seek bar (not just the armed pair), the pass counter, and the ladder state.
- **`src/app.odin`** — player keys: `N` arm next section, `R` save the current A-B
  span as a named section, `K` toggle the ladder, `T` toggle pre-roll; plus a
  name-entry mode.
- **`src/selftests.odin` / `src/main.odin`** — `--sectioncheck`.

## Two judgement calls worth flagging

**1. A sibling `sections.txt`, not an extension of `mixer.txt`.** The plan
allowed either. `mixer.txt` is a fixed-shape record (six stem lines + one rig
line) parsed positionally; sections are a variable-length list. Mixing them would
mean the stem parser has to skip unknown leading keywords, and a corrupt section
line could cost you your mixer. Separate files fail independently.

**2. The count-in is a musical pre-roll, not a click track.** The plan asked for
"a count-in before each pass". The app has **no tempo information** for an
imported song — nothing in the import pipeline extracts one — so a click count-in
could only run at an arbitrary rate with no relationship to the music, which for
a *timing* exercise is worse than nothing. Instead, arming a pre-roll wraps to
`A - preroll` rather than `A`: you hear a run-up of the actual track before the
passage, which is what a loop pedal or a DAW's pre-roll does and needs no tempo.
If a real click count-in is wanted later, it needs tempo detection first, which
is its own story.

## The ladder

Off unless switched on per section. `ladder_speed(start, passes)` is a **pure
function of the starting speed and the number of completed passes**, not a value
that accumulates a step at a time — an accumulating float would drift, and arming
the same section twice could land on a different tempo. It moves toward 1.0 and
stops there, so a passage slowed to 0.6 climbs and one pushed to 1.25 descends.

**A manual `[`/`]` while the ladder is running takes over**: the ladder switches
off for that arming and the speed you chose stands. The ladder must never fight
the user for control of the tempo — you can hear whether you are ready and it
cannot.

## Steps

- [x] **Step 1 (test first):** the `sections` package tests — round-trip, bad
      lines skipped, names normalized, speed clamped, ladder converges on 1.0
      from both directions and is not cumulative.
- [x] **Step 2:** persistence shell + player pass counter and `player_loop_set`.
- [x] **Step 3:** UI — list, markers, counter, keys, name entry.
- [x] **Step 4:** `--sectioncheck` over the real producer.

## Verification

- `./test.sh` — `sections` joins the unit-tested packages.
- `--sectioncheck` — a section round-trips through the library, arming one sets
  the loop span and restores its speed, the pass counter advances as the producer
  wraps, and the ladder advances **only** when it is switched on.
- `--loopcheck` still passes: the A-B mechanism itself is untouched.

### Review follow-ups

The concurrency and memory sides came back clean (`break` inside the modal
correctly exits the switch, not the frame loop — verified with a minimal Odin
program; names are cloned off the temp buffer and freed exactly once). Six things
did need fixing:

- **`L` while a section was armed desynced everything.** It clears the loop but
  left `armed` set, so the HUD kept naming a section that was no longer playing
  *and* the ladder recomputed from the pass counter `L` had just reset — audibly
  yanking the tempo back down. `L` now disarms first.
- **A seek past B credited a pass you never played.** Scrubbing with the arrow
  keys, or arming a section from beyond it, lands in the producer's wrap branch.
  The producer now tracks a `jumped` flag — cleared only once audio has actually
  been produced from the new position — and skips the increment. It has to
  persist across iterations, not be per-iteration: a seek taken *while paused* is
  applied on one iteration and the wrap it causes is not seen until a later one.
- **A whitespace-only name was accepted and then silently vanished.** `format`
  stripped it to nothing and `parse` dropped the line on reload, with no error
  anywhere (`sections_save`'s return was ignored at every call site). `valid` now
  requires a name with a visible character, the entry point trims and refuses,
  and a failed save reports.
- **A 1-frame section could be persisted, and armed at speed ≠ 1.0 it spun a
  core.** `player_loop_mark` deliberately makes a 1-frame span when both marks
  land on one cursor — pressing `L` twice while paused. The producer would feed
  one frame to the stretcher, wrap, clear it, produce nothing, and so never reach
  any of its sleeps. `MIN_FRAMES` (0.1 s) now gates persistence, and the producer
  refuses to loop on a span shorter than a block.
- **There was no section list**, only markers and a count, so `N` cycled blind.
  Now every saved name is listed with the armed one lit, and unarmed markers are
  gold rather than a dim that vanished against the meter.
- **Silent keys now say why.** `R` with no loop, `R` when the span is already
  saved, `N` with no sections, `DELETE` with nothing armed — each posts a line
  instead of feeling dropped. Also: closing the window with the WM used to lose
  the session's mixer, rig and sections, because that path skips the ESC handler.

Separately, I found `--sectioncheck` flaky myself (1 failure in 15, then 3 in 200
with the message visible): the pre-roll assertion sampled the cursor only on
successful ring reads, and a 12,000-frame pre-roll observed in 4,096-frame chunks
gives about three samples inside the run-up. It now samples in 512-frame reads
over a half-second pre-roll and tracks the minimum cursor, with wall-clock rather
than iteration bounds. 450 clean runs after, plus 40 under 30 CPU spinners.

The seek-credit test also had to be fixed twice: the first version exited its
drain loop before the wrap had even happened, so it passed with the fix removed.
It now waits to observe the wrap before judging the counter, and fails as it
should when the guard is neutered.

## Notes / risks

- Sections are stored in **input frames**, like the loop points and the transport
  cursor, so they are speed-independent — a section saved at 0.6x arms to the
  same musical span at 1.0x.
- `MAX` caps a song at 16 sections, which keeps parsing allocation-free.
