# Epic 6 / Story 6.6 — Audio-device selection

**Goal:** Route the guitar in and the sound out through the right devices. The
**Rocksmith Real Tone cable is input-only**, so the one duplex `ma_device` must
bind its **capture** to the cable and its **playback** to speakers/interface —
distinct devices. A full interface (in+out) works as plain default duplex. Add
device enumeration, a Settings picker, name-based persistence, and an auto-detect
that prefers a Rocksmith/Real-Tone/Guitar capture device.

**Key idea:** miniaudio supports distinct `capture.pDeviceID` / `playback.pDeviceID`
in one duplex config (`nil` = system default). We already own the `ma_device`; add
an owned `ma_context` to enumerate and to bind chosen device IDs.

## Files

- **Modify `src/audio.odin`**:
  - Own a `g_context: ma.context_type` (init in `audio_init`, uninit in shutdown);
    pass `&g_context` to `device_init` instead of `nil`.
  - `audio_enumerate()` → cache capture + playback `device_info` (copy `id`,
    `name`, `isDefault`) into fixed arrays; `Audio_Device :: struct { name: string
    (into a fixed buf), id: ma.device_id, is_default: bool }`; getters
    `audio_capture_devices()` / `audio_playback_devices()`.
  - `audio_init` binds capture/playback IDs from the current selection (see
    resolution below); build the duplex config with `capture.pDeviceID` /
    `playback.pDeviceID` set to the chosen `&id` or `nil` (default).
  - `audio_reinit(capture_idx, playback_idx)` — stop+uninit the device, rebuild
    the config with the new IDs, `device_init(&g_context,…)`+start. Main-thread
    only, called from Settings (no player/drill active then). The master clock and
    rings persist across it.
- **Create `src/audioconf.odin`** (`package main`) — tiny global config at
  `audio.txt` (repo root): `capture <name>` / `playback <name>` lines. Save on
  selection; load at startup. Names (not opaque IDs) so they survive replug/reboot.
- **Device resolution** (`audio.odin`, at init): for capture and playback each —
  if the config names a device present in the enumeration, use its ID; else for
  **capture** auto-detect (first device whose name matches `Rocksmith` / `Real
  Tone` / `Guitar`, case-insensitive); else `nil` (system default).
- **Settings screen (`src/app.odin` + a small view)** — a device picker: two
  lists (Capture, Playback), `↑/↓` move, `Enter` select (calls `audio_reinit` +
  saves config), `Tab` switch list. Show which is active. Reachable from Settings.
- **`src/main.odin` / `src/selftests.odin`** — `--devicecheck` (headless).

## Steps

- [ ] **Step 1:** context + `audio_enumerate` + device caches + getters; switch
  `device_init` to the owned context. Verify `audiocheck` still passes.
- [ ] **Step 2:** device resolution (config name → Rocksmith auto-detect →
  default) applied in `audio_init`; build the config with chosen IDs.
- [ ] **Step 3:** `audio_reinit`; `audioconf.odin` load/save.
- [ ] **Step 4 (headless):** `--devicecheck` — init, enumerate, assert ≥1 capture
  and ≥1 playback; `audio_reinit` bound explicitly to the default devices by ID;
  assert the master clock advances after the re-init (device live). Wire dispatch.
- [ ] **Step 5 (UI):** Settings device picker (two lists, select = reinit + save);
  show active devices. Screenshot `settings`.
- [ ] **Step 6:** `./test.sh` green; `./build.sh`; all headless incl. `audiocheck`,
  `--devicecheck`, `--monitorcheck` pass; GUI smoke. Update `CLAUDE.md`, `plan.md`.

## Verification

- **Headless:** `./guitar-trainer --devicecheck` — enumerate (≥1 in/out), re-init
  bound to explicit default IDs, master clock advances. `--audiocheck` /
  `--monitorcheck` still pass (default path unchanged when no selection).
- **Live/manual (gate — needs the cable):** plug in the Rocksmith cable; confirm
  capture auto-binds to it (or pick it in Settings) while playback stays on
  speakers; open a song, enable monitoring, and hear the guitar. Confirm the
  selection persists across a restart.

## Notes / risks

- Device IDs are opaque and can change; persistence matches by **name**.
- `audio_reinit` briefly stops the device — only invoked from Settings, where no
  producer/drill is running, so no ring/clock consumer races it.
- Rocksmith cable quirks (hot level, guitar-on-one-channel when it enumerates as
  stereo — our capture is mono downmix) are a plug-in-and-listen tuning step; if
  the mono downmix halves the guitar, capturing L only is a fast-follow.
