#include "st_shim.h"
#include "SoundTouch.h"

using namespace soundtouch;

extern "C" {

void *st_create(unsigned sample_rate, unsigned channels) {
	SoundTouch *s = new SoundTouch();
	s->setSampleRate(sample_rate);
	s->setChannels(channels);
	// Favour quality for offline-ish backing playback; these are SoundTouch's
	// tunables for the WSOLA stretch. AA filter on keeps pitch clean.
	s->setSetting(SETTING_USE_QUICKSEEK, 0);
	s->setSetting(SETTING_USE_AA_FILTER, 1);
	return s;
}

void st_destroy(void *h) { delete static_cast<SoundTouch *>(h); }

void st_set_tempo(void *h, double tempo) {
	static_cast<SoundTouch *>(h)->setTempo(tempo);
}

void st_put(void *h, const float *data, unsigned num_frames) {
	static_cast<SoundTouch *>(h)->putSamples(data, num_frames);
}

unsigned st_receive(void *h, float *data, unsigned max_frames) {
	return static_cast<SoundTouch *>(h)->receiveSamples(data, max_frames);
}

unsigned st_available(void *h) {
	return static_cast<SoundTouch *>(h)->numSamples();
}

void st_clear(void *h) { static_cast<SoundTouch *>(h)->clear(); }

void st_flush(void *h) { static_cast<SoundTouch *>(h)->flush(); }
}
