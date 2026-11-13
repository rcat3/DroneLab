/*
 * Voice effects (see voice_fx.h).
 *
 * Each 10 ms block from the microphone is halved in sample rate, run through
 * the chain of effects in the chosen preset, and handed on as 16-bit
 * samples. Everything here runs on the microphone's task, except choosing a
 * preset or the speaker (UI loop) and voice_fx_speaker_fill (speaker task).
 *
 * The effects are the same as tools/voice_monitor.py's, so a preset tried
 * there sounds the same here:
 * - gate: silence below a level, so breathing and noise don't come through
 * - gain, highpass, lowpass, ring (ring modulator), crush (fewer bits)
 * - drive: soft clipping above a level, for a harsh, compressed edge
 * - pitch: two delay taps sweeping through a short window, cross faded
 * - shift: PSOLA, your own voice raised or lowered, with the formants moved
 *   separately (see shift_process)
 * - chorus: two delayed copies, their delays swept by slow sine waves
 * - vocoder and tune: the voice rebuilt from its spectral envelope (smoothed
 *   spectrum) on a new buzz, so pitch and formants can be moved separately.
 *   vocoder buzzes at a fixed pitch. tune follows the voice's pitch
 *   (autocorrelation at 8 kHz) and multiplies it, optionally snapped to
 *   musical notes, and uses a hiss for unvoiced sounds.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "audio/fft.h"
#include "audio/mic.h"
#include "audio/voice_fx.h"
#include "audio/voice_lab.h"
#include "hal.h"

#define MAX_IN_BLOCK        (MIC_SAMPLE_RATE / 100)     // up to 10 ms from the microphone
#define FS                  VOICE_FX_SAMPLE_RATE
#define MAX_BLOCK           (FS / 100)
#define DECIMATE_TAPS       31

#define MAX_STEPS           8

// Set to 1 to print how much of the CPU the effect takes, every few seconds.
#define VOICE_FX_DEBUG      0
#define DEBUG_BLOCKS        500

/* ----- Presets ----- */

typedef enum
{
    FX_GAIN,        // dB
    FX_GATE,        // threshold dBFS
    FX_HIGHPASS,    // Hz
    FX_LOWPASS,     // Hz
    FX_DRIVE,       // dB below full scale where it starts to clip
    FX_PITCH,       // ratio
    FX_RING,        // Hz, mix
    FX_TUNE,        // ratio, formant, snap
    FX_SHIFT,       // ratio, formant, snap
    FX_VOCODER,     // Hz, formant
    FX_CHORUS,      // rate Hz, depth ms, mix
    FX_CRUSH,       // bits, factor
} fx_type_t;

typedef struct
{
    fx_type_t type;
    float p[3];
} fx_step_t;

typedef struct
{
    const char *name;
    uint8_t count;
    fx_step_t steps[MAX_STEPS];
} fx_preset_t;

#define GATE { FX_GATE, { -45 } }

static const fx_preset_t presets[] = {
    // Your own voice, like a mask's voice amplifier: only the boom below the
    // voice and the hiss above it taken out
    { "Natural", 3, { GATE, { FX_HIGHPASS, { 200 } }, { FX_LOWPASS, { 5000 } } } },
    // Your own voice raised to around 180 Hz from a typical male voice, and
    // kept to the middle of the voice's range
    { "Female", 5, { GATE, { FX_SHIFT, { 1.9f, 1.2f, 0 } }, { FX_HIGHPASS, { 250 } }, { FX_LOWPASS, { 4500 } }, { FX_GAIN, { 2 } } } },
    // Female snapped to notes, with a faint metallic ring, a little digital
    // grit and a flanger
    { "Fembot", 8, { GATE, { FX_SHIFT, { 1.9f, 1.2f, 1 } }, { FX_RING, { 300, 0.2f } }, { FX_CRUSH, { 10, 1 } },
                     { FX_CHORUS, { 2, 1.5f, 0.5f } }, { FX_HIGHPASS, { 250 } }, { FX_LOWPASS, { 4500 } }, { FX_GAIN, { 8 } } } },
    { "Synthetic", 4, { GATE, { FX_TUNE, { 1.7f, 1.2f, 1 } }, { FX_RING, { 500, 0.15f } }, { FX_CRUSH, { 12, 1 } } } },
    { "Android", 3, { GATE, { FX_VOCODER, { 220, 1.18f } }, { FX_CHORUS, { 0.4f, 4, 0.3f } } } },
    { "AI", 4, { GATE, { FX_HIGHPASS, { 250 } }, { FX_TUNE, { 1.75f, 1.22f, 1 } }, { FX_CHORUS, { 1.5f, 2, 0.4f } } } },
    { "Robot", 2, { GATE, { FX_VOCODER, { 110, 1 } } } },
    { "Deep", 2, { GATE, { FX_PITCH, { 0.75f } } } },
    // A Dalek: a 30 Hz ring modulator, on a voice that's higher, thinner and
    // driven hard
    { "Dalek", 7, { GATE, { FX_HIGHPASS, { 400 } }, { FX_PITCH, { 1.26f } }, { FX_DRIVE, { 24 } }, { FX_RING, { 30, 1 } },
                    { FX_LOWPASS, { 3500 } }, { FX_GAIN, { 8 } } } },
    { "Drone", 4, { GATE, { FX_PITCH, { 0.85f } }, { FX_RING, { 60, 0.6f } }, { FX_CRUSH, { 10, 1 } } } },
};
#define PRESET_COUNT (sizeof(presets) / sizeof(presets[0]))

