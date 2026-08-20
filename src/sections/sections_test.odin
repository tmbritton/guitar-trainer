package sections

import "core:strings"
import "core:testing"

@(test)
test_parse_basic :: proc(t: ^testing.T) {
	out: [MAX]Section
	n := parse("sec 48000 96000 0.75 1 chorus riff\n", out[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, out[0].a, 48000)
	testing.expect_value(t, out[0].b, 96000)
	testing.expect_value(t, out[0].speed, f32(0.75))
	testing.expect(t, out[0].ladder, "ladder should be on")
	testing.expect_value(t, out[0].name, "chorus riff")
}

@(test)
test_parse_skips_bad_lines :: proc(t: ^testing.T) {
	// A malformed line must not cost the whole file: practice state is worth
	// more than strictness.
	text := `
# a comment
sec 0 48000 1.0 0 good one
sec 100 100 1.0 0 zero length
sec 96000 48000 1.0 0 backwards
sec 0 48000 1.0 0
nonsense
sec 48000 96000 1.0 0 good two
`
	out: [MAX]Section
	n := parse(text, out[:])
	testing.expect_value(t, n, 2)
	testing.expect_value(t, out[0].name, "good one")
	testing.expect_value(t, out[1].name, "good two")
}

@(test)
test_parse_respects_capacity :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< MAX + 5 {
		strings.write_string(&b, "sec 0 48000 1.0 0 name\n")
	}
	out: [MAX]Section
	testing.expect_value(t, parse(strings.to_string(b), out[:]), MAX)
}

@(test)
test_round_trip :: proc(t: ^testing.T) {
	in_list := []Section {
		{name = "intro", a = 0, b = 48000, speed = 1, ladder = false},
		{name = "solo section", a = 48000, b = 240000, speed = 0.6, ladder = true},
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	format(&b, in_list)

	out: [MAX]Section
	n := parse(strings.to_string(b), out[:])
	testing.expect_value(t, n, 2)
	for i in 0 ..< n {
		testing.expect_value(t, out[i].name, in_list[i].name)
		testing.expect_value(t, out[i].a, in_list[i].a)
		testing.expect_value(t, out[i].b, in_list[i].b)
		testing.expect_value(t, out[i].ladder, in_list[i].ladder)
		testing.expect(t, abs(out[i].speed - in_list[i].speed) < 1e-4, "speed round-trip")
	}
}

@(test)
test_format_normalizes_names :: proc(t: ^testing.T) {
	// A name comes from text entry; a stray newline would split the record in
	// two and a tab would be read as a field separator.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	format(&b, []Section{{name = "  the\tbig\nriff  ", a = 0, b = 48000, speed = 1}})
	testing.expect_value(t, strings.to_string(b), "sec 0 48000 1.0000 0 the big riff\n")

	out: [MAX]Section
	testing.expect_value(t, parse(strings.to_string(b), out[:]), 1)
	testing.expect_value(t, out[0].name, "the big riff")
}

@(test)
test_format_skips_invalid :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	format(&b, []Section{{name = "", a = 0, b = 48000, speed = 1}, {name = "bad span", a = 10, b = 10, speed = 1}})
	testing.expect_value(t, strings.to_string(b), "")
}

