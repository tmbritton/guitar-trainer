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

## Guitar tone (SoundFont)

Playback uses **TinySoundFont** (`tsf/tsf.h`, compiled to `tsf/libtsf.a` by
build.sh) loading a real sampled-guitar `.sf2`, then convolved with a **cabinet
impulse response** (`conv` pkg; IR loaded via miniaudio's decoder in `ir.odin`)
— the cab IR is the main electric-guitar realism step. Both are third-party
binaries, not committed — run `assets/fetch.sh` to download the fonts + IRs.
**Full modeled rig (best tone):** a clean-DI SoundFont (`assets/clean.sf2`) →
**Neural Amp Modeler** (real-amp capture; NeuralAmpModelerCore built to
`nam/libnam.a` by `nam/build.sh`, which fetches Eigen — `-march=native`, so
build on the target machine) → cabinet IR. Amp models are `.nam` files in
`assets/` (Laney/JCM2000/Dirty Shirley), fetched by `assets/fetch.sh`.

Controls: `N` neural amp on/off, `A` amp model, `B` cabinet, `I` cab on/off,
`F`/`V` guitar/preset (the sampled-amp path when NAM is off). `./guitar-trainer
--riff` auditions the current tone (renders a riff, plays it — no window).

Fallbacks: no `.sf2` → Karplus-Strong synth; no `.nam` → the sampled-amp SF2
path; the `amp` tanh overdrive is used only when neither NAM nor a font applies.
Detection always reads the dry signal.

**Perf note:** NAM inference is CPU-heavy; a cadence renders in ~2.6 s on a
low-power laptop (sub-second on a fast desktop). Currently rendered
synchronously per trial — a background render thread is the planned fix to hide
it. `nam_shim.cpp` is combined into one object (`ld -r`) so the architecture
parsers' static registrations aren't dropped by the linker.

## Headless self-tests (no hardware; loopback)

`./guitar-trainer --<check>`: `audiocheck` (device+clock live), `calibcheck`
(offset math), `pitchcheck` (onset→window→YIN), `synthcheck` (Karplus-Strong
voice engine), `drillcheck` (blocking trial loop), `drillsim` (live frame-stepped
drill → SQLite), `storecheck` (sqlite write, cross-check with `sqlite3` CLI),
`progresscheck` (progress aggregates from the log).

## Status

M0 (audio spine), M1 (pitch), and M2 (v0 scale-degree drill) are code-complete
and tested — the drill is playable end to end (`run_app`) and logs to
`trials.db`. Hardware-gated acceptance (<10 ms offset-corrected pick attack, real
acoustic calibration, plucked-note accuracy, and the M3 three-weeks-daily-use
gate) awaits a class-compliant USB Hi-Z interface — not yet purchased; onboard
audio + software loopback are used for development.
