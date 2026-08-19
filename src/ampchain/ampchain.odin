package ampchain

// Realtime guitar amp chain for live monitoring: input drive -> oversampled
// waveshaper -> tone stack -> streaming-FIR cabinet -> monitor level. Pure DSP,
// per-sample, all fixed-size state (no allocation) so it runs in the audio
// callback. Distinct from the offline NAM/conv path: cheap and low-latency, at
// the cost of some tone realism. Oversampling the waveshaper is the key quality
// lever — it keeps the soft-clip's harmonics from aliasing into harsh fizz.

import "core:math"

SAMPLE_RATE :: 48000

// ============================ oversampled waveshaper ========================

OS :: 4 // oversampling factor
WS_M :: 32 // anti-alias/anti-image prototype length (runs at the oversampled rate)

// Waveshaper soft-clips at OS x the sample rate: a windowed-sinc interpolator
// lifts to OSx, tanh shapes each oversampled sample, then a matching decimator
// drops back to 1x — so the clip's aliasing images are filtered out.
Waveshaper :: struct {
	proto: [WS_M]f32, // shared low-pass prototype (unity DC gain)
	upin:  [WS_M]f32, // zero-stuffed input history (oversampled rate)
	upi:   int,
	shp:   [WS_M]f32, // shaped oversampled history (for decimation)
	shi:   int,
	drive: f32,
}

waveshaper_init :: proc(w: ^Waveshaper, drive: f32) {
	fc := f32(0.5) / OS // cutoff at the pre-oversampling Nyquist
	sum: f32 = 0
	for i in 0 ..< WS_M {
		m := f32(i) - f32(WS_M - 1) / 2
		sinc := m == 0 ? 2 * fc : math.sin(2 * math.PI * fc * m) / (math.PI * m)
		win := f32(0.54) - 0.46 * math.cos(2 * math.PI * f32(i) / f32(WS_M - 1)) // Hamming
		w.proto[i] = sinc * win
		sum += w.proto[i]
	}
	for i in 0 ..< WS_M do w.proto[i] /= sum // normalize to unity DC gain
	w.drive = drive
	waveshaper_reset(w)
}

waveshaper_reset :: proc(w: ^Waveshaper) {
	w.upi = 0
	w.shi = 0
	for i in 0 ..< WS_M {
		w.upin[i] = 0
		w.shp[i] = 0
	}
}

ws_process :: proc(w: ^Waveshaper, x: f32) -> f32 {
	for k in 0 ..< OS {
		v := k == 0 ? x * OS : 0 // zero-stuff, scaled by OS to preserve amplitude
		w.upin[w.upi] = v
		w.upi = (w.upi + 1) %% WS_M
		u := fir_at(w.proto[:], w.upin[:], w.upi) // band-limited upsampled sample
		w.shp[w.shi] = math.tanh(u * w.drive)
		w.shi = (w.shi + 1) %% WS_M
	}
	return fir_at(w.proto[:], w.shp[:], w.shi) // decimate: one output per OS inputs
}

// fir_at convolves `coeffs` with the ring `buf` whose next-write index is `pos`
// (so the most recent sample is at pos-1, weighted by coeffs[0]).
@(private = "file")
fir_at :: proc(coeffs, buf: []f32, pos: int) -> f32 {
	n := len(coeffs)
	acc: f32 = 0
	for j in 0 ..< n {
		acc += coeffs[j] * buf[(pos - 1 - j) %% len(buf)]
	}
	return acc
}

// ============================ tone stack (biquad shelves) ====================

Biquad :: struct {
	b0, b1, b2, a1, a2: f32, // a0-normalized
	z1, z2:             f32, // transposed direct-form II state
}

biquad_process :: proc(bq: ^Biquad, x: f32) -> f32 {
	y := bq.b0 * x + bq.z1
	bq.z1 = bq.b1 * x - bq.a1 * y + bq.z2
	bq.z2 = bq.b2 * x - bq.a2 * y
	return y
}

Tone :: struct {
	bass:   Biquad, // low shelf
	treble: Biquad, // high shelf
}

// tone_set configures a bass low-shelf (~180 Hz) and treble high-shelf (~3 kHz),
// gains in dB (0 = flat, which is an exact pass-through).
tone_set :: proc(t: ^Tone, bass_db, treble_db: f32) {
	z1b, z2b := t.bass.z1, t.bass.z2 // preserve running state across a coeff change
	z1t, z2t := t.treble.z1, t.treble.z2
	set_shelf(&t.bass, 180, bass_db, true)
	set_shelf(&t.treble, 3000, treble_db, false)
	t.bass.z1, t.bass.z2 = z1b, z2b
	t.treble.z1, t.treble.z2 = z1t, z2t
}

tone_process :: proc(t: ^Tone, x: f32) -> f32 {
	return biquad_process(&t.treble, biquad_process(&t.bass, x))
}

