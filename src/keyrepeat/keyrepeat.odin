package keyrepeat

// Held-key auto-repeat, as pure math so it can be unit-tested without a window.
//
// We roll our own rather than use raylib's IsKeyPressedRepeat because that rate
// comes from the OS keyboard settings — typically ~30/s, which for a 5-second
// seek step would scrub 150 seconds of song per second held. The repeat rate has
// to be a property of the *action*, not of the user's desktop preferences, so
// each caller picks a profile (see FAST / SEEK below).
//
// tick returns a *count*, not a bool: a frame that ran long (a stem decode, a
// window resize) still owes the repeats its elapsed time covered, and the caller
// applies them in a loop. The count is derived from accumulated held time rather
// than from frames, so the scroll speed is the same at 30 fps and 144 fps.

// Repeat is one key's auto-repeat state plus its timing profile. Copy a profile
// constant to make one (`r := FAST`).
Repeat :: struct {
	delay: f32, // seconds held before repeating begins
	rate:  f32, // seconds between repeats once it has begun
	held:  f32, // seconds the key has been continuously down
	fired: int, // repeats already emitted for this hold (excludes the press)
}

// FAST steps a list cursor or nudges a level: the action is small and reversible,
// so it can run quickly.
FAST :: Repeat {
	delay = 0.35,
	rate  = 0.05,
}

// SEEK is for coarse, expensive steps — a 5-second transport jump, or a speed
// change that reconfigures the time-stretcher. Slower, so a held key scrubs at a
// speed you can still stop on the passage you wanted.
SEEK :: Repeat {
	delay = 0.35,
	rate  = 0.15,
}

// MAX_BURST caps the repeats one tick may emit. Without it a single pathological
// dt — a debugger breakpoint, a laptop resumed from sleep, a frame stalled on a
// network-share read — would translate its whole duration into actions and, say,
// seek an hour into the song on the frame the app woke up.
MAX_BURST :: 8

// tick advances one key's repeat state by `dt` seconds and returns how many
// times the key's action should fire this frame.
//
// `pressed` is the press edge (raylib's IsKeyPressed) and `down` the held state
// (IsKeyDown). Both are passed rather than deriving the edge from `down`, so a
// tap shorter than one frame — press and release inside the same 16 ms — still
// acts exactly once instead of being missed entirely.
tick :: proc(r: ^Repeat, pressed, down: bool, dt: f32) -> int {
	if pressed {
		// A press edge always restarts the cycle, even mid-hold: re-tapping a
		// key must not resume a repeat run already past its delay and fire a
		// burst for a single tap.
		r.held = 0
		r.fired = 0
		return 1
	}
	if !down {
		r.held = 0
		r.fired = 0
		return 0
	}
	if r.rate <= 0 {
		return 0 // profile with repeating disabled; never divide by it
	}
	r.held += dt
	if r.held < r.delay {
		return 0
	}
	due := int((r.held - r.delay) / r.rate)
	n := due - r.fired
	if n <= 0 {
		return 0
	}
	if n > MAX_BURST {
		n = MAX_BURST
	}
	// Credit only what we actually emit, so a burst clamped above is dropped
	// rather than paid out over the following frames.
	r.fired = due
	return n
}
