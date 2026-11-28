/*
 * Spectral voice change: pitch and formants moved separately, and a robot
 * that keeps the voice's formants (EyeStream's voicefx.py, the reference for
 * the tests).
 *
 * Plain pitch shifting (resample and time stretch) moves the formants, the
 * resonances of the vocal tract that make a voice who it is, along with the
 * pitch: a deep voice an octave up sounds like a chipmunk rather than a
 * woman. A typical male to female change is about 1.7-1.9 times the pitch
 * but only 1.15-1.2 times the formants, so the two have to be separate.
 *
 * Per frame (about 43 ms, hops of an eighth of it, Hann windows):
 *  1. Phase vocoder analysis gives each bin's magnitude and true frequency.
 *  2. Smoothing the log magnitude through its cepstrum gives the spectral
 *     envelope (the formants); dividing by it leaves the flat harmonics.
 *  3. shift: the harmonics move to pitch times their frequency, then take
 *     the envelope stretched by the formant factor.
 *     robot: the harmonics become those of a fixed pitch (with a little
 *     noise for consonants), shaped by the stretched envelope.
 *  4. Phase vocoder synthesis (accumulated phase), windowed overlap-add.
 *
 * 2048 points at 48 kHz, as the reference; at other rates the power of two
 * nearest the same length. The hand-off is a hop behind, plus the frame.
 */
#include <math.h>
#include <string.h>

#include "studio_internal.h"

#define TWO_PI_F 6.28318530717958647692f
#define PI_F     3.14159265358979323846f


struct studio_spectral
{
    int rate, n, hop, bins, lifter;
    studio_fft_t fft;
    float *win, *frame, *ola, *last_phase, *sum_phase;
    float *mag, *true_bin, *env, *env_w, *syn_mag, *syn_bin, *flat, *noise_phase;
    bool *noisy;
    int *dest;          // shift: where each bin goes, for dest_pitch
    float dest_pitch;
    studio_cpx_t *spec;
    float *pending;     // input waiting for a whole hop
    int pending_n;
    float *out;         // output waiting to be handed back
    int out_n, out_cap;
    float norm;
    float gain, p_in, p_out, corr;
    uint32_t rng;
};

static int frame_size(int rate)
{
    // 2048 at 48 kHz: the power of two nearest to 2048 / 48000 s
    float want = 2048.0f * (float)rate / 48000.0f;
    int n = 64;
    while (n * 2 <= want * 1.41421356f)
    {
        n *= 2;
    }
    return n;
}

void studio_spectral_free(studio_spectral_t *s)
{
    if (s == NULL)
    {
        return;
    }
    studio_fft_free(&s->fft);
    float *bufs[] = { s->win, s->frame, s->ola, s->last_phase, s->sum_phase, s->mag, s->true_bin, s->env,
                      s->env_w, s->syn_mag, s->syn_bin, s->flat, s->noise_phase, s->pending, s->out };
    for (size_t i = 0; i < sizeof(bufs) / sizeof(bufs[0]); i++)
    {
        STUDIO_FREE(bufs[i]);
    }
    STUDIO_FREE(s->noisy);
    STUDIO_FREE(s->dest);
    STUDIO_FREE(s->spec);
    STUDIO_FREE(s);
}

