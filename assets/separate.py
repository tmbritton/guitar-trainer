#!/usr/bin/env python3
"""Separate an audio file into 6 instrument stems for the guitar-trainer app.

Usage:
    python3 separate.py <input-audio> <output-dir> [--stub]

Real mode runs Demucs' htdemucs_6s model and writes six WAVs into <output-dir>:
    vocals.wav drums.wav bass.wav guitar.wav piano.wav other.wav

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


def run_stub(input_path: str, out_dir: str) -> int:
    os.makedirs(out_dir, exist_ok=True)
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
            save_audio(by_name[stem], os.path.join(out_dir, stem + ".wav"),
                       model.samplerate)
        else:
            write_silent_wav(os.path.join(out_dir, stem + ".wav"))
        emit("PROGRESS %d" % (90 + int((i + 1) / len(STEMS) * 10)))

    emit("DONE %s" % out_dir)
    return 0


def main(argv) -> int:
    args = [a for a in argv if not a.startswith("--")]
    stub = "--stub" in argv
    if len(args) != 2:
        emit("ERROR usage: separate.py <input> <output-dir> [--stub]")
        return 2
    input_path, out_dir = args
    if not stub and not os.path.isfile(input_path):
        emit("ERROR input not found: %s" % input_path)
        return 2
    try:
        return run_stub(input_path, out_dir) if stub else run_demucs(input_path, out_dir)
    except Exception as e:  # noqa: BLE001 - report any failure to the app
        emit("ERROR %s" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
