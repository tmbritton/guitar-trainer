# Epic 6 / Story 6.14 — Batch-import correctness

**Goal:** Fix the six defects code review found in Story 6.11. One of them
silently destroyed data.

## 1. Slug collisions lost songs (the serious one)

`song_out_dir` named the library folder from the source *filename* alone, so
`Album A/01 Intro.mp3` and `Album B/01 Intro.mp3` both resolved to
`<library>/01-intro`: the second separation overwrote the first, one song was
lost, and the library showed a single entry. `is_finished_song_dir` could not
catch it — it runs before either has been separated. **Reproduced before fixing**
(two files in, one folder out, Album B's `meta.txt` overwriting Album A's).

**Fix:** `songlib.unique_slug` → `<slug>-<8 hex FNV-1a of the full source path>`.
The hash is *stable*, so re-importing the same file resolves to the same folder
and the already-imported skip keeps working; it is distinct per source file, so
collisions are gone. The stem is what gets squeezed on a tight buffer, never the
hash.

**Back-compatibility matters here** — there were already 106 imported songs using
the old names. `already_imported` checks the new folder *and* the legacy
filename-only one, but a legacy hit only counts when that folder's `meta.txt`
names the same `source`; otherwise a different song sharing a filename would be
wrongly skipped. Verified against the real library: re-marking an imported album
reports **0 files to import**.

## 2–6. The rest

- **Overlapping marks** (`Artist/` and `Artist/Album A/`) queued files twice —
  separated twice and overwritten. Deduped in `queue_add`.
- **cwd-relative separator paths** — `.venv/bin/python3` and `assets/separate.py`
  resolved against the working directory, contradicting the cwd-independence
  Story 6.10 established for the library: launched elsewhere, import silently
  fell back to a system `python3` with no Demucs. Now resolved against the
  binary's directory (`app_dir`, cached via `os.get_executable_path`).
- **Per-entry string leak** — `queue_begin_next` popped `files[0]`/`names[0]`
  without freeing. Fixed together with Story 6.12's `current` copy, since freeing
  alone would dangle.
- **Silent `I`** when everything marked is already imported — now posts
  "already imported — nothing to do" via a browser status line.
- **Duplicate `is_finished_song` / `is_finished_song_dir`** collapsed into one
  shared definition in `library.odin`.

## Verification

- `--queuecheck` extended: same filename in two albums resolves to two distinct
  folders and all four songs land; overlapping marks expand to 4 (deduped); a
  re-expand after a completed run finds 0.
- `--importedcheck <folder>` (new) reports what a folder would still import —
  used to confirm the real library is untouched.
- 27 songlib tests (3 new for `unique_slug`: disambiguation, stability, tight
  buffer). All 16 packages green; `--stemcheck` still decodes all 106 songs.

## Notes / risks

- Folder names are less pretty (`01-sweet-leaf-9c3ab71f`), which is acceptable
  because the UI shows tags, not slugs, since Story 6.9.
- Only the *separator* paths were made exe-relative. Other `assets/` lookups
  (soundfonts, IRs, cabs) are still cwd-relative — out of scope here, but the
  same latent problem.
