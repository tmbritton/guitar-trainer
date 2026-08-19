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

- `./build.sh` → `./guitar-trainer`, built `-o:speed` (needed — the DSP, esp.
  IR convolution, is ~10x slower unoptimized). `./build.sh -debug` arms the
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

All Odin source lives under `src/`. The application is `package main`
(`src/*.odin`); each subdirectory is its own imported package. `build.sh`
builds `src` → `./guitar-trainer` at the repo root (so runtime `assets/` paths
resolve). Standalone tools and the C-backed binding modules (`tsf`, `nam`) also
live under `src/`, so their relative imports (`../music`, `../../nam`) are
unchanged by the layout.

```
src/
  main.odin        entry point + command-line dispatch
  app.odin         run_app: the keyboard-driven screen router + menu widget
  drill.odin       drill state machine (Idle→Prep→Listen→Confirm→Fb_Prep→Feedback)
  drill_view.odin  drill HUD + progress-panel rendering (pure view)
  import.odin      song-import worker (spawn separate.py, read progress pipe)
  library.odin     library scan (finished songs) + import file-browser listing
  import_view.odin file browser / importing-progress / library screens (view)
  stems.odin       decode a song's 6 stems to mono f32 @ 48k (Song_Audio)
  player.odin      song player: producer thread mixes stems -> PCM ring; transport
  player_view.odin player screen: mixer strip + transport (pure view)
  songprefs.odin   per-song mixer persistence (library/<song>/mixer.txt)
  selftests.odin   headless --*check verification modes
  riff.odin        --riff / --riff-wav tone-audition modes
  screenshot.odin  --screenshot PNG capture
  audio.odin       duplex ma_device, callback, click generator, loopback
  soundfont.odin   TSF loading + strum/velocity render (sf_render_seq)
  namamp.odin      NAM neural-amp load/cycle;  ir.odin  cabinet IR convolve
  render.odin      background rig-render worker
  calibration.odin run_calibration driver;  debug.odin  callback allocator select
  ui.odin          raylib UI kit (panels, capsules, meters, colours)
  wav.odin         16-bit PCM WAV writer
  clock/           master sample clock + time conversion   (unit-tested)
  ring/            SPSC lock-free ring buffer               (unit-tested)
  detect/          onset + YIN pitch detection              (unit-tested)
  rtalloc/         audio-thread allocation guard            (unit-tested)
  calib/           round-trip offset math                   (unit-tested)
  music/           keys, scale degrees, cadence             (unit-tested)
  game/            trial generation + judging               (unit-tested)
  store/           SQLite trial log (hand-written bindings) (unit-tested)
  menu/            pure keyboard-menu navigation math       (unit-tested)
  songlib/         import protocol parse + slug + song-dir  (unit-tested)
  pcmring/         SPSC f32 sample ring (player->callback)  (unit-tested)
  mix/             stem-mixer gain math (level/mute/solo)   (unit-tested)
  amp/             tanh overdrive fallback                  (unit-tested)
  conv/            IR convolution + L2 normalize            (unit-tested)
  tsf/ nam/ soundtouch/  third-party C/C++ libs + Odin bindings + build scripts
  tools/           standalone helpers (audioprobe, sfcheck, namcheck)
```

## Guitar tone (SoundFont)

