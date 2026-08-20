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
- [~] **Story 4.2 — Three weeks of daily use. PARKED 2026-08-20.** *(The gate was
  never met and is no longer being pursued: playing along with real songs turned
  out to be far more fun than the drill, so the stem play-along (Epic 6) became
  the product and the drill came off the main menu in Story 6.21. Worth noting
  that this gate did its job — it existed to stop us building instead of playing,
  and what it surfaced was that we were building the wrong thing. The drill code
  and its self-tests stay in the tree, so this is reversible.)* Not a coding task.
  Use the drill daily; capture friction notes against open questions (§12).
  **Was the gate on Epic 5.**

## Epic 5 — v1 Call and Response (Milestone M4) — PARKED

**Parked 2026-08-20 with Story 4.2.** This epic extends the *drill*, which is no
longer the product (see Story 6.21). Listed only so the roadmap stays legible; do
not plan it unless the drill comes back off the shelf.

- [ ] **Story 5.1 — Phrase generation** (constrained random walks within a key/position).
- [ ] **Story 5.2 — Playback + capture of a 1–2 bar phrase.**
- [ ] **Story 5.3 — Sequence scoring** (pitch sequence + onset timing; weighting favors timing/contour at low skill, inverts as skill rises).
- [ ] **Story 5.4 — Adaptive chunk length** (extend on success, contract on failure).

## Beyond v1 (v2 songs + fade ladder, v3+ deferred)

Out of scope for this plan per spec §3 and §7. Recorded here so they are not forgotten: local `psarc → gp5 → render` import, the fade ladder against real material, level-6 dropout mode (v2); tune-by-ear, transcription trainer, sing-then-play, notation, other instruments (v3+).

## Epic 6 — Stem Play-Along (new primary direction)

A menu-driven song play-along: import a track, separate it into stems (external Demucs), mix/mute/solo/level + slow it down, and play the turned-down part yourself, judging by ear. Per-song amp/cab prefs; live input monitored through a realtime DSP amp chain (NAM stays offline). Design: `docs/superpowers/plans/` / the approved plan. **This is the product.** The drill (Epics 0–4) was originally kept as one menu entry; as of Story 6.21 it is off the menu — the code stays, but playing along with real songs proved far more compelling than drilling scale degrees.

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
- [~] **Story 6.13 — Native separation: drop the Python dependency. DECLINED
  2026-08-20.** *(Decision made against the report in
  `docs/epic-6/story-13-report.md`: the juice isn't worth the squeeze. The
  numbers that settled it — separation is the only hard one of Python's three
  jobs, and going native costs **6-8x on import speed** (demucs.cpp is CPU-only
  by design; its author's own benchmark is 4m09s for a 4-minute song on a 16c/32t
  5950X against our ~48 s on the GPU, which is 9-12 hours to re-import the
  106-song library instead of ~1.5). demucs.onnx keeps the GPU only via a CUDA
  execution provider that requires CUDA + cuDNN on the user's machine, so it
  relocates the multi-GB dependency rather than removing it. The benefit being
  bought — handing someone a single binary — is not a goal today, and the venv is
  a one-time setup cost for the one person using this. Reopen this if
  distribution ever becomes a real requirement; the report holds the measurements
  and the recommended shape (demucs.cpp as a **fallback** behind the existing
  separator seam, not a replacement, so the GPU path survives).)* Replace the
  `assets/separate.py` subprocess with in-process inference.