/* ----- Simple effects ----- */

typedef struct
{
    float threshold_db;
    float gain;
} gate_t;

static void gate_process(gate_t *g, float *x, int n)
{
    float sum = 0;
    for (int i = 0; i < n; i++)
    {
        sum += x[i] * x[i];
    }
    float db = 10.0f * log10f(sum / n + 1e-12f);
    float target = (db > g->threshold_db) ? 1.0f : 0.0f;
    // Open in about 5 ms, close over about 150 ms.
    float rate = (float)n / FS / ((target > g->gain) ? 0.005f : 0.15f);
    float new_gain = g->gain + fmaxf(-rate, fminf(rate, target - g->gain));
    for (int i = 0; i < n; i++)
    {
        x[i] *= g->gain + (new_gain - g->gain) * i / n;
    }
    g->gain = new_gain;
}

typedef struct
{
    float b0, b1, b2, a1, a2;
    float x1, x2, y1, y2;
} biquad_t;

// Second order Butterworth filters (RBJ's cookbook)

static void highpass_init(biquad_t *f, float hz)
{
    float w = 2.0f * (float)M_PI * hz / FS;
    float alpha = sinf(w) / sqrtf(2.0f);
    float a0 = 1 + alpha;
    f->b0 = (1 + cosf(w)) / 2 / a0;
    f->b1 = -(1 + cosf(w)) / a0;
    f->b2 = f->b0;
    f->a1 = -2 * cosf(w) / a0;
    f->a2 = (1 - alpha) / a0;
}

static void lowpass_init(biquad_t *f, float hz)
{
    float w = 2.0f * (float)M_PI * hz / FS;
    float alpha = sinf(w) / sqrtf(2.0f);
    float a0 = 1 + alpha;
    f->b0 = (1 - cosf(w)) / 2 / a0;
    f->b1 = (1 - cosf(w)) / a0;
    f->b2 = f->b0;
    f->a1 = -2 * cosf(w) / a0;
    f->a2 = (1 - alpha) / a0;
}

static void biquad_process(biquad_t *f, float *x, int n)
{
    for (int i = 0; i < n; i++)
    {
        float y = f->b0 * x[i] + f->b1 * f->x1 + f->b2 * f->x2 - f->a1 * f->y1 - f->a2 * f->y2;
        f->x2 = f->x1;
        f->x1 = x[i];
        f->y2 = f->y1;
        f->y1 = y;
        x[i] = y;
    }
}

typedef struct
{
    float step;
    float mix;
    float phase;
} ring_t;

static void ring_process(ring_t *r, float *x, int n)
{
    for (int i = 0; i < n; i++)
    {
        r->phase += r->step;
        if (r->phase > 2.0f * (float)M_PI)
        {
            r->phase -= 2.0f * (float)M_PI;
        }
        x[i] *= 1.0f - r->mix + r->mix * sinf(r->phase);
    }
}

// Soft clipping: quiet sound passes as it is, and anything much above the
// knee is squashed towards it, which adds a harsh edge and evens out the level.
static void drive_process(float knee, float *x, int n)
{
    for (int i = 0; i < n; i++)
    {
        x[i] = knee * tanhf(x[i] / knee);
    }
}

typedef struct
{
    float levels;
    int factor;
    int count;
    float held;
} crush_t;

static void crush_process(crush_t *c, float *x, int n)
{
    for (int i = 0; i < n; i++)
    {
        if (c->count == 0)
        {
            c->held = roundf(x[i] * c->levels) / c->levels;
        }
        x[i] = c->held;
        c->count = (c->count + 1) % c->factor;
    }
}

/* ----- Delay line effects ----- */

#define DELAY_SIZE 1024     // a power of two, longer than any delay used

typedef struct
{
    float buf[DELAY_SIZE];
    unsigned pos;
} delay_t;

static void delay_push(delay_t *d, float v)
{
    d->buf[d->pos++ & (DELAY_SIZE - 1)] = v;
}

/* The sample from `delay` samples ago (fractional), relative to the last
 * push. Positions stay whole numbers, so this works however long it runs. */
static float delay_read(const delay_t *d, float delay)
{
    unsigned whole = (unsigned)delay;
    float frac = delay - whole;
    unsigned newer = d->pos - 1 - whole;
    float a = d->buf[newer & (DELAY_SIZE - 1)];
    float b = d->buf[(newer - 1) & (DELAY_SIZE - 1)];
    return a + (b - a) * frac;
}

typedef struct
{
    delay_t line;
    float ratio;
    float window;
    float phase;
} pitch_t;

static void pitch_process(pitch_t *p, float *x, int n)
{
    float step = (1.0f - p->ratio) / p->window;
    for (int i = 0; i < n; i++)
    {
        delay_push(&p->line, x[i]);
        p->phase += step;
        p->phase -= floorf(p->phase);
        float out = 0;
        for (int tap = 0; tap < 2; tap++)
        {
            float ph = p->phase + 0.5f * tap;
            ph -= floorf(ph);
            out += delay_read(&p->line, ph * p->window + 1.0f) * (1.0f - fabsf(2.0f * ph - 1.0f));
        }
        x[i] = out;
    }
}

