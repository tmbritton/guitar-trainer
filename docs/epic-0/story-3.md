# Epic 0 / Story 3 — Audio Environment Sanity Check

**Goal:** Enumerate playback/capture devices via miniaudio, confirm which backend is in use and whether a duplex-capable capture device exists, and document the PipeWire quantum. No device is opened by the app yet — this is a throwaway probe that de-risks Epic 1.

**Files:**
- Create: `tools/audioprobe/main.odin` — standalone `package main`; its own binary, separate from the app.
- Create: `tools/audioprobe/README.md` — how to run and what to look for.

## Constraints in play

- This does **not** open a `ma_device` and does **not** run a callback — enumeration only (`context_init` → `context_get_devices` → `context_uninit`).
- The USB interface the spec requires (Scarlett Solo / MOTU M2) may not be plugged in yet. The probe must succeed against onboard/PipeWire audio and simply report what it finds — Epic 1 is not blocked on the hardware being present.

## Steps

- [ ] **Step 1: Probe program.** `ma.context_init(nil, 0, nil, &ctx)`. Then `ma.context_get_devices(&ctx, &playback, &playbackCount, &capture, &captureCount)`. Print backend (`ctx.backend`), and for each playback and capture device print name + isDefault. `context_uninit` at the end.
- [ ] **Step 2: Build.** `mise exec -- odin build tools/audioprobe -out:tools/audioprobe/audioprobe`. (Enumeration pulls the same miniaudio static lib; no X11/GL needed, so no extra linker flags required — but include the miniaudio lib self-heal by reusing `build.sh` conventions if the lib is missing.)
- [ ] **Step 3: Run & capture output.** Run the probe; record the backend and device lists.
- [ ] **Step 4: Document PipeWire quantum.** Capture `pw-metadata -n settings 2>/dev/null | grep quantum` (or `pw-top`) to note the current/forced quantum, and record the `PIPEWIRE_LATENCY=128/48000` env override the app will want.

## Verification

The probe builds and prints the active backend plus non-empty playback and capture device lists. Findings (backend, whether a Hi-Z USB capture device is present, quantum) are recorded in this file.

## Notes

- Backend on PipeWire systems is typically reported as `pulseaudio` (PipeWire's pulse shim) or `jack`/`alsa` depending on what miniaudio negotiates. Record whichever it is — it affects how latency is requested in Epic 1.

## Findings (implementation)

- **Backend:** `pulseaudio` — miniaudio negotiates the PipeWire pulse shim, not native PipeWire/JACK/ALSA.
- **Playback:** `Built-in Audio Analog Stereo` (default). **Capture:** `Built-in Audio Analog Stereo` (default) + a monitor source. **No USB Hi-Z interface is connected yet** — as expected; the spec's Scarlett/MOTU is a pending purchase. Onboard audio is sufficient to build and exercise Epic 1's device/clock/ring/onset code; the physical <10 ms / pick-attack acceptance waits for the interface.
- **PipeWire clock:** rate `48000`, current `clock.quantum=1024` (~21 ms), `min-quantum=32`, `max-quantum=2048`, `force-quantum=0`. Default quantum is far larger than our 128-sample target.
- **Latency-request caveat for Epic 1:** because miniaudio uses the **pulse** backend (not native PipeWire/JACK/ALSA), the `PIPEWIRE_LATENCY=128/48000` env hint is not honored the same way a native client would honor it. Options to force a small quantum, in preference order: (1) run the app as a native PipeWire/JACK client if miniaudio can be pointed at that backend, (2) set `PIPEWIRE_QUANTUM=128/48000` / a node `node.latency` property, or (3) globally `pw-metadata -n settings 0 clock.force-quantum 128` (affects the whole graph — use only for testing). Revisit when the real interface is attached; onboard latency is not representative anyway.
- **Probe is throwaway** but kept under `tools/audioprobe/` since it's a handy diagnostic when swapping interfaces.