Playback uses **TinySoundFont** (`src/tsf/tsf.h`, compiled to `src/tsf/libtsf.a`
by build.sh) loading a real sampled-guitar `.sf2`, then convolved with a **cabinet
impulse response** (`conv` pkg; IR loaded via miniaudio's decoder in `ir.odin`)
— the cab IR is the main electric-guitar realism step. Both are third-party
binaries, not committed — run `assets/fetch.sh` to download the fonts + IRs.
**Full modeled rig (best tone):** a clean-DI SoundFont (`assets/clean.sf2`) →
**Neural Amp Modeler** (real-amp capture; NeuralAmpModelerCore built to
`src/nam/libnam.a` by `src/nam/build.sh`, which fetches Eigen — `-march=native`, so
build on the target machine) → cabinet IR. Amp models are `.nam` files in
`assets/` (Laney/JCM2000/Dirty Shirley), fetched by `assets/fetch.sh`.

Controls: `N` neural amp on/off, `A` amp model, `B` cabinet, `I` cab on/off,
`F`/`V` guitar/preset (the sampled-amp path when NAM is off). `./guitar-trainer
--riff` auditions the current tone (renders a riff, plays it — no window).

Fallbacks: no `.sf2` → Karplus-Strong synth; no `.nam` → the sampled-amp SF2
path; the `amp` tanh overdrive is used only when neither NAM nor a font applies.
Detection always reads the dry signal.

**Perf / async render:** NAM inference is CPU-heavy (~2.6 s per cadence on a
low-power laptop, sub-second on a fast desktop). Rig audio is rendered on a
**background worker** (`render.odin`): the drill publishes a clip (Note_Events),
the worker renders it (TSF→NAM→cab IR) off-thread, and the main thread schedules
the finished PCM — so the UI never freezes (it shows "GET READY" during the
render). New drill phases: `Prep` (trial audio) and `Fb_Prep` (feedback). Tone
switches are gated on `!render_busy()`. The KS fallback path renders inline (no
worker) so headless self-tests are unaffected. `nam_shim.cpp` is combined into
one object (`ld -r`) so the architecture parsers' static registrations aren't
dropped by the linker.

## Song import (stem separation)

The **Import** screen is a keyboard file browser; picking an audio file spawns
**`assets/separate.py`** (Demucs `htdemucs_6s` → 6 stems: vocals/drums/bass/
guitar/piano/other) as a subprocess. The separator prints one line per event on
stdout — `PROGRESS <0..100>` / `DONE <dir>` / `ERROR <msg>` — which `import.odin`
reads over a pipe on a worker thread (parsed by the pure `songlib` pkg) to drive
a live progress bar (Importing screen). Finished stems land in `library/<slug>/`
and show on the **Play a Song** (Library) screen (the player itself is Story
6.3). Real Demucs needs `pip install demucs` and is slow on CPU — a live/manual
gate; automated coverage uses `separate.py --stub` (no ML) via `--importcheck`.

## Song player (play-along)

Opening a library song (Play a Song → ENTER) loads its 6 stems (`stems.odin`,
mono f32 @ 48 kHz) and plays them mixed. The device is **mono** (see audio.odin),
so stems mix down to a mono backing stream — stereo output would mean
reconfiguring the device + every `out`-writer, deferred. A **producer thread**
(`player.odin`) mixes the stems from a shared cursor (per-stem level/mute/solo,
`mix` pkg) into a lock-free **PCM ring** (`pcmring` pkg); the audio callback
drains that ring to `out` when `audio_player_activate(true)` — a separate mode
from the drill (they never run at once). The UI issues commands (play/pause,
seek, mixer) through atomics; it never touches stem PCM or the ring. Mixer state
persists per song in `library/<song>/mixer.txt` (`songprefs.odin`).

**Speed / time-stretch:** **SoundTouch** (LGPL C++, `src/soundtouch/`, built
on-target into `libsoundtouch.a` like nam/tsf) is spliced into the producer:
each mixed block is fed through it and the stretched output goes to the ring.
Pitch-preserving; the **cursor stays in input frames** so the transport time is
right at any speed. At **speed 1.0 the stretcher is bypassed** (mix → ring
directly), so the default path is unchanged and latency-free; it only engages
when speed ≠ 1.0. Speed is clamped to 0.5–1.25 and resets to 1.0 on open
(per-song speed persistence lands with the rig prefs in 6.5).

Controls: `SPACE` play/pause, `←/→` seek, `↑/↓` select stem, `+/-` level,
`M` mute, `S` solo, `[`/`]` speed, `ESC` back (saves). Live-input monitoring
through an amp chain is a later story.

## Headless self-tests (no hardware; loopback)

`./guitar-trainer --<check>`: `audiocheck` (device+clock live), `calibcheck`
(offset math), `pitchcheck` (onset→window→YIN), `synthcheck` (Karplus-Strong
voice engine), `drillcheck` (blocking trial loop), `drillsim` (live frame-stepped
drill → SQLite), `drillabandoncheck` (leaving mid-trial abandons cleanly, no
stray log / onset), `storecheck` (sqlite write, cross-check with `sqlite3` CLI),
`progresscheck` (progress aggregates from the log), `sfplaycheck` (SoundFont
sample voice), `rigdrillcheck` (async worker: full rig drill over loopback),
`importcheck` (song-import worker: spawn `assets/separate.py --stub`, read the
progress pipe, assert 6 stems written), `playercheck` (song player: producer +
PCM ring + mixer over synthetic stems — mute-all silent, solo isolates energy,
pause halts the cursor — plus a stem-decode smoke), `speedcheck` (SoundTouch
time-stretch: asserts the output/input ratio is ~1 at 1.0x bypass and ~2 at
0.5x through the real producer), `riff` / `riff-wav` (audition tone / export
WAV + timing).

## Status

M0 (audio spine), M1 (pitch), and M2 (v0 scale-degree drill) are code-complete
and tested — the drill is playable end to end (`run_app`) and logs to
`trials.db`. Hardware-gated acceptance (<10 ms offset-corrected pick attack, real
acoustic calibration, plucked-note accuracy, and the M3 three-weeks-daily-use
gate) awaits a class-compliant USB Hi-Z interface — not yet purchased; onboard
audio + software loopback are used for development.
