/*
 * The sound analysis the visualizers share (see visualizer.h), done once a
 * frame on the UI loop from the newest samples audio_tap.c has kept.
 *
 * Each source is brought down to around VIS_WAVE_RATE (averaging groups of
 * samples), which is the waveform, and goes through a 512 point FFT. The
 * FFT's bins are gathered into VIS_BANDS log spaced bands from BAND_LOW_HZ to
 * BAND_HIGH_HZ, tilted up towards the treble, as voices have much less
 * energy up there and the mask takes more of it away.
 *
 * The bands then get a range like the level meter's (see audio_level.c):
 *
 * - The microphone's background, per band, follows the quiet moments down
 *   quickly and creeps up slowly, so a quiet room or a steady noise sits
 *   below the bottom of the range. The speaker plays clean digital sound,
 *   so its bottom is fixed.
 * - The top follows the loudest recent band, jumping up at once and
 *   relaxing slowly, never closer than a minimum range to the bottom.
 */
#include <math.h>
#include <string.h>

#include "audio/audio_level.h"
#include "audio/audio_tap.h"
#include "audio/fft.h"
#include "ui/visualizer.h"

#define FFT_SIZE                VIS_WAVE_LEN    // the waveform is the FFT's input
#define BAND_LOW_HZ             80.0f
#define BAND_HIGH_HZ            7000.0f
#define TILT_DB_PER_OCTAVE      4.0f            // treble boost, from TILT_FROM_HZ up (and cut below)
#define TILT_FROM_HZ            500.0f
#define MAX_DECIMATE            4

// Microphone background, per band
#define MIC_FLOOR_FALL_TIME_S   0.3f
#define MIC_FLOOR_RISE_DB_PER_S 3.0f
#define MIC_GATE_DB             8.0f            // above the background before a band lights
#define MIC_MIN_RANGE_DB        24.0f

// The speaker's fixed bottom, dB from a full scale sine
#define SPEAKER_FLOOR_DB        -70.0f
#define SPEAKER_MIN_RANGE_DB    30.0f
#define SPEAKER_LEVEL_LOW_DB    -45.0f          // the speaker's level 0 to 1 across this, dBFS RMS
#define SPEAKER_LEVEL_HIGH_DB   -10.0f

#define TOP_RELEASE_DB_PER_S    6.0f
#define BAND_RISE               0.6f            // of the way to a louder value each frame
#define BAND_FALL_PER_S         2.5f            // full scales per second
#define LEVEL_FALL_PER_S        6.0f

// Waveform scaling: the loudest recent peak fills WAVE_FILL of the range.
#define WAVE_FILL               0.9f
#define WAVE_RELEASE_TIME_S     1.5f
#define MIC_WAVE_NOISE_RATIO    20.0f           // never scaled up past this far above the background
#define MIC_NOISE_RISE_PER_S    1.5f            // the background's RMS creeps up by this ratio a second
#define SPEAKER_WAVE_MIN_PEAK   300.0f

typedef struct
{
    bool started;
    float floor_db[VIS_BANDS];
    float top_db;
    float wave_peak;
    float noise_rms;
    float level;
} source_state_t;

// The buffers, allocated on first use to keep them out of internal RAM
typedef struct
{
    source_state_t states[VIS_SOURCES];
    float band_edges_hz[VIS_BANDS + 1];
    float band_tilt_db[VIS_BANDS];
    float window[FFT_SIZE];
    int16_t raw[AUDIO_TAP_MAX_READ];
    fft_complex_t fft[FFT_SIZE];
    float power[FFT_SIZE / 2];
} buffers_t;

static buffers_t *buf;
static float loudest_band;
static bool speaker_only;       // skip the microphone (a sound others sent is showing)

static bool make_tables(void)
{
    buf = vis_alloc(sizeof(buffers_t));
    if (buf == NULL)
    {
        return false;
    }
    float *band_edges_hz = buf->band_edges_hz;
    for (int b = 0; b <= VIS_BANDS; b++)
    {
        band_edges_hz[b] = BAND_LOW_HZ * powf(BAND_HIGH_HZ / BAND_LOW_HZ, (float)b / VIS_BANDS);
    }
    for (int b = 0; b < VIS_BANDS; b++)
    {
        float center = sqrtf(band_edges_hz[b] * band_edges_hz[b + 1]);
        buf->band_tilt_db[b] = TILT_DB_PER_OCTAVE * log2f(center / TILT_FROM_HZ);
    }
    for (int i = 0; i < FFT_SIZE; i++)
    {
        buf->window[i] = 0.5f - 0.5f * cosf(2.0f * (float)M_PI * i / (FFT_SIZE - 1));
    }
    return true;
}

void vis_audio_speaker_only(bool on)
{
    speaker_only = on;
}

