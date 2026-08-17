# Guitar Trainer — working notes

A single native Odin binary that trains auditory musical fluency on guitar. See
`docs/product-sketch.md` (spec) and `plan.md` (epics/stories + progress).
Per-story implementation plans live in `docs/epic-{N}/story-{M}.md`.

## Toolchain

- **Odin via mise**, pinned in `mise.toml` (`dev-2026-08`). Run Odin as
  `mise exec -- odin ...`.
- `vendor:raylib` and `vendor:miniaudio` ship with Odin. **miniaudio ships source
  only** — its `lib/miniaudio.a` is built on demand by `build.sh`/`test.sh`.

## Build & run

- `./build.sh` → `./guitar-trainer` (release). `./build.sh -debug` arms the
  audio-thread allocation guard (panics on any alloc in the callback).
- raylib links the X11 stack + GL. On this host (Bluefin/Fedora Atomic) the dev
  `.so`s live under Homebrew; `build.sh` passes
  `-L/home/linuxbrew/.linuxbrew/lib` + rpath. Don't remove that.

## Test & verify

- `./test.sh` — unit tests for all pure-logic packages (clock, ring, detect,
  rtalloc, calib, music, game). Skips a package whose dir doesn't exist yet. No
  hardware needed.
- `./guitar-trainer --audiocheck` — headless: opens the real duplex device,
  asserts the master clock advances. Verifies the audio spine is live.
- `./guitar-trainer --calibcheck` — headless: runs calibration over an internal
  software loopback; verifies click→detect→match→aggregate.
- `./tools/audioprobe/audioprobe` — lists devices / backend.

## Architecture rules (from spec §9 — do not violate)

- **Never call `rl.InitAudioDevice()`.** One `ma_device` in duplex mode owns
  audio (`audio.odin`).
- **The audio clock is master** (`clock` pkg): a monotonic sample counter
  advanced in the callback. All timing is in samples; convert to ms for display
  only.
- **SPSC ring** (`ring` pkg), audio→main. The callback only pushes; main only
  drains. Callback never allocates/locks/logs — enforced by the `rtalloc` guard
  under `-debug`.
- **Split onset from pitch:** onset in the callback (samples), pitch confirmed
  later on the main thread from a buffered window. Score timing off onset,
  correctness off pitch.
- **Score the sound, not the fingering:** pitch class / octave / onset /
  duration.

## Package layout

```
main.odin        window, game loop, headless self-test modes
audio.odin       duplex ma_device, callback, click generator, loopback
debug.odin       callback allocator selection (guard vs nil)
calibration.odin run_calibration driver
clock/           master sample clock + time conversion   (unit-tested)
ring/            SPSC lock-free ring buffer               (unit-tested)
detect/          onset detection (pitch detection: Epic 2)(unit-tested)
rtalloc/         audio-thread allocation guard            (unit-tested)
calib/           round-trip offset math                   (unit-tested)
music/           keys, scale degrees, cadence             (unit-tested)
game/            trial generation + judging               (unit-tested)
store/           SQLite trial log (hand-written bindings) (unit-tested)
tools/audioprobe standalone device enumerator
```

## Status

M0 (audio spine) machinery complete and tested. Hardware-gated acceptance
(<10 ms offset-corrected pick attack, real acoustic calibration) awaits a
class-compliant USB Hi-Z interface — not yet purchased; onboard audio is used
for development.
