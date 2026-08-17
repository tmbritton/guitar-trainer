# Epic 1 / Story 1.4 — Realtime-Safe Callback Discipline

**Goal:** Make an accidental heap allocation on the audio thread impossible to miss. The callback already installs a non-heap allocator; this story upgrades it to a **guard allocator** that counts allocation attempts and, in `-debug` builds, panics — so a stray alloc crashes loudly in development instead of clicking in release.

**Files:**
- Create: `rtalloc/rtalloc.odin` — `package rtalloc`.
- Create: `rtalloc/rtalloc_test.odin`.
- Modify: `debug.odin` — `callback_allocator` returns the guard under `-debug`, `mem.nil_allocator()` otherwise.

**Constraints in play:**
- The callback must never allocate. This is the enforcement mechanism for that rule.
- The guard's proc must itself be allocation-free and safe to run on the audio thread.

**Interfaces (Produces):**
- `guard_allocator :: proc() -> mem.Allocator` — an allocator whose alloc/resize modes record an attempt and fail (and panic under `-debug`); free/query modes no-op.
- `attempts :: proc() -> u64` / `reset_attempts :: proc()` — atomic attempt counter (also feeds a debug HUD later).

**Design:** `guard_proc` switches on `Allocator_Mode`. `Alloc`/`Alloc_Non_Zeroed`/`Resize`/`Resize_Non_Zeroed` → `atomic_add(&attempts, 1)`, then `when ODIN_DEBUG do panic(...)`, then `return nil, .Out_Of_Memory`. `Free`/`Free_All`/`Query_Features`/`Query_Info` → `return nil, .None`.

## Steps (TDD)

- [ ] **Step 1 (RED):** calling the guard's `procedure` with `.Alloc` returns `.Out_Of_Memory`, a nil slice, and increments `attempts()`. (Tests build without `-debug`, so the panic branch is compiled out — the error path is what's exercised.)
- [ ] **Step 2 (GREEN):** implement `guard_allocator`, `guard_proc`, `attempts`, `reset_attempts`.
- [ ] **Step 3 (RED):** `.Free` and `.Free_All` return `.None` and do **not** increment `attempts()` (freeing is legal/no-op; only allocation is the sin).
- [ ] **Step 4 (RED):** `reset_attempts` zeroes the counter.
- [ ] **Step 5:** `mise exec -- odin test rtalloc` — green.
- [ ] **Step 6:** Wire `debug.odin`: `when ODIN_DEBUG do return rtalloc.guard_allocator() else return mem.nil_allocator()`.
- [ ] **Step 7:** `./build.sh` (release) and `./build.sh -debug` both compile; `--audiocheck` still PASSes under both, and (debug) reports zero allocation attempts.

## Verification

`odin test rtalloc` green. `./build.sh -debug && ./guitar-trainer --audiocheck` PASSes with **0** audio-thread allocation attempts, proving the callback path is allocation-clean under the strictest guard.

## Notes

- The panic branch (`when ODIN_DEBUG`) is not unit-tested (a panic would abort the runner); it's a single guarded line. The counter is the testable, always-on detector and doubles as telemetry.

## Findings (implementation)

- **Parallel test safety:** Odin's test runner runs tests concurrently (multiple threads). A package-global counter shared across tests is a latent race, so the counter was moved behind the allocator's `data` pointer — tests bind a **local** counter via `guard_allocator(&count)`; only one test touches the global default path. `guard_allocator`'s default arg can't be `&g_attempts` (defaults must be constant), so it defaults to `nil` and binds the global inside the proc.
- **Verified both configs:** release (`mem.nil_allocator`) and `-debug` (guard armed, panics on alloc). Under `-debug`, `--audiocheck` ran ~2 s — the callback fired thousands of times — with **0 alloc attempts and no panic**, proving the audio-thread path is genuinely allocation-clean. This is the strongest available check short of the real interface.
- `odin test rtalloc` — 5 tests green.
