/*
 * Echo: what the sender had from GStreamer's audioecho. A delay line that
 * keeps the input plus feedback times what comes out of it; the output is
 * the input plus mix times the echo. The delay is whole samples, rounded
 * down, at least one.
 */
#include <math.h>
#include <string.h>

#include "studio_internal.h"

bool studio_echo_init(studio_echo_t *e, int rate, float max_s)
{
    e->rate = rate;
    e->size = (int)(max_s * (float)rate) + 1;
    e->pos = 0;
    e->buf = STUDIO_CALLOC((size_t)e->size, sizeof(float));
    return e->buf != NULL;
}

void studio_echo_free(studio_echo_t *e)
{
    STUDIO_FREE(e->buf);
    e->buf = NULL;
}

void studio_echo_process(studio_echo_t *e, float *x, int n, float delay_ms, float feedback, float mix)
{
    // As gst_util_uint64_scale(delay ns, rate, GST_SECOND): rounded down
    int delay = (int)floorf(delay_ms * (float)e->rate / 1000.0f + 1e-4f);
    if (delay < 1)
    {
        delay = 1;
    }
    if (delay > e->size - 1)
    {
        delay = e->size - 1;
    }
    int read = e->pos - delay;
    if (read < 0)
    {
        read += e->size;
    }
    int write = e->pos;
    for (int i = 0; i < n; i++)
    {
        float in = x[i];
        float echo = e->buf[read];
        x[i] = in + mix * echo;
        float keep = in + feedback * echo;
        e->buf[write] = fabsf(keep) < 1e-20f ? 0 : keep;
        if (++read == e->size)
        {
            read = 0;
        }
        if (++write == e->size)
        {
            write = 0;
        }
    }
    e->pos = write;
}
