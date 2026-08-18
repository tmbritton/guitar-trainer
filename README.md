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

Onboard audio is fine for development and for hearing the app, but real use wants
a proper **USB audio interface**. Detection runs on the dry DI signal, and the
pick-attack timing is latency-sensitive, so the interface matters.

**What this tool needs**

- A **Hi-Z instrument input** (≥ 1 MΩ) — plug your guitar straight in. A passive
  magnetic pickup into a line input sounds thin and detects worse.
- **Class-compliant (USB Audio Class 2.0)** — modern interfaces are plug-and-play
  on Linux/PipeWire with no proprietary drivers.
- **Low round-trip latency** — the app targets < 10 ms; better converters/drivers
  help.

**What "record guitar *and* mic" adds**

- **Two inputs**, at least one **Hi-Z instrument** and one **XLR mic with 48 V
  phantom power**, so you can capture a mic and a DI guitar at the same time.
  Interfaces with two **combo XLR/TRS** jacks are the most flexible (each can be
  a mic *or* an instrument).

### Recommended interfaces (all under $250, 2-input, class-compliant on Linux)

Prices are approximate USD (2026) — check current listings.

| Tier | Interface | ~Price | Inputs | Notes |
|------|-----------|-------:|--------|-------|
| Budget | **Behringer UMC202HD** | ~$90 | 2× combo (MIDAS pres) | Cheapest solid option; class-compliant. Shared phantom across channels. |
| Budget+ | **Audient EVO 4** | ~$130 | 2× combo | Great preamps/converters for the price; Smartgain. Very popular, class-compliant. |
| Entry (1 mic + 1 gtr) | **Focusrite Scarlett Solo (4th gen)** | ~$130 | 1× XLR + 1× Hi-Z | Exactly one mic **and** one guitar at once; the spec's entry pick. |
| Best value | **Focusrite Scarlett 2i2 (4th gen)** | ~$200 | 2× combo | The default "just works on Linux" 2-in interface; Auto Gain / Clip Safe. |
| Best for this tool | **MOTU M2** | ~$200 | 2× combo | ESS Sabre converters, class-leading low latency (best for the < 10 ms target), plus **loopback** — handy for recording guitar over backing tracks. |

If you can stretch just past the budget, the **MOTU M4** (~$270) adds two more
inputs (2 mic + a dedicated Hi-Z) with the same low-latency converters.

**Recommendation:** for this trainer specifically, the **MOTU M2** is the sweet
spot — lowest latency (which the drill's timing rewards), two combo inputs for
mic + guitar, and loopback for recording. If you want the cheapest thing that
still does everything well, the **Audient EVO 4** or **Scarlett Solo 4th gen**.

**Don't buy** (per the design's rationale):

- A **Rocksmith Real Tone cable** — mono, fixed gain, single-purpose (no mic
  input, so it can't do the record-guitar-and-mic use case).
- A **hexaphonic pickup** (Cycfi Nu, Roland GK-3, Fishman TriplePlay) — it solves
  string/fret disambiguation, a problem this app avoids by scoring *sound* rather
  than fingering.

Sources:
[MusicRadar](https://www.musicradar.com/news/best-budget-audio-interfaces) ·
[Linuxano: interfaces for Linux](https://linuxano.com/best-usb-audio-interfaces-for-linux/) ·
[ToneStakr: interfaces for guitar](https://tonestakr.com/guides/best-audio-interfaces-guitar/)

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
