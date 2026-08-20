# Guitar Trainer — Implementation Plan

> **How this plan works:** Epics group related work; each story is an independently testable deliverable.
> **Before starting any story**, its detailed implementation plan is written to `docs/epic-{N}/story-{M}.md` and reviewed.
> Stories are checked off here as they complete.

**Goal:** A single native Odin binary that trains auditory musical fluency on guitar — the user hears a tone and finds it on the fretboard, scored by sound (pitch class, octave, onset, duration), not fingering.

**Spec:** `docs/product-sketch.md`

**Tech stack:** Odin + `vendor:raylib` + `vendor:miniaudio`, single duplex `ma_device`, SQLite via C bindings. Linux (Bazzite / PipeWire) primary. Toolchain managed by **mise** (Odin available via `github:odin-lang/Odin`).

## Global Constraints (copied from spec — apply to every story)

- **Single native process, single binary.** No IPC, no daemon split, no web UI. `odin build src` (via `./build.sh`) produces the whole app.
- **Do NOT call raylib's `InitAudioDevice()`.** Own one `ma_device` in **duplex** mode: capture + playback in the same callback, one clock.
- **The audio clock is master.** Never derive musical time from `GetFrameTime()` or frame count. A monotonic sample counter, incremented in the audio callback, drives every scheduling and scoring decision. Convert to seconds only for display.
- **One SPSC lock-free ring buffer, audio → main.** The callback copies input, runs onset detection, pushes events. It **never allocates, never locks, never logs.**
- **`context.allocator = nil_allocator()`** (or a pre-sized arena) inside the miniaudio callback. Assert-on-allocation in debug builds.
- **Split onset from pitch.** Onset detection in the callback (~5 ms, spectral flux / energy), timestamped in samples. Pitch confirmation later on the main thread from a buffered window. Physics floor: a low-E note cannot be *confirmed* under ~25–40 ms — score timing off the onset, correctness off the late pitch.
- **Detect from the dry DI signal.** 48 kHz, mono input, 128-sample buffer to start. Target round-trip latency < 10 ms.
- **Score the sound, not the fingering.** Pitch class / octave / onset / duration. The fretboard is a search space, not a lookup table.
- **Scope discipline:** everything past M2 (v0) is gated on **three weeks of daily use (M3)**. No v1+ feature work — not even detailed planning — until that gate passes. The dominant project risk is building instead of playing.

---

## Epic 0 — Project Setup & Toolchain

Install prerequisites and stand up a buildable skeleton. Prefer mise for Odin.

- [x] **Story 0.1 — Install Odin via mise.** `mise use -g odin@latest`, pin in a project `mise.toml`, verify `odin version` and `odin report`.
- [x] **Story 0.2 — Buildable window skeleton.** `main.odin` opens a `vendor:raylib` window and runs a frame loop; `odin build .` produces one binary. Confirm `vendor:miniaudio` links (compile a stub that references it, without initializing a device yet).
- [x] **Story 0.3 — Audio environment sanity check.** Enumerate playback/capture devices via miniaudio, confirm the USB interface is present and duplex-capable, document PipeWire quantum (`PIPEWIRE_LATENCY=128/48000`). No device opened in the app yet — a throwaway probe is fine.

## Epic 1 — Audio Spine (Milestone M0)

**Done when:** a pick attack produces a timestamped event within 10 ms, offset-corrected.

- [x] **Story 1.1 — Duplex device.** *(device + clock + onset + ring verified live headlessly; formal <10ms pick-attack bar awaits USB interface + calibration)* Own a single `ma_device` in duplex mode (48 kHz, mono in, 128-sample buffer). Bypass raylib audio entirely. Callback runs; input and output frames are wired.
- [x] **Story 1.2 — Sample clock.** Monotonic sample counter incremented in the callback; a thread-safe read for the main thread. This is the master clock.
- [x] **Story 1.3 — SPSC ring buffer.** Lock-free single-producer/single-consumer ring (`ring.odin`), audio → main. Main thread drains; callback only pushes.
- [x] **Story 1.4 — Realtime-safe callback discipline.** *(guard allocator; debug `--audiocheck` runs 2s with 0 alloc attempts)* `nil_allocator()` in the callback context; debug assert that fires if any allocation is attempted on the audio thread.
- [x] **Story 1.5 — Onset detection.** *(logic + tests; live pick-attack timing verified in Story 1.1 / M0 with hardware)* Spectral-flux / energy onset in the callback, timestamped in samples, pushed as a ring event. ~5 ms budget.
- [x] **Story 1.6 — Calibration screen.** *(offset math + click generator + driver; verified over software loopback via `--calibcheck`; real acoustic offset awaits interface)* Emit a click, detect it back through pickup/loopback, measure round-trip offset, store the delta, subtract it from every judgment. StepMania flow is the reference.

