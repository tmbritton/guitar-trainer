package detect

// Onset detection. Runs in the audio callback on the dry input, one hop at a
// time. Energy-based (RMS) detection function — FFT-free, O(n) per hop, no
// allocation. Emits a sample-timestamped onset on a note attack and does not
// retrigger on a sustained note.
//
// Two guards prevent spurious multi-triggers:
//   - re-arm-on-silence: after firing, the detector won't fire again until the
//     signal falls back near the noise floor (so a held note stays quiet).
//   - refractory: a minimum sample gap between emitted onsets, guarding against
//     two attacks landing too close together.

import "core:math"

Onset_Detector :: struct {
	prev_rms:       f32,
	floor:          f32, // absolute RMS below which nothing is an onset
	rise_ratio:     f32, // current RMS must exceed prev * this to count as a rise
	rearm_ratio:    f32, // re-arm when RMS < floor * this
	refractory:     u64, // min samples between emitted onsets
	armed:          bool,
	has_fired:      bool,
	last_onset_pos: u64,
}

default_onset_detector :: proc() -> Onset_Detector {
	return Onset_Detector {
		floor       = 0.02,
		rise_ratio  = 2.0,
		rearm_ratio = 1.0,
		refractory  = 2400, // 50 ms at 48 kHz
		armed       = true,
	}
}

rms :: proc(samples: []f32) -> f32 {
	if len(samples) == 0 {
		return 0
	}
	sum: f32 = 0
	for s in samples {
		sum += s * s
	}
	return math.sqrt(sum / f32(len(samples)))
}

// push_block feeds one hop and reports whether an onset fired (and where).
push_block :: proc(d: ^Onset_Detector, samples: []f32, block_start_pos: u64) -> (onset: bool, pos: u64) {
	e := rms(samples)
	defer d.prev_rms = e

	rising := d.armed && e >= d.floor && e >= d.prev_rms * d.rise_ratio
	if rising {
		// A rise consumes the arm regardless of whether we emit, so a note that
		// is already loud won't fire on every subsequent hop.
		d.armed = false
		past_refractory := !d.has_fired || (block_start_pos - d.last_onset_pos) >= d.refractory
		if past_refractory {
			d.has_fired = true
			d.last_onset_pos = block_start_pos
			return true, block_start_pos
		}
		return false, 0
	}

	// Re-arm once the signal returns to near-silence.
	if e < d.floor * d.rearm_ratio {
		d.armed = true
	}
	return false, 0
}
