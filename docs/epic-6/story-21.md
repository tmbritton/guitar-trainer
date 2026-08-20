# Epic 6 / Story 6.21 — Remove Practice Drill from the main menu

**Goal:** the stem play-along is the project now. Playing along with real songs
turned out to be far more fun than drilling scale degrees, so the drill is no
longer something to offer on the way in.

**Key idea: remove the door, not the rooms.** The menu entry is one line and one
route. `drill.odin`, `drill_view.odin`, the `game` and `music` packages, the
`store` trial log and `render.odin`'s NAM path are a lot of working, tested
machinery, and five headless self-tests exercise them. Deleting all that to hide
one menu item would be trading a reversible decision for an irreversible one, and
`music` in particular is a general-purpose package nothing else should have to
lose. So: drop the entry, keep everything it pointed at, and keep it all green.

## What changed

- **`src/app.odin`** — `"Practice Drill"` out of `main_items`, its route out of
  the main-menu switch, and the file-header comment that named the drill as a
  menu destination.
- **`src/app.odin` (hardening)** — the menu switched on the raw index returned by
  `menu_input`, so removing an item silently shifted every later case: Settings
  was `case 3`, Quit `case 4`. Label and action now live in **one struct per row**
  (`Main_Entry`) at package scope, and the switch is on `.action`.
- **`src/screenshot.odin`** — a `menu` capture case, rendering the app's own
  `g_main_labels`.
- **`CLAUDE.md`** — the drill is described as parked rather than as a menu entry;
  the Status section stops implying the drill is the deliverable.
- **`plan.md`** — already updated when the decision was made (Story 4.2 and
  Epic 5 parked, Epic 6 marked as the product).

## What deliberately did NOT change

- `drill.odin`, `drill_view.odin`, `game/`, `music/`, `store/`, `render.odin`.
- `--drillcheck`, `--drillsim`, `--drillabandoncheck`, `--rigdrillcheck`,
  `--progresscheck` — all still wired and still passing. They are the proof the
  code is intact, and the reason putting the entry back is a one-line change.
- `drill_init`/`drill_destroy` in `run_app`. They are cheap, the `Drill` screen
  case and its draw case still compile and work, and leaving them means the
  feature is genuinely dormant rather than half-dismantled.

## Steps

- [x] **Step 1:** drop the menu item and its route.
- [x] **Step 2:** confirm every drill self-test still passes untouched — that is
      the actual acceptance criterion for "kept the code".
- [x] **Step 3:** update the comments and docs that still call the drill a menu
      destination.

## Verification

- `./test.sh` (17 packages, including `game`, `music`, `store` and `menu`)
  unchanged.
- **All five drill self-tests pass exactly as before** — `--drillcheck`,
  `--drillsim`, `--drillabandoncheck`, `--rigdrillcheck`, `--progresscheck`. This
  is the real acceptance criterion: it is what "kept the code" means.
- `--screenshot menu` before and after: five entries become four, with the drill
  gone and the rest in order.

### Review follow-ups

- **The screenshot was worthless as a regression check.** It built its own copy of
  the item list, so it would have gone on photographing four tidy entries after
  someone added a fifth to the real menu — the exact opposite of the job. The menu
  definition moved to package scope and the capture now renders `g_main_labels`.
- **The first hardening was not enough.** Parallel arrays plus
  `#assert(len(a) == len(b))` catches a *count* mismatch but not a *reordering*:
  swapping two labels alone still compiled, into a menu whose highlighted row
  opened something else. Pairing label and action in one struct fixes that.
- **"Restoring the entry is a one-line change" was wrong** and is corrected below.
- **The loose-end list was incomplete** — see the Settings note below, which is
  bigger than the drag-drop guard this story originally named.

## Notes / risks

- The real risk was an **off-by-one in the menu routes**, not the removal itself.
  What it is now, stated precisely: a wrong pairing is a **single visibly-wrong
  line** (`{"Quit", .Settings}`) rather than a silent mismatch between two arrays
  in different places, and a new action with no `case` is a compile error via
  switch exhaustiveness. It is *not* impossible to get wrong — you can still type
  the wrong action next to a label — so this is "hard to do by accident", not
  "unrepresentable".
- **Restoring the entry costs three edits, not one**: a row in `g_main_entries`, a
  member on `Main_Action`, and a `case` in the router. The hardening bought safety
  at the price of that claim, which is a good trade — but the claim had to go.
- The drag-drop handler's `if screen == .Drill do drill_abandon(&d)` guard becomes
  unreachable from the menu but stays correct, and would be needed again the
  moment the entry comes back.
- **Bigger loose end, deliberately left for Story 6.22:** the Settings screen still
  presents a rig and a calibration that nothing reachable consumes. `sf_render_seq`
  is called only from `render.odin` (drill) and `riff.odin`, and the calibration
  offset is read only by `drill.odin` — so `F`/`V`/`B`/`I`/`N`/`A` and `C` change a
  label while the play-along's monitor path (`ampchain`) is untouched by all of
  them. Press `N`, see "clean DI -> Laney GH100S -> cab Cab A", play a song, hear
  no difference. Same cause: startup still loads `electric.sf2` (9 MB),
  `clean.sf2` and a `.nam` for the parked drill, and `drill_init` still spawns a
  render worker that polls forever with no possible job. None of this is a
  regression from this story — it is the follow-up this story creates, and it
  belongs with the amps-and-cabs decision rather than being guessed at now.
