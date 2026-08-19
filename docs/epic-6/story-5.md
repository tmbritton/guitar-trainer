# Epic 6 / Story 6.5 — Live monitoring (realtime amp chain) + per-song rig

**Goal:** Hear your own guitar in a good tone while you play along. Run the live
interface input through a **realtime DSP amp chain** (input drive → oversampled
waveshaper → tone → streaming-FIR cab → monitor level) in the audio callback and
mix it into the player output. Each song remembers its rig (drive/tone/cab/monitor
level) and its speed.

**Why a DSP chain, not NAM:** per the Rocksmith/Guitarix research, realtime tone
is a light, cheap DSP chain — low-latency and fine on any CPU — whereas NAM is
CPU-heavy and stays the *offline* render engine (the drill). The one quality
lever is **oversampling the waveshaper** (avoids the harsh aliasing of a raw
tanh). All stages are allocation-free → callback-safe (the `-debug` rtalloc guard
still holds). Detection still reads the **dry** signal (spec §9.3): the monitor
chain is strictly downstream of onset/pitch, exactly like the existing `amp`.

> **Hardware:** the user has a **Rocksmith Real Tone cable** (guitar→USB,
> **input-only** — no output) and a good audio interface. So live monitoring is
> testable by ear now. Because the Rocksmith cable has no output, the single
> duplex `ma_device` must bind its **capture** to the cable and its **playback**
> to a *different* device (speakers/interface) — miniaudio allows distinct
> `capture.pDeviceID` / `playback.pDeviceID` in one duplex config. So this story
> also adds **audio-device selection**. A full interface (in+out) works as plain
> default duplex. DSP + wiring are verified headless over loopback; tone tuning +
> Rocksmith quirks (hot/mono-on-one-channel) are a plug-in-and-listen step.

## Audio device selection (for the Rocksmith cable) — SPLIT TO STORY 6.6

> Deferred to its own story (6.6): it can't be validated without the hardware
> plugged in, and monitoring already works with a full interface as the default
> duplex device. Sketch retained below for that story.

- **Modify `src/audio.odin`** — enumerate devices (miniaudio `ma_context` +
  `ma_context_get_devices`); let `audio_init` bind capture and playback to chosen
  device IDs (nil = system default, current behaviour). Add
  `audio_list_devices()` and a way to re-init on selection change. Default policy:
  if a capture device name matches `Rocksmith`/`Real Tone`/`Guitar`, prefer it for
  input while playback stays on the default output.
- **Settings screen (`app.odin`)** — a capture-device / playback-device picker
  (keyboard). Persist the choice globally (a tiny config file), so it sticks
  across runs. (This is separate from per-song rig prefs.)

## Files

- **Create `src/ampchain/ampchain.odin`** (`package ampchain`, unit-tested) — the
  pure realtime DSP, per-sample, all fixed-size state (no alloc):
  - `Waveshaper` — **oversampled** soft-clip: a short polyphase FIR upsampler
    (×4), `tanh`/cubic soft-clip per oversampled sample, FIR decimator back to
    1×. State = a small history ring.
  - `Tone` — a simple bass/treble shelving pair (RBJ biquads) with a mid; unity
    coeffs pass signal through unchanged.
  - `Cab_FIR` — a **streaming** FIR: a persistent delay line convolved with the
    cab IR coeffs sample-by-sample (distinct from the offline batch
    `conv.convolve`), truncated to a realtime-friendly tap count.
  - `Chain :: struct { drive: f32, ws: Waveshaper, tone: Tone, cab: Cab_FIR,
    level: f32 }`; `process :: proc(c: ^Chain, x: f32) -> f32` runs the stages;
    `process_block`, `reset`. Config setters are pure (recompute biquad coeffs).
- **Modify `src/audio.odin`** — a global monitor chain + params, driven from the
  UI via atomics (no locks in the callback):
  - `g_monitor: ampchain.Chain`; atomics for on/off, drive, tone, monitor level,
    and a **cab index** (all cab IRs preloaded into fixed buffers at init; the
    callback reads coeffs from the selected buffer — switching is just an atomic
    index, so no race). `audio_set_monitor_*` setters.
  - In the callback's **player-mode branch**, after draining the ring to `out`,
    if monitoring is on, run the dry `src` (already captured for detection)
    through `g_monitor` and add it to `out` at the monitor level. Alloc/lock/log-
    free; detection is untouched (still upstream).
- **Modify `src/songprefs.odin`** — extend per-song persistence to a small rig
  block (monitor on, drive, tone, cab index, monitor level, **speed**) alongside
  the existing per-stem mixer lines. Backward-compatible: old files (mixer only)
  still load; missing rig → defaults.
- **Modify `src/player.odin` / `src/player_view.odin` / `src/app.odin`** —
  player controls for the rig (e.g. `G` monitor on/off, `D`/`d`… keep it small:
  monitor on/off + monitor level + cab select), show the rig on the HUD, and
  load/save the rig + speed with the song (player_open applies them, ESC saves).
- **Modify `src/main.odin` / `src/selftests.odin`** — `--monitorcheck` (headless,
  loopback).

## Steps

- [ ] **Step 1 (RED/GREEN):** `ampchain` unit tests + impl:
  - `Cab_FIR`: impulse in → output equals the coeffs (FIR identity); silence → 0.
  - `Waveshaper`: small signal ≈ linear×gain; large signal saturates (|out|<1,
    monotonic); DC handled.
  - `Tone`: flat (0 dB) passes a signal through ≈ unchanged; a treble boost raises
    HF-sine gain relative to LF-sine.
  - `Chain.process` wires them; `reset` clears state. Add `ampchain` to `test.sh`.
- [ ] **Step 2:** `audio.odin` monitor globals + atomics + the player-mode
  callback mix; preload cab IRs into fixed buffers; `audio_set_monitor_*`.
- [ ] **Step 3:** `songprefs.odin` rig block (load/save, back-compat); wire
  player_open (apply rig + speed) and ESC (save) in `app.odin`.
- [ ] **Step 4 (UI):** rig controls + HUD line in the player; keep the keymap
  small and documented in the footer.
- [ ] **Step 5 (headless):** `--monitorcheck` — over loopback, schedule a tone as
  "input", enable monitoring, step the callback, and assert the output carries the
  processed monitor signal (energy present with monitor on, ~absent with it off /
  level 0), and that detection still sees the dry tone. Wire dispatch.
- [ ] **Step 6:** `./test.sh` green; `./build.sh` (incl. `-debug` — the callback
  must not allocate); all headless checks pass; screenshot `player` shows the rig.
  Update `CLAUDE.md`, `plan.md`.

## Verification

- **Unit** (`./test.sh`): `ampchain` — FIR identity, waveshaper saturation, tone
  shaping, chain wiring/reset.
- **Headless:** `./guitar-trainer --monitorcheck` — the monitor chain is audible
  in `out` over loopback with monitoring on and gone with it off; dry detection
  unaffected. `./build.sh -debug` then a check run to confirm **no callback
  allocation** (rtalloc guard).
- **Live/manual (gate, needs the USB interface):** play through the interface,
  ride drive/tone/cab/monitor level against a slowed backing, judge tone by ear;
  confirm the rig + speed persist per song.

## Out of scope

NAM as an optional desktop monitor amp; stereo; A-B loop / drag-drop (6.6).
