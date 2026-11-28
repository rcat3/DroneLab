/*
 * Reverb: Jezar's Freeverb (public domain), set up as GStreamer's freeverb
 * element was in the sender, mono in and stereo out: eight damped comb
 * filters in parallel and four all-passes in series per side, the right
 * side's delays 23 samples longer, the lengths scaled from 44.1 kHz.
 *
 * room 0..1 sets the combs' feedback (0.7 to 0.98), damp 0..1 their high cut,
 * level 0..1 goes from all dry to all wet. Full stereo width.
 */
#include <math.h>

#include "studio_internal.h"

#define COMBS       8
#define ALLPASSES   4
#define FIXED_GAIN  0.015f
#define SCALE_ROOM  0.28f
#define OFFSET_ROOM 0.7f
#define SPREAD      23

static const int comb_tuning[COMBS] = { 1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617 };
static const int allpass_tuning[ALLPASSES] = { 556, 441, 341, 225 };

typedef struct
{
    float *buf;
    int size;
    int idx;
    float store;
} line_t;

struct studio_reverb
{
    line_t comb[2][COMBS];
    line_t allpass[2][ALLPASSES];
};

static bool line_init(line_t *l, int size)
{
    l->size = size;
    l->idx = 0;
    l->store = 0;
    l->buf = STUDIO_CALLOC((size_t)size, sizeof(float));
    return l->buf != NULL;
}

void studio_reverb_free(studio_reverb_t *r)
{
    if (r == NULL)
    {
        return;
    }
    for (int s = 0; s < 2; s++)
    {
        for (int i = 0; i < COMBS; i++)
        {
            STUDIO_FREE(r->comb[s][i].buf);
        }
        for (int i = 0; i < ALLPASSES; i++)
        {
            STUDIO_FREE(r->allpass[s][i].buf);
        }
    }
    STUDIO_FREE(r);
}

studio_reverb_t *studio_reverb_new(int rate)
{
    studio_reverb_t *r = STUDIO_CALLOC(1, sizeof(studio_reverb_t));
    if (r == NULL)
    {
        return NULL;
    }
    // As GStreamer: the float factor times the tuning, rounded down
    const float factor = (float)rate / 44100.0f;
    bool ok = true;
    for (int s = 0; s < 2; s++)
    {
        for (int i = 0; i < COMBS; i++)
        {
            ok &= line_init(&r->comb[s][i], (int)((float)(comb_tuning[i] + s * SPREAD) * factor));
        }
        for (int i = 0; i < ALLPASSES; i++)
        {
            ok &= line_init(&r->allpass[s][i], (int)((float)(allpass_tuning[i] + s * SPREAD) * factor));
        }
    }
    if (!ok)
    {
        studio_reverb_free(r);
        return NULL;
    }
    return r;
}

static inline float flush(float v)
{
    return fabsf(v) < 1e-20f ? 0 : v;
}

void studio_reverb_process(studio_reverb_t *r, const float *x, float *lr, int n, float room, float damp,
                           float level)
{
    const float feedback = room * SCALE_ROOM + OFFSET_ROOM;
    const float damp1 = damp;
    const float damp2 = 1.0f - damp;
    const float wet = level;    // width 1: all of a side's own reverb, none of the other's
    const float dry = 1.0f - level;
    for (int k = 0; k < n; k++)
    {
        // Freeverb sums a stereo pair; mono counts twice
        const float in = x[k];
        const float input = 2.0f * in * FIXED_GAIN;
        float out[2];
        for (int s = 0; s < 2; s++)
        {
            float acc = 0;
            for (int i = 0; i < COMBS; i++)
            {
                line_t *c = &r->comb[s][i];
                float tmp = c->buf[c->idx];
                c->store = flush(tmp * damp2 + c->store * damp1);
                c->buf[c->idx] = flush(input + c->store * feedback);
                if (++c->idx >= c->size)
                {
                    c->idx = 0;
                }
                acc += tmp;
            }
            for (int i = 0; i < ALLPASSES; i++)
            {
                line_t *a = &r->allpass[s][i];
                float bufout = a->buf[a->idx];
                float o = bufout - acc;
                a->buf[a->idx] = flush(acc + bufout * 0.5f);
                if (++a->idx >= a->size)
                {
                    a->idx = 0;
                }
                acc = o;
            }
            out[s] = acc;
        }
        lr[2 * k] = out[0] * wet + in * dry;
        lr[2 * k + 1] = out[1] * wet + in * dry;
    }
}
