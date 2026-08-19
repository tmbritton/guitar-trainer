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
- [ ] **Story 6.5 — Live monitoring + per-song rig.** Oversampled DSP amp chain (gain → oversampled waveshaper → tone stack → streaming-FIR cab) on the live input; per-song amp/cab/monitor prefs.
- [ ] **Story 6.6 — Fast-follow.** A-B loop; drag-drop import; dry monitoring.
