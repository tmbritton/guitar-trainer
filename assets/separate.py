#!/usr/bin/env python3
"""Separate an audio file into 6 instrument stems for the guitar-trainer app.

Usage:
    python3 separate.py <input-audio> <output-dir> [--stub] [--tags-only]

Real mode runs Demucs' htdemucs_6s model and writes six mono FLACs into
<output-dir>:
    vocals.flac drums.flac bass.flac guitar.flac piano.flac other.flac

Mono because the app downmixes every stem on load anyway (the device is mono),
which makes the stems ~3.4x smaller than stereo WAV. --stub still writes WAVs,
so both extensions stay covered by the loader.

Both modes also write <output-dir>/meta.txt, the source file's artist/album/
title/track tags, so the library can group by Artist/Album instead of showing
folder names. --tags-only writes just that file and skips separation entirely
(used to backfill songs imported before metadata existed).

Progress and result are reported on stdout, one message per line, for the app's
import worker to parse (src/songlib/parse_line):
    PROGRESS <0..100>      # separation progress
    DONE <output-dir>      # success; stems written
    ERROR <message>        # failure; process exits non-zero

--stub skips Demucs entirely: it emits a few PROGRESS lines and writes six short
silent WAVs. Used by the headless `--importcheck` self-test so the spawn/pipe/
parse path is exercised with no model download and no GPU.

Real mode needs Demucs:  pip install demucs
"""

import os
import struct
import sys
import time
import wave

STEMS = ["vocals", "drums", "bass", "guitar", "piano", "other"]


def emit(msg: str) -> None:
    print(msg, flush=True)


def write_silent_wav(path: str, seconds: float = 0.25, rate: int = 48000) -> None:
    frames = int(seconds * rate)
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(struct.pack("<%dh" % (frames * 2), *([0] * (frames * 2))))


# Tag keys we persist, in meta.txt write order. Everything else in the file
# (lyrics, ISRC, cover art) is ignored.
META_KEYS = ["artist", "albumartist", "album", "title", "track", "disc", "year"]


def _clean(value: str) -> str:
    """One-line, whitespace-normalized value. meta.txt is line-oriented and some
    tags (notably lyrics) carry embedded CR/LF that would corrupt the file."""
    return " ".join(str(value).split()).strip()


def _first(tags, *names) -> str:
    """First non-empty value among `names`; tags may map each key to a list."""
    for n in names:
        v = tags.get(n)
        if not v:
            continue
        if isinstance(v, (list, tuple)):
            v = v[0] if v else ""
        v = _clean(v)
        if v:
            return v
    return ""


def _number(raw: str) -> str:
    """Leading integer of a track/disc tag. ID3 writes these as "3/12"; Vorbis
    comments write a bare "3". Returns "" when there's no usable number."""
    if not raw:
        return ""
    head = raw.split("/")[0].strip()
    return head if head.isdigit() else ""


def read_tags(input_path: str) -> dict:
    """Artist/album/title/track/disc/year for `input_path`. Never raises: an
    unreadable or untagged file yields a title derived from the filename, which
    is what the library falls back to displaying."""
    stem = os.path.splitext(os.path.basename(input_path))[0]
    meta = {k: "" for k in META_KEYS}
    meta["title"] = _clean(stem)
    try:
        import mutagen

        # easy=True gives uniform key names across FLAC/MP3/MP4/OGG instead of
        # format-specific frame ids (TIT2, \xa9nam, ...).
        f = mutagen.File(input_path, easy=True)
        tags = getattr(f, "tags", None) if f is not None else None
        if not tags:
            return meta
        meta["artist"] = _first(tags, "artist", "albumartist", "performer")
        meta["albumartist"] = _first(tags, "albumartist", "artist")
        meta["album"] = _first(tags, "album")
        meta["title"] = _first(tags, "title") or meta["title"]
        meta["track"] = _number(_first(tags, "tracknumber", "track"))
        meta["disc"] = _number(_first(tags, "discnumber", "disc"))
        # "2009-07-14" -> "2009"; some writers use `year` instead of `date`.
        meta["year"] = _clean(_first(tags, "date", "year"))[:4]
    except Exception as e:  # noqa: BLE001 - tags are best-effort, never fatal
        emit("PROGRESS 0")  # keep the protocol well-formed
        sys.stderr.write("tag read failed: %s\n" % e)
    return meta


