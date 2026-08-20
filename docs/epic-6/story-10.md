# Epic 6 / Story 6.10 — Library location + mono FLAC stems

**Goal:** Two storage problems, both surfaced while scoping a bulk import.
(1) The library was the bare relative literal `"library"`, so it depended on the
working directory the binary was launched from and wrote stems inside the source
repo. (2) A single 5-minute song cost **304 MB** — six stereo 16-bit WAVs from a
33 MB FLAC, a ~9x expansion.

**Key idea:** The audio device is mono, so `stems.odin` downmixes every stem to
mono f32 on load — the stereo on disk is discarded at load time. Storing mono
FLAC is therefore lossless *for what the app can actually play*, and much smaller.

## What changed

- **`src/librarypath.odin`** (new) — `library_root()` resolves once and caches:
  `$GUITAR_TRAINER_LIBRARY` → `$XDG_DATA_HOME/guitar-trainer/library` →
  `$HOME/.local/share/guitar-trainer/library` → `./library`; creates it on demand.
  `LIBRARY_DIR` removed from `app.odin`.
- **`assets/separate.py`** — `save_stem` downmixes to mono and writes FLAC via
  `soundfile` (`prevent_clip` first, `PCM_16`).
- **`src/songlib/songlib.odin`** — `STEM_EXTS :: [2]string{".flac", ".wav"}`;
  `is_song_dir` accepts either extension.
- **`src/stems.odin`** — `stems_load` tries each extension in turn.
- **`src/selftests.odin` / `src/main.odin`** — `--stemcheck [dir]`.

## Steps

- [x] **Step 1:** `library_root()`; replace `LIBRARY_DIR`; migrate the existing
      library out of the repo.
- [x] **Step 2:** mono FLAC in `separate.py`; add `soundfile`.
- [x] **Step 3:** accept both extensions in `is_song_dir` + `stems_load`; 3 new
      songlib tests (flac, mixed extensions, near-miss rejection).
- [x] **Step 4:** `--stemcheck` to verify real imported stems decode.

## Verification

- **First real Demucs run** of the project: a 20-second clip separated in **4 s**
  on the GPU (~5x realtime), producing six mono FLACs totalling 2.6 MB.
- `--stemcheck` on that output: `20.0s  6/6 stems`.
- `--stemcheck` on the migrated legacy WAV song: `Sweet Leaf  300.9s  6/6 stems`
  — old imports still load, and the tagged title is used.
- Measured saving: **~39 MB vs ~304 MB** for a 5-minute song, **7.8x** (better
  than the 3.4x predicted, because quiet stems compress well).

## Notes / risks

- **Mono forecloses a future stereo-output mode** without re-importing. Accepted:
  stereo output is already deferred (the device is mono).
- `soundfile` bundles libsndfile in the wheel. demucs's own `save_audio` routes
  `.flac` through `encode_ffmpeg`, i.e. a **system ffmpeg** — avoided deliberately,
  since the only ffmpeg on this host came from Homebrew.
- `--stub` still writes WAV (its hand-rolled writer needs no dependencies), so
  both extensions stay exercised: stub covers `.wav`, real imports cover `.flac`.
- A self-test that imports **must** redirect the library via
  `os.set_env(LIBRARY_ENV, ...)` *before* the first `library_root()` call, which
  caches. `--queuecheck` initially leaked three stub songs into the real library
  for exactly this reason.
- Bug found while writing `--stemcheck`: `defer library_free(songs)` placed
  inside an `if` block runs at the end of *that block*, freeing the songs before
  the loop read them (garbled paths). Odin defers to block scope, not function
  scope.
