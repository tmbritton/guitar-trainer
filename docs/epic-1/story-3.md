# Epic 1 / Story 1.3 — SPSC Lock-Free Ring Buffer

**Goal:** A single-producer/single-consumer lock-free ring buffer carrying events from the audio callback (producer) to the main thread (consumer). The callback only pushes; main only drains. No locks, no allocation on either side after construction.

**Sequencing note:** Pure logic, no hardware. Consumed by the device callback (Story 1.1).

**Files:**
- Create: `ring/ring.odin` — `package ring`.
- Create: `ring/ring_test.odin`.

**Constraints in play:**
- Lock-free SPSC. Producer (audio) writes `head`; consumer (main) writes `tail`; each reads the other's index atomically (acquire/release). Fixed capacity, power-of-two, allocated once.
- The callback never allocates/locks/logs — so `push` must be allocation-free and return a bool for "full" rather than growing.

**Interfaces (Produces):**
- `Event :: struct { kind: Event_Kind, sample_pos: u64, value: f32 }` — a timestamped audio-thread event (onset now; extended later). `Event_Kind :: enum u8 { Onset }`.
- `Ring :: struct($N: int) { buf: [N]Event, head: u64, tail: u64 }` — `N` must be a power of two.
- `push :: proc(r: ^Ring($N), e: Event) -> bool` — producer; false if full (event dropped, never blocks).
- `pop :: proc(r: ^Ring($N)) -> (Event, bool)` — consumer; `ok=false` if empty.
- `len :: proc(r: ^Ring($N)) -> int` — approximate count (for diagnostics).

**Design:** monotonically increasing `head`/`tail` counters, index = `counter & (N-1)`. Full when `head - tail == N`. Empty when `head == tail`. Producer: load tail (acquire), check full, write slot, atomic_store head (release). Consumer: load head (acquire), check empty, read slot, atomic_store tail (release).

## Steps (TDD)

- [ ] **Step 1 (RED):** `pop` on a fresh ring returns `ok=false` (empty).
- [ ] **Step 2:** Watch fail.
- [ ] **Step 3 (GREEN):** Structs + empty `pop`.
- [ ] **Step 4 (RED):** push one, pop one → same event; FIFO order across several.
- [ ] **Step 5 (GREEN):** `push`, complete `pop`.
- [ ] **Step 6 (RED):** fill to capacity → next `push` returns false; ring never overwrites unread data. Then pop one, push succeeds (wrap-around correctness past index N).
- [ ] **Step 7 (GREEN):** full/empty accounting with monotonic counters + masking.
- [ ] **Step 8 (RED):** interleaved push/pop across > N total operations preserves FIFO and values (exercises wrap).
- [ ] **Step 9:** `mise exec -- odin test ring` — all green.

## Verification

`mise exec -- odin test ring` green, including a wrap-around test that pushes/pops more than `N` total events in FIFO order with no loss or duplication.

## Notes

- Single-threaded tests are sufficient to prove FIFO/full/empty/wrap logic. The atomic ordering matters only under real concurrency, which the live device run (Story 1.1) exercises; the memory-order annotations are in the code regardless.
