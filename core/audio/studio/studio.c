/*
 * The studio chain (see studio.h): the effects in order, their settings, the
 * fades when one is switched on or off, and the meters.
 */
#include <math.h>
#include <string.h>

#include "audio/studio/studio.h"
#include "studio_internal.h"

#define CHUNK       480     // the most run at once
#define FADE        (STUDIO_RATE / 50)  // 20 ms
#define METER       (STUDIO_RATE / 10)  // 100 ms
#define ECHO_MAX_S  2.0f

static const char *const key_names[STUDIO_KEYS] = {
    [STUDIO_MUTE] = "mute",
    [STUDIO_DENOISE] = "denoise",
    [STUDIO_GAIN_DB] = "gain_db",
    [STUDIO_GATE_DB] = "gate_db",
    [STUDIO_COMP_RATIO] = "comp_ratio",
    [STUDIO_HIGHPASS_HZ] = "highpass_hz",
    [STUDIO_LOWPASS_HZ] = "lowpass_hz",
    [STUDIO_PITCH] = "pitch",
    [STUDIO_FX_MODE] = "fx_mode",
    [STUDIO_SHIFT_PITCH] = "shift_pitch",
    [STUDIO_SHIFT_FORMANT] = "shift_formant",
    [STUDIO_ROBOT_HZ] = "robot_hz",
    [STUDIO_ROBOT_NOISE] = "robot_noise",
    [STUDIO_ECHO_MS] = "echo_ms",
    [STUDIO_ECHO_FEEDBACK] = "echo_feedback",
    [STUDIO_ECHO_MIX] = "echo_mix",
    [STUDIO_REVERB_ROOM] = "reverb_room",
    [STUDIO_REVERB_DAMP] = "reverb_damp",
    [STUDIO_REVERB_MIX] = "reverb_mix",
};

// The sender's DEFAULT_STATE
static const float defaults[STUDIO_KEYS] = {
    [STUDIO_MUTE] = 0,
    [STUDIO_DENOISE] = 0,
    [STUDIO_GAIN_DB] = 12,
    [STUDIO_GATE_DB] = -55,
    [STUDIO_COMP_RATIO] = 3,
    [STUDIO_HIGHPASS_HZ] = 90,
    [STUDIO_LOWPASS_HZ] = 16000,
    [STUDIO_PITCH] = 1,
    [STUDIO_FX_MODE] = 0,
    [STUDIO_SHIFT_PITCH] = 1,
    [STUDIO_SHIFT_FORMANT] = 1,
    [STUDIO_ROBOT_HZ] = 200,
    [STUDIO_ROBOT_NOISE] = 0.1f,
    [STUDIO_ECHO_MS] = 1,
    [STUDIO_ECHO_FEEDBACK] = 0,
    [STUDIO_ECHO_MIX] = 0,
    [STUDIO_REVERB_ROOM] = 0.2f,
    [STUDIO_REVERB_DAMP] = 0.5f,
    [STUDIO_REVERB_MIX] = 0,
};

/* A step that can be switched: faded between the dry signal and its own. */
typedef struct
{
    float g;            // 0 dry .. 1 the step's
    bool running;
} fade_t;

struct studio
{
    volatile float param[STUDIO_KEYS];

    studio_denoise_t *denoise;
    studio_cheb_t hp, lp;
    studio_dynamics_t dyn;
    studio_spectral_t *spectral;
    studio_pitch_t *pitch;
    studio_echo_t echo;
    studio_reverb_t *reverb;
    fade_t f_denoise, f_spectral, f_pitch;
    int fx_mode;        // the spectral effect while it fades out
    float pitch_ratio;  // simple pitch's, likewise

    float meter_sq[2];
    int meter_n;
    float out_db;
};

int studio_key(const char *name)
{
    for (int k = 0; k < STUDIO_KEYS; k++)
    {
        if (strcmp(name, key_names[k]) == 0)
        {
            return k;
        }
    }
    return -1;
}

void studio_set(studio_t *s, int key, float value)
{
    if (key >= 0 && key < STUDIO_KEYS && isfinite(value))
    {
        s->param[key] = value;
    }
}

float studio_get(const studio_t *s, int key)
{
    return key >= 0 && key < STUDIO_KEYS ? s->param[key] : 0;
}

