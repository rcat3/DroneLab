/*
 * Envelope-following gain, gate, compressor and limiter for the Guide's
 * voice (from EyeStream's dynamics.py, the reference for the tests).
 *
 * A gain computed from each sample's own value (as GStreamer's audiodynamic
 * does) bends the waveform: quiet speech gets its zero crossings crushed by
 * an expander, loud speech its peaks by a compressor. This follows a smoothed
 * level instead, one measurement and decision per 1 ms piece, and ramps the
 * gain across each piece, so the waveform itself isn't distorted.
 *
 * The pieces start afresh at each call, as in the reference, so the same
 * blocks give the same output.
 */
#include <math.h>

#include "studio_internal.h"

#define GATE_FLOOR_DB      -30.0f   // a closed gate turns down rather than mutes: less choppy
#define GATE_HOLD_S        0.20f
#define COMP_THRESHOLD_DB  -24.0f
#define LIMIT_CEILING      0.89f    // -1 dBFS

static float coef(float tau_s, float dt)
{
    return tau_s > 0 ? 1.0f - expf(-dt / tau_s) : 1.0f;
}

static float to_db(float x)
{
    return 20.0f * log10f(fmaxf(x, 1e-9f));
}

void studio_dynamics_init(studio_dynamics_t *d, int rate)
{
    d->rate = rate;
    d->env_db = -100.0f;
    d->gate_db = GATE_FLOOR_DB;
    d->hold = 0.0f;
    d->comp_db = 0.0f;
    d->lim = 1.0f;
    d->prev_gain = 0.0f;
    d->in_db = -100.0f;
    d->out_db = -100.0f;
    d->gate_open = false;
}

void studio_dynamics_process(studio_dynamics_t *d, float *x, int n, float gain_db, float gate_db,
                             float ratio, bool mute)
{
    const int sub = d->rate / 1000;
    const float dt = (float)sub / (float)d->rate;
    const float a_env_up = coef(0.002f, dt), a_env_dn = coef(0.12f, dt);
    const float a_gate_open = coef(0.002f, dt), a_gate_close = coef(0.08f, dt);
    const float a_comp_att = coef(0.005f, dt), a_comp_rel = coef(0.15f, dt);
    const float a_lim_rel = coef(0.05f, dt);
    ratio = fmaxf(1.0f, ratio);
    const float makeup = -COMP_THRESHOLD_DB * (1.0f - 1.0f / ratio) * 0.5f;
    float in_sq = 0.0f;
    float out_sq = 0.0f;

    for (int start = 0; start < n; start += sub)
    {
        float *seg = x + start;
        int m = n - start < sub ? n - start : sub;
        float peak = 0.0f;
        for (int i = 0; i < m; i++)
        {
            peak = fmaxf(peak, fabsf(seg[i]));
            in_sq += seg[i] * seg[i];
        }
        float level = to_db(peak);
        float a = level > d->env_db ? a_env_up : a_env_dn;
        d->env_db += (level - d->env_db) * a;

        // Gate, on the microphone's own level, so the threshold doesn't move with the gain
        if (d->env_db > gate_db)
        {
            d->hold = GATE_HOLD_S;
        }
        else
        {
            d->hold = fmaxf(0.0f, d->hold - dt);
        }
        d->gate_open = d->hold > 0.0f;
        float target = d->gate_open ? 0.0f : GATE_FLOOR_DB;
        a = target > d->gate_db ? a_gate_open : a_gate_close;
        d->gate_db += (target - d->gate_db) * a;

        // Compressor, on the level after the gain
        float over = d->env_db + gain_db - COMP_THRESHOLD_DB;
        float want = over > 0 ? -over * (1.0f - 1.0f / ratio) : 0.0f;
        a = want < d->comp_db ? a_comp_att : a_comp_rel;
        d->comp_db += (want - d->comp_db) * a;

        float g_db = gain_db + d->gate_db + d->comp_db + (ratio > 1.0f ? makeup : 0.0f);
        float g = mute ? 0.0f : powf(10.0f, g_db / 20.0f);

        // Limiter: at once on the way in, smooth on the way out
        if (peak * g * d->lim > LIMIT_CEILING)
        {
            d->lim = LIMIT_CEILING / (peak * g);
        }
        else
        {
            d->lim += (1.0f - d->lim) * a_lim_rel;
        }
        g *= d->lim;

        // The gain ramped across the piece, ending on g
        float step = m > 1 ? (g - d->prev_gain) / (float)(m - 1) : 0.0f;
        for (int i = 0; i < m; i++)
        {
            float r = i == m - 1 && m > 1 ? g : d->prev_gain + step * (float)i;
            seg[i] *= r;
            out_sq += seg[i] * seg[i];
        }
        d->prev_gain = g;
    }
    for (int i = 0; i < n; i++)
    {
        x[i] = fmaxf(-0.99f, fminf(0.99f, x[i]));
    }
    if (n > 0)
    {
        d->in_db = to_db(sqrtf(in_sq / (float)n));
        d->out_db = to_db(sqrtf(out_sq / (float)n));
    }
}
