/*
 * The board's voice effects on the phone's microphone (core/audio/
 * voice_fx_chain.c, the same code), for lib/comm/voice_fx.dart through
 * dart:ffi. libdronelab_fx: built by app/native/Android.mk on Android and
 * app/linux/CMakeLists.txt on Linux.
 *
 * The microphone's 48 kHz comes down to the effects' 16 kHz (a third, after
 * a low pass at 7 kHz, as the board halves its 32 kHz), then goes through
 * the chain 10 ms at a time, and out at 16 kHz, for Opus.
 */
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "audio/voice_fx_chain.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define DL_EXPORT __attribute__((visibility("default")))

#define IN_RATE     48000
#define FACTOR      (IN_RATE / VOICE_FX_SAMPLE_RATE)
#define BLOCK_OUT   (VOICE_FX_SAMPLE_RATE / 100)       // 10 ms out
#define BLOCK_IN    (BLOCK_OUT * FACTOR)
#define TAPS        63

typedef struct
{
    voice_fx_chain_t *chain;
    float taps[TAPS];
    float history[TAPS - 1 + BLOCK_IN];
    int16_t pending[BLOCK_IN];      // what's come towards the next block
    int pending_n;
} dl_fx_t;

DL_EXPORT int dl_fx_preset_count(void)
{
    return (int)voice_fx_preset_count();
}

DL_EXPORT const char *dl_fx_preset_name(int index)
{
    return index < 0 ? "" : voice_fx_preset_name((size_t)index);
}

/* A new one, with no effect till dl_fx_set: NULL without the memory. */
DL_EXPORT dl_fx_t *dl_fx_new(void)
{
    dl_fx_t *f = calloc(1, sizeof(dl_fx_t));
    if (f == NULL)
    {
        return NULL;
    }
    f->chain = voice_fx_chain_new();
    if (f->chain == NULL)
    {
        free(f);
        return NULL;
    }
    // Windowed sinc low pass at 7 kHz, for a third of 48 kHz
    const float cutoff = 7000.0f / IN_RATE;
    const int mid = TAPS / 2;
    float sum = 0;
    for (int i = 0; i < TAPS; i++)
    {
        float t = (float)(i - mid);
        float sinc = (i == mid) ? 2 * cutoff : sinf(2 * (float)M_PI * cutoff * t) / ((float)M_PI * t);
        float window = 0.54f - 0.46f * cosf(2 * (float)M_PI * i / (TAPS - 1));
        f->taps[i] = sinc * window;
        sum += f->taps[i];
    }
    for (int i = 0; i < TAPS; i++)
    {
        f->taps[i] /= sum;
    }
    return f;
}

/* The preset, from 0, built afresh, with nothing kept from before: -1 for
 * none. */
DL_EXPORT void dl_fx_set(dl_fx_t *f, int preset)
{
    voice_fx_chain_build(f->chain, preset);
    memset(f->history, 0, sizeof(f->history));
    f->pending_n = 0;
}

/* n samples at 48 kHz in, the effect's voice at 16 kHz out: as many as
 * there are whole 10 ms blocks for, at most n / 3 (rounded up, with some
 * kept from before). Returns how many. */
DL_EXPORT int dl_fx_process(dl_fx_t *f, const int16_t *in, int n, int16_t *out)
{
    int made = 0;
    for (int at = 0; at < n;)
    {
        int take = BLOCK_IN - f->pending_n;
        if (take > n - at)
        {
            take = n - at;
        }
        memcpy(f->pending + f->pending_n, in + at, (size_t)take * sizeof(int16_t));
        f->pending_n += take;
        at += take;
        if (f->pending_n < BLOCK_IN)
        {
            break;
        }
        f->pending_n = 0;

        float *h = f->history;
        for (int i = 0; i < BLOCK_IN; i++)
        {
            h[TAPS - 1 + i] = f->pending[i] / 32768.0f;
        }
        float x[BLOCK_OUT];
        for (int i = 0; i < BLOCK_OUT; i++)
        {
            const float *src = h + FACTOR * i;
            float s = 0;
            for (int k = 0; k < TAPS; k++)
            {
                s += f->taps[k] * src[k];
            }
            x[i] = s;
        }
        memmove(h, h + BLOCK_IN, (TAPS - 1) * sizeof(float));

        voice_fx_chain_run(f->chain, x, BLOCK_OUT);
        for (int i = 0; i < BLOCK_OUT; i++)
        {
            float v = fmaxf(-1.0f, fminf(1.0f, x[i]));
            out[made++] = (int16_t)(v * 32767.0f);
        }
    }
    return made;
}

DL_EXPORT void dl_fx_free(dl_fx_t *f)
{
    if (f != NULL)
    {
        voice_fx_chain_free(f->chain);
        free(f);
    }
}
