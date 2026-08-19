# Epic 6 / Story 6.1 — Menu / screen router

**Goal:** The app is outgrowing a single screen. Turn `run_app` into a keyboard-
driven **screen router** with a Main Menu; move the drill and the tone/cab/
calibration controls into their own screens. Foundation for the play-along.

**Files:**
- Create: `menu.odin` (`package main`) — `Screen` enum, a small `Menu` list
  widget (items + selection), pure `menu_move`/`menu_wrap` (unit-testable), and
  `menu_draw` using `ui.odin`.
- Modify: `main.odin` — `run_app` hosts the router: per-screen update + draw into
  the existing fullscreen render texture. Move the tone keys (F/V/B/I/N/A) and
  calibration (C) into a **Settings** screen; the drill becomes a **Drill**
  screen.

**Screens:** `Main_Menu`, `Drill`, `Settings`, `Library` (stub), `Import` (stub).
Main Menu items → Play a Song (Library), Import Song, Practice Drill, Settings,
Quit. `↑/↓` move, `Enter` activate, `Esc` back to Main Menu (Esc on Main Menu
quits).

**Constraints:** reuse the fullscreen render-texture/letterbox path and `ui.odin`
kit; keep the drill's audio/rig/worker lifecycle (`drill_init`/`drill_destroy`)
once around the whole app — only call `drill_update` while on the Drill screen.
Nothing deleted; the drill still fully works.

## Steps

- [ ] **Step 1 (RED):** unit-test the pure menu navigation — `menu_move(sel, n,
  delta)` wraps (0 → up wraps to n-1; n-1 → down wraps to 0; clamps to range).
- [ ] **Step 2 (GREEN):** implement `menu_move` + the `Menu`/`Screen` types.
- [ ] **Step 3:** `menu_draw` — title + vertical item list, selected item
  highlighted (ui panel/capsule styling), a footer hint.
- [ ] **Step 4:** refactor `run_app` into the router: a `g_screen` state; each
  frame dispatch update+draw for the current screen; `Esc` handling.
- [ ] **Step 5:** Settings screen — draw the current TONE/rig line and handle
  F/V/B/I/N/A (gated on `!render_busy()`) + C (calibrate). Drill screen — the
  existing `drill_update`/`drill_draw` (drop its inline tone/calib keys, now in
  Settings). Library/Import — a "coming soon" stub with `Esc` back.
- [ ] **Step 6:** extend `--screenshot` with `menu` / `settings` targets; verify.
- [ ] **Step 7:** `./test.sh` green; build; GUI smoke (menu navigates, drill
  reachable, no hang).

## Verification

`odin test menu`-style nav test green (folded into an existing pkg or a `menu`
check). Screenshots show the Main Menu, the Drill screen, and Settings. Live GUI
navigates Menu ↔ Drill ↔ Settings without hanging; existing self-tests unaffected
(the headless `--*check` modes don't use `run_app`).