## Epic 2 — Pitch Detection (Milestone M1)

**Done when:** correctly identifies every note on the neck, plucked and picked, on a clean signal.

- [x] **Story 2.1 — Windowed pitch buffer.** *(history ring + windowed detect; `--pitchcheck` detects 220/330/440Hz over loopback within 0.02Hz)* Buffer input windows (1024–2048 samples) on the main thread, keyed to onset timestamps from the ring.
- [x] **Story 2.2 — YIN/MPM detector.** *(YIN; within 1Hz E2..E5 on synthetic tones)* `detect/pitch.odin` — autocorrelation-family pitch detection over the window, on the main thread. Returns frequency → MIDI.
- [x] **Story 2.3 — "No confident pitch" state.** *(voiced flag; silence/noise reported unvoiced)* Return an explicit low-confidence/unvoiced result rather than guessing (bends, palm mutes, dead strings).
- [x] **Story 2.4 — Fretboard accuracy harness.** *(synthetic sweep MIDI 40..88 all correct; real plucked-note verification awaits interface)* A test/verification pass over notes across the neck (recorded or live) confirming correct identification. Fix accuracy before any game work.

## Epic 3 — v0 Scale-Degree Drill (Milestone M2)

**Done when:** playable end to end — cadence plays, target tone plays, user finds it, judged, logged.

- [x] **Story 3.1 — Music theory core.** `music/theory.odin` — keys, scale degrees, degree ↔ MIDI mapping in a chosen key/octave.
- [x] **Story 3.2 — Cadence generation & playback.** *(cadence notes tested; synth voice engine verified via `--synthcheck`)* Generate and synthesize a I–IV–V–I cadence in a random key through the duplex output.
- [x] **Story 3.3 — Trial loop.** *(game pkg judged pure; full cadence->target->listen->judge verified via `--drillcheck`, incl. octave-agnostic)* `game/degrees.odin` — cadence → random target scale degree (tone) → listen → judge detected pitch class against target → next trial. Octave-agnostic pitch-class judging to start (open question 12.3).
- [x] **Story 3.4 — SQLite trial log.** *(hand-written sqlite3 bindings; insert/count/persist tested; `sqlite3` CLI cross-check via `--storecheck`)* `store.odin` — SQLite via C bindings; single `trials(id, ts, key, target_degree, target_midi, detected_midi, onset_offset_samples, correct, response_ms, session_id)` table; insert per trial. Resist adding tables.
- [x] **Story 3.5 — Naive trial scheduling.** *(log-weighted degree selection; deterministic pick tested; store.degree_stats aggregation tested)* Start with simple selection (random / lightly weighted); instrument via the trial log, defer SM-2 vs. Kellman decision to data (open question 12.2).
- [x] **Story 3.6 — Drill UI & gamefeel.** *(frame-stepped drill state machine, delayed auditory feedback, per-trial SQLite logging; `--drillsim` PASS, live GUI runs)* Minimal on-screen loop with count-in, feedback that is delayed/phrase-level and auditory where possible (backing stumbles on wrong, locks on right) — not per-note green/red.

## Epic 4 — Daily-Use Gate & Instrumentation (Milestone M3)

**The real milestone.** A hard gate: no v1+ work until three weeks of daily use.

- [x] **Story 4.1 — Session & progress instrumentation.** *(store aggregates tested; progress panel toggled with P; `--progresscheck` PASS)* Session IDs on trials; a minimal progress view derived entirely from the trial log (no new tables). Enough to answer "did I practice today" and "am I improving."
- [ ] **Story 4.2 — Three weeks of daily use.** Not a coding task. Use the drill daily; capture friction notes against open questions (§12): engagement past day 10, octave-agnostic slop, scheduling behavior. **Gate — do not proceed to Epic 5 until met.**

