# Guitar Trainer

A native desktop app that trains **auditory musical fluency** on guitar: you
hear a note and find it on the fretboard — by ear, not by reading tab. It scores
the *sound* you play (pitch class, octave, onset, duration), so the fretboard
becomes a search space instead of a lookup table.

It's a single native binary (Odin + raylib + miniaudio), with realtime pitch
detection from a dry DI signal and a genuinely realistic electric-guitar
playback tone (sampled SoundFont → Neural Amp Modeler amp → cabinet impulse
response).

See [`docs/product-sketch.md`](docs/product-sketch.md) for the full design
rationale and [`plan.md`](plan.md) for the build plan / progress.

> **Status:** the v0 scale-degree drill is playable end to end (milestones
> M0–M2). Some acceptance criteria are gated on a class-compliant USB audio
> interface (see [Hardware](#hardware)); onboard audio works for development.

## What it does

- Plays a **I–IV–V–I cadence** to establish a key, then plays a random
  **scale-degree** target tone.
- You **play the note back** on your guitar; it detects your pitch (YIN) and
  judges it by pitch class.
- **Delayed, auditory feedback** (a confirming tone or a short "stumble") — no
  per-note green/red screen-watching.
- Logs every trial to a local SQLite file and shows a **progress** view.
- **Fullscreen, distraction-free.** Real guitar tone with switchable amps/cabs.

## Requirements

- **Linux** (developed on Fedora Atomic / Bazzite with PipeWire).
- [**mise**](https://mise.jdx.dev/) — manages the Odin toolchain (pinned in
  `mise.toml`). Odin is fetched automatically on first build.
- A **C/C++ compiler** (`cc`/`c++` — gcc or clang) to build the vendored native
  libraries (miniaudio, TinySoundFont, and the Neural Amp Modeler core).
- **git** and **curl** — the first build fetches Eigen; `assets/fetch.sh`
  downloads the audio assets.
- Link-time libraries: the **X11 + OpenGL** stack (for raylib), **sqlite3**,
  **libstdc++**, **libm**.
  - `build.sh` currently points the linker at Homebrew's lib path
    (`/home/linuxbrew/.linuxbrew/lib`) because that's where the dev `.so`s live
    on the author's host. On a different setup, adjust `BREW_LIB`/`LINK_FLAGS`
    in `build.sh` to wherever your `libX11.so`, `libGL.so`, `libsqlite3.so`,
    etc. are.

## Getting started (fresh clone)

```bash
git clone git@github.com:tmbritton/guitar-trainer.git
cd guitar-trainer

# 1. Download the audio assets (SoundFonts, cabinet IRs, neural-amp models).
#    They're third-party and not committed — see Third-party assets below.
assets/fetch.sh

# 2. Build. The FIRST run also fetches Odin (via mise) and clones Eigen to
#    build the neural-amp lib — this takes a few minutes. Later builds are fast.
./build.sh

# 3. Run (launches fullscreen).
./guitar-trainer
```

The neural-amp library is compiled with `-march=native`, so build on the
machine you'll run on to get the fastest tone rendering. Without the assets the
app still runs — it falls back to a built-in synth.

### Controls

| Key | Action |
|-----|--------|
| `ESC` | quit |
| `C` | calibrate round-trip latency (between trials) |
| `P` | toggle the progress view |
| `N` | neural amp on/off |
| `A` | cycle amp model (Laney GH100S / Marshall JCM2000 / Dirty Shirley) |
| `B` | cycle cabinet (Marshall 1960A / Mesa 4×12 / 5150) |
| `I` | cabinet on/off |
| `F` / `V` | cycle guitar SoundFont / preset (the non-neural path) |

Your trial history is written to `trials.db` in the working directory.

## Hardware

For real use the spec calls for a **class-compliant USB interface with a Hi-Z
instrument input** (e.g. Focusrite Scarlett Solo 4th gen or MOTU M2). Detection
runs on the dry DI signal; distortion/amp-sim is a separate, downstream path.
Onboard audio is fine for development and for hearing the app, but the low-latency
pick-attack timing needs the interface.

## Development

```bash
./test.sh            # unit tests for all pure-logic packages (no hardware)
./build.sh -debug    # arms an audio-thread allocation guard (panics on any alloc)
```

Headless self-tests exercise the real audio pipeline over an internal loopback
(no hardware, no window):

```bash
./guitar-trainer --audiocheck     # duplex device + master clock are live
./guitar-trainer --pitchcheck     # onset -> windowed YIN pitch
./guitar-trainer --drillsim       # full drill loop -> SQLite
./guitar-trainer --rigdrillcheck  # drill through the neural-amp rig + async render
./guitar-trainer --riff           # audition the tone (plays a riff)
```

Architecture, invariants, and the full self-test list are documented in
[`CLAUDE.md`](CLAUDE.md). Per-story implementation notes are under `docs/`.

## How the guitar tone works

Playback is a modeled rig, rendered on a background thread (so the UI never
freezes) and kept off the detection path:

```
clean-DI SoundFont  ->  Neural Amp Modeler (real amp capture)  ->  cabinet IR
```

Pitch detection always reads the clean, dry signal — the amp/cab only colour
what you *hear*.

## Third-party assets & libraries

Fetched by `assets/fetch.sh` (not committed; check each source's terms for your
use):

- **Guitar SoundFonts** — [zanderjaz.com](https://www.zanderjaz.com/downloads/soundfonts/guitars/)
- **Cabinet impulse responses** — [fnpngn/IR](https://github.com/fnpngn/IR)
- **Neural Amp Modeler captures** — [pelennor2170/NAM_models](https://github.com/pelennor2170/NAM_models)

Vendored / fetched libraries:

- [TinySoundFont](https://github.com/schellingb/TinySoundFont) (MIT) — SF2 synth
  (`tsf/tsf.h`).
- [NeuralAmpModelerCore](https://github.com/sdatkinson/NeuralAmpModelerCore)
  (MIT) — neural amp DSP (built by `nam/build.sh`).
- [Eigen](https://eigen.tuxfamily.org/) (MPL2) and
  [nlohmann/json](https://github.com/nlohmann/json) (MIT) — NAM dependencies.
- Odin's `vendor:raylib` and `vendor:miniaudio`.

## License

Personal project — no license is currently specified. The bundled third-party
assets and libraries retain their own licenses (above).