void vis_audio_reset(void)
{
    if (buf != NULL)
    {
        memset(buf->states, 0, sizeof(buf->states));
    }
    loudest_band = 0.0f;
}

/* The newest FFT_SIZE samples of a source at around VIS_WAVE_RATE, with the
 * DC taken out. Returns the rate they're at, or 0 if it's silent. */
static uint32_t read_source(vis_source_t source, float *out)
{
    int16_t *raw = buf->raw;
    uint32_t rate;

    // The rate isn't known until it's read, so peek at a little first.
    if (!audio_tap_read((audio_tap_source_t)source, raw, 1, &rate) || rate == 0)
    {
        return 0;
    }
    uint32_t decimate = (rate + VIS_WAVE_RATE / 2) / VIS_WAVE_RATE;
    decimate = decimate < 1 ? 1 : decimate > MAX_DECIMATE ? MAX_DECIMATE : decimate;
    if (!audio_tap_read((audio_tap_source_t)source, raw, FFT_SIZE * decimate, &rate))
    {
        return 0;
    }

    float mean = 0.0f;
    for (int i = 0; i < FFT_SIZE; i++)
    {
        int32_t sum = 0;
        for (uint32_t k = 0; k < decimate; k++)
        {
            sum += raw[i * decimate + k];
        }
        out[i] = (float)sum / decimate;
        mean += out[i];
    }
    mean /= FFT_SIZE;
    for (int i = 0; i < FFT_SIZE; i++)
    {
        out[i] -= mean;
    }
    return rate / decimate;
}

/* Band levels in dB (0 dB is a full scale sine), with the tilt. */
static void band_levels(const float *samples, uint32_t rate, float *db)
{
    fft_complex_t *x = buf->fft;
    float *power = buf->power;
    const float *window = buf->window;
    const float *band_edges_hz = buf->band_edges_hz;

    for (int i = 0; i < FFT_SIZE; i++)
    {
        x[i].re = samples[i] * window[i];
        x[i].im = 0.0f;
    }
    fft(x, FFT_SIZE, false);

    // A full scale sine through the Hann window peaks at 32768 * N / 4.
    const float full_scale = 32768.0f * FFT_SIZE / 4.0f;
    const float norm = 1.0f / (full_scale * full_scale);
    for (int k = 0; k < FFT_SIZE / 2; k++)
    {
        power[k] = (x[k].re * x[k].re + x[k].im * x[k].im) * norm;
    }

    float bin_hz = (float)rate / FFT_SIZE;
    for (int b = 0; b < VIS_BANDS; b++)
    {
        float k0 = band_edges_hz[b] / bin_hz;
        float k1 = band_edges_hz[b + 1] / bin_hz;
        float p;
        if (k1 - k0 < 1.0f)
        {
            // Narrower than a bin (the low bands): between the nearest two.
            float k = (k0 + k1) * 0.5f;
            int i = (int)k;
            float f = k - i;
            i = i < 1 ? 1 : i > FFT_SIZE / 2 - 2 ? FFT_SIZE / 2 - 2 : i;
            p = power[i] * (1.0f - f) + power[i + 1] * f;
        }
        else
        {
            int i0 = (int)(k0 + 0.5f);
            int i1 = (int)(k1 + 0.5f);
            i0 = i0 < 1 ? 1 : i0 > FFT_SIZE / 2 - 1 ? FFT_SIZE / 2 - 1 : i0;
            i1 = i1 <= i0 ? i0 + 1 : i1 > FFT_SIZE / 2 ? FFT_SIZE / 2 : i1;
            p = 0.0f;
            for (int i = i0; i < i1; i++)
            {
                p += power[i];
            }
            p /= (float)(i1 - i0);
        }
        db[b] = 10.0f * log10f(p + 1e-14f) + buf->band_tilt_db[b];
    }
}

/* Bands 0 to 1 for one source, from their levels, moving its range along. */
static void normalize_bands(source_state_t *st, vis_source_t source, const float *db, float dt, float *out)
{
    bool mic = source == VIS_MIC;
    if (!st->started && mic)
    {
        memcpy(st->floor_db, db, sizeof(st->floor_db));
    }

    float loudest = 0.0f;
    for (int b = 0; b < VIS_BANDS; b++)
    {
        float floor_db;
        if (mic)
        {
            float *f = &st->floor_db[b];
            if (db[b] < *f)
            {
                *f += (db[b] - *f) * (1.0f - expf(-dt / MIC_FLOOR_FALL_TIME_S));
            }
            else
            {
                *f += MIC_FLOOR_RISE_DB_PER_S * dt;
            }
            floor_db = *f + MIC_GATE_DB;
        }
        else
        {
            floor_db = SPEAKER_FLOOR_DB;
        }
        out[b] = db[b] - floor_db;          // dB above the bottom, for now
        loudest = fmaxf(loudest, out[b]);
    }

    float min_range = mic ? MIC_MIN_RANGE_DB - MIC_GATE_DB : SPEAKER_MIN_RANGE_DB;
    if (!st->started || loudest > st->top_db)
    {
        st->top_db = loudest;
    }
    else
    {
        st->top_db -= TOP_RELEASE_DB_PER_S * dt;
    }
    st->top_db = fmaxf(st->top_db, min_range);

    for (int b = 0; b < VIS_BANDS; b++)
    {
        float v = out[b] / st->top_db;
        out[b] = v < 0.0f ? 0.0f : v > 1.0f ? 1.0f : v;
    }
}

