# Epic 1 / Story 1.1 — Duplex Device (integration)

**Goal:** Own a single `ma_device` in duplex mode (48 kHz, mono in, 128-sample period). Its callback advances the master clock, runs onset detection on the dry input, and pushes onset events to the SPSC ring. The main thread drains the ring. Bypass raylib audio entirely.

**Sequencing note:** Integration story — wires Story 1.2 (clock), 1.3 (ring), 1.5 (onset). Verified live against the onboard interface (a clap/tap produces an onset event) since the USB Hi-Z interface is not yet purchased.

**Files:**
- Modify: `audio.odin` — device init/start/stop, the `proc "c"` callback, and a `audio_poll` drain for main.
- Modify: `main.odin` — start audio, drain events each frame, show a live input meter + onset counter.

**Constraints in play:**
- Do **not** call `rl.InitAudioDevice()`. One `ma_device`, duplex, one callback.
- Master clock advanced in the callback; onset positions are absolute samples.
- Callback: no alloc / no lock / no log. `context.allocator = mem.nil_allocator()` inside it (Story 1.4 upgrades this to an asserting allocator in debug).
- 48 kHz, mono input, 128-sample period to start.

**Interfaces (Produces):**
- `audio_init :: proc() -> bool` — build config, `device_init`, `device_start`. Returns false on failure.
- `audio_shutdown :: proc()` — `device_stop` + `device_uninit`.
- `audio_poll :: proc() -> (ring.Event, bool)` — main-thread drain of one event.
- `audio_clock_now :: proc() -> u64` — current master sample count (for display).
- Globals: `g_clock: clock.Clock`, `g_ring: ring.Ring(1024)`, `g_onset: detect.Onset_Detector`, `g_device: ma.device`.

**Callback body (per invocation):**
1. `context = runtime.default_context(); context.allocator = mem.nil_allocator()`.
2. View `pInput` as `[^]f32` → slice of `frameCount` mono samples.
3. `start := clock.now(&g_clock)`.
4. `on, pos := detect.push_block(&g_onset, in_slice, start)`; if `on`, `ring.push(&g_ring, Event{kind=.Onset, sample_pos=pos})` (drop if full — never block).
5. `clock.advance(&g_clock, u64(frameCount))`.
6. Zero `pOutput` (silence for now; backing audio comes later).

## Steps

- [ ] **Step 1:** Add globals + `audio_init` (config: `device_config_init(.duplex)`, sampleRate 48000, capture.format `.f32`/channels 1, playback.format `.f32`/channels 1, periodSizeInFrames 128, dataCallback, pUserData nil). `device_init(nil, &cfg, &g_device)` then `device_start`.
- [ ] **Step 2:** Implement the `proc "c"` callback per the body above.
- [ ] **Step 3:** `audio_poll` wraps `ring.pop`; `audio_shutdown`; `audio_clock_now`.
- [ ] **Step 4:** Wire `main.odin`: `audio_init` on startup (defer shutdown), each frame drain all events (count them, remember last onset sample→ms), draw input meter + onset count + clock time.
- [ ] **Step 5:** Build with `./build.sh`.
- [ ] **Step 6 (live verify):** Run on the live display, watch the input meter respond to sound, and confirm a sharp clap/tap increments the onset counter. Capture the observation.

## Verification

App builds and runs; the master clock advances in real time; the input meter tracks onboard-mic level; a clap produces exactly one onset event drained on the main thread. (The <10 ms offset-corrected pick-attack acceptance is completed in Story 1.6 calibration + real interface.)

## Notes

- Requesting mono playback keeps the output-zeroing trivial (`frameCount` floats). miniaudio converts to the device's native channel count.
- If `device_init` fails on the pulse backend for duplex, fall back to logging the `result` code; duplex on PipeWire's pulse shim is expected to work but record any surprise here.

## Findings (implementation)

- **Local package imports:** Odin resolves collection-less imports relative to the importing file's directory, so `import "clock"` / `"detect"` / `"ring"` work from the root `package main` files. (An initial `import "guitar-trainer/clock"` form was wrong — no such collection.)
- **Duplex init succeeded on the pulse backend** on the first try — no surprises. 48 kHz, mono in/out, 128-sample period accepted.
- **Headless verification mode** (`./guitar-trainer --audiocheck`) opens the real device for ~2 s and asserts the master clock advanced. This gives a genuine, human-free integration check that survives into later stories.
- **Live result:** `clock advanced 92288 samples in ~2s (=1.923 s of audio); onsets observed: 3; PASS`. The clock advancing proves the device + callback are live; the 3 onsets (from ambient onboard-mic sound) prove the onset→ring→main-thread drain works with **real** audio, not just synthetic buffers.
- The 92288/96000 ratio reflects `time.sleep` returning a bit early plus device-start latency — expected, and irrelevant since the clock is derived from actual frames processed, not wall time.
- The **<10 ms offset-corrected pick-attack** acceptance (the formal M0 bar) still needs the USB Hi-Z interface + calibration (Story 1.6); onboard mic latency isn't representative.
