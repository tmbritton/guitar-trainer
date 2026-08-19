// C shim over the SoundTouch C++ time-stretch class, so Odin can bind it with a
// plain foreign import (see soundtouch.odin). Samples are float, one channel
// (the app's audio path is mono). Tempo is a multiplier: 1.0 = normal, 0.5 =
// half speed (twice as long), pitch preserved.
#ifndef GT_ST_SHIM_H
#define GT_ST_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

void *st_create(unsigned sample_rate, unsigned channels);
void st_destroy(void *h);
void st_set_tempo(void *h, double tempo);
void st_put(void *h, const float *data, unsigned num_frames);
unsigned st_receive(void *h, float *data, unsigned max_frames);
unsigned st_available(void *h);
void st_clear(void *h);
void st_flush(void *h);

#ifdef __cplusplus
}
#endif

#endif
