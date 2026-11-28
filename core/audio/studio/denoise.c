/*
 * Noise removal with RNNoise (third_party/rnnoise, its built-in model), on
 * 10 ms frames at 48 kHz. It takes samples at 16-bit scale. Handed back a
 * frame behind, plus RNNoise's own two frames of delay (30 ms in all).
 */
#include <string.h>

#include "rnnoise.h"
#include "studio_internal.h"

#define FRAME 480

struct studio_denoise
{
    DenoiseState *st;
    float pending[FRAME];
    int pending_n;
    float out[2 * FRAME + 8192];
    int out_n;
};

studio_denoise_t *studio_denoise_new(void)
{
    studio_denoise_t *d = STUDIO_CALLOC(1, sizeof(studio_denoise_t));
    if (d == NULL)
    {
        return NULL;
    }
    d->st = rnnoise_create(NULL);
    if (d->st == NULL)
    {
        STUDIO_FREE(d);
        return NULL;
    }
    studio_denoise_reset(d);
    return d;
}

void studio_denoise_free(studio_denoise_t *d)
{
    if (d != NULL)
    {
        rnnoise_destroy(d->st);
        STUDIO_FREE(d);
    }
}

void studio_denoise_reset(studio_denoise_t *d)
{
    rnnoise_init(d->st, NULL);
    d->pending_n = 0;
    memset(d->out, 0, FRAME * sizeof(float));
    d->out_n = FRAME;
}

int studio_denoise_latency(void)
{
    return 3 * FRAME;
}

void studio_denoise_process(studio_denoise_t *d, float *x, int n)
{
    int done = 0;
    while (done < n)
    {
        int take = FRAME - d->pending_n;
        if (take > n - done)
        {
            take = n - done;
        }
        memcpy(d->pending + d->pending_n, x + done, (size_t)take * sizeof(float));
        d->pending_n += take;
        done += take;
        if (d->pending_n < FRAME)
        {
            break;
        }
        d->pending_n = 0;
        if (d->out_n + FRAME > (int)(sizeof(d->out) / sizeof(d->out[0])))
        {
            break;
        }
        float in[FRAME];
        for (int i = 0; i < FRAME; i++)
        {
            in[i] = d->pending[i] * 32768.0f;
        }
        float *y = d->out + d->out_n;
        rnnoise_process_frame(d->st, y, in);
        for (int i = 0; i < FRAME; i++)
        {
            y[i] *= 1.0f / 32768.0f;
        }
        d->out_n += FRAME;
    }
    int give = n < d->out_n ? n : d->out_n;
    memcpy(x, d->out, (size_t)give * sizeof(float));
    for (int i = give; i < n; i++)
    {
        x[i] = 0;
    }
    memmove(d->out, d->out + give, (size_t)(d->out_n - give) * sizeof(float));
    d->out_n -= give;
}
