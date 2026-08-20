# Guitar Trainer

A native desktop app for **playing along with real songs**. Import a track, split
it into instrument stems, turn one part down (say, the guitar), and play that part
yourself — hearing your own guitar through a built-in amp, mixed with the rest of
the band. Mute/solo stems, slow the song down without changing pitch, and each
song remembers your mix and tone.

It also includes an **ear-training drill** (the project's original mode): it plays
a cadence to establish a key, then a scale-degree target, and you play it back by
ear — it scores the *sound* (pitch class / octave / onset), not the fingering.

Single native binary — Odin + raylib + miniaudio, with realtime pitch detection
from a dry DI signal, offline neural-amp tone for the drill, and a light realtime
amp chain for live monitoring. Stem separation is an external Python step (Demucs);
everything realtime stays native.

See [`docs/product-sketch.md`](docs/product-sketch.md) for the design rationale,
[`plan.md`](plan.md) for the build plan / progress, and
[`CLAUDE.md`](CLAUDE.md) for architecture and invariants.

> **Status:** the play-along tool is complete end to end — import + stem
> separation, the stem mixer + transport, pitch-preserving speed, live guitar
> monitoring through an amp chain, per-song rig, and audio-device selection. The
> scale-degree drill is playable (milestones M0–M2). Tone tuning and the Rocksmith
> cable's behavior are best judged on your own rig.

## What it does

**Play along with a song**

- **Import** an audio file from an in-app file browser; the app runs
  [Demucs](https://github.com/adefossez/demucs) to separate it into 6 stems
  (vocals / drums / bass / guitar / piano / other) with a live progress bar, then
  caches them to a library.
- **Mix** the stems — per-stem level, mute, solo — so you can pull the part you
  want to play down (or solo it to learn it).
- **Transport** — play / pause / seek, with a position + seek bar.
- **Slow it down** (or speed up), pitch-preserved, via
  [SoundTouch](https://codeberg.org/soundtouch/soundtouch) — learn fast passages
  at 0.5–1.25×.
- **Monitor your guitar** through a realtime amp chain (drive → tone → cabinet)
  mixed in with the backing, so you hear yourself in a usable tone while you play.
- Your **mixer, tone, and speed persist per song**.

**Ear-training drill**

- Plays a **I–IV–V–I cadence** to set a key, then a random **scale-degree** tone.
- You **play it back**; it detects your pitch (YIN) and judges it by pitch class.
- **Delayed, auditory feedback** — no per-note green/red screen-watching.
- Logs every trial to a local SQLite file with a **progress** view.

Distraction-free and keyboard-driven; a simple menu ties it together. It runs
in an ordinary window — make it fullscreen with your window manager if you want
to shut everything else out.

## Requirements

- **Linux**, with any audio backend miniaudio supports (PipeWire, PulseAudio,
  ALSA, JACK).
- [**mise**](https://mise.jdx.dev/) — manages the Odin *and* Python toolchains
  (both pinned in `mise.toml`); each is fetched automatically. Add
  `eval "$(mise activate zsh)"` to your shell rc (or the `bash`/`fish`
  equivalent) so entering the directory activates them. Without `mise activate`,
  use `mise exec -- <cmd>` / `mise run <task>` instead — shims alone will not
  activate the Python virtualenv.
- A **C/C++ compiler** (`cc`/`c++`, gcc or clang) — builds the vendored native
  libraries (miniaudio, TinySoundFont, NeuralAmpModelerCore, SoundTouch).
- **`clang` on your PATH** — Odin invokes it as the linker driver on every
  build, even when gcc compiles the C/C++ above. Install your distro's `clang`
  package (on Homebrew it's inside the keg-only `llvm` formula, so add
  `$(brew --prefix llvm)/bin` to PATH).
- **git** and **curl** — the first build clones/fetches native deps (Eigen for
  NAM, SoundTouch source); `assets/fetch.sh` downloads the audio assets.
- **Python + Demucs** — *only* for the **Import** step (stem separation). Playing
  already-separated songs and everything else needs no Python. Nothing is
  installed system-wide: mise pins the interpreter and creates a project
  virtualenv at `./.venv`, and `mise run setup-python` installs the locked deps
  (`requirements.lock.txt`) into it. That download is large — a few GB, mostly
  CUDA-enabled torch. Demucs is slow on CPU (minutes/song), fast on a GPU — a
  one-time cost per song.
- **Disk space for the library.** Separation turns one track into six stems.
  They're stored as mono FLAC (the app plays mono, so stereo would be discarded
  at load) which keeps a 5-minute song to roughly **40 MB** — but that still adds
  up across an album collection. By default the library lives in
  `~/.local/share/guitar-trainer/library`; set **`GUITAR_TRAINER_LIBRARY`** to
  put it on a bigger disk:

  ```bash
  GUITAR_TRAINER_LIBRARY=/mnt/big/guitar-trainer ./guitar-trainer
  ```
- Link-time libraries: the **X11 + OpenGL** stack (raylib), **sqlite3**,
  **libstdc++**, **libm**.
  - Distros put these in different places, and some (e.g. immutable/atomic ones)
    keep the dev `.so`s outside the default linker path. `build.sh` and `test.sh`
    add one extra `-L` + rpath via `BREW_LIB` for that case. If the link can't
    find `libX11.so`, `libGL.so`, `libsqlite3.so`, etc., set `BREW_LIB` to
    whichever prefix holds them; if they're already on the default path, the
    setting is inert and can be ignored.

## Getting started (fresh clone)

```bash
git clone git@github.com:tmbritton/guitar-trainer.git
cd guitar-trainer

# 1. Download the audio assets (SoundFonts, cabinet IRs, neural-amp models).
#    Third-party, not committed — see Third-party assets below.
assets/fetch.sh

# 2. (Optional, for importing songs) install the stem separator into ./.venv.
#    Several GB — CUDA-enabled torch is the bulk of it. Skip if you won't import.
mise run setup-python
mise run check-python   # prints demucs/torch versions + whether CUDA is on

# 3. Build. The FIRST run also fetches Odin (via mise) and builds the native
#    libraries — NAM clones Eigen, SoundTouch clones its source — so it takes a
#    few minutes. Later builds are fast.
./build.sh

# 4. Run.
./guitar-trainer
```

The neural-amp library is compiled with `-march=native`, so build on the machine
you'll run on for the fastest tone rendering (NAM inference is much quicker on a
desktop than a low-power laptop). Without the assets the app still runs — it falls
back to a built-in synth.

## Using it

The app opens on a **main menu** — Play a Song · Import Song · Practice Drill ·
Settings · Quit. `↑`/`↓` move, `Enter` selects, `Esc` goes back (and quits from
the menu).

**Import Song** — a file browser for picking what to separate.

| Key | Action |
|-----|--------|
| `↑` / `↓` | move |
| `Enter` | open a folder, or import the selected file |
| `Backspace` | up a folder |
| `P` | **Places** — jump to home, Music, or any mounted disk / USB stick / NAS share |
| `L` | type or paste a path (`Ctrl+V`) |
| `Space` | **mark** the selected row for batch import |
| `I` | import everything marked |
| `C` | clear marks |

Marking a **folder** means everything under it, so you can mark a few albums (or
a whole artist) and import them in one run. The queue skips anything already in
your library, so re-marking a part-imported album only does the remainder, and it
runs one song at a time — Demucs holds a single model on the GPU, so running them
concurrently would finish no sooner.

Imports spawn Demucs and show a progress bar; finished songs appear under **Play
a Song**.

**Play a Song** — a drill-down through your library: **Artist → Album → Song**,
built from the tags of the file you imported (songs list in album track order).
`↑`/`↓` move, `Enter` descends, `Esc` goes back up a level — and out to the menu
from the artist list. Songs with no tags fall back to the folder name under
"Unknown Artist".

Imported a song before this existed? Re-read its tags without re-running Demucs:

```bash
./guitar-trainer --meta library/<song-folder> /path/to/original.flac
```

Then the player:

| Key | Action | Key | Action |
|-----|--------|-----|--------|
| `Space` | play / pause | `G` | monitor your guitar on / off |
| `←` / `→` | seek | `,` / `.` | monitor drive − / + |
| `↑` / `↓` | select stem | `B` | cycle monitor cabinet |
| `+` / `−` | selected stem level | `9` / `0` | monitor level − / + |
| `M` | mute stem | `Z` / `X` | monitor bass − / + |
| `S` | solo stem | `C` / `V` | monitor treble − / + |
| `[` / `]` | speed − / + | `Esc` | back (saves mix + rig + speed) |

**Practice Drill** — `P` toggles the progress view; `Esc` returns to the menu.
Trial history is written to `trials.db` in the working directory.

**Settings** — tone, calibration, and audio devices:

| Key | Action |
|-----|--------|
| `1` / `2` | cycle the audio **input** / **output** device |
| `C` | calibrate round-trip latency |
| `N` / `A` | neural amp on-off / cycle amp model (Laney GH100S / JCM2000 / Dirty Shirley) |
| `B` / `I` | cycle cabinet / cabinet on-off |
| `F` / `V` | cycle guitar SoundFont / preset (the non-neural path) |

## Audio hardware

Detection runs on the dry DI signal and pick-attack timing is latency-sensitive,
so how you get your guitar in matters. Two things to know:

- **Play-along works with a cheap input.** The **Rocksmith Real Tone cable**
  (guitar → USB) is the least-fuss way to get playing: it's input-only (no
  output), so the app binds **capture** to the cable and **playback** to your
  speakers/headphones — the single duplex device supports two different endpoints.
  It should auto-detect; otherwise pick it in **Settings → `1`** (input device).
  The selection persists across runs. Its signal is hot and single-purpose, but
  for playing along it's fine.
- **A proper USB audio interface is better** for low latency (the drill's timing
  rewards it) and for recording guitar *and* a mic at once. Any **class-compliant
  (USB Audio Class 2.0)** interface is plug-and-play on Linux/PipeWire; a **Hi-Z
  instrument input** lets you plug your guitar straight in.

### Interfaces worth a look (2-input, class-compliant on Linux, ≲ $250)

Approximate USD (2026) — check current listings.

| Tier | Interface | ~Price | Inputs | Notes |
|------|-----------|-------:|--------|-------|
| Budget | **Behringer UMC202HD** | ~$90 | 2× combo | Cheapest solid option; shared phantom. |
| Budget+ | **Audient EVO 4** | ~$130 | 2× combo | Great preamps/converters for the price; Smartgain. |
| 1 mic + 1 gtr | **Focusrite Scarlett Solo (4th gen)** | ~$130 | 1× XLR + 1× Hi-Z | Exactly one mic **and** one guitar at once. |
| Best value | **Focusrite Scarlett 2i2 (4th gen)** | ~$200 | 2× combo | The default "just works on Linux" 2-in. |
| Lowest latency | **MOTU M2** | ~$200 | 2× combo | ESS Sabre converters, class-leading latency, plus loopback. |

The **MOTU M2** is the sweet spot if you want the best latency for the drill; the
**Audient EVO 4** or **Scarlett Solo** are the cheapest that do everything well.
Skip a **hexaphonic pickup** (Roland GK, Fishman TriplePlay) — it solves
string/fret disambiguation, a problem this app sidesteps by scoring *sound*.

## How the audio works

Two tone paths, both kept off the detection path (pitch detection always reads the
clean, dry signal — the amps only colour what you *hear*):

- **Offline modeled rig** (the drill's playback), rendered on a background thread
  so the UI never freezes:

  ```
  clean-DI SoundFont  ->  Neural Amp Modeler (real amp capture)  ->  cabinet IR
  ```

- **Realtime monitor amp chain** (live guitar while playing along) — a light,
  low-latency DSP chain that runs in the audio callback:

  ```
  input drive  ->  oversampled waveshaper  ->  tone shelves  ->  streaming-FIR cab
  ```

  Neural amp modeling is too CPU-heavy for the realtime path, so it stays the
  offline engine; the monitor uses the cheap DSP chain instead.

Audio is one duplex `ma_device` (miniaudio); the master clock is a sample counter
advanced in the callback, which never allocates or locks. Backing playback and
the live monitor are lock-free producer→callback handoffs.

## Development

```bash
./test.sh            # unit tests for all pure-logic packages (no hardware)
./build.sh -debug    # arms an audio-thread allocation guard (panics on any alloc)
```

Headless self-tests exercise the real audio pipeline over an internal loopback
(no hardware, no window):

```bash
./guitar-trainer --audiocheck     # duplex device + master clock are live
./guitar-trainer --devicecheck    # device enumeration + re-init to explicit IDs
./guitar-trainer --pitchcheck     # onset -> windowed YIN pitch
./guitar-trainer --drillsim       # full drill loop -> SQLite
./guitar-trainer --importcheck    # song import worker (Demucs stub) -> 6 stems
./guitar-trainer --playercheck    # stem player: mixer (mute/solo) + decode
./guitar-trainer --speedcheck     # SoundTouch time-stretch ratio
./guitar-trainer --monitorcheck   # live-monitor amp chain mixes into output
./guitar-trainer --riff           # audition the drill tone (plays a riff)
```

Architecture, invariants, and the full self-test list are in
[`CLAUDE.md`](CLAUDE.md). Per-story implementation notes are under `docs/`.

## Third-party assets & libraries

Audio assets are fetched by `assets/fetch.sh` (not committed; check each source's
terms for your use):

- **Guitar SoundFonts** — [zanderjaz.com](https://www.zanderjaz.com/downloads/soundfonts/guitars/)
- **Cabinet impulse responses** — [fnpngn/IR](https://github.com/fnpngn/IR)
- **Neural Amp Modeler captures** — [pelennor2170/NAM_models](https://github.com/pelennor2170/NAM_models)

Vendored / fetched libraries (built on first `./build.sh`):

- [TinySoundFont](https://github.com/schellingb/TinySoundFont) (MIT) — SF2 synth (`src/tsf/`).
- [NeuralAmpModelerCore](https://github.com/sdatkinson/NeuralAmpModelerCore) (MIT) — offline neural amp (`src/nam/`).
- [SoundTouch](https://codeberg.org/soundtouch/soundtouch) (LGPL) — pitch-preserving time-stretch (`src/soundtouch/`).
- [Eigen](https://eigen.tuxfamily.org/) (MPL2) and [nlohmann/json](https://github.com/nlohmann/json) (MIT) — NAM dependencies.
- Odin's `vendor:raylib` and `vendor:miniaudio`.

External tool (run as a subprocess for the Import step, not linked):

- [Demucs](https://github.com/adefossez/demucs) (MIT) — music source separation.

## License

Personal project — no license is currently specified. The bundled third-party
assets and libraries retain their own licenses (above).