tone_reset :: proc(t: ^Tone) {
	t.bass.z1, t.bass.z2 = 0, 0
	t.treble.z1, t.treble.z2 = 0, 0
}

// set_shelf fills a biquad with RBJ low- or high-shelf coefficients.
@(private = "file")
set_shelf :: proc(bq: ^Biquad, f0, gain_db: f32, low: bool) {
	A := math.pow(f32(10), gain_db / 40)
	w0 := 2 * math.PI * f0 / SAMPLE_RATE
	cw := math.cos(w0)
	sw := math.sin(w0)
	alpha := sw / 2 * math.sqrt((A + 1 / A) * (1.0 / 1.0 - 1) + 2) // slope S = 1
	twoSqrtAalpha := 2 * math.sqrt(A) * alpha

	b0, b1, b2, a0, a1, a2: f32
	if low {
		b0 = A * ((A + 1) - (A - 1) * cw + twoSqrtAalpha)
		b1 = 2 * A * ((A - 1) - (A + 1) * cw)
		b2 = A * ((A + 1) - (A - 1) * cw - twoSqrtAalpha)
		a0 = (A + 1) + (A - 1) * cw + twoSqrtAalpha
		a1 = -2 * ((A - 1) + (A + 1) * cw)
		a2 = (A + 1) + (A - 1) * cw - twoSqrtAalpha
	} else {
		b0 = A * ((A + 1) + (A - 1) * cw + twoSqrtAalpha)
		b1 = -2 * A * ((A - 1) + (A + 1) * cw)
		b2 = A * ((A + 1) + (A - 1) * cw - twoSqrtAalpha)
		a0 = (A + 1) - (A - 1) * cw + twoSqrtAalpha
		a1 = 2 * ((A - 1) - (A + 1) * cw)
		a2 = (A + 1) - (A - 1) * cw - twoSqrtAalpha
	}
	bq.b0, bq.b1, bq.b2 = b0 / a0, b1 / a0, b2 / a0
	bq.a1, bq.a2 = a1 / a0, a2 / a0
}

// ============================ streaming FIR cabinet ==========================

CAB_MAX :: 1024 // realtime tap budget (~21 ms) — the cab's character lives early

// Cab_FIR convolves the signal with a cabinet IR sample-by-sample from a
// persistent delay line (unlike the offline batch conv.convolve).
Cab_FIR :: struct {
	coeffs: [CAB_MAX]f32,
	n:      int,
	line:   [CAB_MAX]f32,
	pos:    int,
}

// cab_set loads an IR (truncated to CAB_MAX taps) and clears the delay line.
cab_set :: proc(c: ^Cab_FIR, ir: []f32) {
	c.n = min(len(ir), CAB_MAX)
	for i in 0 ..< c.n do c.coeffs[i] = ir[i]
	cab_reset(c)
}

cab_reset :: proc(c: ^Cab_FIR) {
	c.pos = 0
	for i in 0 ..< CAB_MAX do c.line[i] = 0
}

cab_process :: proc(c: ^Cab_FIR, x: f32) -> f32 {
	if c.n == 0 do return x // no cab loaded -> pass through
	c.line[c.pos] = x
	acc: f32 = 0
	for j in 0 ..< c.n {
		acc += c.coeffs[j] * c.line[(c.pos - j) %% CAB_MAX]
	}
	c.pos = (c.pos + 1) %% CAB_MAX
	return acc
}

// ============================ full chain =====================================

Chain :: struct {
	level: f32,
	ws:    Waveshaper,
	tone:  Tone,
	cab:   Cab_FIR,
}

chain_init :: proc(c: ^Chain) {
	c.level = 1
	waveshaper_init(&c.ws, 1)
	tone_set(&c.tone, 0, 0)
	c.cab.n = 0 // no cab until chain_set_cab
	cab_reset(&c.cab)
}

chain_set_drive :: proc(c: ^Chain, drive: f32) {c.ws.drive = drive}
chain_set_level :: proc(c: ^Chain, level: f32) {c.level = level}
chain_set_tone :: proc(c: ^Chain, bass_db, treble_db: f32) {tone_set(&c.tone, bass_db, treble_db)}
chain_set_cab :: proc(c: ^Chain, ir: []f32) {cab_set(&c.cab, ir)}

process :: proc(c: ^Chain, x: f32) -> f32 {
	y := ws_process(&c.ws, x)
	y = tone_process(&c.tone, y)
	y = cab_process(&c.cab, y)
	return y * c.level
}

process_block :: proc(c: ^Chain, buf: []f32) {
	for &s in buf do s = process(c, s)
}

chain_reset :: proc(c: ^Chain) {
	waveshaper_reset(&c.ws)
	tone_reset(&c.tone)
	cab_reset(&c.cab)
}
