package mix

// Pure stem-mixer math: given each stem's level/mute/solo, what gain does it
// contribute to the mono backing mix? Deterministic and allocation-free so the
// player's DSP is unit-testable independent of audio/threads.

Stem_Ctl :: struct {
	level: f32, // 0..1 fader
	mute:  bool,
	solo:  bool,
}

// any_solo reports whether at least one stem is soloed. When true, only soloed
// (and unmuted) stems are heard.
any_solo :: proc(ctls: []Stem_Ctl) -> bool {
	for c in ctls {
		if c.solo do return true
	}
	return false
}

// stem_gain is a stem's effective gain: 0 if muted, or if any solo is active and
// this stem isn't the soloed one; otherwise its level. `any_solo` is the result
// of any_solo() over the whole set (passed in so callers compute it once).
stem_gain :: proc(c: Stem_Ctl, any_solo: bool) -> f32 {
	if c.mute do return 0
	if any_solo && !c.solo do return 0
	return c.level
}