typedef struct
{
    delay_t line;
    float rate;
    float depth;
    float base;
    float mix;
    float phase;
} chorus_t;

static void chorus_process(chorus_t *c, float *x, int n)
{
    for (int i = 0; i < n; i++)
    {
        delay_push(&c->line, x[i]);
        c->phase += 2.0f * (float)M_PI * c->rate / FS;
        if (c->phase > 2.0f * (float)M_PI)
        {
            c->phase -= 2.0f * (float)M_PI;
        }
        float wet = 0;
        for (int tap = 0; tap < 2; tap++)
        {
            float delay = c->base + c->depth * 0.5f * (1.0f + sinf(c->phase + (float)M_PI * tap));
            wet += delay_read(&c->line, delay);
        }
        x[i] = (1.0f - c->mix) * x[i] + c->mix * 0.5f * wet;
    }
}

/* ----- Resynthesis (vocoder and tune) ----- */

// The voice is reshaped in 16 ms slices, which keeps the delay down. Its
// pitch is found from the last 32 ms, at 4 kHz (plenty for a voice), to
// catch at least two cycles of a deep voice.
#define RS_SIZE             256                 // 16 ms at 16 kHz
#define RS_HOP              (RS_SIZE / 4)
#define RS_BINS             (RS_SIZE / 2 + 1)
#define RS_SMOOTH           3                   // bins, about 200 Hz
#define PITCH_HISTORY       512                 // 32 ms at 16 kHz
#define PITCH_DECIMATE      4
#define PITCH_FS            (FS / PITCH_DECIMATE)
#define PITCH_SIZE          (PITCH_HISTORY / PITCH_DECIMATE)
#define PITCH_MIN_LAG       (PITCH_FS / 500)
#define PITCH_MAX_LAG       (PITCH_FS / 60)
#define PITCH_VOICED        0.5f

typedef struct
{
    bool track;         // tune (follow the voice's pitch) rather than vocoder
    float pitch;        // vocoder: buzz pitch in Hz; tune: multiplier
    float formant;
    bool snap;

    float window[RS_SIZE];
    float history[PITCH_HISTORY];   // for finding the pitch
    float in[RS_SIZE];
    float carrier[RS_SIZE];
    float out[RS_SIZE];
    fft_complex_t spec[RS_SIZE];
    fft_complex_t carrier_spec[RS_BINS];
    float env[RS_BINS];
    float carrier_mag[RS_BINS];
    float smooth_tmp[RS_BINS];

    float pending[RS_HOP];      // input waiting for a whole hop
    int pending_count;
    float ready[2 * (RS_HOP + MAX_BLOCK)];  // output waiting to be handed back
    int ready_count;
    bool primed;

    float phase;
    float hz;
    uint32_t noise;
} resynth_t;

static void resynth_init(resynth_t *r, bool track, float pitch, float formant, bool snap)
{
    memset(r, 0, sizeof(*r));
    r->track = track;
    r->pitch = pitch;
    r->formant = formant;
    r->snap = snap;
    r->noise = 0x12345678;
    for (int i = 0; i < RS_SIZE; i++)
    {
        r->window[i] = 0.5f - 0.5f * cosf(2.0f * (float)M_PI * i / (RS_SIZE - 1));
    }
}

/* The voice's pitch in Hz, from the newest PITCH_HISTORY samples, or 0 if it
 * isn't voiced. */
static float detect_pitch(const float *in)
{
    float x[PITCH_SIZE];
    float energy[PITCH_SIZE + 1];     // energy[i] is the sum of x squared before i
    energy[0] = 0;
    for (int i = 0; i < PITCH_SIZE; i++)
    {
        const float *src = in + PITCH_DECIMATE * i;
        x[i] = 0.25f * (src[0] + src[1] + src[2] + src[3]);
        energy[i + 1] = energy[i] + x[i] * x[i];
    }
    if (energy[PITCH_SIZE] / PITCH_SIZE < 1e-7f)
    {
        return 0;
    }

    // Normalized autocorrelation: 1 for a perfectly repeating wave.
    float best = 0;
    int best_lag = 0;
    float r[PITCH_MAX_LAG + 2];
    for (int lag = PITCH_MIN_LAG - 1; lag <= PITCH_MAX_LAG + 1; lag++)
    {
        float sum = 0;
        for (int i = 0; i + lag < PITCH_SIZE; i++)
        {
            sum += x[i] * x[i + lag];
        }
        float e1 = energy[PITCH_SIZE - lag];
        float e2 = energy[PITCH_SIZE] - energy[lag];
        r[lag] = sum / sqrtf(e1 * e2 + 1e-12f);
        if (lag >= PITCH_MIN_LAG && lag <= PITCH_MAX_LAG && r[lag] > best)
        {
            best = r[lag];
            best_lag = lag;
        }
    }
    if (best < PITCH_VOICED)
    {
        return 0;
    }
    // Refine the peak between samples.
    float a = r[best_lag - 1], b = r[best_lag], c = r[best_lag + 1];
    float lag = best_lag + 0.5f * (a - c) / (a - 2 * b + c + 1e-12f);
    return PITCH_FS / lag;
}

