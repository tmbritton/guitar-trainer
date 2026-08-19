# Epic 6 / Story 6.7 — Fast-follow (A-B loop · drag-drop import · dry monitoring)

**Goal:** Three small quality-of-life features that make the play-along tool nicer
to practice with.

1. **A-B loop** — mark a start (A) and end (B) in the player; playback loops that
   span so you can drill a passage.
2. **Drag-drop import** — drop an audio file on the window to import it (a second
   path to the file-browser flow).
3. **Dry monitoring** — a monitor "bypass" that passes the guitar through clean
   (no amp chain), for players who use their own outboard amp/tone.

## Files

- **Modify `src/player.odin`** — A-B loop state + producer wrap:
  - Atomics `g_loop_a`, `g_loop_b` (`i64`, -1 = unset), `g_loop_on` (`u32`).
  - `player_loop_mark()` (the `L` key): cycles no-loop → set A (at cursor) → set B
    (at cursor; order A<B; enable) → clear. `player_loop_clear()`. Getters
    `player_loop_a/b()`, `player_loop_on()`.
  - Producer: when looping and `cursor >= B`, jump `cursor = A` (and `st_clear` the
    stretcher, like a seek); clamp the block so it never crosses B. End-of-song
    logic is unaffected (a loop with B ≤ frames wraps first).
- **Modify `src/audio.odin`** — dry monitoring:
  - Atomic `g_mon_dry` (`u32`); `audio_set_monitor_dry` / `audio_monitor_dry`.
  - In the callback monitor mix: if dry, add `src[i] * level` (clean passthrough);
    else run the amp chain as today. Still downstream of detection.
- **Modify `src/songprefs.odin`** — persist `dry` in the per-song rig (append a
  field to the rig line; back-compatible). (Loop points stay transient — reset on
  reopen.)
- **Modify `src/app.odin`**:
  - Player keys: `L` loop mark, `D` dry on/off. Wire the rig `dry` on open/save.
  - **Drag-drop**: at the top of the main loop, `rl.IsFileDropped()` →
    `rl.LoadDroppedFiles()`; if the first path is a supported audio file, start the
    same import (`import_start` into `library/<slug>/`) and go to the Importing
    screen; `rl.UnloadDroppedFiles`.
- **Modify `src/player_view.odin`** — draw the A-B markers on the seek bar + a
  "LOOP A–B" indicator; show "DRY" vs the amp rig on the monitor line.
- **Modify `src/main.odin` / `src/selftests.odin`** — `--loopcheck` (headless).

## Steps

- [ ] **Step 1:** A-B loop in `player.odin` (mark/clear/getters + producer wrap).
- [ ] **Step 2 (headless):** `--loopcheck` — synthetic song, set A/B, run the
  producer, assert the cursor stays within [A, B) and wraps (never runs past B).
  Wire dispatch.
- [ ] **Step 3:** dry monitoring in `audio.odin` (+ setter/getter); extend the
  monitor mix; persist `dry` in `songprefs`; `D` key + `L` key + rig wiring in
  `app.odin`.
- [ ] **Step 4:** drag-drop import in `run_app` (reuses the tested import path).
- [ ] **Step 5 (UI):** loop markers + indicator + DRY tag in `player_view`.
- [ ] **Step 6:** `./test.sh` green; `./build.sh` (+ `-debug` for the callback);
  all headless (`--loopcheck`, `--monitorcheck`, `--playercheck`, …) pass;
  screenshot `player` shows a loop + DRY. Update `CLAUDE.md`, `plan.md`.

## Verification

- **Headless:** `./guitar-trainer --loopcheck` — the producer keeps the cursor
  inside the A-B span and wraps. `--monitorcheck` / `--playercheck` still pass;
  `-debug` shows no callback allocation (dry path is a plain add).
- **Live/manual:** open a song, set an A-B loop over a lick and drill it at a
  slow speed; drag a file onto the window to import; toggle dry monitoring when
  playing through your own amp.

## Out of scope

Loop-point persistence (transient by design); nudging/fine-tuning loop points;
multi-file drag-drop (first file only).
