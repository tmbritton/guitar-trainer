# audioprobe

Throwaway diagnostic (Epic 0 / Story 3). Enumerates audio devices miniaudio can
see and prints the active backend. Does **not** open a device or run a callback.

## Build & run

```sh
mise exec -- odin build tools/audioprobe -out:tools/audioprobe/audioprobe
./tools/audioprobe/audioprobe
```

## What to look for

- **backend** — `pulseaudio` on a stock PipeWire box (the pulse shim). Affects how
  low-latency quantum is requested (see `docs/epic-0/story-3.md` findings).
- A **capture device** matching your USB interface (Scarlett Solo / MOTU M2) once
  it's plugged in. Until then only `Built-in Audio` shows up, which is fine for
  building Epic 1.

## PipeWire quantum

```sh
pw-metadata -n settings | grep -iE 'quantum|rate'
```
