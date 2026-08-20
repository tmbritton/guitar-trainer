package sections

// Named practice sections of a song: a span of frames you can arm as an A-B
// loop, plus the speed you were working it at and whether a speed ladder is
// switched on for it.
//
// Pure: parsing, serializing and the ladder arithmetic only. Nothing here reads
// a file or touches the player — `sections.odin` in the app is the I/O shell,
// the way `songlib` relates to `library.odin`.
//
// Line format, one section per line:
//
//     sec <a_frames> <b_frames> <speed> <ladder 0|1> <name...>
//
// The name is the rest of the line, so it may contain spaces. Anything else
// (blank lines, comments, an unrecognised keyword, a malformed span) is skipped
// rather than failing the whole file — a section list is practice state, and
// losing all of it because one line is bad would be worse than losing one.

import "core:fmt"
import "core:strconv"
import "core:strings"

// MAX is the most sections one song can hold. A cap keeps parsing
// allocation-free (the caller supplies the output slice) and a song with more
// than a handful of named passages is not a thing anyone practises.
MAX :: 16

// SPEED_MIN / SPEED_MAX mirror the player's clamp. Kept here so parsing can
// reject nonsense from a hand-edited file without importing the app.
SPEED_MIN :: f32(0.5)
SPEED_MAX :: f32(1.25)

// MIN_FRAMES is the shortest span worth calling a section — 0.1 s at 48 kHz.
//
// This is not fussiness. `player_loop_mark` deliberately forces a 1-frame span
// when both marks land on the same cursor, which is what happens if you press
// `L` twice while paused. Transiently that is merely useless; *persisted* and
// then armed at a speed other than 1.0 it is a hang: the producer feeds one
// frame to the stretcher, wraps, clears it, produces no output, and so never
// reaches any of its sleeps — a silent 100% CPU spin.
MIN_FRAMES :: 4800

Section :: struct {
	name:   string, // display name; a subslice of the parsed text (see parse)
	a, b:   int, // span in input frames; a < b
	speed:  f32, // the speed this passage was last worked at
	ladder: bool, // step the speed toward 1.0 as passes accumulate
}

// ---- ladder ----

// LADDER_STEP is how much closer to 1.0 each rung moves the speed, and
// LADDER_EVERY how many clean passes earn a rung. Deliberately gentle: the
// ladder is a nudge, not a metronome that drags you along.
LADDER_STEP :: f32(0.05)
LADDER_EVERY :: 4

// ladder_speed is the speed after `passes` completed passes of a section that
// started at `start`.
//
// It is a pure function of (start, passes) rather than a value that accumulates
// step by step, which matters: an accumulating float would drift, and arming a
// section twice could land on a different tempo the second time. Movement is
// always *toward* 1.0 and stops there, so a section slowed to 0.6 climbs and one
// set to 1.25 descends.
ladder_speed :: proc(
	start: f32,
	passes: int,
	step := LADDER_STEP,
	every := LADDER_EVERY,
) -> f32 {
	if passes <= 0 || every <= 0 || step <= 0 do return clamp_speed(start)
	s := clamp_speed(start)
	rungs := f32(passes / every)
	if s < 1 do return min(1, s + rungs * step)
	if s > 1 do return max(1, s - rungs * step)
	return 1
}

// clamp_speed holds a speed inside the player's supported range.
clamp_speed :: proc(s: f32) -> f32 {
	if s != s do return 1 // NaN from a corrupt file
	return clamp(s, SPEED_MIN, SPEED_MAX)
}

// ---- parse / format ----

// valid reports whether a section describes a real span with a real name.
//
// The name check is `has_visible`, not `len > 0`: a whitespace-only name used to
// be accepted, written out by `format` as an empty name (write_clean strips it),
// and then silently dropped by `parse` on the next load — the section vanished
// with no error anywhere.
valid :: proc(s: Section) -> bool {
	return s.a >= 0 && s.b - s.a >= MIN_FRAMES && has_visible(s.name)
}

// has_visible reports whether `name` contains anything that would actually be
// drawn — i.e. survives write_clean.
has_visible :: proc(name: string) -> bool {
	for c in transmute([]u8)name {
		if c > 0x20 do return true
	}
	return false
}

// parse fills `out` with the sections in `text` and returns how many were
// written. Names are subslices of `text` — allocation-free, exactly as
// songlib.parse_meta works — so a caller that keeps them past the lifetime of
// the buffer must clone them.
parse :: proc(text: string, out: []Section) -> int {
	n := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if n >= len(out) do break
		s, ok := parse_line(line)
		if !ok do continue
		out[n] = s
		n += 1
	}
	return n
}

// parse_line reads one "sec a b speed ladder name" line.
parse_line :: proc(line: string) -> (s: Section, ok: bool) {
	// Leading indentation and tabs between fields are both accepted: the file
	// advertises itself as hand-editable, and next_field already treats tabs as
	// separators. Matching the keyword as a *field* rather than the literal
	// prefix "sec " is what makes that true — and it still rejects a line whose
	// first word merely starts with "sec".
	rest := strings.trim_space(line)
	kw := next_field(&rest) or_return
	if kw != "sec" do return {}, false

	a := next_field(&rest) or_return
	b := next_field(&rest) or_return
	speed := next_field(&rest) or_return
	ladder := next_field(&rest) or_return
	// Whatever is left is the name, which may contain spaces.
	name := strings.trim_space(rest)
	if len(name) == 0 do return {}, false

	av, aok := strconv.parse_int(a)
	bv, bok := strconv.parse_int(b)
	if !aok || !bok do return {}, false
	sv, sok := strconv.parse_f32(speed)
	if !sok do sv = 1
	lv, _ := strconv.parse_int(ladder)

	s = Section {
		name   = name,
		a      = av,
		b      = bv,
		speed  = clamp_speed(sv),
		ladder = lv != 0,
	}
	return s, valid(s)
}

// next_field splits the leading whitespace-delimited token off `rest`.
@(private)
next_field :: proc(rest: ^string) -> (string, bool) {
	s := strings.trim_left_space(rest^)
	i := strings.index_any(s, " \t")
	if i < 0 do return "", false // no field left, or no name after it
	rest^ = s[i:]
	return s[:i], true
}

// format writes `list` in the line format above. Names are normalized to one
// line with single spaces — a newline or tab in a name would corrupt the file,
// and the name comes from user text entry.
format :: proc(b: ^strings.Builder, list: []Section) {
	for s in list {
		if !valid(s) do continue
		strings.write_string(b, "sec ")
		strings.write_int(b, s.a)
		strings.write_byte(b, ' ')
		strings.write_int(b, s.b)
		strings.write_byte(b, ' ')
		// %.4f to match songprefs.odin's mixer.txt — one numeric convention
		// across the per-song files.
		fmt.sbprintf(b, "%.4f", clamp_speed(s.speed))
		strings.write_string(b, s.ladder ? " 1 " : " 0 ")
		write_clean(b, s.name)
		strings.write_byte(b, '\n')
	}
}

// write_clean writes `name` collapsed to single spaces, with no control
// characters — so it always round-trips through parse as one line.
@(private)
write_clean :: proc(b: ^strings.Builder, name: string) {
	space := false
	wrote := false
	for c in transmute([]u8)name {
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			space = wrote // no leading space
			continue
		}
		if c < 0x20 do continue // control characters would break the line
		if space {
			strings.write_byte(b, ' ')
			space = false
		}
		strings.write_byte(b, c)
		wrote = true
	}
}
