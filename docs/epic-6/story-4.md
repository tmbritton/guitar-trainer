# Epic 6 / Story 6.4 — Playback speed (time-stretch)

**Goal:** Slow a song down (or speed it up) without changing pitch, so you can
learn fast parts. Add a speed control to the player; the backing plays at the
chosen rate, pitch-preserved.

**Approach:** vendor **SoundTouch** (LGPL C++ WSOLA time-stretch), built on-target
into `libsoundtouch.a` like `nam`/`tsf`, wrapped by a tiny C shim + Odin bindings,
and inserted into the **producer chain** (player.odin): the producer feeds each
mixed mono block through SoundTouch and writes the stretched output to the PCM
ring. The audio callback is unchanged (still just drains the ring).

## Files

- **Create `src/soundtouch/`** — the vendored lib + binding, mirroring `src/nam`:
  - `build.sh` — `git clone --depth 1` SoundTouch (codeberg), compile
    `source/SoundTouch/*.cpp` + `st_shim.cpp` with
    `-DSOUNDTOUCH_FLOAT_SAMPLES=1 -std=c++17 -O2 -fPIC`, `ar rcs libsoundtouch.a`.
    Vendored source and the `.a` are gitignored (fetched on build).
  - `st_shim.cpp` / `st_shim.h` — `extern "C"` over `soundtouch::SoundTouch`:
    `st_create(sr,ch)`, `st_destroy`, `st_set_tempo(tempo)` (1.0 = normal, 0.5 =
    half speed), `st_put(data,n)`, `st_receive(data,n)->got`, `st_available()`,
    `st_clear`, `st_flush`.
  - `soundtouch.odin` (`package soundtouch`) — `foreign import lib
    "libsoundtouch.a"` + the extern-C decls (same idiom as `nam.odin`).
- **Modify `build.sh`** — build `src/soundtouch/libsoundtouch.a` if missing
  (`bash src/soundtouch/build.sh`), before the Odin build. `-lstdc++` is already
  in `LINK_FLAGS`.
- **Modify `.gitignore`** — ignore `src/soundtouch/libsoundtouch.a`,
  `src/soundtouch/vendor/`, `src/soundtouch/obj/`.
- **Modify `src/player.odin`** — insert SoundTouch in the producer:
  - `player_open` creates a stretcher (48 kHz, mono); `player_close` destroys it.
  - `player_set_speed(x)` / `player_speed() -> f32` via an atomic (f32 bits).
  - Producer: read the target speed each iteration; on change apply `st_set_tempo`
    (and `st_clear` when entering/leaving stretch so no stale audio bleeds). At
    **speed 1.0 bypass** SoundTouch entirely (mix → ring directly, exactly the
    current path) so the default is bit-identical and adds no latency; only engage
    the stretcher when speed ≠ 1.0. When stretching, feed the mixed block via
    `st_put`, then drain `st_receive` into the ring while ring space allows.
  - **Cursor stays in input frames** (song position): advance by input frames
    consumed regardless of path, so the transport time is correct at any speed.
    `player_seek` also `st_clear`s the stretcher (flush buffered audio).
- **Modify `src/player_view.odin`** — show the speed (e.g. `1.00x`) on the
  transport line.
- **Modify `src/app.odin`** — Player input: `[` slower, `]` faster (± 0.05,
  clamped to a sane range e.g. 0.5–1.25).
- **Modify `src/main.odin` / `src/selftests.odin`** — `--speedcheck` (headless).

## Steps

- [ ] **Step 1:** `src/soundtouch/` — `st_shim.{h,cpp}`, `soundtouch.odin`,
  `build.sh`. Wire `build.sh` + `.gitignore`. Confirm `libsoundtouch.a` builds
  and the app links.
- [ ] **Step 2:** producer integration in `player.odin` (speed atomic, bypass at
  1.0, stretch path, cursor in input frames, seek clears the stretcher).
- [ ] **Step 3 (headless):** `--speedcheck` — open a synthetic song; at speed 1.0
  assert cursor advances ≈ output samples drained (bypass); at speed 0.5 assert
  the cursor advances ≈ 0.5 × output samples drained (time-stretch ratio through
  the real producer + SoundTouch). Wire `--speedcheck` dispatch.
- [ ] **Step 4 (UI):** speed on the transport line + `[`/`]` in the router.
- [ ] **Step 5:** `./test.sh` green; `./build.sh` (builds SoundTouch); all
  headless checks pass incl. `--playercheck` (1.0 path unchanged) and
  `--speedcheck`; screenshot `player` still renders. Update `CLAUDE.md`, `plan.md`.

## Verification

- **Headless:** `./guitar-trainer --speedcheck` — asserts the time-stretch ratio
  (cursor-vs-output) at 1.0 (bypass) and 0.5 (stretch) through the real
  producer + SoundTouch path. `--playercheck` still passes (bypass path intact).
- **Live/manual (gate):** open a real song, slow it to ~0.6×, confirm pitch is
  preserved and it's usable to play along with; sweep speed while playing.

## Notes / risks

- SoundTouch is LGPL C++, fetched + built on-target (like `nam`); extreme
  slow-downs (< 0.5×) lose quality, so the UI clamps to a practical range.
- Speed is **not** persisted here (per-song speed persistence lands with the rig
  prefs in Story 6.5); it resets to 1.0 on open.