studio_spectral_t *studio_spectral_new(int rate)
{
    studio_spectral_t *s = STUDIO_CALLOC(1, sizeof(studio_spectral_t));
    if (s == NULL)
    {
        return NULL;
    }
    s->rate = rate;
    s->n = frame_size(rate);
    s->hop = s->n / 8;
    s->bins = s->n / 2 + 1;
    // 100 cepstral coefficients at 2048 points: about 2 ms, below the pitch period of voices up to
    // about 400 Hz, fine enough to keep F1 and F2 apart
    s->lifter = (int)lroundf(100.0f * (float)s->n / 2048.0f);
    s->out_cap = 2 * s->hop + 8192;
    const size_t n = (size_t)s->n, b = (size_t)s->bins;
    s->win = STUDIO_CALLOC(n, sizeof(float));
    s->frame = STUDIO_CALLOC(n, sizeof(float));
    s->ola = STUDIO_CALLOC(n, sizeof(float));
    s->last_phase = STUDIO_CALLOC(b, sizeof(float));
    s->sum_phase = STUDIO_CALLOC(b, sizeof(float));
    s->mag = STUDIO_CALLOC(b, sizeof(float));
    s->true_bin = STUDIO_CALLOC(b, sizeof(float));
    s->env = STUDIO_CALLOC(b, sizeof(float));
    s->env_w = STUDIO_CALLOC(b, sizeof(float));
    s->syn_mag = STUDIO_CALLOC(b, sizeof(float));
    s->syn_bin = STUDIO_CALLOC(b, sizeof(float));
    s->flat = STUDIO_CALLOC(b, sizeof(float));
    s->noise_phase = STUDIO_CALLOC(b, sizeof(float));
    s->noisy = STUDIO_CALLOC(b, sizeof(bool));
    s->dest = STUDIO_CALLOC(b, sizeof(int));
    s->spec = STUDIO_CALLOC(n, sizeof(studio_cpx_t));
    s->pending = STUDIO_CALLOC((size_t)s->hop, sizeof(float));
    s->out = STUDIO_CALLOC((size_t)s->out_cap, sizeof(float));
    if (!studio_fft_init(&s->fft, s->n) || s->win == NULL || s->frame == NULL || s->ola == NULL ||
        s->last_phase == NULL || s->sum_phase == NULL || s->mag == NULL || s->true_bin == NULL ||
        s->env == NULL || s->env_w == NULL || s->syn_mag == NULL || s->syn_bin == NULL || s->flat == NULL ||
        s->noise_phase == NULL || s->noisy == NULL || s->dest == NULL || s->spec == NULL ||
        s->pending == NULL || s->out == NULL)
    {
        studio_spectral_free(s);
        return NULL;
    }
    // Periodic Hann; overlap-add gain of analysis times synthesis window at this hop
    double sum = 0;
    for (int i = 0; i < s->n; i++)
    {
        double w = 0.5 - 0.5 * cos(2.0 * M_PI * i / s->n);
        s->win[i] = (float)w;
        sum += w * w;
    }
    s->norm = (float)(sum / s->hop);
    s->rng = 7;
    s->dest_pitch = -1;
    studio_spectral_reset(s);
    return s;
}

void studio_spectral_reset(studio_spectral_t *s)
{
    memset(s->frame, 0, (size_t)s->n * sizeof(float));
    memset(s->ola, 0, (size_t)s->n * sizeof(float));
    memset(s->last_phase, 0, (size_t)s->bins * sizeof(float));
    memset(s->sum_phase, 0, (size_t)s->bins * sizeof(float));
    s->pending_n = 0;
    // A hop of silence ahead: a fixed delay, and it never runs dry
    memset(s->out, 0, (size_t)s->hop * sizeof(float));
    s->out_n = s->hop;
    s->gain = 1.0f;
    s->p_in = 0;
    s->p_out = 0;
    s->corr = 1.0f;
}

int studio_spectral_latency(const studio_spectral_t *s)
{
    return s->n;
}

static float random01(studio_spectral_t *s)
{
    // xorshift32: the reference's numpy generator can't be matched, so robot noise is compared by
    // its level, not sample for sample
    uint32_t x = s->rng;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    s->rng = x;
    return (float)(x >> 8) * (1.0f / 16777216.0f);
}

static float wrap_pi(float p)
{
    // As Python's (p + pi) % 2pi - pi
    return p - TWO_PI_F * floorf((p + PI_F) / TWO_PI_F);
}

static void envelope(studio_spectral_t *s)
{
    const int n = s->n, b = s->bins;
    studio_cpx_t *c = s->spec;
    // Real cepstrum of the log magnitude: its spectrum is real and even
    for (int k = 0; k < b; k++)
    {
        c[k].re = logf(s->mag[k] + 1e-9f);
        c[k].im = 0;
    }
    for (int k = b; k < n; k++)
    {
        c[k].re = c[n - k].re;
        c[k].im = 0;
    }
    studio_fft(&s->fft, c, true);
    for (int i = 0; i < n; i++)
    {
        c[i].re /= (float)n;
        c[i].im = 0;
    }
    for (int i = s->lifter; i <= n - s->lifter; i++)
    {
        c[i].re = 0;
    }
    studio_fft(&s->fft, c, false);
    for (int k = 0; k < b; k++)
    {
        s->env[k] = expf(c[k].re);
    }
}

