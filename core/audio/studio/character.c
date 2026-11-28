/*
 * The studio chain's versions of the board's simpler effects (from
 * core/audio/voice_fx_chain.c), so the DroneLab presets can be approximated
 * on the Guide's voice: drive (soft clipping), ring modulator, bit crusher,
 * chorus, and a crowd of three pitch shifted voices (the Borg). At the
 * studio's rate, not the board's 16 kHz, so close rather than the same.
 */
#include <math.h>
#include <string.h>

#include "studio_internal.h"

#define TWO_PI_F 6.28318530717958647692f

void studio_drive_process(float *x, int n, float knee_db)
{
    // Quiet sound passes as it is; anything much above the knee is squashed towards it
    const float knee = powf(10.0f, -knee_db / 20.0f);
    for (int i = 0; i < n; i++)
    {
        x[i] = knee * tanhf(x[i] / knee);
    }
}

void studio_ring_process(studio_ring_t *r, float *x, int n, float hz, float mix)
{
    const float step = TWO_PI_F * hz / (float)r->rate;
    for (int i = 0; i < n; i++)
    {
        r->phase += step;
        if (r->phase > TWO_PI_F)
        {
            r->phase -= TWO_PI_F;
        }
        x[i] *= 1.0f - mix + mix * sinf(r->phase);
    }
}

void studio_crush_process(float *x, int n, float bits)
{
    const float levels = powf(2.0f, bits - 1.0f);
    for (int i = 0; i < n; i++)
    {
        x[i] = roundf(x[i] * levels) / levels;
    }
}

bool studio_chorus_init(studio_chorus_t *c, int rate)
{
    c->rate = rate;
    c->size = 4096;     // a power of two, over the longest sweep (20 ms at 48 kHz, and its base)
    c->buf = STUDIO_CALLOC((size_t)c->size, sizeof(float));
    c->pos = 0;
    c->phase = 0;
    return c->buf != NULL;
}

void studio_chorus_free(studio_chorus_t *c)
{
    STUDIO_FREE(c->buf);
    c->buf = NULL;
}

void studio_chorus_reset(studio_chorus_t *c)
{
    memset(c->buf, 0, (size_t)c->size * sizeof(float));
    c->pos = 0;
    c->phase = 0;
}

static float delay_read(const studio_chorus_t *c, float delay)
{
    unsigned whole = (unsigned)delay;
    float frac = delay - (float)whole;
    unsigned newer = c->pos - 1 - whole;
    float a = c->buf[newer & (unsigned)(c->size - 1)];
    float b = c->buf[(newer - 1) & (unsigned)(c->size - 1)];
    return a + (b - a) * frac;
}

void studio_chorus_process(studio_chorus_t *c, float *x, int n, float rate_hz, float depth_ms, float mix)
{
    // Two copies, delayed by sweeps half a cycle apart
    float depth = fminf(20.0f, fmaxf(0.0f, depth_ms)) * (float)c->rate / 1000.0f;
    float base = depth + 2.0f;
    const float step = TWO_PI_F * rate_hz / (float)c->rate;
    for (int i = 0; i < n; i++)
    {
        c->buf[c->pos++ & (unsigned)(c->size - 1)] = x[i];
        c->phase += step;
        if (c->phase > TWO_PI_F)
        {
            c->phase -= TWO_PI_F;
        }
        float wet = 0;
        for (int tap = 0; tap < 2; tap++)
        {
            float d = base + depth * 0.5f * (1.0f + sinf(c->phase + (float)M_PI * (float)tap));
            wet += delay_read(c, d);
        }
        x[i] = (1.0f - mix) * x[i] + mix * 0.5f * wet;
    }
}

/* The crowd: as the board's Borg, one voice a little higher than yours and
 * two lower, summed. */
static const float crowd_ratios[STUDIO_CROWD] = { 0.94f, 0.8f, 1.19f };

bool studio_crowd_init(studio_crowd_t *c, int rate)
{
    for (int k = 0; k < STUDIO_CROWD; k++)
    {
        c->voice[k] = studio_pitch_new(rate);
        if (c->voice[k] == NULL)
        {
            studio_crowd_free(c);
            return false;
        }
    }
    return true;
}

void studio_crowd_free(studio_crowd_t *c)
{
    for (int k = 0; k < STUDIO_CROWD; k++)
    {
        studio_pitch_free(c->voice[k]);
        c->voice[k] = NULL;
    }
}

void studio_crowd_reset(studio_crowd_t *c)
{
    for (int k = 0; k < STUDIO_CROWD; k++)
    {
        studio_pitch_reset(c->voice[k]);
    }
}

int studio_crowd_latency(const studio_crowd_t *c)
{
    return studio_pitch_latency(c->voice[0], 1.0f);
}

void studio_crowd_process(studio_crowd_t *c, float *x, int n)
{
    float in[512], sum[512];
    for (int at = 0; at < n; at += 512)
    {
        int m = n - at < 512 ? n - at : 512;
        memset(sum, 0, sizeof(sum));
        for (int k = 0; k < STUDIO_CROWD; k++)
        {
            memcpy(in, x + at, (size_t)m * sizeof(float));
            studio_pitch_process(c->voice[k], in, m, crowd_ratios[k]);
            for (int i = 0; i < m; i++)
            {
                sum[i] += in[i];
            }
        }
        const float scale = 1.0f / sqrtf((float)STUDIO_CROWD);
        for (int i = 0; i < m; i++)
        {
            x[at + i] = sum[i] * scale;
        }
    }
}
