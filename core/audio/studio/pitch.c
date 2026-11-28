/*
 * Simple pitch: the whole voice, formants too, raised or lowered (the
 * sender's "Pitch (simple)", which was GStreamer's pitch element, SoundTouch).
 * Not the same code, so not the same sound to the sample: tested for the pitch
 * it reaches, its level and clicks.
 *
 * Grains of 30 ms, half overlapped with Hann windows, are read from the
 * input at ratio times the speed, so each grain comes out at the new pitch.
 * Each grain's start is the one, within 15 ms before the latest it can be, that
 * best continues the previous grain (WSOLA: the overlap's cross-correlation),
 * so the joins keep the voice's cycles in step instead of clicking or
 * beating. The read point drifts by (ratio - 1) of the time and the search
 * pulls it back: that's the time stretch.
 */
#include <math.h>
#include <string.h>

#include "studio_internal.h"

#define RING        16384   // a power of two, well over the longest look back

struct studio_pitch
{
    int rate, grain, hop, search;
    float *ring;            // the input, by absolute sample number
    long long written;      // input samples so far
    float *win;
    float *ola;             // grain overlap-add, grain long
    float *pending;
    int pending_n;
    float *out;
    int out_n, out_cap;
    long long prev_start;   // where the last grain started reading
    bool primed;
};

void studio_pitch_free(studio_pitch_t *p)
{
    if (p == NULL)
    {
        return;
    }
    STUDIO_FREE(p->ring);
    STUDIO_FREE(p->win);
    STUDIO_FREE(p->ola);
    STUDIO_FREE(p->pending);
    STUDIO_FREE(p->out);
    STUDIO_FREE(p);
}

studio_pitch_t *studio_pitch_new(int rate)
{
    studio_pitch_t *p = STUDIO_CALLOC(1, sizeof(studio_pitch_t));
    if (p == NULL)
    {
        return NULL;
    }
    p->rate = rate;
    p->grain = (rate * 30 / 1000) & ~1;
    p->hop = p->grain / 2;
    p->search = rate * 75 / 10000;
    p->out_cap = 2 * p->hop + 8192;
    p->ring = STUDIO_CALLOC(RING, sizeof(float));
    p->win = STUDIO_CALLOC((size_t)p->grain, sizeof(float));
    p->ola = STUDIO_CALLOC((size_t)p->grain, sizeof(float));
    p->pending = STUDIO_CALLOC((size_t)p->hop, sizeof(float));
    p->out = STUDIO_CALLOC((size_t)p->out_cap, sizeof(float));
    if (p->ring == NULL || p->win == NULL || p->ola == NULL || p->pending == NULL || p->out == NULL)
    {
        studio_pitch_free(p);
        return NULL;
    }
    for (int i = 0; i < p->grain; i++)
    {
        // Periodic Hann: two at half overlap add up to exactly 1
        p->win[i] = (float)(0.5 - 0.5 * cos(2.0 * M_PI * i / p->grain));
    }
    studio_pitch_reset(p);
    return p;
}

void studio_pitch_reset(studio_pitch_t *p)
{
    memset(p->ring, 0, RING * sizeof(float));
    memset(p->ola, 0, (size_t)p->grain * sizeof(float));
    p->written = 0;
    p->pending_n = 0;
    memset(p->out, 0, (size_t)p->hop * sizeof(float));
    p->out_n = p->hop;
    p->primed = false;
}

/* How far back the latest grain start is: a whole grain's read and the
 * interpolation's samples. */
static int look_back(const studio_pitch_t *p, float ratio)
{
    return (int)ceilf(ratio * (float)p->grain) + 3;
}

int studio_pitch_latency(const studio_pitch_t *p, float ratio)
{
    // Output lags by a hop plus the read's lag at the middle of a grain
    return p->hop + p->search + look_back(p, ratio) - (int)(ratio * (float)p->grain / 2.0f);
}

static inline float at(const studio_pitch_t *p, long long i)
{
    return i < 0 ? 0.0f : p->ring[i & (RING - 1)];
}

