# Guitar Trainer — working notes

A single native Odin binary that trains auditory musical fluency on guitar. See
`docs/product-sketch.md` (spec) and `plan.md` (epics/stories + progress).
Per-story implementation plans live in `docs/epic-{N}/story-{M}.md`.

## Toolchain

- **Odin via mise**, pinned in `mise.toml` (`dev-2026-08`). Run Odin as
  `mise exec -- odin ...`.
- **`clang` must be on PATH** — Odin shells out to it as the linker driver on
  every build, regardless of which compiler builds the C/C++ libs. `-linker:lld`
  / `-linker:mold` don't avoid it; they only append `-fuse-ld=`. A `clang`
  wrapper that execs `gcc` works if a real clang isn't available.
- `vendor:raylib` and `vendor:miniaudio` ship with Odin. **miniaudio ships source
  only** — its `lib/miniaudio.a` is built on demand by `build.sh`/`test.sh`.
- **Python is mise-managed too** (pinned in `mise.toml`), with a project venv at
  `./.venv` (`_.python.venv`, auto-created). It only holds the song-import deps
  (Demucs); nothing else in the app uses Python. `mise run setup-python` installs
  `requirements.lock.txt`; `mise run lock-python` re-resolves it from
  `requirements.txt`. The venv activates under `mise activate` / `mise exec` only
  — **not** via shims. Note `uv_create_args = ["--seed"]`: mise builds the venv
  with `uv`, which ships no `pip`, so without it `pip install` silently escapes
  the venv and writes into the mise Python toolchain instead.

## Build & run

- `./build.sh` → `./guitar-trainer`, built `-o:speed` (needed — the DSP, esp.
  IR convolution, is ~10x slower unoptimized). `./build.sh -debug` arms the
  audio-thread allocation guard (panics on any alloc in the callback).
- raylib links the X11 stack + GL, and `store` links sqlite3. Where those dev
  `.so`s live varies by distro, so `build.sh`/`test.sh` pass an extra `-L` +
  rpath (`BREW_LIB`) for setups where they aren't on the default linker path.
  Point it at your own prefix if the link fails to resolve them.

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
                   (Play a Song / Import / Settings / Quit; the drill is off the
                    menu as of Story 6.21 but still built and still tested)
  drill.odin       drill state machine (Idle→Prep→Listen→Confirm→Fb_Prep→Feedback)
  drill_view.odin  drill HUD + progress-panel rendering (pure view)
  import.odin      song-import worker (spawn separate.py, read progress pipe)
  library.odin     library scan (finished songs + meta.txt) + file-browser listing
  librarypath.odin resolve the library root (env / XDG), created on demand
  placelist.odin   "Places" jump list: home, Music, mounted volumes
  importqueue.odin batch import: expand marked folders -> sequential file queue
  import_view.odin file browser / importing-progress / library screens (view)
  stems.odin       decode a song's 6 stems to mono f32 @ 48k (Song_Audio)
  stemload.odin    async stem load: one worker per stem, polled from the frame loop
  player.odin      song player: producer thread mixes stems -> PCM ring; transport
  player_view.odin player screen: mixer strip + transport + rig (pure view)
  songprefs.odin   per-song mixer + rig + speed persistence (library/<song>/mixer.txt)
  sections.odin    per-song practice sections (library/<song>/sections.txt)
  selftests.odin   headless --*check verification modes
  riff.odin        --riff / --riff-wav tone-audition modes
  screenshot.odin  --screenshot PNG capture
  audio.odin       duplex ma_device, callback, click generator, loopback, monitor
  audiodev.odin    device enumeration + capture/playback selection + re-init
  audioconf.odin   global audio-device config (audio.txt, name-based)
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
  songlib/         import protocol parse + slug + song-dir + meta.txt (unit-tested)
  places/          /proc/mounts parse -> media mount shortcuts   (unit-tested)
  sections/        practice-section format + speed-ladder math    (unit-tested)
  pcmring/         SPSC f32 sample ring (player->callback)  (unit-tested)
  mix/             stem-mixer gain math (level/mute/solo)   (unit-tested)
  ampchain/        realtime monitor amp DSP (oversampled ws + tone + FIR cab) (unit-tested)
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
6.3). Real Demucs lives in the project venv (`mise run setup-python`; pinned by
`requirements.lock.txt`) and is slow on CPU — a live/manual
gate; automated coverage uses `separate.py --stub` (no ML) via `--importcheck`.