static void make_dest(studio_spectral_t *s, float pitch)
{
    if (pitch == s->dest_pitch)
    {
        return;
    }
    s->dest_pitch = pitch;
    // Once per pitch, in double, from the setting's decimal value (the float it came as, 1.65 say,
    // is a little under 1.65, so 30 * 1.65 would round down instead of to 50): half to even, as
    // numpy's rint
    double p = round((double)pitch * 1e6) / 1e6;
    for (int k = 0; k < s->bins; k++)
    {
        s->dest[k] = (int)nearbyint((double)k * p);
    }
}

static void do_frame(studio_spectral_t *s, int mode, float pitch, float formant, float robot_hz,
                     float robot_noise, float *y)
{
    const int n = s->n, b = s->bins, hop = s->hop;
    studio_cpx_t *X = s->spec;
    for (int i = 0; i < n; i++)
    {
        X[i].re = s->frame[i] * s->win[i];
        X[i].im = 0;
    }
    studio_fft(&s->fft, X, false);
    // A real frame's 0 Hz and Nyquist bins are real: rounding leaves a trace of an imaginary part,
    // which would make a negative one's phase -pi or pi by chance (numpy's rfft gives exactly 0)
    X[0].im = 0.0f;
    X[n / 2].im = 0.0f;
    // A bin's phase moves by 2 pi hop k / n each hop: that's hundreds of radians at the top, too big
    // for a float to keep exact, so it's taken whole turns out first (hop k / n = k / 8 turns)
    const int turns = n / hop;
    const float to_bins = (float)n / (TWO_PI_F * (float)hop);
    for (int k = 0; k < b; k++)
    {
        float re = X[k].re, im = X[k].im;
        s->mag[k] = sqrtf(re * re + im * im);
        float phase = atan2f(im, re);
        float expected = TWO_PI_F * (float)(k % turns) / (float)turns;
        float dphi = phase - s->last_phase[k] - expected;
        // The Nyquist bin only ever steps by 0 or a half turn, and either sign of a half turn is as
        // right as the other; the reference keeps the sign it came with there (its expected step is
        // 128 turns less a rounding error), and so does this, so the two agree
        if (k != n / 2)
        {
            dphi = wrap_pi(dphi);
        }
        s->last_phase[k] = phase;
        s->true_bin[k] = (float)k + dphi * to_bins;
    }

    envelope(s);
    formant = fminf(2.0f, fmaxf(0.5f, formant));
    // The envelope stretched: env_w[k] = env at k / formant, as numpy's interp, and past the top
    // bin a thousandth of its last value
    for (int k = 0; k < b; k++)
    {
        float pos = (float)k / formant;
        if (pos >= (float)(b - 1))
        {
            s->env_w[k] = pos > (float)(b - 1) ? s->env[b - 1] * 1e-3f : s->env[b - 1];
        }
        else
        {
            int i = (int)pos;
            float f = pos - (float)i;
            s->env_w[k] = s->env[i] + (s->env[i + 1] - s->env[i]) * f;
        }
        s->syn_mag[k] = 0;
        s->syn_bin[k] = (float)k;   // bin centre by default: keeps the phase advancing sanely
    }

    if (mode == STUDIO_FX_SHIFT)
    {
        pitch = fminf(4.0f, fmaxf(0.25f, pitch));
        make_dest(s, pitch);
        for (int k = 0; k < b; k++)
        {
            s->flat[k] = fminf(s->mag[k] / s->env[k], 20.0f);
        }
        for (int k = 0; k < b; k++)
        {
            int d = s->dest[k];
            if (d > 0 && d < b)
            {
                s->syn_mag[d] += s->flat[k];
                s->syn_bin[d] = s->true_bin[k] * pitch;
            }
        }
        for (int k = 0; k < b; k++)
        {
            s->syn_mag[k] *= s->env_w[k];
        }
    }
    else
    {
        // Robot: harmonics of a fixed pitch, shaped by the voice's (stretched) envelope
        float f0_bins = fminf(1000.0f, fmaxf(40.0f, robot_hz)) * (float)n / (float)s->rate;
        int harmonics = (int)((float)(b - 2) / f0_bins);
        for (int k = 0; k < b; k++)
        {
            s->noisy[k] = true;
        }
        for (int h = 1; h <= harmonics; h++)
        {
            float hb = (float)h * f0_bins;
            int d = (int)rintf(hb);
            s->syn_mag[d] = s->env_w[d];
            s->syn_bin[d] = hb;
            s->noisy[d] = false;
        }
        if (robot_noise > 0)
        {
            for (int k = 0; k < b; k++)
            {
                s->syn_mag[k] += robot_noise * s->env_w[k] * random01(s);
            }
        }
    }

    // Each frame's energy matched to the input's, so the effect isn't louder or quieter
    float e_in = 0, e_out = 0;
    for (int k = 0; k < b; k++)
    {
        e_in += s->mag[k] * s->mag[k];
        e_out += s->syn_mag[k] * s->syn_mag[k];
    }
    float g = e_out > 1e-12f ? sqrtf(e_in / e_out) : 0.0f;
    s->gain += (fminf(g, 8.0f) - s->gain) * 0.3f;

    const bool noise_phase = mode == STUDIO_FX_ROBOT && robot_noise > 0;
    for (int k = 0; k < b; k++)
    {
        float m = s->syn_mag[k] * s->gain;
        // Likewise: syn_bin / 8 turns, whole turns taken out before it's an angle
        float t = s->syn_bin[k] / (float)turns;
        float ph = s->sum_phase[k] + TWO_PI_F * (t - floorf(t));
        ph -= TWO_PI_F * floorf(ph / TWO_PI_F);
        s->sum_phase[k] = ph;
        if (noise_phase && s->noisy[k])
        {
            // Noise bins get a random phase; the harmonics keep theirs
            ph = random01(s) * TWO_PI_F;
        }
        X[k].re = m * cosf(ph);
        X[k].im = m * sinf(ph);
    }
    // As numpy's irfft: the imaginary parts at 0 and Nyquist are dropped
    X[0].im = 0;
    X[b - 1].im = 0;
    for (int k = b; k < n; k++)
    {
        X[k].re = X[n - k].re;
        X[k].im = -X[n - k].im;
    }
    studio_fft(&s->fft, X, true);
    const float scale = 1.0f / ((float)n * s->norm);
    for (int i = 0; i < n; i++)
    {
        s->ola[i] += X[i].re * s->win[i] * scale;
    }
    memcpy(y, s->ola, (size_t)hop * sizeof(float));
    memmove(s->ola, s->ola + hop, (size_t)(n - hop) * sizeof(float));
    memset(s->ola + n - hop, 0, (size_t)hop * sizeof(float));
}