static float carrier_hz(resynth_t *r)
{
    if (!r->track)
    {
        return r->pitch;
    }
    float f0 = detect_pitch(r->history);
    if (f0 <= 0)
    {
        r->hz = 0;
        return 0;
    }
    float target = f0 * r->pitch;
    if (r->snap)
    {
        float note = roundf(12.0f * log2f(target / 440.0f));
        r->hz = 440.0f * powf(2.0f, note / 12.0f);
    }
    else
    {
        // Glide a little, so the pitch doesn't jitter.
        r->hz = (r->hz <= 0) ? target : r->hz + 0.5f * (target - r->hz);
    }
    return r->hz;
}

/* Correction for a sawtooth's jump, so it doesn't alias (PolyBLEP). */
static float poly_blep(float t, float dt)
{
    if (t < dt)
    {
        t /= dt;
        return t + t - t * t - 1.0f;
    }
    if (t > 1.0f - dt)
    {
        t = (t - 1.0f) / dt;
        return t * t + t + t + 1.0f;
    }
    return 0;
}

static void next_carrier(resynth_t *r, float *dest)
{
    float hz = carrier_hz(r);
    if (hz <= 0)
    {
        for (int i = 0; i < RS_HOP; i++)
        {
            r->noise ^= r->noise << 13;
            r->noise ^= r->noise >> 17;
            r->noise ^= r->noise << 5;
            dest[i] = (float)r->noise / 2147483648.0f - 1.0f;
        }
        return;
    }
    float dt = hz / FS;
    for (int i = 0; i < RS_HOP; i++)
    {
        r->phase += dt;
        r->phase -= floorf(r->phase);
        dest[i] = 2.0f * r->phase - 1.0f - poly_blep(r->phase, dt);
    }
}

/* Smooth a magnitude spectrum over RS_SMOOTH bins, treating the ends as zero
 * like numpy's convolve(mode="same"). */
static void smooth(const float *in, float *out)
{
    const int half = RS_SMOOTH / 2;
    for (int k = 0; k < RS_BINS; k++)
    {
        float sum = 0;
        for (int j = k - half; j <= k + half; j++)
        {
            if (j >= 0 && j < RS_BINS)
            {
                sum += in[j];
            }
        }
        out[k] = sum / RS_SMOOTH;
    }
}

static void resynth_frame(resynth_t *r)
{
    // Both real signals in one complex FFT: the voice in the real part and
    // the carrier in the imaginary part.
    for (int i = 0; i < RS_SIZE; i++)
    {
        r->spec[i].re = r->in[i] * r->window[i];
        r->spec[i].im = r->carrier[i] * r->window[i];
    }
    fft(r->spec, RS_SIZE, false);

    fft_complex_t *carrier = r->carrier_spec;
    for (int k = 0; k < RS_BINS; k++)
    {
        fft_complex_t z = r->spec[k];
        fft_complex_t zc = r->spec[(RS_SIZE - k) & (RS_SIZE - 1)];
        float vre = 0.5f * (z.re + zc.re), vim = 0.5f * (z.im - zc.im);
        carrier[k].re = 0.5f * (z.im + zc.im);
        carrier[k].im = -0.5f * (z.re - zc.re);
        r->smooth_tmp[k] = sqrtf(vre * vre + vim * vim);
    }
    smooth(r->smooth_tmp, r->env);
    for (int k = 0; k < RS_BINS; k++)
    {
        r->smooth_tmp[k] = sqrtf(carrier[k].re * carrier[k].re + carrier[k].im * carrier[k].im);
    }
    smooth(r->smooth_tmp, r->carrier_mag);

    // The voice's envelope, moved up or down by the formant factor, on the
    // carrier's flattened spectrum.
    for (int k = 0; k < RS_BINS; k++)
    {
        float src = k / r->formant;
        int i = (int)src;
        float env = 0;
        if (i + 1 < RS_BINS)
        {
            env = r->env[i] + (r->env[i + 1] - r->env[i]) * (src - i);
        }
        float scale = env / (r->carrier_mag[k] + 1e-6f);
        r->spec[k].re = carrier[k].re * scale;
        r->spec[k].im = carrier[k].im * scale;
    }
    r->spec[0].im = 0;
    r->spec[RS_SIZE / 2].im = 0;
    for (int k = 1; k < RS_SIZE / 2; k++)
    {
        r->spec[RS_SIZE - k].re = r->spec[k].re;
        r->spec[RS_SIZE - k].im = -r->spec[k].im;
    }
    fft(r->spec, RS_SIZE, true);

    for (int i = 0; i < RS_SIZE; i++)
    {
        r->out[i] += r->spec[i].re / RS_SIZE;
    }
    // Hann windows at 75% overlap add up to 2.
    for (int i = 0; i < RS_HOP; i++)
    {
        r->ready[r->ready_count++] = r->out[i] * 0.5f;
    }
    memmove(r->out, r->out + RS_HOP, (RS_SIZE - RS_HOP) * sizeof(float));
    memset(r->out + RS_SIZE - RS_HOP, 0, RS_HOP * sizeof(float));
}