void studio_free(studio_t *s)
{
    if (s == NULL)
    {
        return;
    }
    studio_denoise_free(s->denoise);
    studio_spectral_free(s->spectral);
    studio_pitch_free(s->pitch);
    studio_echo_free(&s->echo);
    studio_reverb_free(s->reverb);
    STUDIO_FREE(s);
}

studio_t *studio_new(void)
{
    studio_t *s = STUDIO_CALLOC(1, sizeof(studio_t));
    if (s == NULL)
    {
        return NULL;
    }
    for (int k = 0; k < STUDIO_KEYS; k++)
    {
        s->param[k] = defaults[k];
    }
    s->denoise = studio_denoise_new();
    s->spectral = studio_spectral_new(STUDIO_RATE);
    s->pitch = studio_pitch_new(STUDIO_RATE);
    s->reverb = studio_reverb_new(STUDIO_RATE);
    if (s->denoise == NULL || s->spectral == NULL || s->pitch == NULL || s->reverb == NULL ||
        !studio_echo_init(&s->echo, STUDIO_RATE, ECHO_MAX_S))
    {
        studio_free(s);
        return NULL;
    }
    studio_reset(s);
    return s;
}

void studio_reset(studio_t *s)
{
    studio_denoise_reset(s->denoise);
    studio_cheb_init(&s->hp, STUDIO_RATE, true);
    studio_cheb_init(&s->lp, STUDIO_RATE, false);
    studio_dynamics_init(&s->dyn, STUDIO_RATE);
    studio_spectral_reset(s->spectral);
    studio_pitch_reset(s->pitch);
    memset(s->echo.buf, 0, (size_t)s->echo.size * sizeof(float));
    s->echo.pos = 0;
    studio_reverb_free(s->reverb);
    s->reverb = studio_reverb_new(STUDIO_RATE);
    s->f_denoise = s->f_spectral = s->f_pitch = (fade_t){ 0 };
    s->fx_mode = STUDIO_FX_OFF;
    s->pitch_ratio = 1;
    s->meter_sq[0] = s->meter_sq[1] = 0;
    s->meter_n = 0;
    s->out_db = -100;
}

static bool pitch_on(float ratio)
{
    return fabsf(ratio - 1.0f) > 1e-3f;
}

int studio_latency(const studio_t *s)
{
    int n = 0;
    if (s->f_denoise.running)
    {
        n += studio_denoise_latency();
    }
    if (s->f_spectral.running)
    {
        n += studio_spectral_latency(s->spectral);
    }
    if (s->f_pitch.running)
    {
        n += studio_pitch_latency(s->pitch, s->pitch_ratio);
    }
    return n;
}

/* Whether to run a switchable step on this chunk, starting it afresh if it
 * was off. */
static bool fade_begin(fade_t *f, bool want, bool *fresh)
{
    *fresh = false;
    if (!f->running && want)
    {
        f->running = true;
        f->g = 0;
        *fresh = true;
    }
    return f->running;
}

/* x is the dry signal, wet the step's: x becomes the mix. Returns whether
 * the step has faded right out (and so stops). */
static bool fade_mix(fade_t *f, bool want, float *x, const float *wet, int n)
{
    const float step = 1.0f / FADE;
    if (want && f->g >= 1.0f)
    {
        memcpy(x, wet, (size_t)n * sizeof(float));
        return false;
    }
    for (int i = 0; i < n; i++)
    {
        f->g = want ? fminf(1.0f, f->g + step) : fmaxf(0.0f, f->g - step);
        x[i] = x[i] * (1.0f - f->g) + wet[i] * f->g;
    }
    if (!want && f->g <= 0.0f)
    {
        f->running = false;
        return true;
    }
    return false;
}

