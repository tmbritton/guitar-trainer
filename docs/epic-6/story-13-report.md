# Story 6.13 — Dropping Python: a distribution decision report

**Status: DECLINED, 2026-08-20.** "The juice isn't worth the squeeze."

Kept because the measurements are the reason, and a decision without its reason
gets relitigated. The short version: separation is the only hard one of Python's
three jobs, going native costs **6-8x on import speed**, and the benefit it buys
— handing someone a single binary — is not a goal today. If distribution ever
becomes a real requirement, §4's recommended shape still stands: `demucs.cpp` as
a *fallback* behind the existing separator seam, not a replacement.

One item here is **independent of this decision** and survives it: the
`-march=native` finding in §1 is about build flags, not Python. It is tracked
separately as Story 6.19 and is likewise only worth doing if the binary is ever
handed to someone else.

Everything below is the report as written, before the decision.

**The question as originally written** was "get rid of the Python dependency."
**The question you actually care about** is "can I hand this to someone as a
single binary." Those turn out to be different questions, and separating them
changes the answer — so this report answers both.

---

## 1. What ships today

| Piece | Size | How it arrives |
|---|---|---|
| `guitar-trainer` | **3.8 MB** | `./build.sh` |
| `assets/` (SoundFonts, NAM amps, cab IRs) | **21 MB** | `assets/fetch.sh`, third-party |
| `.venv` (Demucs + torch + CUDA) | **4.8 GB** | `mise run setup-python` |
| `htdemucs_6s` weights | **53 MB** | downloaded by Demucs on first import |

Inside that 4.8 GB: **2.7 GB of NVIDIA CUDA libraries** and **1.1 GB of torch**.

That ratio is the single most important fact in this report. **The model is
53 MB. The runtime around it is 4.8 GB — roughly 90x the thing it exists to
run.** Whatever else is true, that is what makes the current setup undistributable.

### The blocker that has nothing to do with Python

`src/nam/build.sh:22` compiles the neural-amp library with **`-march=native`**:

```
FLAGS="-std=c++17 -O3 -march=native -ffast-math -funroll-loops -DNDEBUG -fPIC -DNAM_SAMPLE_FLOAT"
```

A binary built on this machine emits instructions for *this* CPU. Handed to
someone with an older or different CPU, it does not run slowly — it dies with
SIGILL, possibly not at startup but at the first AVX-512 instruction inside an
amp render, which looks like a random crash.

**So there is no distributable binary today, and removing Python would not
create one.** This is cheap to fix (`-march=x86-64-v2` or `-v3`, or runtime
dispatch) and it gates everything else. It should be its own small story
regardless of what is decided below.

The binary also dynamically links `libX11`, `libsqlite3`, `libstdc++`,
`libxcb`, `libXau`, `libXdmcp` — currently resolved against
`/home/linuxbrew/.linuxbrew/lib` via a baked rpath. Fine for you; not fine for a
stranger. Static-linking sqlite3 and libstdc++ is easy; X11 is normally left
dynamic (every desktop Linux has it) and that is the usual, acceptable choice.

---

## 2. Python is doing three separate jobs

Only one of them is hard.

| Job | Library | Difficulty to replace | Notes |
|---|---|---|---|
| Stem separation | Demucs / torch | **Hard** | The whole 4.8 GB |
| Tag reading | mutagen | Easy | ~300 lines: FLAC Vorbis comments, ID3v2, MP4 atoms |
| FLAC encoding | soundfile | Easy–moderate | libFLAC static (~400 KB), or accept mono WAV (3.4x larger) |

Tags and FLAC together are perhaps a weekend, they are pure and unit-testable,
and `songlib.parse_meta` / `meta.txt` already isolate the rest of the app from
where tags come from. **They can be done independently of the separation
decision** and are worth doing on their own merits — they remove two of the
three reasons the venv exists, and neither carries a performance risk.

---

## 3. Separation: the actual decision

### Baseline to beat

Today: **~5x realtime on the GPU** — a 4-minute song in roughly 48 seconds.

### Option A — `demucs.cpp`

MIT. C++17 + header-only **Eigen3** — already vendored for NAM, so it fits the
existing on-target build pattern exactly. Supports `htdemucs_6s`. Pre-converted
ggml weights are published (`ggml-model-htdemucs-6s-f16.bin`, **53 MB**), so
`assets/fetch.sh` could just download them. Separation quality is "practically
identical" to PyTorch per the project's own SDR scores.

**It is CPU-only by design, and the cost is not small.** From the author's own
benchmarks, on a **16-core / 32-thread Ryzen 5950X**, a **4-minute song**:

| Mode | Wall clock |
|---|---|
| Single-threaded program, `OMP_NUM_THREADS=16` | **10m 23s** |
| Multi-threaded program, 4 threads x 4 OMP | **4m 09s** |

So the *best* case on a 16-core desktop is roughly **realtime** — against your
current ~5x realtime. On your 12-core machine, expect **5–8 minutes per song**
where you now spend ~48 seconds: call it a **6–8x regression**.

Scaled to your library: re-importing 106 songs goes from about **1.5 hours** to
**9–12 hours**.

The author is explicit that this is deliberate and not fixable at the margin —
he tried a cuBLAS/NVBLAS branch and reports it "not very useful", because the
implementation is built around for-loops and small matrix multiplies to fit
Android and WebAssembly memory limits, which is exactly the shape that does not
accelerate on a GPU.

**Maintenance:** 173 stars, last pushed **December 2024** — about 20 months
stale. Not abandoned-looking, but not moving either. Vendoring it means owning
it.

### Option B — `demucs.onnx` + ONNX Runtime

MIT. Keeps the door open to GPU via ONNX Runtime execution providers, and the
README claims CUDA / WebGPU / WebNN support.

Three problems, in increasing order of seriousness:

1. **No benchmarks.** The GPU claim is a capability statement about ONNX
   Runtime, not a measurement of this model. It would have to be benchmarked
   before being believed.
2. **Less mature.** 65 stars, 15 commits, last pushed February 2026. ORT is
   consumed via a *minimal from-source build* (`ort-builder`), which is a real
   build-system commitment.
3. **The CUDA execution provider defeats the goal.** It requires the user to
   have a matching CUDA runtime and cuDNN installed. If GPU is what you're
   keeping Python for, ONNX does not let you keep it *and* ship one binary — it
   moves the multi-GB dependency from your venv onto your user's machine. The
   CPU execution provider ships fine and is plausibly faster than demucs.cpp
   (better-tuned kernels), but that is a guess until measured.

### Option C — keep Python, change what "distribution" means

Ship the binary; make importing require a one-line setup step for people who
want it. Honest, zero work, and leaves a stranger unable to add a song — which
is most of the app.

---

## 4. Recommendation

**Do not treat this as one ticket, and do not treat it as a straight
replacement.**

1. **Fix `-march=native` first.** It blocks every distribution story and is
   nearly free. Do this whatever else is decided.
2. **Go native for tags and FLAC.** Small, pure, testable, no downside, and it
   removes two of the three Python dependencies.
3. **For separation, add `demucs.cpp` as a fallback rather than a replacement.**

Point 3 is the one worth arguing for. `import.odin` already talks to the
separator across a narrow seam — spawn a process, read `PROGRESS` / `DONE` /
`ERROR` — and `import_view.odin` only knows about that protocol. A native
in-process separator can publish the same events to the same UI. That means the
two paths can *coexist*:

- **A stranger** gets a genuine single binary that imports songs with no Python,
  no venv, no 4.8 GB, at a few minutes per song. Slow, but it is a one-time
  offline cost per song, and the alternative is that they cannot import at all.
- **You** keep the GPU path: if the venv is present, use it, and imports stay at
  ~5x realtime. Nothing about your workflow regresses.

This costs a runtime selection check and one extra code path, and it avoids the
trap in the ticket as originally framed — that "drop Python" implies accepting a
6–8x import slowdown on your own machine for a benefit (distribution) that
`-march=native` was blocking anyway.

**If you would rather not maintain two paths**, take Option A alone and accept
the slowdown; the quality is equivalent and imports are something you start and
walk away from. What is *not* recommended is Option B on the strength of its GPU
claim, unless someone benchmarks the CUDA execution provider on your hardware
first — and even then it does not deliver the single-binary goal.

## 5. If we proceed, rough order

1. `-march=native` → a portable baseline (small, independent, do it now).
2. Native tag reading (`meta` pkg) — deletes mutagen.
3. Native FLAC encode, or accept mono WAV — deletes soundfile.
4. Vendor `demucs.cpp` the way `nam`/`soundtouch` are vendored, behind the
   existing separator seam; `assets/fetch.sh` gains the 53 MB ggml weights.
5. Runtime selection: native by default, Python/GPU when a venv is present.
6. Static-link sqlite3 + libstdc++; leave X11 dynamic.

Sources: [demucs.cpp](https://github.com/sevagh/demucs.cpp),
[its PERFORMANCE notes](https://github.com/sevagh/demucs.cpp/blob/main/.github/PERFORMANCE.md),
[demucs.onnx](https://github.com/sevagh/demucs.onnx).