- [~] **Story 6.19 — Portable build flags.** *(Superseded by Story 7.1 — it is
  the first step of Epic 7 rather than a stray item under Epic 6.)*
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
- [x] **Story 6.16 — Saved riff sections (practice a passage).** *(Story 6.7 already
  looped a span; what was missing was everything around it — the loop was
  transient (`player_open` cleared it, nothing persisted it), so the passage you
  set up vanished on leaving the song, and there was only ever one anonymous
  region. Added identity, persistence, plurality and drill feedback, with the
  A-B machinery itself untouched. New pure `sections` package (11 tests):
  `Section {name, a, b, speed, ladder}`, a line format, allocation-free `parse`
  (names are subslices, as in `songlib.parse_meta`), `format` that normalizes a
  typed name to one line, and `ladder_speed`. Persisted in a sibling
  `library/<song>/sections.txt`, **not** inside `mixer.txt`: that file is a
  fixed-shape positional record and sections are a variable-length list, so
  keeping them apart means a corrupt section line cannot cost you your mixer.
  The producer counts a pass each time it wraps at B — it is the only thing that
  knows a repetition completed — and `player_loop_set` arms a saved span
  directly. Player keys: `N` arm/cycle, `R` save the current A-B span (modal
  name field, which owns the keyboard or every letter would also fire a player
  shortcut), `K` ladder, `T` pre-roll, `DEL` remove; markers for **every** saved
  section on the seek bar, plus a pass counter and the ladder state. **The ladder
  is opt-in and pure**: `ladder_speed(start, passes)` is a function of the
  starting speed and the pass count rather than an accumulating value, so it
  cannot drift and re-arming lands on the same tempo; it moves toward 1.0 from
  either side and stops. A manual `[`/`]` nudge takes the tempo over for that
  arming and becomes the section's remembered speed — the ladder must never
  fight you for control of the tempo, because you can hear whether you are ready
  and the app cannot. **Judgement call on the count-in:** the plan asked for a
  click before each pass, but nothing in the import pipeline extracts a tempo, so
  a metronome could only tick at a rate unrelated to the music — which for a
  timing exercise is worse than nothing. It is a **musical pre-roll** instead:
  the wrap goes to `A - preroll` so you hear the run-up into the passage, the way
  a loop pedal does, needing no tempo. Also fixed a rendering bug the screenshots
  caught: raylib's default font has no em dash, so `—` was drawing as `?` on the
  Importing and Library screens too. `--sectioncheck` covers the round-trip
  (including surviving a temp reset), arming the real producer, the pass counter,
  the pre-roll, and the ladder advancing only when enabled. Review fixes: `L`
  while armed desynced `armed` from the loop and let the ladder audibly yank the
  tempo back; a seek past B credited a pass never played (the producer now tracks
  a `jumped` flag that persists across iterations, since a seek taken while
  paused wraps on a *later* one); a whitespace-only name was accepted, written as
  empty and silently dropped on reload; a 1-frame span — reachable by pressing
  `L` twice while paused — could be persisted and then **spun a core** when armed
  at speed != 1.0, because the producer cleared the stretcher every iteration and
  so never reached a sleep; there was no actual section list, only markers and a
  count; and silent keys now say why. Two of my own tests were caught as weak and
  rewritten: the pre-roll assertion was flaky (3 failures in 200 — it sampled the
  cursor too coarsely to see a 0.25 s window) and the seek-credit test exited
  before the wrap it was judging.)* Named, persisted
  practice sections with a repetition counter, pre-roll, and an opt-in speed
  ladder.
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