static void run_chunk(studio_t *s, float *x, int n, float *lr)
{
    float p[STUDIO_KEYS];
    for (int k = 0; k < STUDIO_KEYS; k++)
    {
        p[k] = s->param[k];
    }
    float wet[CHUNK];
    bool fresh;

    // Denoise
    bool want = p[STUDIO_DENOISE] > 0.5f;
    if (fade_begin(&s->f_denoise, want, &fresh))
    {
        if (fresh)
        {
            studio_denoise_reset(s->denoise);
        }
        memcpy(wet, x, (size_t)n * sizeof(float));
        studio_denoise_process(s->denoise, wet, n);
        fade_mix(&s->f_denoise, want, x, wet, n);
    }

    // High and low pass, as the sender clamped them
    studio_cheb_set(&s->hp, fmaxf(10.0f, p[STUDIO_HIGHPASS_HZ]));
    studio_cheb_set(&s->lp, fminf(23000.0f, fmaxf(200.0f, p[STUDIO_LOWPASS_HZ])));
    studio_cheb_process(&s->hp, x, n);
    studio_cheb_process(&s->lp, x, n);

    studio_dynamics_process(&s->dyn, x, n, p[STUDIO_GAIN_DB], p[STUDIO_GATE_DB], p[STUDIO_COMP_RATIO],
                            p[STUDIO_MUTE] > 0.5f);

    // Shift or robot: switching between the two carries on; to or from off fades
    int mode = (int)lroundf(p[STUDIO_FX_MODE]);
    want = mode == STUDIO_FX_SHIFT || mode == STUDIO_FX_ROBOT;
    if (want)
    {
        s->fx_mode = mode;
    }
    if (fade_begin(&s->f_spectral, want, &fresh))
    {
        if (fresh)
        {
            studio_spectral_reset(s->spectral);
        }
        memcpy(wet, x, (size_t)n * sizeof(float));
        studio_spectral_process(s->spectral, wet, n, s->fx_mode, p[STUDIO_SHIFT_PITCH], p[STUDIO_SHIFT_FORMANT],
                                p[STUDIO_ROBOT_HZ], p[STUDIO_ROBOT_NOISE]);
        fade_mix(&s->f_spectral, want, x, wet, n);
    }

    // Simple pitch; a ratio of 1 switches it off
    want = pitch_on(p[STUDIO_PITCH]);
    if (fade_begin(&s->f_pitch, want, &fresh))
    {
        if (fresh)
        {
            studio_pitch_reset(s->pitch);
        }
        memcpy(wet, x, (size_t)n * sizeof(float));
        // While it fades out, at the last ratio it had
        if (want)
        {
            s->pitch_ratio = p[STUDIO_PITCH];
        }
        studio_pitch_process(s->pitch, wet, n, s->pitch_ratio);
        fade_mix(&s->f_pitch, want, x, wet, n);
    }

    studio_echo_process(&s->echo, x, n, fmaxf(1.0f, p[STUDIO_ECHO_MS]), fminf(0.95f, p[STUDIO_ECHO_FEEDBACK]),
                        p[STUDIO_ECHO_MIX]);
    studio_reverb_process(s->reverb, x, lr, n, fminf(1, fmaxf(0, p[STUDIO_REVERB_ROOM])),
                          fminf(1, fmaxf(0, p[STUDIO_REVERB_DAMP])), fminf(1, fmaxf(0, p[STUDIO_REVERB_MIX])));

    // The output's level, every 100 ms: the louder side, as GStreamer's level element
    for (int i = 0; i < n; i++)
    {
        s->meter_sq[0] += lr[2 * i] * lr[2 * i];
        s->meter_sq[1] += lr[2 * i + 1] * lr[2 * i + 1];
        if (++s->meter_n == METER)
        {
            float sq = fmaxf(s->meter_sq[0], s->meter_sq[1]) / METER;
            s->out_db = 10.0f * log10f(fmaxf(sq, 1e-10f));
            s->meter_sq[0] = s->meter_sq[1] = 0;
            s->meter_n = 0;
        }
    }
}

void studio_process(studio_t *s, const float *in, int n, float *out_lr)
{
    float x[CHUNK];
    for (int at = 0; at < n; at += CHUNK)
    {
        int m = n - at < CHUNK ? n - at : CHUNK;
        memcpy(x, in + at, (size_t)m * sizeof(float));
        run_chunk(s, x, m, out_lr + 2 * at);
    }
}

void studio_meter(const studio_t *s, float *in_db, float *out_db, bool *gate_open)
{
    *in_db = s->dyn.in_db;
    *out_db = s->out_db;
    *gate_open = s->dyn.gate_open;
}
