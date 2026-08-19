# Epic 6 / Story 6.3 — Player: stems + mixer + transport

**Goal:** The first fully usable slice of the play-along tool. Open a separated
song from the Library, hear its stems mixed and playing in sync, ride a per-stem
mixer (mute / solo / level), and control transport (play / pause / seek). Turn
the guitar stem down and play along on your own amp. Mixer settings persist per
song. (Time-stretch is Story 6.4; live monitoring + per-song rig is 6.5.)

**Why this shape:** the audio device is a single **mono** duplex `ma_device`
(audio.odin) — output is 1 channel at `clock.SAMPLE_RATE` (48 kHz). So stems
decode to **mono f32 @ 48 kHz** and mix down to a mono backing stream. Stereo
output would mean reconfiguring the device (playback channels, and every
`out`-writer: tone/click/mix_voices/mix_samples) — out of scope here; noted as a
later enhancement. Mono backing is fine for practice.

## Concurrency model (three threads, no locks)

Mirrors the existing SPSC + atomics discipline; the audio callback stays
allocation/lock-free.

- **Main (UI)** → **producer**: commands via atomics — play/pause, seek target,
  per-stem level (f32 bits) / mute / solo. Main never touches stem PCM or the ring.
- **Producer** (`player.odin` worker thread) owns the cursor and the stem PCM: it
  mixes the next block (applying the mixer) and writes mono samples into a
  **lock-free PCM ring**. Publishes the cursor (atomic) for the UI position readout.
- **Producer** → **callback** (SPSC PCM ring): the callback drains the ring into
  `out` in player mode; underrun = silence. The callback is otherwise unchanged.

Seek = producer jumps the cursor; the small amount of already-buffered audio
(ring ≈ ⅓ s) plays out first, so seek lag is sub-second (precise flush-on-seek is
a fast-follow). Producing only when `playing` keeps paused output silent.

## Files

- **Create `src/pcmring/pcmring.odin`** (`package pcmring`, unit-tested) — SPSC
  lock-free **f32 sample** ring (the `ring` pkg carries `Event`s; this carries raw
  audio). Power-of-two `Ring($N)` with `[N]f32 buf`, free-running `head`/`tail`
  (same acquire/release idiom as `ring`). `write(r, src) -> int` (writes as many
  as fit, producer side), `read(r, dst) -> int` (reads up to len(dst), consumer
  side; caller zero-fills the remainder on underrun), `available`/`space`.
- **Create `src/mix/mix.odin`** (`package mix`, unit-tested) — the pure mixer
  math. `Stem_Ctl :: struct { level: f32, mute, solo: bool }`;
  `any_solo(ctls: []Stem_Ctl) -> bool`; `stem_gain(ctl, any_solo) -> f32`
  (0 if muted, or if a solo is active elsewhere and this isn't soloed; else
  `level`). Deterministic, allocation-free → the DSP is unit-testable.
- **Create `src/stems.odin`** (`package main`) — decode a song's stems. Reuse the
  `ir.odin` miniaudio-decoder pattern (`ma.decoder_config_init(.f32, 1, 48000)`),
  size via `ma.decoder_get_length_in_pcm_frames`, allocate per-stem mono `[]f32`.
  `Song_Audio :: struct { stems: [6][]f32, ctl: [6]mix.Stem_Ctl, frames: int }`;
  `stems_load(dir) -> (Song_Audio, bool)` (missing stems load as empty/silent),
  `stems_free(^Song_Audio)`. Heap alloc (a 4-min song ≈ tens of MB/stem) — main
  thread only, never the audio path.
- **Create `src/player.odin`** (`package main`) — producer thread + transport +
  the command atomics. `player_open(song: Song_Audio)`, `player_close()`,
  `player_toggle()`, `player_seek(frames: int)`, `player_set_level/mute/solo`,
  `player_cursor() -> int`, `player_playing() -> bool`, `player_is_active()`. The
  worker mixes stems→ring via `mix.stem_gain`; a `g_player_active` atomic gates
  the callback drain.