## Epic 5 — v1 Call and Response (Milestone M4) — GATED, plan later

Deferred. **Do not write detailed story plans for this epic until Epic 4's gate is met.** Listed only so the roadmap is visible.

- [ ] **Story 5.1 — Phrase generation** (constrained random walks within a key/position).
- [ ] **Story 5.2 — Playback + capture of a 1–2 bar phrase.**
- [ ] **Story 5.3 — Sequence scoring** (pitch sequence + onset timing; weighting favors timing/contour at low skill, inverts as skill rises).
- [ ] **Story 5.4 — Adaptive chunk length** (extend on success, contract on failure).

## Beyond v1 (v2 songs + fade ladder, v3+ deferred)

Out of scope for this plan per spec §3 and §7. Recorded here so they are not forgotten: local `psarc → gp5 → render` import, the fade ladder against real material, level-6 dropout mode (v2); tune-by-ear, transcription trainer, sing-then-play, notation, other instruments (v3+).

## Epic 6 — Stem Play-Along (new primary direction)

A menu-driven song play-along: import a track, separate it into stems (external Demucs), mix/mute/solo/level + slow it down, and play the turned-down part yourself, judging by ear. Per-song amp/cab prefs; live input monitored through a realtime DSP amp chain (NAM stays offline). Design: `docs/superpowers/plans/` / the approved plan. The drill (Epics 0–4) stays as one menu entry.

