package conv

// Direct time-domain convolution for offline cabinet impulse-response (IR)
// processing. We pre-render notes on the main thread, so there's no realtime
// budget to fight; a short (truncated) cab IR convolved directly is simple,
// exact, and fast enough. Convolving the guitar signal with a real speaker+mic
// IR is the single biggest realism lever for electric guitar tone.

import "core:math"

// convolve computes out = input * ir (linear convolution), writing up to
// len(out) samples and returning how many were written. out is fully cleared
// over the written range first.
convolve :: proc(input, ir, out: []f32) -> int {
	n := len(input)
	m := len(ir)
	if n == 0 || m == 0 {
		return 0
	}
	out_len := min(n + m - 1, len(out))
	for i in 0 ..< out_len {
		out[i] = 0
	}
	for i in 0 ..< n {
		x := input[i]
		if x == 0 {
			continue // note tails are exact silence; skip the inner loop
		}
		kmax := min(m, out_len - i)
		for k in 0 ..< kmax {
			out[i + k] += x * ir[k]
		}
	}
	return out_len
}

// normalize_l2 scales the IR in place to unit energy, so convolution roughly
// preserves signal loudness regardless of the IR's raw level.
normalize_l2 :: proc(ir: []f32) {
	energy: f32 = 0
	for s in ir {
		energy += s * s
	}
	if energy <= 0 {
		return
	}
	inv := 1 / math.sqrt(energy)
	for &s in ir {
		s *= inv
	}
}
