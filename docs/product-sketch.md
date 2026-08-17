**Status:** Draft v0.1 **Author:** Tom **Audience:** Me. Single user, single machine, no distribution. **Date:** 2026-08-05

---

## 1. Summary

A native desktop application that trains **auditory musical fluency** on guitar. The user hears music and finds it on the instrument. Visual scaffolding (tab, notation, fretboard hints) exists only as removable training wheels, and the system is designed to take them away on a schedule.

This is explicitly **not** a game with a learning veneer. It is a training tool with good gamefeel.

## 2. Motivation

Rocksmith proved that real-time audio input from a physical instrument can drive a compelling practice loop, and then optimized for the wrong outcome: players get very good at reading a scrolling note highway and remain unable to hear a melody and play it. The note highway is a permanent crutch that the product never removes.

Every by-ear tradition — bluegrass, Irish trad, blues, and most of the world's music — transmits without notation. Stevie Wonder did not learn from tab. The pedagogy for this exists; the software does not.

## 3. Scope constraints (read this before adding anything)

This is a personal tool. The following are **explicitly out of scope forever unless that changes**:

- Accounts, sync, multi-user, telemetry
- Content distribution or hosting
- Difficulty curves that must work for players who are not me
- Mobile, web, console
- Bass, drums, keys (revisit only after guitar is used daily for three months)

The primary project risk is **not technical**. It is that this becomes six months of enjoyable DSP and architecture work during which I play very little guitar. Every milestone below is gated on _actual daily use of the previous milestone_, not on completeness.

## 4. Target user

Me. 46, ~30 years of visual art, 15+ years of software, **beginner guitarist**. Bottlenecks are:

1. Fretboard location — knowing where a pitch lives without looking it up
2. Chord transition speed
3. Steady time

All three are trainable with zero notation. All three are measurable from onset timing plus pitch, which is exactly what the audio layer produces.

## 5. Pedagogical thesis and prior art

The design is not novel. It is an assembly of well-established things that have not been assembled before in this form.

|Component|Prior art|
|---|---|
|Sound-before-symbol sequencing|Edwin Gordon, Music Learning Theory; the term of art is **audiation**. Sequence: aural/oral → verbal association → partial synthesis → symbolic association.|
|Listen-first instruction|Suzuki (mother-tongue method), Kodály (movable-do solfège), folk transmission generally|
|Neuroscience framing, "fluency" as the goal|Josh Turknett, _Anyone Can Play Music_ / Brainjo Method|
|Scale-degree-in-context over isolated intervals|Alain Benbassat / Functional Ear Trainer; Bruce Arnold's contextual ear training|
|High-trial-count adaptive perceptual drilling|Philip Kellman, perceptual learning modules|
|Real-instrument input + gamefeel|Rocksmith 2014 / Rocksmith+; Melodics (best-in-class feel, MIDI)|
|Scaffolding removal|**Guidance hypothesis** (Salmoni, Schmidt & Walter 1984): concurrent per-trial augmented feedback improves practice performance and _degrades retention_. Also expertise reversal effect (Kalyuga) and guidance fading (Renkl & Atkinson).|
|Phrase dropout as an audiation test|Time Guru (Avi Bortnick) — metronome that randomly mutes beats|
|Rhythm-game timing architecture|StepMania/Etterna, osu!framework — audio clock as master, mandatory offset calibration|

### 5.1 Two design positions that follow from the above

**Isolated interval identification is the wrong primitive.** It transfers poorly to hearing actual music. Replaced throughout with **scale-degree-in-context**: establish tonality with a cadence or drone, then ask for a degree.

**Real-time per-note correctness feedback is itself a visual crutch.** Green/red on every note trains screen-watching, not listening. Feedback is therefore:

- **Delayed** — phrase-level summary, not per-note
- **Auditory where possible** — a wrong note makes the backing stumble; a right one locks in
- **Bandwidth-gated** — surfaces only when error exceeds a threshold that tightens with skill

## 6. The fade ladder

Scaffolding is a numbered, explicit axis. It is tracked **per skill**, not per user — L5 on open chords and L1 on a solo is a normal state.

|Level|On screen|In the ears|
|---|---|---|
|0|Full tab + fingering + timing|Isolated part, slow|
|1|Tab, no fingering hints|Part + click|
|2|Rhythm slashes + chord symbols|Part + backing|
|3|Chord symbols only|Full mix|
|4|Section labels only|Full mix|
|5|Nothing — backing + count-in|Full mix, variable tempo|
|6|Nothing — backing drops out bars 5–8|You fill the hole|