static void resynth_process(resynth_t *r, float *x, int n)
{
    for (int i = 0; i < n; i++)
    {
        r->pending[r->pending_count++] = x[i];
        if (r->pending_count == RS_HOP)
        {
            memmove(r->in, r->in + RS_HOP, (RS_SIZE - RS_HOP) * sizeof(float));
            memcpy(r->in + RS_SIZE - RS_HOP, r->pending, RS_HOP * sizeof(float));
            memmove(r->history, r->history + RS_HOP, (PITCH_HISTORY - RS_HOP) * sizeof(float));
            memcpy(r->history + PITCH_HISTORY - RS_HOP, r->pending, RS_HOP * sizeof(float));
            memmove(r->carrier, r->carrier + RS_HOP, (RS_SIZE - RS_HOP) * sizeof(float));
            next_carrier(r, r->carrier + RS_SIZE - RS_HOP);
            r->pending_count = 0;
            resynth_frame(r);
        }
    }

    // Hand back as much as came in, once there's enough to keep going.
    if (!r->primed && r->ready_count >= n)
    {
        r->primed = true;
    }
    if (!r->primed || r->ready_count < n)
    {
        memset(x, 0, n * sizeof(float));
        return;
    }
    memcpy(x, r->ready, n * sizeof(float));
    r->ready_count -= n;
    memmove(r->ready, r->ready + n, r->ready_count * sizeof(float));
}

/* ----- PSOLA pitch shifting ----- */

// Your own voice, raised or lowered (pitch-synchronous overlap and add). The
// pitch is found as for tune, and the voice is cut into grains two pitch
// periods long, centered one per period at the same point in each cycle
// ("marks"). Laying the grains down closer together raises the pitch, and
// squeezing each one moves the formants up as well. Unvoiced sound passes
// through in short grains. It adds about 20 ms of delay: a grain needs a
// period of the voice after its center, and reaches back about one before.
// tools/voice_monitor.py's shift is the same, for trying it out.
#define SH_IN           2048                // input kept, a power of two (128 ms)
#define SH_OUT          1024                // output being built, a power of two
#define SH_MARKS        64                  // a power of two
#define SH_DETECT_HOP   64                  // how often the pitch is found
#define SH_DELAY        80                  // 5 ms, on top of a grain's reach
#define SH_UNVOICED     80                  // grain spacing for unvoiced sound, 5 ms
#define SH_MAX_PERIOD   (FS / 60)
#define SH_LAG_RELAX    8.0                 // samples per grain
#define SH_MIN_WEIGHT   0.5f                // the windows' sum is divided out, but never more than doubles anything

typedef struct
{
    int64_t pos;        // in input samples since the start
    float period;       // 0 for unvoiced
} shift_mark_t;

typedef struct
{
    float ratio;
    float formant;
    bool snap;

    float in[SH_IN];
    int64_t count;                  // input samples so far
    int since_detect;
    float period;                   // the voice's pitch period now, 0 unvoiced
    float history[PITCH_HISTORY];   // for detect_pitch

    shift_mark_t marks[SH_MARKS];
    unsigned mark_count;            // marks so far; the last SH_MARKS are kept
    int64_t last_mark;

    float out[SH_OUT];
    float weight[SH_OUT];
    double next_synth;              // the next grain's center, in output time
    double lag;                     // how far behind its center a grain is taken from
} shift_t;

static void shift_init(shift_t *s, float ratio, float formant, bool snap)
{
    memset(s, 0, sizeof(*s));
    s->ratio = ratio;
    s->formant = formant;
    s->snap = snap;
}

/* The input at absolute sample position i. */
#define SHIFT_IN(s, i)  ((s)->in[(uint64_t)(i) & (SH_IN - 1)])

/* The input off samples from absolute position base, between samples.  The
 * fraction is kept in a float, because the ESP32-S3 does doubles in software. */
static float shift_at(const shift_t *s, int64_t base, float off)
{
    float whole = floorf(off);
    float frac = off - whole;
    int64_t i = base + (int)whole;
    float a = SHIFT_IN(s, i);
    float b = SHIFT_IN(s, i + 1);
    return a + (b - a) * frac;
}

/* Move a new mark to where the waveform best matches the one at the last
 * mark, so every grain starts at the same point in its cycle. */
static int64_t shift_refine(const shift_t *s, int64_t guess, float period)
{
    int half = (int)(period / 2);
    int reach = (int)(period / 4);
    float best = -1e30f;
    int best_d = 0;
    for (int d = -reach; d <= reach; d++)
    {
        float dot = 0, energy = 0;
        for (int k = -half; k < half; k++)
        {
            float a = SHIFT_IN(s, s->last_mark + k);
            float b = SHIFT_IN(s, guess + d + k);
            dot += a * b;
            energy += b * b;
        }
        float score = dot / sqrtf(energy + 1e-12f);
        if (score > best)
        {
            best = score;
            best_d = d;
        }
    }
    return guess + best_d;
}

/* The strongest point within half a period of guess: where the vocal cords
 * close, which is where a grain is best centered. */
static int64_t shift_peak(const shift_t *s, int64_t guess, float period)
{
    int half = (int)(period / 2);
    float best = -1;
    int best_k = 0;
    for (int k = -half; k <= half; k++)
    {
        float v = fabsf(SHIFT_IN(s, guess + k));
        if (v > best)
        {
            best = v;
            best_k = k;
        }
    }
    return guess + best_k;
}

static void shift_add_marks(shift_t *s)
{
    for (;;)
    {
        float p = s->period;
        int64_t pos;
        if (p > 0)
        {
            if (s->last_mark + p + p * 0.75 + 1 > s->count)
            {
                return;
            }
            bool after_voiced = s->mark_count > 0 && s->marks[(s->mark_count - 1) & (SH_MARKS - 1)].period > 0;
            // The first of a voiced run starts at a peak, and the rest follow it.
            int64_t guess = s->last_mark + (int)(p + 0.5f);
            pos = after_voiced ? shift_refine(s, guess, p) : shift_peak(s, guess, p);
        }
        else
        {
            if (s->last_mark + 2 * SH_UNVOICED + 1 > s->count)
            {
                return;
            }
            pos = s->last_mark + SH_UNVOICED;
        }
        shift_mark_t *m = &s->marks[s->mark_count++ & (SH_MARKS - 1)];
        m->pos = pos;
        m->period = p;
        s->last_mark = pos;
    }
}