- [ ] **Story 6.20 — SPACE restarts a finished song.** When a song reaches the
  end the player sits on PAUSED and SPACE does nothing at all. **Cause:** the
  producer's end-of-song branch (`player.odin`, `if cursor >= g_player_song.frames`)
  stores `g_player_playing = 0` and leaves the cursor parked at `frames`.
  `player_toggle` flips the flag back to 1, but the producer's very next
  iteration hits the same branch and stores 0 again — so it is a true no-op, not
  a slow response. Pressing play from the end should rewind first: seek to 0
  (or to the armed section's A point, if one is armed) and play. Decide whether
  that lives in `player_toggle` (UI thread, explicit) or in the producer's
  "asked to play from the end" case, and note that a finished song is also the
  one state where the transport readout should probably say something other than
  PAUSED.

- [ ] **Story 6.21 — Remove Practice Drill from the main menu.** The stem
  play-along is the project now; the drill is no longer something to offer on the
  way in. Drop the `"Practice Drill"` item from `main_items` (`app.odin:129`) and
  its `case 2` route to `screen = .Drill`.
  **Keep the drill code and its self-tests** rather than deleting them — the menu
  entry is one line and one route, while `drill.odin` / `drill_view.odin` / the
  `game` and `music` packages / the `store` trial log / `render.odin`'s NAM path
  are a lot of working, tested machinery. Removing the door is reversible;
  removing the rooms is not. `--drillcheck`, `--drillsim`, `--drillabandoncheck`,
  `--rigdrillcheck` and `--progresscheck` should all keep passing untouched, and
  `drill_init`/`drill_destroy` can stay in `run_app` (they are cheap) or move
  behind the self-tests.
  Loose ends to handle in the same pass: the drag-drop handler's
  `if screen == .Drill do drill_abandon(&d)` guard (`app.odin:150`) becomes dead
  but harmless; the file header comment naming the drill as a menu destination
  (`app.odin:4`) needs updating; and `CLAUDE.md` still describes the drill as
  "one menu entry".
  **This is a direction change, not a menu edit** — decided 2026-08-20, on the
  evidence of actually using it: *playing along with real songs is far more fun
  than the drill.* Story 4.2 (three weeks of daily drill use) and all of Epic 5,
  which it gates, are parked accordingly; Epic 6's header line about the drill
  staying as one menu entry is corrected. The drill code stays in the tree and
  under test, so this is reversible — but it is no longer the product.

- [ ] **Story 6.22 — In-app amps and cabs: revisit once the interface arrives.**
  Placeholder, deliberately unspecified. The requirements come from playing
  through a real Hi-Z input; writing them before that is guessing, and guessing is
  what the Story 4.2 gate existed to prevent. Two facts to hand whoever picks
  this up:
  - **The best amp modelling in the codebase is currently unreachable from the
    product.** `render_submit` — the NAM (Neural Amp Modeler, real-amp capture)
    path — is called only from `drill.odin`, `riff.odin` and the self-tests. The
    drill is parked (6.21), so NAM's only interactive consumer is gone. What you
    actually hear while playing along is `ampchain`, the lighter realtime DSP
    (drive → oversampled waveshaper → tone shelves → FIR cab), chosen in Story
    6.5 because NAM was assumed too slow for the callback.
  - **That assumption is worth re-testing.** Measured here: `--riff-wav` renders
    **6.34 s of audio in ~3.1 s wall — about 2x realtime**. So NAM is not
    categorically too slow; the barrier is architectural (it runs on a render
    worker producing whole clips, not inside the audio callback) plus the
    latency budget, not raw throughput. 2x is thin headroom for hitting every
    128-sample deadline and the per-block cost may not be uniform — but "measure
    NAM in the callback properly" is a real option, not a fantasy. If it holds,
    the play-along could use the same amp models the drill did.
  Also unverified until the interface lands: the whole live-monitoring path
  (Story 6.5) has only ever run over software loopback, and the Rocksmith cable's
  input-only device binding (6.6) is a plug-in-and-listen gate.

## Epic 7 — Multi-platform distribution

**Why now:** the goal changed from "runs on my machine" to "someone else can use
it" — specifically a guitarist on a Mac. That is a different project: it means
building somewhere other than the machine that runs it, on architectures this has
never been compiled for, and handing the result to someone who will not open a
terminal to fix it.

**Scope note:** Story 6.13 (drop the Python dependency) was declined on the
grounds that distribution was not a goal. That premise no longer holds, and
Story 7.6 is where it gets revisited — but see 7.6 for a route that may make it
unnecessary anyway.

### What is already portable (verified by reading the code, not assumed)

Encouraging: there is **no platform-specific application code to port**. `grep`
for `ODIN_OS` across `src/` returns two hits, both `ODIN_DEBUG`, neither about
the OS.

- **`vendor:raylib`** has a Darwin branch that links Cocoa / IOKit / CoreVideo.
- **`vendor:miniaudio`**'s build script is generic (`cc`, `ar`, no platform
  branches); miniaudio itself speaks CoreAudio.
- **`system:sqlite3`** — macOS ships libsqlite3.
- **`places`** already treats a missing `/proc/mounts` as "no mounted volumes"
  rather than an error, so the Import browser degrades instead of breaking.
- **`separate.py`** already picks `cpu` when CUDA is unavailable.

### What actually blocks it