def write_meta(input_path: str, out_dir: str) -> None:
    """Write out_dir/meta.txt: one `key value` line per non-empty tag, plus the
    absolute source path so a song can be re-tagged later without re-separating."""
    meta = read_tags(input_path)
    os.makedirs(out_dir, exist_ok=True)
    lines = ["%s %s" % (k, meta[k]) for k in META_KEYS if meta[k]]
    lines.append("source %s" % _clean(os.path.abspath(input_path)))
    with open(os.path.join(out_dir, "meta.txt"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def save_stem(wav, path: str, samplerate: int) -> None:
    """Write one separated stem as mono FLAC.

    The app decodes every stem to mono f32 at load (src/stems.odin) because the
    audio device is mono, so keeping stereo on disk costs ~3.4x for audio that
    is thrown away. FLAC is lossless, so this is a pure size win today; it does
    foreclose a future stereo-output mode without re-importing.
    """
    import numpy as np
    import soundfile as sf
    from demucs.audio import prevent_clip

    wav = prevent_clip(wav, mode="rescale")
    mono = wav.mean(0).cpu().numpy().astype(np.float32)
    sf.write(path, mono, samplerate, format="FLAC", subtype="PCM_16")


def run_stub(input_path: str, out_dir: str) -> int:
    os.makedirs(out_dir, exist_ok=True)
    write_meta(input_path, out_dir)
    for i, stem in enumerate(STEMS):
        emit("PROGRESS %d" % int((i / len(STEMS)) * 100))
        write_silent_wav(os.path.join(out_dir, stem + ".wav"))
        time.sleep(0.02)
    emit("PROGRESS 100")
    emit("DONE %s" % out_dir)
    return 0


def run_demucs(input_path: str, out_dir: str) -> int:
    try:
        import torch
        from demucs.apply import apply_model
        from demucs.audio import AudioFile, save_audio
        from demucs.pretrained import get_model
    except ImportError as e:
        emit("ERROR demucs not installed (pip install demucs): %s" % e)
        return 1

    os.makedirs(out_dir, exist_ok=True)
    write_meta(input_path, out_dir)
    emit("PROGRESS 1")
    model = get_model("htdemucs_6s")
    model.eval()

    wav = AudioFile(input_path).read(
        streams=0, samplerate=model.samplerate, channels=model.audio_channels
    )
    ref = wav.mean(0)
    wav = (wav - ref.mean()) / ref.std()
    emit("PROGRESS 5")

    # apply_model reports progress on stderr; we bracket it with coarse marks.
    sources = apply_model(
        model, wav[None], device="cuda" if torch.cuda.is_available() else "cpu",
        progress=True,
    )[0]
    sources = sources * ref.std() + ref.mean()
    emit("PROGRESS 90")

    by_name = dict(zip(model.sources, sources))
    for i, stem in enumerate(STEMS):
        if stem in by_name:
            save_stem(by_name[stem], os.path.join(out_dir, stem + ".flac"),
                      model.samplerate)
        else:
            write_silent_wav(os.path.join(out_dir, stem + ".wav"))
        emit("PROGRESS %d" % (90 + int((i + 1) / len(STEMS) * 10)))

    emit("DONE %s" % out_dir)
    return 0


def main(argv) -> int:
    args = [a for a in argv if not a.startswith("--")]
    stub = "--stub" in argv
    tags_only = "--tags-only" in argv
    if len(args) != 2:
        emit("ERROR usage: separate.py <input> <output-dir> [--stub] [--tags-only]")
        return 2
    input_path, out_dir = args
    if not stub and not os.path.isfile(input_path):
        emit("ERROR input not found: %s" % input_path)
        return 2
    try:
        if tags_only:
            # Backfill: re-read tags for an already-separated song. Deliberately
            # does not touch the stems, so it costs nothing.
            if not os.path.isdir(out_dir):
                emit("ERROR song dir not found: %s" % out_dir)
                return 2
            write_meta(input_path, out_dir)
            emit("PROGRESS 100")
            emit("DONE %s" % out_dir)
            return 0
        return run_stub(input_path, out_dir) if stub else run_demucs(input_path, out_dir)
    except Exception as e:  # noqa: BLE001 - report any failure to the app
        emit("ERROR %s" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
