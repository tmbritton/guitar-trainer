# Epic 6 / Story 6.2 — Song import + Demucs separation with progress

**Goal:** Import an audio file from inside the app and separate it into instrument
stems, with a live progress bar. Pick a file in an in-app browser → spawn an
external Python separator (`separate.py`, Demucs `htdemucs_6s` → 6 stems) on a
worker thread → read its progress over a stdout pipe → cache the stems into a
`library/<song>/` folder → the song appears on the **Play a Song** (Library)
screen. The player itself is Story 6.3; here Library just lists what's importable.

**Why this shape:** the ML is kept **offline/external** (a subprocess), the app
stays native. The one genuinely new integration is *spawn a subprocess and read
its progress incrementally* — de-risk that with a hermetic stub, not by depending
on a multi-minute Demucs run in tests.

## Toolchain note (verified)

This Odin build (`dev-2026-08`) merged `os2` into **`core:os`**: `os.args` is a
package var, and the high-level process API is present —
`os.process_start(desc: os.Process_Desc) -> (os.Process, os.Error)` with
`desc.command: []string` and `desc.stdout: ^os.File`; `os.pipe() -> (r, w:
^os.File, err)`; `os.read(f, buf)`; `os.pipe_has_data(r)`; `os.process_wait`.
The worker redirects the child's stdout to a pipe and reads `PROGRESS`/`DONE`/
`ERROR` lines as they arrive.

## Files

- **Create `src/songlib/songlib.odin`** (`package songlib`, unit-tested) — the
  pure logic, no I/O:
  - `Progress_Msg :: struct { kind: Kind, pct: int, text: string }`,
    `Kind :: enum { Progress, Done, Error, Unknown }`;
    `parse_line(line: string) -> Progress_Msg` — parses one separator stdout line
    (`PROGRESS 42`, `DONE /path`, `ERROR msg`, anything else → `Unknown`).
  - `is_supported_audio(name: string) -> bool` — extension filter
    (`.wav .flac .mp3 .ogg .m4a`, case-insensitive).
  - `slug(name: string) -> string` — filename → library folder name (strip ext,
    lowercase, spaces/punct → `-`, collapse repeats). Pure; caller owns the
    buffer (return into a supplied `[]u8` to stay allocation-simple), matching
    how `calib`/`music` avoid allocating.
  - `STEMS :: [6]string{"vocals","drums","bass","guitar","piano","other"}` and
    `is_song_dir(entries: []string) -> bool` — true iff every `STEMS[i].wav` is
    present (used to decide which `library/` subdirs are finished songs).
- **Create `assets/separate.py`** — Demucs wrapper. Args: `<input> <outdir>
  [--stub]`. Real mode: run `htdemucs_6s`, emit `PROGRESS <0..100>` as it goes,
  write the 6 stem WAVs into `<outdir>/`, print `DONE <outdir>`; on failure
  `ERROR <msg>` + nonzero exit. `--stub` mode: no Demucs — emit a few `PROGRESS`
  lines with tiny sleeps and write 6 short silent WAVs, so the spawn/pipe/parse
  path is testable with no model and no GPU. Header documents `pip install
  demucs`. Line-buffered stdout (`flush=True`).
- **Create `src/import.odin`** (`package main`) — the separation worker + state,
  modeled on `render.odin`'s atomics:
  - `import_start(input_path, out_dir: string)` spawns `separate.py` on a thread;
    the thread reads the stdout pipe line-by-line, calls `songlib.parse_line`,
    and stores results in atomics: `g_import_pct: u32`, a `g_import_state` enum
    (`Idle/Running/Done/Error`), and a fixed status buffer.
  - `import_progress() -> (pct: f32, state)`, `import_message() -> string`,
    `import_reset()`. No allocation in the poll path (the UI polls each frame).
  - The child's stdout goes to an `os.pipe`; the worker loops `pipe_has_data`/
    `read` into a line assembler until EOF/`process_wait`. All the parsing is
    `songlib` (already unit-tested); this file is just the I/O shell.
- **Create `src/library.odin`** (`package main`) — `library_scan(dir: string) ->
  []Song` reads `library/`, keeps subdirs where `songlib.is_song_dir` holds;
  `Song :: struct { name: string, dir: string }`. Used by the Library screen.