/* Overlap-add the grain at a mark, centered at output time at. Returns how
 * far on the next grain goes. */
static double shift_grain(shift_t *s, const shift_mark_t *m, double at)
{
    float p = m->period;
    float half, spacing;
    if (p > 0)
    {
        float target = FS / p * s->ratio;
        if (s->snap)
        {
            target = 440.0f * powf(2.0f, roundf(12.0f * log2f(target / 440.0f)) / 12.0f);
        }
        half = p / s->formant;
        spacing = FS / target;
    }
    else
    {
        p = half = spacing = SH_UNVOICED;
    }
    int reach = (int)half;
    float step = p / half;
    int64_t center = (int64_t)llround(at);
    for (int k = -reach; k <= reach; k++)
    {
        float w = 0.5f + 0.5f * cosf((float)M_PI * k / half);
        unsigned o = (uint64_t)(center + k) & (SH_OUT - 1);
        s->out[o] += shift_at(s, m->pos, k * step) * w;
        s->weight[o] += w;
    }
    return spacing;
}

static void shift_process(shift_t *s, float *x, int n)
{
    for (int i = 0; i < n; i++)
    {
        s->in[(uint64_t)s->count & (SH_IN - 1)] = x[i];
        s->count++;
        if (++s->since_detect == SH_DETECT_HOP)
        {
            s->since_detect = 0;
            for (int k = 0; k < PITCH_HISTORY; k++)
            {
                s->history[k] = s->in[(uint64_t)(s->count - PITCH_HISTORY + k) & (SH_IN - 1)];
            }
            float f0 = s->count >= PITCH_HISTORY ? detect_pitch(s->history) : 0;
            s->period = f0 > 0 ? FS / f0 : 0;
            shift_add_marks(s);
        }
    }
    shift_add_marks(s);

    // Each grain is taken from the mark nearest the same time in the input,
    // lag behind it, so the timing stays as it was. lag grows at once when a
    // grain isn't ready yet, and shrinks back slowly, so the delay stays
    // steady from voiced sounds to unvoiced ones and back.
    int64_t end = s->count - SH_DELAY;
    for (;;)
    {
        float next_half = s->period > 0 ? s->period / s->formant : SH_UNVOICED;
        if (s->next_synth - next_half >= end)
        {
            break;
        }
        unsigned first = s->mark_count > SH_MARKS ? s->mark_count - SH_MARKS : 0;
        int newest = -1;
        for (unsigned j = first; j < s->mark_count; j++)
        {
            const shift_mark_t *m = &s->marks[j & (SH_MARKS - 1)];
            if (m->pos + (m->period > 0 ? m->period : SH_UNVOICED) <= s->count)
            {
                newest = (int)j;
            }
        }
        if (newest < 0)
        {
            break;
        }
        double newest_pos = (double)s->marks[newest & (SH_MARKS - 1)].pos;
        if (newest_pos < s->next_synth - s->lag)
        {
            s->lag = s->next_synth - newest_pos;
        }
        double want = s->next_synth - s->lag;
        const shift_mark_t *best = NULL;
        double best_dist = 0;
        for (unsigned j = first; j <= (unsigned)newest; j++)
        {
            const shift_mark_t *m = &s->marks[j & (SH_MARKS - 1)];
            if (m->pos + (m->period > 0 ? m->period : SH_UNVOICED) > s->count)
            {
                continue;
            }
            double dist = fabs((double)m->pos - want);
            if (best == NULL || dist < best_dist)
            {
                best = m;
                best_dist = dist;
            }
        }
        s->next_synth += shift_grain(s, best, s->next_synth);
        s->lag -= SH_LAG_RELAX;
    }

    // Hand back what's finished: up to end, n samples.
    for (int i = 0; i < n; i++)
    {
        int64_t t = end - n + i;
        unsigned o = (uint64_t)t & (SH_OUT - 1);
        x[i] = t < 0 ? 0 : s->out[o] / fmaxf(s->weight[o], SH_MIN_WEIGHT);
        s->out[o] = 0;
        s->weight[o] = 0;
    }
}

/* ----- The chain ----- */

typedef struct
{
    fx_type_t type;
    union
    {
        float gain;
        float knee;
        gate_t gate;
        biquad_t biquad;
        ring_t ring;
        crush_t crush;
        pitch_t *pitch;
        shift_t *shift;
        chorus_t *chorus;
        resynth_t *resynth;
    } u;
} fx_state_t;

static fx_state_t chain[MAX_STEPS];
static int chain_count;
static int chain_preset = -1;       // the preset the chain was built for, or -1 for none
static volatile int wanted_preset;  // set by the UI loop

static void free_chain(void)
{
    for (int i = 0; i < chain_count; i++)
    {
        switch (chain[i].type)
        {
            case FX_PITCH:
                free(chain[i].u.pitch);
                break;
            case FX_SHIFT:
                free(chain[i].u.shift);
                break;
            case FX_CHORUS:
                free(chain[i].u.chorus);
                break;
            case FX_TUNE:
            case FX_VOCODER:
                free(chain[i].u.resynth);
                break;
            default:
                break;
        }
    }
    chain_count = 0;
}

