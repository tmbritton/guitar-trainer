# Epic 6 / Story 6.17 — Run in a window (drop forced fullscreen)

**Goal:** `run_app` forced borderless fullscreen and hid the cursor at startup.
That took over the whole machine — untenable once a batch import can run for
hours on a worker thread you only need to glance at. Fullscreen is no longer a
design goal: run in an ordinary window and let the window manager do fullscreen,
which it already does well.

**Key idea:** Nothing about the rendering needed to change. Every screen is drawn
into a fixed 800x480 render texture, and `blit_fit` scales and letterboxes it to
the current window size each frame — so arbitrary window sizes already worked.
The story is almost entirely about *removing* the two calls that opted out of it.

## What changed

- **`src/app.odin`** — dropped `rl.ToggleBorderlessWindowed()` and
  `rl.HideCursor()`; added `rl.SetConfigFlags({.WINDOW_RESIZABLE})` **before**
  `rl.InitWindow` and `rl.SetWindowMinSize(WINDOW_W/2, WINDOW_H/2)` after it.
- **`src/screenshot.odin`** — the `fullscreen` capture case had its own inline
  2-frame warm-up loop and so produced an all-black PNG; raised to 8 to match
  `shot_frame`.
- **`README.md`** — "Fullscreen and distraction-free" is no longer claimed as a
  goal; it now says the app runs in a window and points at the window manager.

## Steps

- [x] **Step 1:** remove the forced-fullscreen and cursor-hiding calls.
- [x] **Step 2:** resizable flag before `InitWindow`; minimum window size.
- [x] **Step 3:** de-goal fullscreen in the README.
- [x] **Step 4:** verify the letterbox path still renders at a non-native size.

## Verification

- `./build.sh`, `./test.sh` (16 packages), and `--importcheck` / `--queuecheck` /
  `--loopcheck` / `--playercheck` / `--monitorcheck` all pass.
- `--screenshot fullscreen` renders the 800x480 scene into a 1280x600 window with
  correct black side bars — the same `blit_fit` path any resized window uses.
- Actually dragging/resizing the window is a manual check (needs the GUI).

## Notes / risks

- `SetConfigFlags` is a no-op after `InitWindow`, so the ordering here is
  load-bearing, not stylistic.
- `HideCursor` had to go with the fullscreen call, not stay: a hidden pointer in
  a window makes it impossible to move, resize, or reach another application.
- The minimum size exists because the scene is a fixed 800x480 — scaled much
  below half, the pixel font stops being readable.
- The screenshot case named "fullscreen" now just exercises letterboxing at a
  non-native size; the name is historical.
