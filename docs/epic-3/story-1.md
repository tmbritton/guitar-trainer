# Epic 3 / Story 3.1 — Music Theory Core

**Goal:** Keys, scale degrees, and the degree↔MIDI mapping the drill needs, plus pitch-class helpers for octave-agnostic judging. Pure logic, TDD.

**Files:**
- Create: `music/theory.odin` (`package music`).
- Create: `music/theory_test.odin`.

**Constraints in play:**
- Score the sound: judging is by **pitch class** (octave-agnostic) in v0 (spec open question 12.3 — start octave-agnostic, revisit from data).
- Major key only for v0 (cadence is I–IV–V–I major).

**Interfaces (Produces):**
- `MAJOR_SCALE :: [7]int{0, 2, 4, 5, 7, 9, 11}`
- `pitch_class :: proc(midi: int) -> int` — `((midi % 12) + 12) % 12`, robust to negatives.
- `same_pitch_class :: proc(a, b: int) -> bool`
- `degree_to_midi :: proc(tonic_midi: int, degree: int) -> int` — 1-based degree; degree 8 = octave up; wraps via `MAJOR_SCALE`.
- `note_name :: proc(midi: int) -> string` — pitch-class name (`C`, `C#`, …, `B`).
- `Key :: struct { tonic_midi: int }` and `random_key :: proc(low, high: int) -> Key` (tonic in a comfortable octave; used by cadence generation next story).

## Steps (TDD)

- [ ] **Step 1 (RED):** `pitch_class(60)==0`, `pitch_class(72)==0`, `pitch_class(61)==1`, `pitch_class(-1)==11`.
- [ ] **Step 2 (GREEN):** implement `pitch_class`, `same_pitch_class`.
- [ ] **Step 3 (RED):** `degree_to_midi(60,1)==60`, `..2==62`, `..3==64`, `..4==65`, `..5==67`, `..6==69`, `..7==71`, `..8==72`.
- [ ] **Step 4 (GREEN):** implement `degree_to_midi`.
- [ ] **Step 5 (RED):** `note_name(60)=="C"`, `note_name(69)=="A"`, `note_name(61)=="C#"`, `note_name(70)=="A#"`.
- [ ] **Step 6 (GREEN):** implement `note_name`.
- [ ] **Step 7 (RED):** `same_pitch_class(60,72)`, `!same_pitch_class(60,61)`.
- [ ] **Step 8:** `mise exec -- odin test music` green.

## Verification

`odin test music` green: degrees map to the major scale, octave-agnostic pitch-class comparison works, note names correct.