/* Cubic (Catmull-Rom) read at a fractional position. */
static inline float read_at(const studio_pitch_t *p, long long base, float frac)
{
    float y0 = at(p, base - 1), y1 = at(p, base), y2 = at(p, base + 1), y3 = at(p, base + 2);
    float c1 = 0.5f * (y2 - y0);
    float c2 = y0 - 2.5f * y1 + 2.0f * y2 - 0.5f * y3;
    float c3 = 0.5f * (y3 - y0) + 1.5f * (y1 - y2);
    return ((c3 * frac + c2) * frac + c1) * frac + y1;
}

/* Read at base + offset, base whole, offset a float (no doubles per sample). */
static inline float read_from(const studio_pitch_t *p, long long base, float offset)
{
    float f = floorf(offset);
    return read_at(p, base + (long long)f, offset - f);
}

/* The overlap's match between a grain starting at start and the previous
 * one's continuation, every step-th sample. */
static float match(const studio_pitch_t *p, const float *ref, long long start, float ratio, int step)
{
    float xy = 0, yy = 1e-9f;
    for (int i = 0; i < p->hop; i += step)
    {
        float y = read_from(p, start, ratio * (float)i);
        xy += ref[i] * y;
        yy += y * y;
    }
    return xy / sqrtf(yy);
}

static void do_grain(studio_pitch_t *p, float ratio, float *y)
{
    // The latest start that still has the whole grain's read in the input
    const long long nominal = p->written - look_back(p, ratio);
    long long start = nominal;
    if (p->primed)
    {
        // Where the previous grain would have gone on reading: what this one should continue
        float cont = ratio * (float)p->hop;
        float ref[4096];
        for (int i = 0; i < p->hop; i++)
        {
            ref[i] = read_from(p, p->prev_start, cont + ratio * (float)i);
        }
        // Coarse, every 4th offset on every 4th sample, then the best one's neighbours. Earlier
        // only: later would run past the input
        float best = -1e30f;
        int best_off = 0;
        for (int off = -2 * p->search; off <= 0; off += 4)
        {
            float m = match(p, ref, nominal + off, ratio, 4);
            if (m > best)
            {
                best = m;
                best_off = off;
            }
        }
        int centre = best_off;
        best = -1e30f;
        for (int off = centre - 3; off <= centre + 3; off++)
        {
            if (off < -2 * p->search || off > 0)
            {
                continue;
            }
            float m = match(p, ref, nominal + off, ratio, 1);
            if (m > best)
            {
                best = m;
                best_off = off;
            }
        }
        start = nominal + best_off;
    }
    p->prev_start = start;
    p->primed = true;
    for (int i = 0; i < p->grain; i++)
    {
        p->ola[i] += p->win[i] * read_from(p, start, ratio * (float)i);
    }
    memcpy(y, p->ola, (size_t)p->hop * sizeof(float));
    memmove(p->ola, p->ola + p->hop, (size_t)(p->grain - p->hop) * sizeof(float));
    memset(p->ola + p->grain - p->hop, 0, (size_t)p->hop * sizeof(float));
}

void studio_pitch_process(studio_pitch_t *p, float *x, int n, float ratio)
{
    ratio = fminf(2.0f, fmaxf(0.5f, ratio));
    int done = 0;
    while (done < n)
    {
        int take = p->hop - p->pending_n;
        if (take > n - done)
        {
            take = n - done;
        }
        memcpy(p->pending + p->pending_n, x + done, (size_t)take * sizeof(float));
        p->pending_n += take;
        done += take;
        if (p->pending_n < p->hop)
        {
            break;
        }
        p->pending_n = 0;
        for (int i = 0; i < p->hop; i++)
        {
            p->ring[(p->written + i) & (RING - 1)] = p->pending[i];
        }
        p->written += p->hop;
        if (p->out_n + p->hop > p->out_cap)
        {
            break;
        }
        do_grain(p, ratio, p->out + p->out_n);
        p->out_n += p->hop;
    }
    int give = n < p->out_n ? n : p->out_n;
    memcpy(x, p->out, (size_t)give * sizeof(float));
    for (int i = give; i < n; i++)
    {
        x[i] = 0;
    }
    memmove(p->out, p->out + give, (size_t)(p->out_n - give) * sizeof(float));
    p->out_n -= give;
}