void studio_spectral_process(studio_spectral_t *s, float *x, int n, int mode, float pitch, float formant,
                             float robot_hz, float robot_noise)
{
    const int hop = s->hop;
    // About 300 ms for the slow loudness match (which sees the overlap-add's losses that each
    // frame's own match can't)
    const float a = 1.0f - expf(-(float)hop / (0.3f * (float)s->rate));
    int at = 0;
    while (at < n)
    {
        int take = hop - s->pending_n;
        if (take > n - at)
        {
            take = n - at;
        }
        memcpy(s->pending + s->pending_n, x + at, (size_t)take * sizeof(float));
        s->pending_n += take;
        at += take;
        if (s->pending_n < hop)
        {
            break;
        }
        s->pending_n = 0;
        memmove(s->frame, s->frame + hop, (size_t)(s->n - hop) * sizeof(float));
        memcpy(s->frame + s->n - hop, s->pending, (size_t)hop * sizeof(float));
        if (s->out_n + hop > s->out_cap)
        {
            break;  // can't happen while each call's output is taken
        }
        float *y = s->out + s->out_n;
        do_frame(s, mode, pitch, formant, robot_hz, robot_noise, y);
        float sum_in = 0, sum_out = 0;
        for (int i = 0; i < hop; i++)
        {
            sum_in += s->pending[i] * s->pending[i];
            sum_out += y[i] * y[i];
        }
        s->p_in += (sum_in / (float)hop - s->p_in) * a;
        s->p_out += (sum_out / (float)hop - s->p_out) * a;
        if (s->p_in > 1e-8f && s->p_out > 1e-10f)   // only adapt while there's a voice
        {
            float want = fminf(6.0f, fmaxf(0.5f, sqrtf(s->p_in / s->p_out)));
            s->corr += (want - s->corr) * 0.05f;
        }
        for (int i = 0; i < hop; i++)
        {
            y[i] *= s->corr;
        }
        s->out_n += hop;
    }
    // Hand back as many as came in
    int give = n < s->out_n ? n : s->out_n;
    memcpy(x, s->out, (size_t)give * sizeof(float));
    for (int i = give; i < n; i++)
    {
        x[i] = 0;
    }
    memmove(s->out, s->out + give, (size_t)(s->out_n - give) * sizeof(float));
    s->out_n -= give;
}