static void build_chain(int index)
{
    free_chain();
    const fx_preset_t *preset = &presets[index];
    for (int i = 0; i < preset->count; i++)
    {
        const fx_step_t *step = &preset->steps[i];
        fx_state_t *s = &chain[chain_count];
        memset(s, 0, sizeof(*s));
        s->type = step->type;
        switch (step->type)
        {
            case FX_GAIN:
                s->u.gain = powf(10.0f, step->p[0] / 20.0f);
                break;
            case FX_GATE:
                s->u.gate.threshold_db = step->p[0];
                break;
            case FX_HIGHPASS:
                highpass_init(&s->u.biquad, step->p[0]);
                break;
            case FX_LOWPASS:
                lowpass_init(&s->u.biquad, step->p[0]);
                break;
            case FX_DRIVE:
                s->u.knee = powf(10.0f, -step->p[0] / 20.0f);
                break;
            case FX_RING:
                s->u.ring.step = 2.0f * (float)M_PI * step->p[0] / FS;
                s->u.ring.mix = step->p[1];
                break;
            case FX_CRUSH:
                s->u.crush.levels = powf(2.0f, step->p[0] - 1);
                s->u.crush.factor = (step->p[1] >= 1) ? (int)step->p[1] : 1;
                break;
            case FX_PITCH:
                s->u.pitch = calloc(1, sizeof(pitch_t));
                if (s->u.pitch == NULL)
                {
                    continue;
                }
                s->u.pitch->ratio = step->p[0];
                s->u.pitch->window = FS * 0.020f;   // 20 ms: long enough for a deep voice, short enough not to add much delay
                break;
            case FX_SHIFT:
                s->u.shift = malloc(sizeof(shift_t));
                if (s->u.shift == NULL)
                {
                    continue;
                }
                shift_init(s->u.shift, step->p[0], step->p[1], step->p[2] != 0);
                break;
            case FX_CHORUS:
                s->u.chorus = calloc(1, sizeof(chorus_t));
                if (s->u.chorus == NULL)
                {
                    continue;
                }
                s->u.chorus->rate = step->p[0];
                s->u.chorus->depth = FS * step->p[1] / 1000.0f;
                s->u.chorus->base = s->u.chorus->depth + 2;
                s->u.chorus->mix = step->p[2];
                break;
            case FX_TUNE:
            case FX_VOCODER:
                s->u.resynth = malloc(sizeof(resynth_t));
                if (s->u.resynth == NULL)
                {
                    continue;
                }
                resynth_init(s->u.resynth, step->type == FX_TUNE, step->p[0], step->p[1], step->p[2] != 0);
                break;
        }
        chain_count++;
    }
    chain_preset = index;
}

static void run_chain(float *x, int n)
{
    for (int i = 0; i < chain_count; i++)
    {
        fx_state_t *s = &chain[i];
        switch (s->type)
        {
            case FX_GAIN:
                for (int j = 0; j < n; j++)
                {
                    x[j] *= s->u.gain;
                }
                break;
            case FX_GATE:
                gate_process(&s->u.gate, x, n);
                break;
            case FX_HIGHPASS:
            case FX_LOWPASS:
                biquad_process(&s->u.biquad, x, n);
                break;
            case FX_DRIVE:
                drive_process(s->u.knee, x, n);
                break;
            case FX_RING:
                ring_process(&s->u.ring, x, n);
                break;
            case FX_CRUSH:
                crush_process(&s->u.crush, x, n);
                break;
            case FX_PITCH:
                pitch_process(s->u.pitch, x, n);
                break;
            case FX_SHIFT:
                shift_process(s->u.shift, x, n);
                break;
            case FX_CHORUS:
                chorus_process(s->u.chorus, x, n);
                break;
            case FX_TUNE:
            case FX_VOCODER:
                resynth_process(s->u.resynth, x, n);
                break;
        }
    }
}

/* ----- Speaker buffer ----- */

// Written by the microphone's task, read by the speaker's task.
#define SPEAKER_BUF     2048                // a power of two
#define SPEAKER_MAX_LAG (FS * 30 / 1000)    // drop anything older than 30 ms
static int16_t speaker_buf[SPEAKER_BUF];
static uint32_t speaker_write;
static uint32_t speaker_read;
static volatile bool speaker_on;
static volatile float speaker_gain = 3.16f;    // set by voice_fx_set_volume

static void speaker_push(const float *x, int n)
{
    uint32_t w = speaker_write;
    float gain = speaker_gain;
    for (int i = 0; i < n; i++)
    {
        // tanh rounds off peaks instead of clipping them.
        speaker_buf[w++ & (SPEAKER_BUF - 1)] = (int16_t)(tanhf(x[i] * gain) * 32767.0f);
    }
    __atomic_store_n(&speaker_write, w, __ATOMIC_RELEASE);
}

#define SPEAKER_MIN_FRAMES  RS_HOP
#define SPEAKER_WAIT_MS     20