## Song metadata + library grouping

`separate.py` also reads the **source file's tags** (mutagen, `easy=True` so
FLAC/MP3/MP4/OGG all give uniform key names) and writes
`library/<slug>/meta.txt` — a line-oriented `key value` file: `artist`,
`albumartist`, `album`, `title`, `track`, `disc`, `year`, `source`. Both the real
and `--stub` paths write it. Values are whitespace-normalized to one line, since
tags like `lyrics` carry embedded newlines that would corrupt the format.

`songlib.parse_meta` parses it (allocation-free — fields are subslices of the
caller's buffer, so `library.odin` clones them into the Song). Display falls back
gracefully: no `title` → the folder slug, no artist/album → `Unknown Artist` /
`Unknown Album`, so songs imported before metadata existed still list.
**Grouping prefers `albumartist`** over `artist`, or a "feat." track would split
its own album. `songlib.meta_less` sorts artist → album → disc → track → title,
so one sort feeds both the drill-down levels and album track order.

The Library screen is a **drill-down**: Artist → Album → Song (`Lib_Level` in
`import_view.odin`). `rows` holds the song indices backing the level on screen,
rebuilt only on a level change — never per frame. ENTER descends,
`library_view_enter` returning a Song only at the Song level; ESC ascends, and
`library_view_back` returns false at the top so `app.odin` knows to leave for the
main menu instead.

**Folder names:** a song's library folder is `<slug>-<8 hex hash of the full
source path>` (`songlib.unique_slug`). The hash is not decoration — naming from
the filename alone meant `Album A/01 Intro.mp3` and `Album B/01 Intro.mp3` both
resolved to `01-intro` and the second import silently overwrote the first. It is
stable, so re-importing the same file still resolves to the same folder and the
already-imported skip works. `already_imported` also accepts the **legacy**
filename-only folder, but only when that folder's `meta.txt` names the same
`source` — otherwise a different song sharing a filename would be wrongly skipped.

**Backfill:** `./guitar-trainer --meta <song-dir> <source-file>` re-reads tags
into an existing song via `separate.py --tags-only`, which skips separation
entirely — so re-tagging costs nothing and never re-runs Demucs.

## Where the library lives

`librarypath.odin` resolves the root once per process: `$GUITAR_TRAINER_LIBRARY`
→ `$XDG_DATA_HOME/guitar-trainer/library` → `$HOME/.local/share/guitar-trainer/
library` → `./library`. It used to be the bare relative literal `"library"`,
which meant the library silently depended on the working directory the binary was
launched from — and put hundreds of GB inside the source repo. Self-tests that
import must redirect it via `os.set_env(LIBRARY_ENV, ...)` **before** the first
`library_root()` call (it caches), or they pollute the real library.

## Stem format (mono FLAC)

Imports write six **mono FLAC** stems. The device is mono, so `stems.odin`
downmixes every stem to mono f32 on load anyway — stereo on disk costs ~3.4x for
audio that is discarded. Measured: a 5-minute song is ~39 MB mono FLAC against
~304 MB stereo WAV. Encoded by `soundfile` (bundles libsndfile in the wheel — no
system ffmpeg, which the demucs FLAC path would otherwise require).
`songlib.STEM_EXTS` lists `.flac` then `.wav`, and both `is_song_dir` and
`stems_load` accept either, so pre-FLAC imports keep working and the `--stub`
separator can stay on its dependency-free WAV writer.

## Batch import (choosing albums)

The Import browser reaches a media library three ways: **P** opens a Places jump
list (home, Music, and every mounted volume found in `/proc/mounts` via the pure
`places` pkg), **L** opens a path field (typing or CTRL+V), and BACKSPACE still
walks up. **SPACE marks** the selected row — a marked *folder* means "everything
under it", which is how an album or a whole artist gets picked — and **I** starts
the run.

`importqueue.odin` expands the marks (recursive, depth-capped at
`QUEUE_MAX_DEPTH` so a symlink cycle on a share can't walk forever), **skips
anything already in the library**, sorts by path (album order), then feeds
`import.odin` one file at a time. Sequential on purpose: Demucs holds one model
on the GPU, so concurrent separations would just contend. The UI calls
`queue_poll()` each frame to advance it.

**autofs caveat:** an idle automounted NAS share appears in `/proc/mounts` *only*
as an `autofs` entry — the CIFS/NFS mount exists just while something holds it
open. So autofs entries must be kept (skipping them hides exactly the shares
Places exists to reach), and their paths must **not** be `stat`ed to test
liveness: on a direct automount that triggers the mount and blocks until an
unreachable server times out.

## Song player (play-along)

Opening a library song (Play a Song → ENTER) loads its 6 stems and plays them
mixed. The decode is **asynchronous and parallel** (`stemload.odin`): one worker
per stem, a `.Loading` screen showing "N / 6 stems", and the player opens when
they land. It used to run synchronously on the main thread — ~2.1 s of frozen UI
for a 6-minute song, on one core — and is now ~565 ms with nothing frozen.
**Only the main thread frees**: workers write their own stem slot and decrement a
counter, and ESC does *not* join (a stem on a network share can take seconds), so
a cancelled load is left to drain and reaped by `frame_begin`'s per-frame
`stems_load_poll`. One load at a time — a decoded song is ~340 MB.

The device is **mono** (see audio.odin), so stems mix down to a mono backing
stream — stereo output would mean reconfiguring the device + every `out`-writer,
deferred. A **producer thread**
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

**Live monitoring:** the callback runs the **dry interface input** through a
realtime amp chain (`ampchain` pkg: input drive → **oversampled** waveshaper →
tone shelves → **streaming-FIR** cab → monitor level) and mixes it into the
player output, so you hear your guitar in a good tone while playing along. It's a
light DSP chain (not NAM — that stays the offline drill engine): cheap,
low-latency, allocation-free (holds under `-debug`). Detection still reads the
dry signal upstream (spec §9.3) — monitoring never feeds it. The chain is owned
by the callback; the UI changes params via atomics (`audio_set_monitor_*`), which
the callback applies; cab IRs are preloaded into fixed buffers so switching is a
race-free atomic index. **Dry monitoring** (`D`) bypasses the amp chain — a clean
passthrough at the monitor level for players using their own outboard amp.

**Practice sections:** a marked A-B span can be **named and saved** per song
(`sections` pkg + `sections.odin` → `library/<song>/sections.txt`, a sibling of
mixer.txt so a corrupt section line can't cost you your mixer). `N` arms/cycles,
`R` names the current span, `K` toggles that section's speed ladder, `T` cycles
the pre-roll, `DEL` removes; `L` disarms (it clears the loop, so leaving a
section armed would desync the HUD and the ladder).

The producer counts a **pass** on each wrap at B — but not one caused by a seek
(it tracks a `jumped` flag cleared only once audio has been produced from the new
position; a seek taken while *paused* wraps on a later iteration, so a
per-iteration flag is not enough). Spans shorter than `sections.MIN_FRAMES` are
refused: `player_loop_mark` makes a 1-frame span when both marks land on one
cursor, and armed at speed != 1.0 that spins a core (the stretcher is cleared
before it can emit, so the producer never reaches a sleep).
`sections.ladder_speed(start, passes)` is a pure function of the start speed and
pass count (not an accumulator, so it can't drift and re-arming lands on the same
tempo), moves toward 1.0 from either side, and is **off unless switched on**. A
manual `[`/`]` nudge takes the tempo over for that arming and becomes the
section's remembered speed — the ladder never fights the user for the tempo. The
"count-in" is a **musical pre-roll** (wrap to `A - preroll`), not a click track:
nothing extracts a tempo from an imported song, so a metronome could only tick at
an arbitrary rate.

Note **raylib's default font has no em dash** — `—` draws as `?`. The middot `·`
is fine. Stick to ASCII punctuation in anything passed to `DrawText`/`ui_text`.

**A-B loop:** `L` cycles mark-A → mark-B → clear (`player.odin`; loop points as
atomics, transient — reset on reopen). The producer wraps the cursor back to A at
B (like a seek: `st_clear`s the stretcher, clamps the block so it never crosses
B). **Drag-drop import:** dropping an audio file on the window (`rl.IsFileDropped`)
starts the same import flow as the browser.

A song that runs out reads **ENDED**, not PAUSED, and `SPACE` restarts it
(`player_restart`) — to the armed section's start if one is armed *and playable*,
else to the top. **`loop_on` being set is not the same as looping**: the producer
clamps loop B to the song length but not loop A, so a span starting past the end
(a hand-edited `sections.txt`) leaves the loop "armed" while nothing wraps.
`loop_span` holds that one definition, shared by the producer and the restart.
The producer's end-of-song branch also bails while a seek is pending, or it would
clobber the play flag a restart just set and leave the song rewound but paused.

Controls: `SPACE` play/pause (restart at the end), `←/→` seek, `↑/↓` select
stem, `+/-` level,
`M` mute, `S` solo, `[`/`]` speed, `L` A-B loop, `N` arm section, `R` save span,
`K` ladder, `T` pre-roll, `DEL` remove section, `G` monitor on/off, `D` dry
(bypass), `,`/`.` drive, `B` cab, `9`/`0` monitor level, `Z`/`X` bass, `C`/`V`
treble, `ESC` back (saves mix + rig + speed + sections per song).

## Audio-device selection

The **Rocksmith Real Tone cable is input-only**, so the single duplex `ma_device`
binds its **capture** (the cable) and **playback** (speakers) to *different*
devices — miniaudio allows distinct `capture.pDeviceID`/`playback.pDeviceID` in
one duplex config (`nil` = default). We own an `ma_context` (`audiodev.odin`) to
enumerate devices and bind chosen IDs; `device_open` builds the config from the
current selection, shared by `audio_init` and `audio_reinit` (Settings picker).
Selection resolves at startup: a name saved in `audio.txt` (`audioconf.odin`) →
else a **Rocksmith/Real-Tone/Guitar** capture auto-detect → else system default.
Settings: `1` cycles the audio IN device, `2` the OUT device (re-inits + saves).
A full interface (in+out) just works as the default duplex. Verified headless by
`--devicecheck` (enumerate + re-init to explicit IDs, clock stays live); the
Rocksmith routing itself is a plug-in-and-listen gate.

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
0.5x through the real producer), `monitorcheck` (live-monitor amp chain: over
loopback, output rises with monitoring on and returns to baseline at level 0),
`devicecheck` (enumerate audio devices; re-init the duplex device to explicit
device IDs; master clock stays live), `loopcheck` (A-B loop keeps the player
cursor inside the span and wraps at B), `endcheck` (a finished song restarts on
play, and mid-song pause/resume still carries on), `sectioncheck` (practice
sections: round-trip through the library, arming drives the real producer loop,
the pass counter advances, pre-roll runs up to A, the ladder advances only when
enabled), `loadcheck` (async
stem load: matches the sequential path, `stems_load_begin` returns without
decoding, a cancelled load frees itself; `--loadcheck <dir>` times one real song
both ways), `tempcheck` (temp allocator is bounded:
repeated `queue_expand` does not grow the arena, UI state survives a `free_all`,
and `frame_begin` — run_app's real frame prologue — reclaims), `queuecheck`
(batch import: recursive
folder expansion, already-imported skipping, path ordering, and a 3-song stub
run driven to completion in a redirected temp library), `stemcheck [dir]`
(decode real imported stems — the whole library by default — reporting per-song
length and stem count; catches a stem-format change the loader can't read),
`importedcheck <folder>` (report how many files under a folder the library does
not already hold — proves the already-imported skip, incl. legacy folder names),
`meta <song-dir> <source-file>` (backfill a song's meta.txt from its source
file's tags; no separation), `riff` / `riff-wav` (audition tone /
export WAV + timing).

## Status

**The stem play-along is the product** (Epic 6). Import a song, mix/slow/loop it,
and play the turned-down part yourself.

The **ear-training drill** (Epics 0-4) is code-complete and still fully tested,
but is **off the main menu** as of Story 6.21 and no longer the direction:
playing along with real songs proved far more fun. Its code, screen and five
self-tests are all intact, so restoring the menu entry is three small edits (a
row in `g_main_entries`, a `Main_Action` member, a router `case`) — don't delete
`drill.odin` / `drill_view.odin` / `game/` / `music/` on the assumption it is
dead. Note the **Settings screen's tone and calibration controls now change
nothing you can hear**: they feed the drill's offline NAM render, not the
play-along's `ampchain` monitor. That is Story 6.22's problem, not a bug.

The M3 three-weeks-daily-use gate (Story 4.2) and Epic 5,
which it gated, are parked with it.

Hardware-gated acceptance (<10 ms offset-corrected pick attack, real acoustic
calibration, plucked-note accuracy) still awaits a class-compliant USB Hi-Z
interface — not yet purchased; onboard audio + software loopback are used for
development. The live-monitoring path (6.5) and the Rocksmith cable routing (6.6)
have only ever run over loopback.
