/*
 * High and low pass: 4-pole Chebyshev type 1 with 0.25 dB of ripple, the
 * filters the sender had from GStreamer's audiocheblimit, worked out the same
 * way (the method in Smith, "The Scientist and Engineer's Guide to Digital
 * Signal Processing", chapter 20): the poles of a low pass at 1 rad/s moved
 * onto an ellipse for the ripple, through the bilinear transform, then turned
 * into a low or high pass at the cutoff. Run as two biquads in float rather
 * than one 4th-order filter in double; unity gain at 0 Hz (low pass) or at
 * the Nyquist frequency (high pass).
 *
 * The design is done in double, once per cutoff, not per sample.
 */
#include <math.h>

#include "studio_internal.h"

#define RIPPLE_DB 0.25

void studio_cheb_init(studio_cheb_t *c, int rate, bool highpass)
{
    c->rate = rate;
    c->highpass = highpass;
    c->cutoff = -1;
    c->mode = 1;
    for (int s = 0; s < STUDIO_CHEB_POLES / 2; s++)
    {
        c->stage[s].z1 = c->stage[s].z2 = 0;
    }
}

void studio_cheb_set(studio_cheb_t *c, float cutoff_hz)
{
    if (cutoff_hz == c->cutoff)
    {
        return;
    }
    c->cutoff = cutoff_hz;
    if (cutoff_hz >= c->rate / 2.0f)
    {
        c->mode = c->highpass ? 2 : 1;
        return;
    }
    if (cutoff_hz <= 0)
    {
        c->mode = c->highpass ? 1 : 2;
        return;
    }
    c->mode = 0;
    const int np = STUDIO_CHEB_POLES;
    double gain = 1.0;
    for (int p = 1; p <= np / 2; p++)
    {
        double angle = (M_PI / 2.0) * (2.0 * p - 1) / np;
        double rp = -sin(angle);
        double ip = cos(angle);
        double es = sqrt(pow(10.0, RIPPLE_DB / 10.0) - 1.0);
        double vx = (1.0 / np) * asinh(1.0 / es);
        rp *= sinh(vx);
        ip *= cosh(vx);

        double t = 2.0 * tan(0.5);
        double m = rp * rp + ip * ip;
        double d = 4.0 - 4.0 * rp * t + m * t * t;
        double x0 = (t * t) / d;
        double x1 = 2.0 * x0;
        double x2 = x0;
        double y1 = (8.0 - 2.0 * m * t * t) / d;
        double y2 = (-4.0 - 4.0 * rp * t - m * t * t) / d;

        double omega = 2.0 * M_PI * (cutoff_hz / (double)c->rate);
        double k = c->highpass ? -cos((omega + 1.0) / 2.0) / cos((omega - 1.0) / 2.0)
                               : sin((1.0 - omega) / 2.0) / sin((1.0 + omega) / 2.0);
        d = 1.0 + y1 * k - y2 * k * k;
        double b0 = (x0 + k * (-x1 + k * x2)) / d;
        double b1 = (x1 + k * k * x1 - 2.0 * k * (x0 + x2)) / d;
        double b2 = (x0 * k * k - x1 * k + x2) / d;
        double a1 = (2.0 * k + y1 + y1 * k * k - 2.0 * y2 * k) / d;
        double a2 = (-k * k - y1 * k + y2) / d;
        if (c->highpass)
        {
            a1 = -a1;
            b1 = -b1;
        }
        // Gain at z = 1 (low pass) or z = -1 (high pass)
        double z = c->highpass ? -1.0 : 1.0;
        gain *= (b0 + b1 * z + b2) / (1.0 - a1 * z - a2);
        studio_biquad_t *s = &c->stage[p - 1];
        s->b0 = (float)b0;
        s->b1 = (float)b1;
        s->b2 = (float)b2;
        s->a1 = (float)a1;
        s->a2 = (float)a2;
    }
    // The whole filter's gain taken out in the first stage
    studio_biquad_t *s = &c->stage[0];
    s->b0 = (float)(s->b0 / gain);
    s->b1 = (float)(s->b1 / gain);
    s->b2 = (float)(s->b2 / gain);
}

void studio_cheb_process(studio_cheb_t *c, float *x, int n)
{
    if (c->mode == 1)
    {
        return;
    }
    if (c->mode == 2)
    {
        for (int i = 0; i < n; i++)
        {
            x[i] = 0;
        }
        return;
    }
    for (int s = 0; s < STUDIO_CHEB_POLES / 2; s++)
    {
        studio_biquad_t *q = &c->stage[s];
        float z1 = q->z1, z2 = q->z2;
        // Transposed direct form II
        for (int i = 0; i < n; i++)
        {
            float in = x[i];
            float out = q->b0 * in + z1;
            z1 = q->b1 * in + q->a1 * out + z2;
            z2 = q->b2 * in + q->a2 * out;
            x[i] = out;
        }
        // Keep tiny values from going subnormal in silence
        q->z1 = fabsf(z1) < 1e-20f ? 0 : z1;
        q->z2 = fabsf(z2) < 1e-20f ? 0 : z2;
    }
}