Advancement is gated on **retention across sessions** (spaced), never on a single clean run.

## 7. Feature roadmap

### v0 — Scale Degree Drill (no songs, no tab renderer, no charts)

The entire v0 loop:

1. Generate and play a I–IV–V–I cadence in a random key
2. Play a random scale-degree tone
3. User finds it on the fretboard and plays it
4. Detect pitch class → judge → next trial

No content dependency whatsoever. Trains scale-degree hearing and fretboard location simultaneously, which are the two actual year-one bottlenecks.

**Ship criteria:** runs, judges correctly, feels good to fail at. **Gate to v1:** used daily for three weeks.

### v1 — Call and Response

App plays a 1–2 bar phrase; user plays it back. Score pitch sequence + onset timing. Adaptive chunk length: extend on success, contract on failure. Generated phrases first (constrained random walks within a key and position), real material later.

This is the loop Rocksmith never had and the core of every by-ear tradition. It is also where gamefeel investment pays off — the tightness of the audio response on a nailed phrase _is_ the product.

**Gate to v2:** used regularly, and I find myself wanting real songs.

### v2 — Songs and the ladder

- Local import only. Path of least resistance: **psarc → gp5 → render**, using existing converters rather than writing SNG decryption. `.gp` parsing is well-trodden.
- Fade ladder implemented against real material
- Level 6 dropout mode

### v3+ — Deferred, revisit only when wanted

Tune-by-ear game (beat-frequency nulling, cents scoring) · Transcription trainer (stem-separated loop, slow-down, verify through pickup) · Sing-then-play · Optional notation rendering · Other instruments

## 8. Scoring model

**Score the sound, not the fingering.** Rocksmith scores string + fret. This tool scores pitch class, octave, onset time, and duration, and lets the user play the phrase in whatever position they find. This single choice turns the fretboard into a search space instead of a lookup table and is the core differentiator.

Weighting: at low levels, timing tightness and phrase contour outrank per-note pitch accuracy. The weighting inverts as skill rises.

## 9. Technical design

### 9.1 Stack

**Odin + `vendor:raylib` + `vendor:miniaudio`**, single native binary, Linux (Bazzite / PipeWire) primary.

Rationale:

- Both dependencies ship in Odin's `vendor` collection, curated together, current (miniaudio bindings at v0.11.24). `odin build .` produces one binary with no build-system archaeology.
- No GC, manual allocators — the audio callback can be genuinely realtime-safe.
- Prior exposure to the stack shortens the ramp, which directly mitigates the primary project risk.
- The DSP surface for v0 is small: autocorrelation or YIN over a 1024–2048 sample window is ~150 lines and needs no FFT. Ecosystem gap doesn't bite yet; FFI to C remains available if CQT or a neural model is ever needed.

Rejected: **Rust** (better DSP ecosystem — cpal/rtrb/realfft/pitch-detection — but slower iteration; a defensible alternative, not a wrong one). **C + SDL3** (most boring and durable, least leverage per line). **C++ + JUCE** (industry-standard audio plumbing, but its GUI layer fights the one thing this project cares about).

**Explicitly reverted:** an earlier plan split a native detection daemon from a Phoenix/LiveView UI. With a fully native app that split is pure overhead — an IPC hop, a serialization format, and a second clock domain sitting in the latency path. **Single process.**

### 9.2 Architecture rules

**Do not call `InitAudioDevice()`.** Raylib spins up its own miniaudio context. Skip raylib's audio module entirely and own a single `ma_device` in **duplex** mode — one device, one clock, capture and playback in the same callback.

**The audio clock is the master clock.** Never derive musical time from `GetFrameTime()` or frame count. Maintain a monotonic sample counter incremented in the audio callback. Every scheduling decision and every scoring comparison uses sample positions; convert to seconds only for display. Frame-derived timing drifts, and it drifts in a way that presents as "the detection is bad."

**One SPSC lock-free ring buffer, audio → main.** The callback copies input, runs onset detection, and pushes events. It never allocates, never locks, never logs. Main thread drains the ring and does everything expensive.

**Odin gotcha:** Odin's implicit `context` carries a default heap allocator. In the miniaudio callback, set `context.allocator = nil_allocator()` or a pre-sized arena. Otherwise an allocation eventually lands on the audio thread and clicks at the worst moment.

**Split onset from pitch.** Onset detection in the callback (~5 ms, spectral flux or energy-based), timestamped in samples. Pitch confirmation later on the main thread from a buffered window.

