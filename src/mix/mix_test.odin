package mix

import "core:testing"

@(test)
any_solo_detects_a_soloed_stem :: proc(t: ^testing.T) {
	none := []Stem_Ctl{{level = 1}, {level = 1}}
	testing.expect(t, !any_solo(none), "no solo -> false")

	some := []Stem_Ctl{{level = 1}, {level = 1, solo = true}}
	testing.expect(t, any_solo(some), "one solo -> true")
}

@(test)
gain_is_level_when_nothing_special :: proc(t: ^testing.T) {
	testing.expect_value(t, stem_gain({level = 0.8}, false), f32(0.8))
}

@(test)
muted_stem_is_silent :: proc(t: ^testing.T) {
	testing.expect_value(t, stem_gain({level = 0.8, mute = true}, false), f32(0))
}

@(test)
solo_silences_non_soloed_stems :: proc(t: ^testing.T) {
	// a solo is active somewhere; this stem is not soloed -> silent
	testing.expect_value(t, stem_gain({level = 1}, true), f32(0))
	// this stem is the soloed one -> plays at its level
	testing.expect_value(t, stem_gain({level = 0.5, solo = true}, true), f32(0.5))
}

@(test)
mute_wins_over_solo :: proc(t: ^testing.T) {
	// a muted stem stays silent even if it is also soloed
	testing.expect_value(t, stem_gain({level = 1, solo = true, mute = true}, true), f32(0))
}