- [x] **Story 6.1 — Menu / screen router.** *(run_app is a keyboard-driven screen router; drill + tone/cab/calibration controls moved under Drill / Settings; `menu` pkg unit-tested. main.odin also split into focused files and all source moved under `src/`.)* `run_app` becomes a screen router (Main Menu → Play a Song / Import / Practice Drill / Settings / Quit); the drill + tone/cab/calibration controls move under Drill / Settings. Keyboard-driven, reuses `ui.odin`.
- [x] **Story 6.2 — Song import + Demucs separation with progress.** *(Import screen = keyboard file browser; picking a file spawns `assets/separate.py` (Demucs `htdemucs_6s`, 6 stems) on a worker that reads its `PROGRESS/DONE/ERROR` stdout over a pipe → live progress bar → stems cached to `library/<slug>/` → Play a Song lists them. Pure logic in the `songlib` pkg (unit-tested); the subprocess/pipe path covered headless by `--importcheck` against `separate.py --stub`. Real Demucs is a live/manual gate.)* In-app file browser → spawn `separate.py` (Demucs 6-stem) on a worker → progress bar → cache stems to a library → Library screen.
- [x] **Story 6.3 — Player: stems + mixer + transport.** *(Play a Song → ENTER loads a song's 6 stems (`stems.odin`, mono f32 @ 48k) and plays them mixed. Producer thread (`player.odin`) mixes stems from a shared cursor (`mix` pkg gains) into a lock-free PCM ring (`pcmring` pkg) that the callback drains in player mode; UI drives it via atomics. Per-stem mute/solo/level, play/pause/seek; mixer persists per song (`songprefs.odin`). `pcmring`+`mix` unit-tested; producer/ring/mixer path covered headless by `--playercheck`. Device is mono, so mono backing — stereo deferred.)* SPSC PCM ring + producer thread; load stems, play synced, per-stem mute/solo/level, play/pause/seek; persist mixer per song.
- [x] **Story 6.4 — Playback speed (time-stretch).** *(Vendored SoundTouch (LGPL C++, `src/soundtouch/`, built on-target into `libsoundtouch.a` like nam/tsf via a C shim + Odin binding) spliced into the player's producer: each mixed block feeds through it, stretched output goes to the ring. Pitch-preserving; cursor stays in input frames so transport time is right at any speed; speed 1.0 bypasses the stretcher entirely (default path unchanged). `[`/`]` control it (0.5–1.25); `--speedcheck` asserts the output/input ratio through the real producer.)* Vendored SoundTouch in the producer chain (pitch-preserving).
- [x] **Story 6.5 — Live monitoring + per-song rig.** *(`ampchain` pkg: realtime DSP amp chain — input drive → oversampled waveshaper → tone shelves → streaming-FIR cab → monitor level, unit-tested. Wired into the callback's player path over the dry input, mixed into the output; params via atomics, cabs preloaded (race-free index), allocation-free under `-debug`. Detection still reads dry (spec §9.3). Per-song rig (drive/tone/cab/level) + speed persisted (`songprefs`); player HUD + keys (`G` `,/.` `B` `9/0` `Z/X` `C/V`). `--monitorcheck` verifies the path over loopback.)* Oversampled DSP amp chain on the live input; per-song amp/cab/monitor prefs.
- [x] **Story 6.6 — Audio-device selection.** *(Own an `ma_context` (`audiodev.odin`) to enumerate devices and bind the duplex device's `capture.pDeviceID`/`playback.pDeviceID` to chosen devices — the input-only Rocksmith cable → speakers. `device_open` shared by `audio_init`/`audio_reinit`; resolution at startup: saved name (`audio.txt`, `audioconf.odin`) → Rocksmith/guitar capture auto-detect → default. Settings `1`/`2` cycle in/out devices. `--devicecheck` verifies enumerate + re-init to explicit IDs with the clock live; the cable routing is a plug-in gate.)* Enumerate devices; bind the duplex device's capture + playback to chosen devices; persist the choice; picker in Settings.
- [x] **Story 6.7 — Fast-follow.** *(A-B loop: `L` cycles mark-A → mark-B → clear; the producer wraps the cursor at B (`--loopcheck`). Drag-drop import: dropping an audio file on the window reuses the import flow. Dry monitoring: `D` bypasses the amp chain for a clean passthrough; persisted in the per-song rig.)* A-B loop; drag-drop import; dry monitoring.
- [x] **Story 6.8 — Toolchain: project-scoped Python + portable build.** *(Import failed with "demucs not found" because there was no managed Python at all. mise now pins Python alongside Odin and owns a project venv (`_.python.venv`, `./.venv`) with `setup-python` / `lock-python` / `check-python` tasks and a 52-package `requirements.lock.txt`. Two traps found and documented: mise builds the venv with `uv`, which ships no `pip`, so without `uv_create_args = ["--seed"]` a `pip install` silently escapes the venv and writes into the mise Python toolchain (4.8 GB landed there before this was caught); and demucs 4.1.0 imports numpy without declaring it, so a plain `pip install demucs` yields a venv that fails at import. `import.odin` resolves `./.venv/bin/python3` directly so importing works outside a mise-activated shell. Also made the build docs host-agnostic (`clang` is Odin's linker driver on every platform; `BREW_LIB` documented as an optional extra `-L`), and disabled raylib's default ESC exit key — ESC is now per-screen "back" and quits only from the main menu.)* Contain the Python dependency to the project; make the build reproducible off one host.
- [x] **Story 6.9 — Song metadata + grouped library.** *(`separate.py` reads the source file's tags with mutagen (`easy=True`, so FLAC/MP3/MP4/OGG give uniform keys) and writes `library/<slug>/meta.txt` — a line-oriented `key value` file, values whitespace-normalized because tags like `lyrics` carry embedded newlines. `songlib/meta.odin` parses it allocation-free (subslices of the caller's buffer, cloned by `library.odin`); grouping prefers `albumartist` over `artist` so a "feat." track can't split its own album; `meta_less` sorts artist → album → disc → track → title, feeding both the drill-down levels and album track order from one sort. The Library screen became a drill-down (Artist → Album → Song, `Lib_Level`) whose `rows` rebuild only on level change; ENTER descends, ESC ascends and leaves for the menu only at the top. Player shows title + artist instead of the folder slug. `--meta <song-dir> <source-file>` backfills tags via `separate.py --tags-only`, skipping separation entirely. 8 new songlib tests; all three levels screenshot-verified.)* Display artist/album/title from file tags; group the library by Artist/Album/Song in album order.
- [x] **Story 6.10 — Library location + mono FLAC stems.** *(The library was the bare relative literal `"library"`, so it depended on the working directory the binary was launched from and put stems inside the source repo. `librarypath.odin` now resolves it once: `$GUITAR_TRAINER_LIBRARY` → `$XDG_DATA_HOME/...` → `$HOME/.local/share/guitar-trainer/library` → `./library`. Stems changed from stereo 16-bit WAV to **mono FLAC**: the device is mono so `stems.odin` downmixes on load anyway, making stereo pure waste. Measured on a real Demucs run: ~39 MB for a 5-minute song against ~304 MB — 7.8x. Encoded with `soundfile` (bundles libsndfile; the demucs FLAC path would otherwise need system ffmpeg). `songlib.STEM_EXTS` lists `.flac` then `.wav` and both `is_song_dir` and `stems_load` accept either, so pre-FLAC imports keep working and `--stub` stays on its dependency-free WAV writer. New `--stemcheck [dir]` decodes real library stems and reports length + stem count.)* Move the library out of the repo and make it configurable; stop storing 8x more stem audio than the app can play.
- [x] **Story 6.11 — Browse anywhere + batch album import.** *(Reaching a media library meant walking up to `/` and back down. Import now has three modes: `P` opens a **Places** jump list (home, Music, and every mounted volume parsed from `/proc/mounts` by the pure `places` pkg), `L` opens a path field (typing or CTRL+V), and BACKSPACE still walks up. `SPACE` marks a row — a marked *folder* means everything under it, which is how an album or artist gets picked — and `I` starts the run. `importqueue.odin` expands marks recursively (depth-capped so a symlink cycle on a share can't walk forever), skips anything already in the library, sorts by path, and feeds `import.odin` one file at a time — sequential on purpose, since Demucs holds one GPU model and concurrency would only contend. Key finding: an idle automounted NAS share appears in `/proc/mounts` **only** as an `autofs` entry, so skipping autofs hid exactly the shares Places exists to reach; and such paths must never be `stat`ed to test liveness, because on a direct automount that triggers the mount and blocks until an unreachable server times out. 7 `places` tests; `--queuecheck` covers expansion, skip-already-imported, path ordering, and a 3-song stub run driven to completion in a redirected temp library.)* Pick folders/albums to import from anywhere, including a NAS share.
- [x] **Story 6.12 — Import completion summary.** *(Fixed a hang, not just a missing message: `queue_poll` calls `import_reset()` as it retires the last song, so `import_progress()` reported `Idle` on that frame and never `Done` again — the Importing screen sat at 0% on "separating stems" with a blank title and ENTER dead, escapable only by ESC and indistinguishable from a crash. Completion is now **latched in the queue** (`finished`, plus elapsed time and the names of failures) and the screen keys off `queue_is_batch() ? queue_finished() : per-song state`. A finished batch replaces the screen with a summary — "N songs added", elapsed, and any failures named so a bad file is actionable — and the footer now advertises the ENTER that always worked. `--queuecheck` asserts the latched state and the summary tallies, guarding the regression.)* A distinct completed state for single and batch imports.
- [ ] **Story 6.13 — Native separation: drop the Python dependency.** Replace the
  `assets/separate.py` subprocess with in-process inference, so a fresh clone
  needs no venv, no multi-GB torch download, and no `PROGRESS/DONE/ERROR` pipe
  protocol. Python is used for three separate things and each needs its own
  answer — separation is the hard one, the other two are small:
  - **Separation.** Two viable routes, and the choice hinges on GPU support.
    (a) [`demucs.cpp`](https://github.com/sevagh/demucs.cpp) — C++17 + header-only
    **Eigen3** (already vendored for NAM, so this fits the existing on-target
    build pattern exactly) + OpenMP, supports `htdemucs_6s`, quality "practically
    identical" to PyTorch. But it is **CPU-only by design** (built for low-memory
    environments, trading away Torch's speed) — a real regression here, where
    separation currently runs ~5x realtime on the GPU. (b)
    [`demucs.onnx`](https://github.com/sevagh/demucs.onnx) + ONNX Runtime's C API —
    keeps GPU via the CUDA execution provider, and `htdemucs_6s` ONNX weights are
    published; the cost is a large prebuilt ORT dependency rather than a
    source-built one. **Benchmark (b) on the target GPU against today's ~5x
    realtime before committing** — if it holds, (b); if ORT proves painful to
    vendor, (a) with the CPU cost accepted.
  - **Tag reading (mutagen).** A native `meta` pkg: FLAC Vorbis comments, ID3v2,
    MP4 atoms. Pure and unit-testable, and `songlib.parse_meta` / `meta.txt`
    already isolate the rest of the app from where tags come from.
  - **FLAC encoding (soundfile).** miniaudio decodes FLAC but does not encode, so
    this needs libFLAC (or accept larger mono WAV stems).
  Note the model weights need a one-off conversion (ggml for `demucs.cpp`, ONNX
  for `demucs.onnx`) — but pre-converted weights are published, so `assets/fetch.sh`
  can just download them and the runtime stays genuinely Python-free.
- [x] **Story 6.14 — Batch-import correctness.** *(All six review findings fixed. **Slug collisions** — library folders are now `<slug>-<8 hex FNV-1a of the full source path>` (`songlib.unique_slug`), so `Album A/01 Intro.mp3` and `Album B/01 Intro.mp3` no longer collapse onto one folder and silently lose a song; the hash is stable, so the already-imported skip still works across runs. Legacy filename-only folders are still recognised — but only when the folder's `meta.txt` names the same source, so a *different* song sharing a filename isn't wrongly skipped. Verified against the real 106-song library: re-marking an imported album reports 0 to import, so nothing is re-separated. **Duplicate marks** deduped in `queue_add`. **cwd-relative separator** — the venv interpreter and `assets/separate.py` now resolve against the binary's own directory (`app_dir`, cached), matching the cwd-independence Story 6.10 established. **String leak** — `queue_begin_next` frees the popped entries, and `current` is copied into a fixed buffer first (a view would dangle while `importing_draw` renders it). **Silent `I`** now posts "already imported — nothing to do". **Duplicate `is_finished_song`** collapsed into one shared `is_finished_song_dir`. New `--importedcheck <folder>` reports what a folder would still import.)* Fix the defects code review found in Story 6.11.
- [x] **Story 6.15 — Bound the temp allocator.** *(Nothing in `src/*.odin` ever
  called `free_all(context.temp_allocator)`, and Odin's default temp allocator is
  a **growing arena** — it reclaims nothing until something frees it. Draw code
  formats a dozen strings a frame, so the process grew for as long as the window
  stayed open; worse, `queue_expand` reads a directory listing and joins a path
  per entry, recursively, so marking a large NAS folder left the entire walk
  resident. Measured on a 120-file tree: **41 KB retained per expansion**. The
  two need different fixes and conflating them breaks things — the frame loop can
  `free_all` outright, but a recursive walk cannot, because a nested call would
  free the parent's still-live listing. `collect_audio` and `queue_expand` use
  `runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD` instead, a scoped watermark restore
  that unwinds correctly through recursion and takes peak temp from O(files) to
  O(depth). Also closed a hole in the audio-thread guard: the callback set
  `context.allocator` to the guard but left `context.temp_allocator` pointing at
  the audio thread's own arena, so a stray *temp* allocation — exactly what the
  guard exists to catch — would have been invisible. New `--tempcheck` asserts all
  three claims, including that library/browser state survives a temp reset (the
  per-frame reset depends on that invariant) and that `run_app`'s real frame
  prologue reclaims — the prologue was extracted into a named `frame_begin` for
  exactly that reason, after review caught that the first version of this test
  drove a `free_all` written in the test itself and so proved nothing about the
  app. Verified with the
  guard armed: `-debug` `--audiocheck` / `--monitorcheck` / `--playercheck` show
  0 allocation attempts.)* Free per frame in `run_app` and scope the walk in
  `queue_expand`.
- [ ] **Story 6.16 — Saved riff sections (practice a passage).** Story 6.7 already
  loops a span: `L` cycles mark-A → mark-B → clear and the producer wraps at B.
  What's missing for actually *drilling a riff* is everything around it. The loop
  is explicitly transient — `player_open` calls `player_loop_clear()` and nothing
  in `songprefs.odin` stores it — so the passage you set up is gone the moment you
  leave the song, and there is only ever one anonymous region. Wanted:
  - **Named sections persisted per song** (extend `mixer.txt`, which is already
    tolerant of missing/short lines, or a sibling `sections.txt`): "chorus riff",
    "solo", each with A/B frames. Pick one to arm the loop; the player's existing
    wrap logic does the rest.
  - **A section list in the player** — cycle/select, showing markers for all of
    them on the seek bar rather than just the armed pair.
  - **Practice affordances** on the armed section, which is the actual point:
    a repetition counter and a count-in before each pass.
  - **Speed stays manual by default.** `[`/`]` already control speed (0.5–1.25),
    and that is the primary way to work a passage up — you decide when you're
    ready, because you can hear it and the app can't. Persist the per-section
    speed so re-arming a section returns you to the tempo you were working at.
  - **An optional speed ladder**, off unless explicitly enabled: step toward 1.0
    every N passes, using the SoundTouch stretcher already in the producer.
    Opt-in per section, and a manual `[`/`]` nudge while it's running takes over
    (the ladder should never fight the user for control of the tempo).
  Keep the frame math in the player (loop points are already atomics read by the
  producer) and the persistence pure, so a headless check can assert that a saved
  section round-trips, that per-section speed restores, and that the ladder
  advances only when it is switched on.
- [x] **Story 6.17 — Run in a window (drop forced fullscreen).** *(`run_app` no longer calls `ToggleBorderlessWindowed()` or `HideCursor()` — the app opens as an ordinary resizable window, and fullscreen is left to the window manager, which already does it well. Forcing it took over the machine while a multi-hour batch import ran, and made the pointer unusable. `SetConfigFlags({.WINDOW_RESIZABLE})` moved above `InitWindow` (flags set afterwards are ignored) and a minimum size of 400x240 keeps the text readable. Almost no layout work was needed: every screen already renders into a fixed 800x480 texture that `blit_fit` scales and letterboxes to the current window each frame — verified by the `fullscreen` screenshot, which blits into a 1280x600 window with correct side bars. Fullscreen is no longer a stated design goal; README updated.)* Stop forcing fullscreen; run in a normal resizable window.
- [x] **Story 6.18 — Song loading must not block the UI.** *(Selecting a song
  froze the app for ~2 s before the player appeared, which reads as a hang.
  **Cause:** `app.odin` called `stems_load(s.dir)` synchronously on the main
  thread and only switched to the player once all six stems had decoded, so
  nothing could redraw and the stale Library frame stayed up. Measured with
  `--stemcheck` on a real 380-second song: **2.08 s user, 99% of a single CPU**
  on a 12-core machine — and *not* the mono-FLAC change from 6.10 (the one
  remaining WAV song takes 1.9 s, so the codec is nearly free). Two fixes, and
  only the second removes the wait: `stemload.odin` decodes on **one worker per
  stem** (they are six independent files and eleven cores were idle), publishing
  through atomics like `render.odin`/`import.odin`/`player.odin`, while a new
  `.Loading` screen draws a live "N / 6 stems" bar from the first frame after
  ENTER. Real measurement: **2236 ms sequential -> 565 ms parallel, 4.0x**, with
  zero frozen frames. ESC cancels **without joining** — a stem on a network share
  can take seconds and joining would reintroduce the freeze — so the job is left
  to drain and reaped by `frame_begin`'s per-frame `stems_load_poll`; only the
  main thread ever frees, which is what keeps the ownership single-sided — and
  because that leaves the loader briefly refusing a new job, choosing a song
  during the drain latches a **pending open** that retries each frame, rather
  than silently swallowing the ENTER (the review's find: worst exactly on the
  network share the non-join exists for). One load at a time on purpose: a
  decoded song is ~340 MB, so overlapping two would double peak memory. New `--loadcheck` asserts the parallel path returns the
  same PCM as the sequential one (a crossed stem slot would show), that
  `stems_load_begin` returns in a fraction of the decode time rather than
  blocking, that a cancelled load drains **and frees** (`stems_load_held` back to
  0 — returning to Idle is not the same thing), and that a song with no stems
  ends Failed rather than hanging. Review caught that the first version asserted
  "parallel was faster than sequential", which flakes: on synthetic WAV the
  margin is a few ms, the sequential run warms the page cache for the parallel
  one, and it failed 1 in 6 under load — wall clock is now reported, never
  asserted, and `--loadcheck <dir>` measures the real thing on real FLAC.)* Decode stems
  on a worker, in parallel, behind a loading screen.