/* Scale a source's waveform to -1 to 1, and return its RMS (in samples). */
static float scale_wave(source_state_t *st, vis_source_t source, float *wave, float dt)
{
    float peak = 0.0f;
    float sum_squares = 0.0f;
    for (int i = 0; i < VIS_WAVE_LEN; i++)
    {
        peak = fmaxf(peak, fabsf(wave[i]));
        sum_squares += wave[i] * wave[i];
    }
    float rms = sqrtf(sum_squares / VIS_WAVE_LEN);

    if (!st->started || peak > st->wave_peak)
    {
        st->wave_peak = peak;
    }
    else
    {
        st->wave_peak *= expf(-dt / WAVE_RELEASE_TIME_S);
    }

    float min_peak;
    if (source == VIS_MIC)
    {
        if (!st->started || rms < st->noise_rms)
        {
            st->noise_rms = rms;
        }
        else
        {
            st->noise_rms *= powf(MIC_NOISE_RISE_PER_S, dt);
        }
        min_peak = fmaxf(st->noise_rms * MIC_WAVE_NOISE_RATIO, 64.0f);
    }
    else
    {
        min_peak = SPEAKER_WAVE_MIN_PEAK;
    }

    float scale = WAVE_FILL / fmaxf(st->wave_peak, min_peak);
    for (int i = 0; i < VIS_WAVE_LEN; i++)
    {
        float v = wave[i] * scale;
        wave[i] = v < -1.0f ? -1.0f : v > 1.0f ? 1.0f : v;
    }
    return rms;
}

void vis_audio_update(vis_audio_t *a, float dt)
{
    if (buf == NULL && !make_tables())
    {
        return;     // no room: it stays still and dark
    }
    a->dt = dt;
    a->time += dt;

    float targets[VIS_BANDS] = { 0 };
    float levels[VIS_SOURCES] = { 0 };
    for (int s = 0; s < VIS_SOURCES; s++)
    {
        source_state_t *st = &buf->states[s];
        float *wave = a->wave[s];
        uint32_t rate = speaker_only && s == VIS_MIC ? 0 : read_source((vis_source_t)s, wave);
        a->wave_on[s] = rate != 0;
        if (rate == 0)
        {
            memset(wave, 0, sizeof(a->wave[s]));
            st->level = 0.0f;
            continue;
        }

        float db[VIS_BANDS];
        float bands[VIS_BANDS];
        band_levels(wave, rate, db);
        normalize_bands(st, (vis_source_t)s, db, dt, bands);
        for (int b = 0; b < VIS_BANDS; b++)
        {
            targets[b] = fmaxf(targets[b], bands[b]);
        }

        float rms = scale_wave(st, (vis_source_t)s, wave, dt);
        if (s == VIS_MIC)
        {
            st->level = (float)audio_level_get() / AUDIO_LEVEL_MAX;
        }
        else
        {
            float rms_db = 20.0f * log10f(rms / 32768.0f + 1e-9f);
            float target = (rms_db - SPEAKER_LEVEL_LOW_DB) / (SPEAKER_LEVEL_HIGH_DB - SPEAKER_LEVEL_LOW_DB);
            target = target < 0.0f ? 0.0f : target > 1.0f ? 1.0f : target;
            st->level = fmaxf(target, st->level - LEVEL_FALL_PER_S * dt);
        }
        levels[s] = st->level;
        st->started = true;
    }
    a->level = speaker_only ? levels[VIS_SPEAKER] : fmaxf(levels[VIS_MIC], levels[VIS_SPEAKER]);

    int loudest = 0;
    for (int b = 0; b < VIS_BANDS; b++)
    {
        float *v = &a->bands[b];
        if (targets[b] > *v)
        {
            *v += (targets[b] - *v) * BAND_RISE;
        }
        else
        {
            *v = fmaxf(targets[b], *v - BAND_FALL_PER_S * dt);
        }
        if (*v > a->bands[loudest])
        {
            loudest = b;
        }
    }
    if (a->bands[loudest] > 0.1f)
    {
        loudest_band += ((float)loudest / (VIS_BANDS - 1) - loudest_band) * 0.25f;
    }
    a->loudest_band = loudest_band;
}
