package detect

// Pitch detection via YIN (de Cheveigné & Kawahara 2002). Runs on the main
// thread from a buffered window of dry samples — never in the audio callback
// (the physics floor means a low note needs 2-3 periods before it can be
// confirmed). Returns a "no confident pitch" state rather than guessing.

import "core:math"

Pitch_Result :: struct {
	freq:       f32,
	confidence: f32, // 1 - aperiodicity at the chosen lag
	voiced:     bool,
}

YIN_THRESHOLD :: 0.15

// detect_pitch runs YIN over `samples`. `scratch` receives the cumulative mean
// normalized difference function and must be at least len(samples)/2 long.
detect_pitch :: proc(
	samples: []f32,
	scratch: []f32,
	sample_rate: f32 = 48000,
	threshold: f32 = YIN_THRESHOLD,
) -> Pitch_Result {
	W := len(samples)
	tau_max := W / 2
	if tau_max < 2 || len(scratch) < tau_max {
		return {}
	}
	d := scratch[:tau_max]

	// Step 1: difference function d(tau).
	d[0] = 0
	for tau in 1 ..< tau_max {
		sum: f32 = 0
		for j in 0 ..< tau_max {
			diff := samples[j] - samples[j + tau]
			sum += diff * diff
		}
		d[tau] = sum
	}

	// Step 2: cumulative mean normalized difference d'(tau).
	d[0] = 1
	running: f32 = 0
	for tau in 1 ..< tau_max {
		running += d[tau]
		if running > 0 {
			d[tau] = d[tau] * f32(tau) / running
		} else {
			d[tau] = 1
		}
	}

	// Step 3: absolute threshold — first local min below `threshold`.
	tau := -1
	for i in 2 ..< tau_max - 1 {
		if d[i] < threshold && d[i] <= d[i + 1] {
			tau = i
			// walk down to the actual local minimum of this dip
			for tau + 1 < tau_max && d[tau + 1] < d[tau] {
				tau += 1
			}
			break
		}
	}

	voiced := true
	if tau == -1 {
		// No lag crossed the threshold: fall back to the global minimum, and
		// report unvoiced (no confident pitch).
		voiced = false
		tau = 1
		best := d[1]
		for i in 2 ..< tau_max {
			if d[i] < best {
				best = d[i]
				tau = i
			}
		}
	}

	// Step 4: parabolic interpolation around tau for sub-sample precision.
	better_tau := f32(tau)
	if tau > 0 && tau < tau_max - 1 {
		s0 := d[tau - 1]
		s1 := d[tau]
		s2 := d[tau + 1]
		denom := 2 * (2 * s1 - s2 - s0)
		if denom != 0 {
			better_tau = f32(tau) + (s2 - s0) / denom
		}
	}

	freq := better_tau > 0 ? sample_rate / better_tau : 0
	confidence := 1 - d[tau]
	if confidence < 0 {
		confidence = 0
	}
	return Pitch_Result{freq = freq, confidence = confidence, voiced = voiced}
}

freq_to_midi_f :: proc(freq: f32) -> f32 {
	return 69 + 12 * math.log2(freq / 440)
}

freq_to_midi :: proc(freq: f32) -> int {
	return int(math.round(freq_to_midi_f(freq)))
}

midi_to_freq :: proc(midi: int) -> f32 {
	return 440 * math.pow(f32(2), f32(midi - 69) / 12)
}
