/*
 * A complex FFT of any power of two, with its own tables (the board's
 * core/audio/fft.c has one fixed table up to 512 points, in internal RAM).
 */
#include <math.h>

#include "studio_internal.h"

bool studio_fft_init(studio_fft_t *f, int n)
{
    f->n = n;
    f->bitrev = STUDIO_CALLOC((size_t)n, sizeof(int));
    f->twiddle = STUDIO_CALLOC((size_t)(n / 2), sizeof(studio_cpx_t));
    if (f->bitrev == NULL || f->twiddle == NULL)
    {
        studio_fft_free(f);
        return false;
    }
    int bits = 0;
    while ((1 << bits) < n)
    {
        bits++;
    }
    for (int i = 0; i < n; i++)
    {
        int r = 0;
        for (int b = 0; b < bits; b++)
        {
            r |= ((i >> b) & 1) << (bits - 1 - b);
        }
        f->bitrev[i] = r;
    }
    // The tables once, in double: not per sample
    for (int k = 0; k < n / 2; k++)
    {
        double a = -2.0 * M_PI * k / n;
        f->twiddle[k].re = (float)cos(a);
        f->twiddle[k].im = (float)sin(a);
    }
    return true;
}

void studio_fft_free(studio_fft_t *f)
{
    STUDIO_FREE(f->bitrev);
    STUDIO_FREE(f->twiddle);
    f->bitrev = NULL;
    f->twiddle = NULL;
}

void studio_fft(const studio_fft_t *f, studio_cpx_t *x, bool inverse)
{
    const int n = f->n;
    for (int i = 0; i < n; i++)
    {
        int j = f->bitrev[i];
        if (j > i)
        {
            studio_cpx_t t = x[i];
            x[i] = x[j];
            x[j] = t;
        }
    }
    for (int len = 2; len <= n; len <<= 1)
    {
        int half = len / 2;
        int step = n / len;
        for (int start = 0; start < n; start += len)
        {
            for (int k = 0; k < half; k++)
            {
                studio_cpx_t w = f->twiddle[k * step];
                if (inverse)
                {
                    w.im = -w.im;
                }
                studio_cpx_t *a = &x[start + k];
                studio_cpx_t *b = &x[start + k + half];
                float tr = b->re * w.re - b->im * w.im;
                float ti = b->re * w.im + b->im * w.re;
                b->re = a->re - tr;
                b->im = a->im - ti;
                a->re += tr;
                a->im += ti;
            }
        }
    }
}
