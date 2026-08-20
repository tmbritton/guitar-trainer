# Epic 6 / Story 6.9 — Song metadata + grouped library

**Goal:** The library listed folder slugs (`01-sweet-leaf`). Show real
artist/album/title from the source file's tags, and browse the library as
**Artist → Album → Song** with songs in album track order.

**Key idea:** Import is already a Python step, so read tags there (mutagen,
`easy=True` for uniform keys across FLAC/MP3/MP4/OGG) and persist them next to
the stems as `meta.txt`. The app never parses container formats; it parses one
small line-oriented file, which keeps the Odin side pure and testable and leaves
the door open to a native tag reader later (Story 6.13).

## Format

`library/<slug>/meta.txt` — one `key value` line per tag; key is the first token,
value is the rest of the line:

```
artist Black Sabbath
albumartist Black Sabbath
album Master of Reality (2009 Remastered Version)
title Sweet Leaf
track 1
disc 1
year 2009
source /home/tom/Music/01 - Sweet Leaf.flac
```

`source` is kept so a song can be re-tagged later without re-separating.

## What changed

- **`assets/separate.py`** — `read_tags` / `write_meta`, called from both the
  real and `--stub` paths; `--tags-only` writes just `meta.txt` and skips
  separation.
- **`src/songlib/meta.odin`** (new) — `Meta`, `parse_meta`, `group_artist`,
  `group_album`, `display_title`, `less_fold`, `meta_less`. Allocation-free:
  fields are subslices of the caller's buffer.
- **`src/library.odin`** — `Song` carries a `Meta`; `read_meta` clones the fields
  (the file buffer is temp); `library_scan` sorts with `meta_less`; `song_artist`
  / `song_album` / `song_title` accessors.
- **`src/import_view.odin`** — `Lib_Level` (Artist/Album/Song), `rows`,
  `library_rebuild_rows`, `library_view_enter`, `library_view_back`, and a
  three-level `library_view_draw`.
- **`src/app.odin`** — ENTER descends, ESC ascends and leaves for the menu only
  at the top level; player shows title + artist.
- **`src/import.odin` / `src/main.odin`** — `--meta <song-dir> <source-file>`.

## Steps

- [x] **Step 1:** tag reading + `meta.txt` in `separate.py`; `--tags-only`.
- [x] **Step 2:** `songlib/meta.odin` + 8 unit tests.
- [x] **Step 3:** `library_scan` reads and sorts by metadata.
- [x] **Step 4:** drill-down view + navigation.
- [x] **Step 5:** `--meta` backfill; player title/artist.

## Verification

- 24 `songlib` tests pass (8 new: parsing, junk tolerance, albumartist
  preference, case-insensitive ordering, disc-before-track, slug fallback).
- Backfilled the real `01-sweet-leaf` from its FLAC and read back the expected
  tags.
- Screenshots of all three levels: artist counts correct, album years/counts
  correct, and songs render **01 / 03 / 04** — in track order despite being
  seeded deliberately out of order.
- `--meta` exit codes: 2 for a missing dir/source, 0 on success.

## Notes / risks

- **Grouping prefers `albumartist` over `artist`** — otherwise a "feat." track
  files under a different artist and splits its own album.
- Values are whitespace-normalized to one line on write: real files carry tags
  (notably `lyrics`) with embedded CR/LF that would corrupt a line-oriented file.
- One sort (`meta_less`: artist → album → disc → track → title) feeds both the
  drill-down levels and album track order, so groups are contiguous runs.
- `rows` is rebuilt only on a level change, never per frame.
- `lv.artist` / `lv.album` are slices into `lv.songs`; `library_view_reload`
  clears them because the songs they point into are freed.
- raylib's default font is ASCII-only — the breadcrumb `›` rendered as `?` and
  became `>`.
- Grouping uses `strings.equal_fold` while sorting uses ASCII `less_fold`; they
  agree for ASCII, but keep them in sync if non-ASCII artists appear.