@(test)
test_speed_clamped :: proc(t: ^testing.T) {
	out: [MAX]Section
	parse("sec 0 48000 9.0 0 too fast\n", out[:])
	testing.expect_value(t, out[0].speed, SPEED_MAX)
	parse("sec 0 48000 0.01 0 too slow\n", out[:])
	testing.expect_value(t, out[0].speed, SPEED_MIN)
	// An unparseable speed falls back to 1.0 rather than dropping the section.
	n := parse("sec 0 48000 fast 0 junk speed\n", out[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, out[0].speed, f32(1))
}

@(test)
test_ladder_climbs_to_one :: proc(t: ^testing.T) {
	testing.expect_value(t, ladder_speed(0.7, 0), f32(0.7))
	// No rung until a full LADDER_EVERY passes are done.
	testing.expect_value(t, ladder_speed(0.7, LADDER_EVERY - 1), f32(0.7))
	testing.expect(t, abs(ladder_speed(0.7, LADDER_EVERY) - 0.75) < 1e-5, "one rung")
	testing.expect(t, abs(ladder_speed(0.7, 2 * LADDER_EVERY) - 0.80) < 1e-5, "two rungs")
	// It stops at 1.0 and never overshoots, however many passes accumulate.
	testing.expect_value(t, ladder_speed(0.7, 1000 * LADDER_EVERY), f32(1))
}

@(test)
test_ladder_descends_to_one :: proc(t: ^testing.T) {
	// A section set faster than 1.0 must also converge on 1.0, not run away.
	testing.expect(t, abs(ladder_speed(1.2, LADDER_EVERY) - 1.15) < 1e-5, "one rung down")
	testing.expect_value(t, ladder_speed(1.2, 1000 * LADDER_EVERY), f32(1))
	testing.expect_value(t, ladder_speed(1, 1000 * LADDER_EVERY), f32(1))
}

@(test)
test_ladder_is_not_cumulative :: proc(t: ^testing.T) {
	// Pure in (start, passes): re-arming a section must land on the same tempo,
	// which an accumulating float would not guarantee.
	for p in 0 ..< 40 {
		testing.expect_value(t, ladder_speed(0.6, p), ladder_speed(0.6, p))
	}
	// And it never leaves the player's supported range.
	for p in 0 ..< 40 {
		s := ladder_speed(0.5, p)
		testing.expect(t, s >= SPEED_MIN && s <= SPEED_MAX, "ladder stays in range")
	}
}

@(test)
test_valid :: proc(t: ^testing.T) {
	testing.expect(t, valid(Section{name = "x", a = 0, b = MIN_FRAMES}), "minimal valid")
	testing.expect(t, !valid(Section{name = "x", a = 5, b = 5}), "empty span")
	testing.expect(t, !valid(Section{name = "x", a = -1, b = MIN_FRAMES}), "negative start")
	testing.expect(t, !valid(Section{name = "", a = 0, b = MIN_FRAMES}), "unnamed")
}

@(test)
test_blank_name_rejected :: proc(t: ^testing.T) {
	// A whitespace-only name used to be accepted, written out as an empty name,
	// and then silently dropped on reload — the section vanished with no error.
	testing.expect(t, !valid(Section{name = "   ", a = 0, b = MIN_FRAMES}), "spaces only")
	testing.expect(t, !valid(Section{name = "\t\n", a = 0, b = MIN_FRAMES}), "whitespace only")
	testing.expect(t, valid(Section{name = " x ", a = 0, b = MIN_FRAMES}), "has a real character")

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	format(&b, []Section{{name = "   ", a = 0, b = MIN_FRAMES, speed = 1}})
	testing.expect_value(t, strings.to_string(b), "")
}

@(test)
test_degenerate_span_rejected :: proc(t: ^testing.T) {
	// A 1-frame span is reachable by pressing L twice while paused. Persisting
	// one is worse than transient: armed at a speed other than 1.0 the producer
	// clears the stretcher every iteration, writes nothing, never sleeps, and
	// spins a core.
	testing.expect(t, !valid(Section{name = "x", a = 100, b = 101}), "one frame")
	testing.expect(t, !valid(Section{name = "x", a = 0, b = MIN_FRAMES - 1}), "under the floor")
	testing.expect(t, valid(Section{name = "x", a = 0, b = MIN_FRAMES}), "at the floor")

	out: [MAX]Section
	testing.expect_value(t, parse("sec 100 101 1.0 0 too short\n", out[:]), 0)
}

@(test)
test_parse_tolerates_whitespace :: proc(t: ^testing.T) {
	// The file advertises itself as hand-editable, so an indented line or tabs
	// between fields must still read.
	out: [MAX]Section
	n := parse("   sec\t0\t48000\t0.75\t1\tmain riff\n", out[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, out[0].b, 48000)
	testing.expect_value(t, out[0].name, "main riff")
	// A keyword that merely starts with "sec" is not a section line.
	testing.expect_value(t, parse("second thoughts 1 2 3 4\n", out[:]), 0)
}

@(test)
test_name_cannot_inject_a_record :: proc(t: ^testing.T) {
	// The name is the rest of the line, so text that looks like another record
	// stays part of the name rather than becoming one.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	format(&b, []Section{{name = "sec 0 999 1 1 evil", a = 0, b = 48000, speed = 1}})
	out: [MAX]Section
	testing.expect_value(t, parse(strings.to_string(b), out[:]), 1)
	testing.expect_value(t, out[0].name, "sec 0 999 1 1 evil")
	testing.expect_value(t, out[0].b, 48000)
}