size_t voice_fx_speaker_fill(int16_t *frames, size_t max_frames, uint32_t *sample_rate)
{
    // Wait for the voice rather than padding with silence, which would queue
    // up in the speaker and delay everything after it.
    uint32_t w = __atomic_load_n(&speaker_write, __ATOMIC_ACQUIRE);
    for (int waited = 0; w - speaker_read < SPEAKER_MIN_FRAMES && waited < SPEAKER_WAIT_MS; waited++)
    {
        rcat_hal_delay_ms(1);
        w = __atomic_load_n(&speaker_write, __ATOMIC_ACQUIRE);
    }
    uint32_t r = speaker_read;
    // Keep the delay down: skip ahead if the speaker has fallen behind.
    if (w - r > SPEAKER_MAX_LAG)
    {
        r = w - SPEAKER_MAX_LAG;
    }
    size_t count = w - r;
    if (count > max_frames)
    {
        count = max_frames;
    }
    for (size_t i = 0; i < count; i++)
    {
        frames[2 * i] = frames[2 * i + 1] = speaker_buf[r++ & (SPEAKER_BUF - 1)];
    }
    speaker_read = r;
    *sample_rate = FS;
    return count;
}

/* ----- Microphone ----- */

static float decimate_taps[DECIMATE_TAPS];
static float decimate_history[DECIMATE_TAPS + MAX_IN_BLOCK];

static void make_decimator(void)
{
    // Windowed sinc low pass at 7 kHz, for halving 32 kHz to 16 kHz.
    float sum = 0;
    const int mid = DECIMATE_TAPS / 2;
    for (int i = 0; i < DECIMATE_TAPS; i++)
    {
        float t = i - mid;
        float cutoff = 7000.0f / MIC_SAMPLE_RATE;
        float sinc = (t == 0) ? 2 * cutoff : sinf(2 * (float)M_PI * cutoff * t) / ((float)M_PI * t);
        float window = 0.54f - 0.46f * cosf(2 * (float)M_PI * i / (DECIMATE_TAPS - 1));
        decimate_taps[i] = sinc * window;
        sum += decimate_taps[i];
    }
    for (int i = 0; i < DECIMATE_TAPS; i++)
    {
        decimate_taps[i] /= sum;
    }
}

static void mic_cb(const int16_t *samples, size_t count, void *user_data)
{
    // Only run while something's listening: the speaker or the voice lab.
    // Starting again builds the chain afresh, so nothing stale comes out.
    if (!speaker_on && !voice_lab_running())
    {
        if (chain_preset >= 0)
        {
            free_chain();
            chain_preset = -1;
        }
        return;
    }
    int preset = wanted_preset;
    if (preset != chain_preset)
    {
        build_chain(preset);
    }
    if (count > MAX_IN_BLOCK || count % 2 != 0)
    {
        return;
    }
    int n = (int)count / 2;
#if VOICE_FX_DEBUG
    static clock_t busy;
    static int blocks;
    clock_t start = clock();
#endif

    // Halve the sample rate.
    float *h = decimate_history;
    for (size_t i = 0; i < count; i++)
    {
        h[DECIMATE_TAPS - 1 + i] = samples[i] / 32768.0f;
    }
    float x[MAX_BLOCK];
    for (int i = 0; i < n; i++)
    {
        const float *src = h + 2 * i;
        float sum = 0;
        for (int k = 0; k < DECIMATE_TAPS; k++)
        {
            sum += decimate_taps[k] * src[k];
        }
        x[i] = sum;
    }
    // Keep the last few samples for the next block's filter.
    memmove(h, h + count, (DECIMATE_TAPS - 1) * sizeof(float));

    run_chain(x, n);

    int16_t out[MAX_BLOCK];
    for (int i = 0; i < n; i++)
    {
        float v = fmaxf(-1.0f, fminf(1.0f, x[i]));
        out[i] = (int16_t)(v * 32767.0f);
    }
    voice_lab_send(VOICE_LAB_KIND_EFFECT, FS, out, n);
    if (speaker_on)
    {
        speaker_push(x, n);
    }

#if VOICE_FX_DEBUG
    busy += clock() - start;
    static int processed;
    processed += n;
    if (++blocks == DEBUG_BLOCKS)
    {
        printf("voice fx: %s takes %.1f%% of a core\n", presets[preset].name,
               100.0 * busy / CLOCKS_PER_SEC / ((float)processed / FS));
        processed = 0;
        busy = 0;
        blocks = 0;
    }
#endif
}

/* ----- Public ----- */

bool voice_fx_start(void)
{
    static bool started;
    if (!started && mic_start())
    {
        make_decimator();
        started = mic_add_listener(mic_cb, NULL);
    }
    return started;
}

size_t voice_fx_preset_count(void)
{
    return PRESET_COUNT;
}

const char *voice_fx_preset_name(size_t index)
{
    return (index < PRESET_COUNT) ? presets[index].name : "";
}

void voice_fx_set_preset(size_t index)
{
    wanted_preset = (index < PRESET_COUNT) ? (int)index : 0;
}

void voice_fx_set_speaker(bool on)
{
    if (on)
    {
        // Start from now, not from whatever was left in the buffer.
        speaker_read = __atomic_load_n(&speaker_write, __ATOMIC_ACQUIRE);
    }
    speaker_on = on;
}

void voice_fx_set_volume(uint8_t percent)
{
    speaker_gain = percent == 0 ? 0.0f : powf(10.0f, (10.0f + (percent - 50) * 0.5f) / 20.0f);
}

bool voice_fx_speaker_on(void)
{
    return speaker_on;
}
