/*
 * The studio chain (core/audio/studio/, HiveSight's Guide voice effects) in
 * libdronelab_fx, for the HiveSight sender (tools/hivesight-sender, through
 * ctypes) and later the app (dart:ffi). 48 kHz, mono in, stereo out.
 *
 * Settings go by the sender's voice.* names: dl_voice_key("gain_db") once,
 * then dl_voice_set with it. Safe from any thread; everything else from the
 * thread that runs the audio.
 */
#include <stdbool.h>

#include "audio/studio/studio.h"

#if defined(_WIN32)
#define DL_EXPORT __declspec(dllexport)
#else
#define DL_EXPORT __attribute__((visibility("default")))
#endif

DL_EXPORT int dl_voice_rate(void)
{
    return STUDIO_RATE;
}

DL_EXPORT studio_t *dl_voice_new(void)
{
    return studio_new();
}

DL_EXPORT void dl_voice_free(studio_t *v)
{
    studio_free(v);
}

DL_EXPORT int dl_voice_key(const char *name)
{
    return studio_key(name);
}

DL_EXPORT void dl_voice_set(studio_t *v, int key, float value)
{
    studio_set(v, key, value);
}

/* n mono samples in, n stereo frames (2n floats) out. Returns n. */
DL_EXPORT int dl_voice_process(studio_t *v, const float *in, int n, float *out_lr)
{
    studio_process(v, in, n, out_lr);
    return n;
}

DL_EXPORT void dl_voice_meter(studio_t *v, float *in_db, float *out_db, int *gate_open)
{
    bool open;
    studio_meter(v, in_db, out_db, &open);
    *gate_open = open;
}

DL_EXPORT int dl_voice_latency(studio_t *v)
{
    return studio_latency(v);
}

DL_EXPORT void dl_voice_reset(studio_t *v)
{
    studio_reset(v);
}