> **Physics floor:** pitch detection needs roughly 2–3 periods of the fundamental. Low E at 82.4 Hz is ~12 ms per period, so a low note cannot be _confirmed_ in under ~25–40 ms regardless of hardware. Score timing off the onset; score correctness off the late pitch. Tying them together makes timing feedback inherit pitch latency and the whole thing feels mushy.

**Calibration is a v0 feature, not a polish item.** Measure round-trip offset (emit a click, detect it back through the pickup or loopback, store the delta) and subtract it from every judgment. StepMania's flow is the reference. Without this, the first two weeks of "detection feels wrong" will actually be an uncorrected 8 ms offset.

### 9.3 Audio configuration

- 48 kHz, mono input, 128-sample buffer (2.7 ms) to start
- Detection runs on the **dry DI signal**. Any amp-sim path is separate and downstream. Distortion and palm mutes wreck pitch detection.
- PipeWire: set `PIPEWIRE_LATENCY=128/48000` if quantum negotiation gives something lazier
- Target round-trip latency < 10 ms

### 9.4 Hardware

**Required:** a class-compliant USB interface with a Hi-Z instrument input (≥ 1 MΩ). Passive magnetic pickups into a line input sound thin and detect worse.

- **Focusrite Scarlett Solo 4th gen** (~$140) — class-compliant, zero-config on Linux, ~7.8 ms RTL at 128 samples
- **MOTU M2** (~$200) — better converters, useful loopback; the pick if it should double as the interface for recording guitar over Strudel beds

**Do not buy:** a Rocksmith Real Tone Cable (mono, fixed gain, single-purpose). A hexaphonic pickup (Cycfi Nu, Roland GK-3, Fishman TriplePlay) — it solves string/fret disambiguation, a problem this design avoids entirely by scoring sound rather than fingering.

### 9.5 Module layout (v0)

```
main.odin             window, game loop, calibration screen
audio.odin            ma_device duplex init, callback, sample clock
ring.odin             SPSC ring buffer, audio → main events
detect/onset.odin     spectral flux / energy onset, in callback
detect/pitch.odin     YIN or MPM, main thread, windowed
music/theory.odin     keys, scale degrees, cadence generation
game/degrees.odin     v0 loop: cadence → target tone → listen → judge
store.odin            SQLite via C bindings; trial log + scheduling
```

### 9.6 Data model (v0)

Single SQLite file. One `trials` table is enough to start:

```
trials(id, ts, key, target_degree, target_midi,
       detected_midi, onset_offset_samples,
       correct, response_ms, session_id)
```

Everything else — spacing schedules, per-skill ladder levels, progress views — is derivable from the trial log. Resist adding tables until a query is actually painful.

## 10. Milestones

|#|Deliverable|Done when|
|---|---|---|
|M0|Audio spine: duplex device, sample clock, ring buffer, onset detection, calibration screen|A pick attack produces a timestamped event within 10 ms, offset-corrected|
|M1|Pitch detection: YIN/MPM on main thread, fretboard-wide accuracy check|Correctly identifies every note on the neck, plucked and picked, clean signal|
|M2|v0 game loop: cadence generation, trial scheduling, judging, SQLite log|Playable end to end|
|M3|**Three weeks of daily use**|—|
|M4|v1 call-and-response|Gated on M3|

M0–M2 is roughly two weekends. M3 is the real milestone.

## 11. Risks

|Risk|Mitigation|
|---|---|
|**Building instead of playing** — the dominant risk|Hard gate at M3. No new features until three weeks of daily use.|
|Detection false negatives on bends, palm mutes, dead strings|Detect from dry DI. Accept a "no confident pitch" state rather than guessing. Fix accuracy before adding features.|
|Timing feels wrong|Almost always uncorrected offset or frame-derived clock, not detection quality. Calibration ships in M0 for this reason.|
|Audio-thread allocation clicks|`nil_allocator` in the callback; assert on it in debug builds.|
|Scope creep toward "a product"|Section 3.|

## 12. Open questions

- Does the v0 drill stay engaging past ~day 10 without any visual reward layer? If not, is the fix gamefeel juice or a different loop?
- Should trial scheduling be pure spaced repetition (SM-2-ish) or something closer to Kellman's adaptive mastery criteria? Start naive, instrument the trial log, decide from data.
- Is octave-agnostic pitch-class judging correct for v0, or does it let too much slop through?
- At what point does chord detection (chroma template matching) become worth adding — v1 or v2?
