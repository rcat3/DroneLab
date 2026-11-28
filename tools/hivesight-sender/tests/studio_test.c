/*
 * Each studio effect on its own, for the golden tests (run_tests.py through
 * ctypes). Built with the studio sources by build_fx.sh into
 * build/libstudio_test.so; not part of the app.
 */
#include <stdlib.h>
#include <string.h>

#include "audio/studio/studio_internal.h"

#define EXPORT __attribute__((visibility("default")))

/* Each one runs a whole signal in blocks of block samples, in place. */

EXPORT void t_dynamics(float *x, int n, int block, float gain_db, float gate_db, float ratio, int mute)
{
    studio_dynamics_t d;
    studio_dynamics_init(&d, 48000);
    for (int at = 0; at < n; at += block)
    {
        int m = n - at < block ? n - at : block;
        studio_dynamics_process(&d, x + at, m, gain_db, gate_db, ratio, mute != 0);
    }
}

EXPORT int t_spectral(float *x, int n, int block, int rate, int mode, float pitch, float formant, float robot_hz,
                      float robot_noise)
{
    studio_spectral_t *s = studio_spectral_new(rate);
    if (s == NULL)
    {
        return -1;
    }
    for (int at = 0; at < n; at += block)
    {
        int m = n - at < block ? n - at : block;
        studio_spectral_process(s, x + at, m, mode, pitch, formant, robot_hz, robot_noise);
    }
    int lat = studio_spectral_latency(s);
    studio_spectral_free(s);
    return lat;
}

EXPORT void t_cheb(float *x, int n, int highpass, float cutoff)
{
    studio_cheb_t c;
    studio_cheb_init(&c, 48000, highpass != 0);
    studio_cheb_set(&c, cutoff);
    studio_cheb_process(&c, x, n);
}

EXPORT void t_echo(float *x, int n, float delay_ms, float feedback, float mix)
{
    studio_echo_t e;
    studio_echo_init(&e, 48000, 2.0f);
    for (int at = 0; at < n; at += 480)
    {
        int m = n - at < 480 ? n - at : 480;
        studio_echo_process(&e, x + at, m, delay_ms, feedback, mix);
    }
    studio_echo_free(&e);
}

EXPORT void t_reverb(const float *x, float *lr, int n, float room, float damp, float level)
{
    studio_reverb_t *r = studio_reverb_new(48000);
    studio_reverb_process(r, x, lr, n, room, damp, level);
    studio_reverb_free(r);
}

EXPORT int t_pitch(float *x, int n, int block, float ratio)
{
    studio_pitch_t *p = studio_pitch_new(48000);
    for (int at = 0; at < n; at += block)
    {
        int m = n - at < block ? n - at : block;
        studio_pitch_process(p, x + at, m, ratio);
    }
    int lat = studio_pitch_latency(p, ratio);
    studio_pitch_free(p);
    return lat;
}

EXPORT int t_denoise(float *x, int n, int block)
{
    studio_denoise_t *d = studio_denoise_new();
    for (int at = 0; at < n; at += block)
    {
        int m = n - at < block ? n - at : block;
        studio_denoise_process(d, x + at, m);
    }
    studio_denoise_free(d);
    return studio_denoise_latency();
}