- [ ] **Story 7.1 — Portable build flags.** (Was 6.19.) `src/nam/build.sh:22`
  passes **`-march=native`**. Two distinct problems: on x86-64 it bakes in the
  *building* machine's instruction set, so the binary dies with SIGILL on an
  older CPU — possibly not at startup but at the first wide instruction inside an
  amp render, which reads as a random crash. And on **Apple Silicon it is not
  merely wrong but invalid**: clang spells the equivalent `-mcpu` on arm64 and
  rejects `-march=native` outright, so this script cannot build at all on an
  M-series Mac. Replace with a baseline (`-march=x86-64-v2`, or `-v3` for AVX2)
  plus an env override for local builds, and nothing on arm64 (NEON is already
  baseline). Also `-lstdc++` must become `-lc++` on macOS, and the `BREW_LIB`
  rpath is a Linux path. **Measure the cost**: NAM inference is the one place the
  flags matter, and `--riff-wav` times a full render (~3.1 s here at `native`).
- [ ] **Story 7.2 — Build and run on macOS at all.** Nobody has ever compiled
  this on a Mac. Known risks beyond 7.1: `src/nam/build.sh` uses **`ld -r`** to
  combine objects into one relocatable so the WaveNet parser's static
  registrations survive the linker — Apple's ld64 accepts `-r`, but the
  registration trick may need `libtool -static` or `-Wl,-force_load` instead, and
  that failing is silent (the model just won't load). Also verify the duplex
  `ma_device` opens on CoreAudio with distinct capture/playback devices, which is
  how the Rocksmith cable is bound.
- [ ] **Story 7.3 — CI build matrix.** GitHub Actions producing artifacts for
  macOS arm64 (Apple Silicon), macOS x86-64 (Intel Macs), and Linux x86-64;
  Linux arm64 if a runner is cheap to get. Needs mise-provisioned Odin per
  runner, the three vendored C/C++ libs built on each, and `assets/fetch.sh` (or
  7.5's bundling) run as a step. A universal macOS binary via `lipo` is worth
  considering over two downloads.
- [ ] **Story 7.4 — macOS signing and notarisation.** The step that decides
  whether this is *actually* givable. An unsigned binary downloaded from the
  internet is refused by Gatekeeper — "cannot be opened because the developer
  cannot be verified" — with no obvious way out for a non-technical user.
  Options: an Apple Developer account (~$99/yr) plus `codesign` + `notarytool` in
  CI; or ship unsigned and talk the recipient through right-click → Open (once
  per binary, and it looks alarming). Decide before 7.3 finishes, because signing
  changes the CI shape.
- [ ] **Story 7.5 — Asset bundling and licensing.** `assets/fetch.sh` downloads
  third-party SoundFonts, cabinet IRs and NAM amp captures at build time; they
  are deliberately not committed. Redistributing them inside an app is a
  different permission from downloading them for personal use — `fetch.sh`
  already carries a "check their licensing for your use" warning. **This is a
  legal gate, not a technical one**, and it needs answering before anything ships
  with tone in it. Fallbacks exist (no `.sf2` → Karplus-Strong; no `.nam` → the
  sampled path), so a stripped build is possible but sounds much worse.
- [ ] **Story 7.6 — Song import on a machine with no venv.** The real one. A
  recipient who cannot import songs has an inert app, since import is the only
  way songs get in. Three routes, in increasing cost:
  - **Hand over a pre-separated library.** Separate on the GPU box here and give
    him `library/` on a USB stick or a download — ~40 MB per song as mono FLAC.
    His build never needs Python at all, and his copy is a player rather than an
    importer. Cheapest by far, and worth trying first.
  - **Bootstrap the venv for him.** On a Mac there is no CUDA, so torch is a
    fraction of the 4.8 GB it is here — but it is still a terminal step, and
    CPU/MPS separation will be slow.
  - **Revisit Story 6.13** (native separation via `demucs.cpp`). Declined when
    distribution was not a goal; that premise has changed. The report's
    recommended shape stands: a fallback behind the existing separator seam, not
    a replacement, so the GPU path here survives.
  Decide this **before** 7.3, because it determines whether the CI artifact needs
  a Python story at all.
- [ ] **Story 7.7 — Platform conventions.** Small, cosmetic, last. The Places
  jump list reads `/proc/mounts`, so on macOS it offers home and Music but no
  volumes (they live in `/Volumes`). The library resolves to
  `$HOME/.local/share/guitar-trainer/library`, which works on macOS but is not
  the convention (`~/Library/Application Support`). Neither breaks anything.
