// C shim around NeuralAmpModelerCore so Odin can FFI a neural amp model.
// Compiled with -DNAM_SAMPLE_FLOAT so NAM_SAMPLE == float and process() takes
// float** (matching our audio). Mono in / mono out.

#include <cstdio>
#include <filesystem>
#include <new>

#include "NAM/dsp.h"
#include "NAM/get_dsp.h"

extern "C" {

// Load a .nam model. Returns an opaque handle, or null on failure.
void* nam_load(const char* path)
{
  try
  {
    std::unique_ptr<nam::DSP> dsp = nam::get_dsp(std::filesystem::path(path));
    return static_cast<void*>(dsp.release());
  }
  catch (const std::exception& e)
  {
    std::fprintf(stderr, "nam_load error: %s\n", e.what());
    return nullptr;
  }
  catch (...)
  {
    std::fprintf(stderr, "nam_load error: unknown\n");
    return nullptr;
  }
}

// Reset for a given sample rate and max block size (prewarms by default).
void nam_reset(void* h, double sample_rate, int max_buffer)
{
  if (h)
    static_cast<nam::DSP*>(h)->Reset(sample_rate, max_buffer);
}

int nam_has_loudness(void* h)
{
  return (h && static_cast<nam::DSP*>(h)->HasLoudness()) ? 1 : 0;
}

double nam_loudness(void* h)
{
  try
  {
    return h ? static_cast<nam::DSP*>(h)->GetLoudness() : 0.0;
  }
  catch (...)
  {
    return 0.0;
  }
}

// Process n frames, mono. `in` and `out` may alias.
void nam_process(void* h, float* in, float* out, int n)
{
  if (!h)
    return;
  float* ins[1] = {in};
  float* outs[1] = {out};
  static_cast<nam::DSP*>(h)->process(ins, outs, n);
}

void nam_free(void* h)
{
  delete static_cast<nam::DSP*>(h);
}
}
