# Epic 0 / Story 2 — Buildable Window Skeleton

**Goal:** `odin build .` produces a single binary that opens a `vendor:raylib` window and runs a frame loop. Confirm `vendor:miniaudio` links (reference a symbol) without opening a device.

**Files:**
- Create: `main.odin` — window + frame loop, `package main`.
- Create: `audio.odin` — stub that imports `vendor:miniaudio` and references a symbol so the linker pulls it in. No device init yet (that is Story 1.1).
- Create: `build.sh` — thin wrapper: `mise exec -- odin build . -out:guitar-trainer "$@"`.

## Constraints in play

- Single binary, single process.
- Do **not** call raylib's `InitAudioDevice()` — we own audio separately later. This story doesn't touch audio init at all.

## Steps

- [ ] **Step 1: `main.odin`.** `import rl "vendor:raylib"`. `InitWindow(800, 480, "Guitar Trainer")`, `SetTargetFPS(60)`, loop `for !rl.WindowShouldClose()` with `BeginDrawing`/`ClearBackground`/`DrawText`/`EndDrawing`, then `CloseWindow`. Do **not** call `InitAudioDevice`.
- [ ] **Step 2: `audio.odin` link probe.** `import ma "vendor:miniaudio"`. A proc `audio_version :: proc() -> string { return string(ma.version_string()) }` (references a miniaudio symbol so it links). Call it from `main.odin` and draw the version string in the window.
- [ ] **Step 3: `build.sh`.** `#!/usr/bin/env bash` + `set -euo pipefail` + `exec mise exec -- odin build . -out:guitar-trainer "$@"`. `chmod +x`.
- [ ] **Step 4: Build.** Run `./build.sh`. Expected: compiles to `./guitar-trainer` with no errors. Raylib on Linux needs GL/X11/Wayland system libs at link time — if the linker complains, note which `-l` is missing (raylib vendor ships the static lib; system GL/X11 dev libs may be required).
- [ ] **Step 5: Headless smoke test.** Running a GUI binary needs a display. Verify the binary exists and is executable; attempt a short run under a virtual display if available (`xvfb-run -a ./guitar-trainer` with a kill after ~1s) or just confirm it starts and exits cleanly when a display is present. Building cleanly is the primary acceptance; live window display is verified when a display is attached.

## Verification

`./build.sh` produces `./guitar-trainer`. The binary references both raylib and miniaudio (miniaudio via `audio_version`). No `InitAudioDevice` call anywhere.

## Notes

- miniaudio's exact binding name for the version string is checked against the vendor source during implementation; if `version_string` differs, use whatever the binding exposes (e.g. `MA_VERSION` constant) — the point is only to force a link reference.

## Findings (implementation)

- **`vendor:miniaudio` ships source only** — `lib/miniaudio.a` did not exist. Built it once with the vendored `src/build_miniaudio.sh` (pulls in `vendor/stb`). Because the Odin install lives under mise and could be wiped on reinstall, `build.sh` self-heals: it rebuilds `miniaudio.a` if missing.
- **raylib link deps (X11 stack + GL) on this host (Bluefin / Fedora Atomic):** the runtime `.so.N` libs are in `/usr/lib64` but the dev `.so` symlinks are not; the full set (with dev symlinks) is present under Homebrew at `/home/linuxbrew/.linuxbrew/lib`. Homebrew's `ld` does not search its own lib dir by default, so `build.sh` passes `-extra-linker-flags:"-L/home/linuxbrew/.linuxbrew/lib -Wl,-rpath,/home/linuxbrew/.linuxbrew/lib"`. `ldd` resolves all libs; no rpm-ostree layering was needed.
- **Verified live:** `guitar-trainer` opened a window (raylib 6.0, GLFW/X11, Mesa Intel UHD 620), ran the frame loop, exited cleanly. `miniaudio 0.11.24` links and reports its version.
- raylib's own `raudio` module loads but is inert — we never call `InitAudioDevice()`.