- **Modify `src/app.odin`** — flesh out the `Import` and `Library` screens
  (currently stubs):
  - `Import` becomes a **file browser**: list a source dir (default `$HOME/Music`,
    fall back to `$HOME`), filtered by `songlib.is_supported_audio`, `↑/↓/Enter`
    (reuse `menu.move`). Enter starts `import_start` and switches to a new
    `Importing` screen.
  - New `Importing` screen: draws a progress bar from `import_progress()`; on
    `Done` returns to Library (now listing the new song); on `Error` shows the
    message. `Esc` cancels back to Main Menu.
  - `Library` lists `library_scan("library")`; selecting a song is a no-op stub
    until Story 6.3 (footer: "player coming soon").
- **Modify `src/main.odin`** — add `--importcheck` dispatch.
- **Modify `src/selftests.odin`** — `importcheck()` (headless): run the worker
  against `assets/separate.py --stub` into a temp dir; assert the state reaches
  `Done`, `pct` advanced past 0 and ended at 100, and all 6 `STEMS[i].wav` exist.
- **Modify `src/screenshot.odin`** — add `import`/`library` screenshot targets.
- **Modify** `test.sh` (add `songlib` to `packages`), `.gitignore` (ignore
  `/library/`), `CLAUDE.md` (new `songlib` pkg, `import.odin`/`library.odin`,
  `--importcheck`, `assets/separate.py`), `plan.md` (check off 6.2).

## Constraints

- Keep the audio-thread rules intact: separation is a subprocess, its reader is a
  plain worker thread — nothing here touches the audio callback or allocates on
  it. (The `-debug` rtalloc guard is unaffected.)
- Reuse `menu.move` for both the file browser and Library nav; reuse the `ui.odin`
  kit + the fullscreen letterbox path. Nothing deleted; the drill still works.
- Real Demucs (model download, minutes/song, guitar-stem quality) is a **live/
  manual gate**, like the hardware gates — not run in `./test.sh`. Automated
  coverage uses the `--stub` separator so it is fast and needs no ML deps.

## Steps

- [ ] **Step 1 (RED):** `src/songlib/songlib_test.odin` — `parse_line` cases
  (PROGRESS/DONE/ERROR/garbage, extra whitespace, non-numeric pct),
  `is_supported_audio` (each ext + uppercase + unsupported + no-ext), `slug`
  (spaces/punct/case/collapse), `is_song_dir` (all-present vs one-missing). Run
  `./test.sh` — RED (package doesn't compile yet).
- [ ] **Step 2 (GREEN):** implement `songlib.odin` until the tests pass; add
  `songlib` to `test.sh`.
- [ ] **Step 3:** `assets/separate.py` with `--stub` (progress + 6 silent WAVs)
  and the real Demucs path; verify by hand: `python assets/separate.py in.wav
  /tmp/out --stub` prints PROGRESS…DONE and writes 6 WAVs.
- [ ] **Step 4:** `src/import.odin` worker (spawn + pipe read + atomics, parsing
  via `songlib`). `src/library.odin` scan.
- [ ] **Step 5 (headless):** `--importcheck` runs the worker against the stub,
  asserts Done + pct 0→100 + 6 stems. Wire dispatch in `main.odin`. Green.
- [ ] **Step 6 (UI):** Import file browser + Importing progress screen + Library
  list in `app.odin`; `Importing` in the `Screen` enum. Screenshot targets.
- [ ] **Step 7:** `./test.sh` green; `./build.sh`; `--importcheck` passes; GUI
  smoke (browse → import via stub → song appears in Library, no hang). Update
  `CLAUDE.md`, `plan.md`, `.gitignore`.

## Verification

- **Unit** (`./test.sh`): `songlib` green — parsing, extension filter, slug,
  song-dir detection are all pure and covered.
- **Headless:** `./guitar-trainer --importcheck` — spawns the stub separator,
  drives the real worker/pipe/parse path end-to-end, asserts progress advanced
  and 6 stems were written. No ML deps, deterministic.
- **Live/manual (gate):** `pip install demucs`; import a real song in the GUI;
  watch the progress bar climb during a real `htdemucs_6s` run; confirm the song
  lands in `library/<slug>/` with 6 stems and shows on Play a Song. (Player is
  6.3; here we only confirm the file lands and lists.)