- **Modify `src/audio.odin`** — a player-mode branch in `audio_callback`: when
  `g_player_active`, drain the PCM ring into `out` (after the zero-fill, before/
  instead of the drill voice mix — the drill isn't running then). New
  `audio_player_activate(on)` + the shared `g_pcm_ring` + `audio_pcm_write` used
  by the producer. No alloc/lock/log added.
- **Create `src/songprefs.odin`** (`package main`) — persist the mixer per song:
  `prefs_save(dir, ctls: [6]mix.Stem_Ctl)` writes `library/<song>/mixer.txt`
  (one `stem level mute solo` line each); `prefs_load(dir) -> ([6]mix.Stem_Ctl,
  bool)`. Simple text; tolerant of a missing file (defaults: level 1, unmuted).
- **Create `src/player_view.odin`** (`package main`) — the player screen: 6 stem
  rows (name, level bar via `ui_meter`, MUTE/SOLO tags), a transport line
  (play/pause, `mm:ss / mm:ss`, a seek bar). Pure view over player getters.
- **Modify `src/app.odin`** — Library `ENTER` opens the selected song:
  `stems_load` → `prefs_load` → `player_open` → `Screen.Player`. Player screen
  input: `SPACE` play/pause, `←/→` seek ±5 s, `↑/↓` select stem, `+/-` level,
  `M` mute, `S` solo, `ESC` → `prefs_save` + `player_close` + `stems_free` back
  to Library. Add `Player` to the `Screen` enum.
- **Modify `src/main.odin` / `src/selftests.odin`** — `--playercheck` (headless).
- **Modify** `test.sh` (add `pcmring`, `mix`), `CLAUDE.md`, `plan.md`.

## Steps

- [ ] **Step 1 (RED/GREEN):** `pcmring` — tests for write/read roundtrip,
  wrap-around, fill-to-full (write returns short), underrun (read returns short).
  Implement. Add to `test.sh`.
- [ ] **Step 2 (RED/GREEN):** `mix` — tests for `any_solo`, `stem_gain`
  (muted→0, non-soloed-while-solo-active→0, soloed→level, normal→level).
  Implement. Add to `test.sh`.
- [ ] **Step 3:** `stems.odin` decode + `Song_Audio`; `songprefs.odin` load/save.
- [ ] **Step 4:** `player.odin` producer thread + transport + command atomics;
  `audio.odin` PCM ring + player-mode callback drain + `audio_player_activate`.
- [ ] **Step 5 (headless):** `--playercheck` — build synthetic in-memory stems
  with distinct known energy, run the producer, drain the ring, and assert: mute
  all → output RMS ≈ 0; solo one → output RMS tracks that stem's level; play/pause
  gates production. Also write 6 tone WAVs to a temp dir and `stems_load` them to
  cover the decode path (frames > 0, non-zero RMS). Wire `--playercheck` dispatch.
- [ ] **Step 6 (UI):** `player_view.odin` + wire the Player screen and Library
  `ENTER` in `app.odin`; screenshot target `player`.
- [ ] **Step 7:** `./test.sh` green; `./build.sh`; `--playercheck` passes; no
  drill/import regressions; GUI smoke (open a song, ride faders, seek, play along).
  Update `CLAUDE.md`, `plan.md`.

## Verification

- **Unit** (`./test.sh`): `pcmring` (fill/drain/wrap/short), `mix`
  (level/mute/solo → expected gain).
- **Headless:** `./guitar-trainer --playercheck` — the producer/ring/mix path end
  to end over synthetic stems (mute-all silence; solo tracks energy; pause gates),
  plus a `stems_load` decode smoke.
- **Live/manual (gate):** import a real song (6.2), open it, mute the guitar
  stem, ride levels + seek, and play along on your amp — judge sync/mix by ear.

## Out of scope (later stories)

Stereo output (device reconfig); time-stretch/speed (6.4, SoundTouch); live-input
monitoring through an amp chain + per-song rig prefs (6.5); A-B loop + precise
flush-on-seek + drag-drop (6.6).
