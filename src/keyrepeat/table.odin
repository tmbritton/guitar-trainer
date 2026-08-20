package keyrepeat

// Table holds one Repeat per key the caller has asked about, so call sites stay
// one-liners instead of each declaring and threading its own state.
//
// Keys are plain i32 rather than raylib's KeyboardKey: this package stays pure
// (no vendor imports) so it can be unit-tested without a window, and the app
// casts at the boundary.
//
// `query` is idempotent within a frame. The hold clock advances on the frame's
// *first* query for a key, and later queries replay the cached answer — so two
// call sites asking about the same key cannot run its clock at double speed.
// Nothing in the app does that today; it is defence against a call site added
// later, since the symptom (one key repeating twice as fast as its neighbour)
// would be baffling to track down.

Table :: struct {
	frame: u64,
	n:     int,
	slots: [64]Slot,
}

Slot :: struct {
	key:   i32,
	rep:   Repeat,
	frame: u64, // the frame `count` was computed on
	count: int,
}

// next_frame opens a new frame. Call it once per frame, before any query.
next_frame :: proc(t: ^Table) {
	t.frame += 1
}

// reset forgets every key's hold.
//
// The caller needs this at a screen change. A key's clock only advances on the
// frames it is asked about, and neither a gap in queries nor a screen switch is
// visible to `tick` — so a finger still down on DOWN after ENTER moved from the
// library to the player would arrive already past its delay and scroll the new
// screen's list several rows before the user could react. Forgetting the holds
// makes the new screen wait for a fresh press, which is what pressing ENTER
// meant.
reset :: proc(t: ^Table) {
	t.n = 0
}

// query reports how many times `key`'s action should fire this frame under
// `profile` (a FAST/SEEK constant). `pressed` and `down` come from the platform;
// `dt` is the frame's elapsed seconds.
query :: proc(t: ^Table, key: i32, profile: Repeat, pressed, down: bool, dt: f32) -> int {
	slot: ^Slot
	for i in 0 ..< t.n {
		if t.slots[i].key == key {
			slot = &t.slots[i]
			break
		}
	}
	fresh := false
	if slot == nil {
		if t.n >= len(t.slots) {
			// Out of slots: report the press so the key still *works*, and give
			// up only on its auto-repeat. Losing the keystroke would be a much
			// worse failure than losing its repeat. This path cannot be
			// idempotent (there is nowhere to cache the answer), which is one
			// more reason the table is sized well above the ~20 keys the app
			// uses.
			return pressed ? 1 : 0
		}
		slot = &t.slots[t.n]
		t.n += 1
		slot^ = Slot {
			key = key,
		}
		fresh = true
	}
	// `fresh` rather than a frame comparison: a brand-new slot has frame 0, and
	// so does a Table nobody has called next_frame on yet — so the cache would
	// hit on the very query that created the slot and swallow the keypress.
	if !fresh && slot.frame == t.frame {
		return slot.count
	}
	if slot.rep.rate != profile.rate {
		// Retime, keeping the accumulated hold: the same key can carry different
		// profiles on different screens, and a swap must not reset a hold in
		// progress. `fired` is counted in units of the *old* rate, though, so it
		// has to be re-derived — carrying it across a fast-to-slow swap leaves
		// far more repeats credited than the new rate has earned, and the key
		// goes dead until the hold time catches up (seconds, in practice).
		if slot.rep.rate > 0 && profile.rate > 0 {
			slot.rep.fired = int(max(0, slot.rep.held - profile.delay) / profile.rate)
		} else {
			slot.rep.fired = 0
		}
	}
	slot.rep.delay, slot.rep.rate = profile.delay, profile.rate
	slot.frame = t.frame
	slot.count = tick(&slot.rep, pressed, down, dt)
	return slot.count
}
