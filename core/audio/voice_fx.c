/*
 * Voice effects (see voice_fx.h).
 *
 * Each 10 ms block from the microphone is halved in sample rate, run through
 * the chain of effects in the chosen preset (voice_fx_chain.c, where the
 * effects are), and handed on as 16-bit samples. Everything here runs on
 * the microphone's task, except choosing a preset or the speaker (UI loop)
 * and voice_fx_speaker_fill (speaker task).
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "audio/mic.h"
#include "audio/speaker.h"
#include "audio/voice_fx.h"
#include "audio/voice_fx_chain.h"
#include "audio/voice_lab.h"
#include "hal.h"

#define MAX_IN_BLOCK        (MIC_SAMPLE_RATE / 100)     // up to 10 ms from the microphone
#define FS                  VOICE_FX_SAMPLE_RATE
#define MAX_BLOCK           (FS / 100)
// 63, as the app's (native/voice_fx_app.c): 31 let the top of the voice,
// above 8 kHz, fold back down into it, and began cutting below 7 kHz.
// About 1% of a core more, and half a millisecond.
#define DECIMATE_TAPS       63

// Set to 1 to print how much of the CPU the effect takes, every few seconds.
#define VOICE_FX_DEBUG      0
#define DEBUG_BLOCKS        500


// Two chains: one for the speaker (and the voice lab), and one for the comm
// channel, which can have an effect of its own. While they're the same, only
// the speaker's runs.
static voice_fx_chain_t *speaker_chain;
static voice_fx_chain_t *comm_chain;
static volatile int wanted_preset;          // set by the UI loop
static volatile int wanted_comm_preset = -1;    // -1 for the speaker's
static volatile bool listen_to_speaker;         // the listener gets the speaker's effect, not the comm one
static volatile bool comm_sending;              // the comm channel's sending (voice_fx_set_comm_sending)
// The seal test's feedback check (voice_fx_feedback_test): Natural, without
// its gate, at test_gain, until it trips
static volatile bool feedback_test;
static volatile float test_gain;
static volatile bool test_tripped;
static uint64_t test_sum_sq;
static uint32_t test_n;


/* ----- Speaker buffer ----- */

// Written by the microphone's task, read by the speaker's task.
#define SPEAKER_BUF     2048                // a power of two
#define SPEAKER_MAX_LAG (FS * 30 / 1000)    // drop anything older than 30 ms
static int16_t speaker_buf[SPEAKER_BUF];
static uint32_t speaker_write;
static uint32_t speaker_read;
static volatile bool speaker_on;
static volatile float speaker_gain = 3.16f;    // set by voice_fx_set_volume

// The feedback check stops by itself once the speaker's this loud for this
// long: a howl, past the tanh. A knock or a voice in the room is shorter.
#define TRIP_LEVEL      0.1f    // mean square: -10 dBFS
#define TRIP_MS         300

static void speaker_push(const float *x, int n, float trim_db)
{
    static int loud_samples;
    uint32_t w = speaker_write;
    bool test = feedback_test;
    float gain = test ? (test_tripped ? 0.0f : test_gain) : speaker_gain * powf(10.0f, trim_db / 20.0f);
    uint64_t sum = 0;
    for (int i = 0; i < n; i++)
    {
        // tanh rounds off peaks instead of clipping them.
        int16_t v = (int16_t)(tanhf(x[i] * gain) * 32767.0f);
        speaker_buf[w++ & (SPEAKER_BUF - 1)] = v;
        sum += (uint32_t)((int32_t)v * v);
    }
    __atomic_store_n(&speaker_write, w, __ATOMIC_RELEASE);
    if (test && n > 0)
    {
        __atomic_add_fetch(&test_sum_sq, sum, __ATOMIC_RELAXED);
        __atomic_add_fetch(&test_n, (uint32_t)n, __ATOMIC_RELAXED);
        loud_samples = (float)sum / (float)n / (32768.0f * 32768.0f) > TRIP_LEVEL ? loud_samples + n : 0;
        if (loud_samples >= FS * TRIP_MS / 1000)
        {
            test_tripped = true;
        }
    }
    else
    {
        loud_samples = 0;
    }
}

#define SPEAKER_MIN_FRAMES  voice_fx_chain_hop()
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

// A listener for the processed voice (the comm channel), set from the UI
// loop. user_data is filled in before cb, so the microphone's task never sees
// a cb without it.
static voice_fx_listener_t listener_cb;
static void *listener_user_data;

static void to_pcm(const float *x, int16_t *out, int n)
{
    for (int i = 0; i < n; i++)
    {
        float v = fmaxf(-1.0f, fminf(1.0f, x[i]));
        out[i] = (int16_t)(v * 32767.0f);
    }
}

static void mic_cb(const int16_t *samples, size_t count, void *user_data)
{
    // Only run while something's listening: the speaker, the voice lab or a
    // listener. Starting again builds the chain afresh, so nothing stale
    // comes out.
    if (!speaker_on && !voice_lab_running() && __atomic_load_n(&listener_cb, __ATOMIC_ACQUIRE) == NULL)
    {
        if (voice_fx_chain_preset(speaker_chain) >= 0)
        {
            voice_fx_chain_clear(speaker_chain);
        }
        if (voice_fx_chain_preset(comm_chain) >= 0)
        {
            voice_fx_chain_clear(comm_chain);
        }
        return;
    }
    int preset = feedback_test ? 0 : wanted_preset;
    if (preset != voice_fx_chain_preset(speaker_chain))
    {
        voice_fx_chain_build(speaker_chain, preset);
    }
    // The comm channel's own effect, if it has one and something's listening.
    // It's kept ready, but runs only while the comm channel sends, and then
    // instead of the speaker's, which goes quiet: the processor hasn't time
    // for two of the heavier effects at once.
    int comm_preset = wanted_comm_preset;
    bool has_comm = comm_preset >= 0 && comm_preset != preset && !listen_to_speaker &&
                    __atomic_load_n(&listener_cb, __ATOMIC_ACQUIRE) != NULL;
    bool own_comm = has_comm && comm_sending;
    if (has_comm && comm_preset != voice_fx_chain_preset(comm_chain))
    {
        voice_fx_chain_build(comm_chain, comm_preset);
    }
    else if (!has_comm && voice_fx_chain_preset(comm_chain) >= 0)
    {
        voice_fx_chain_clear(comm_chain);
    }
    if (count > MAX_IN_BLOCK || count % 2 != 0)
    {
        return;
    }
    int n = (int)count / 2;
#if VOICE_FX_DEBUG
    static clock_t busy;
    static int blocks;
    static uint32_t last_ms, longest_gap_ms;   // between the microphone's blocks, 10 ms each
    clock_t start = clock();
    uint32_t now_ms = rcat_hal_millis();
    if (last_ms != 0 && now_ms - last_ms > longest_gap_ms)
    {
        longest_gap_ms = now_ms - last_ms;
    }
    last_ms = now_ms;
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
    voice_fx_chain_track_noise(x, n);

    // One effect or the other: the comm channel's while it sends its own,
    // with the speaker quiet, or else the speaker's
    int16_t out[MAX_BLOCK];
    if (own_comm)
    {
        voice_fx_chain_run(comm_chain, x, n);
        to_pcm(x, out, n);
        memset(x, 0, (size_t)n * sizeof(float));
    }
    else
    {
        voice_fx_chain_run(speaker_chain, x, n);
        to_pcm(x, out, n);
    }

    voice_lab_send(VOICE_LAB_KIND_EFFECT, FS, out, n);
    voice_fx_listener_t cb = __atomic_load_n(&listener_cb, __ATOMIC_ACQUIRE);
    if (cb != NULL)
    {
        cb(out, n, listener_user_data);
    }
    if (speaker_on)
    {
        int p = voice_fx_chain_preset(speaker_chain);
        speaker_push(x, n, p >= 0 ? voice_fx_preset_speaker_db((size_t)p) : 0);
    }

#if VOICE_FX_DEBUG
    busy += clock() - start;
    static int processed;
    processed += n;
    if (++blocks == DEBUG_BLOCKS)
    {
        printf("voice fx: %s%s takes %.1f%% of a core, blocks up to %lu ms apart\n", own_comm ? "comm " : "",
               voice_fx_preset_name((size_t)(own_comm ? comm_preset : preset)),
               100.0 * busy / CLOCKS_PER_SEC / ((float)processed / FS), (unsigned long)longest_gap_ms);
        longest_gap_ms = 0;
        processed = 0;
        busy = 0;
        blocks = 0;
    }
#endif
}

/* ----- Public ----- */

static bool started;

bool voice_fx_start(void)
{
#if !RCAT_VOICE_FX
    // Not on this board: its speaker can't play them without feeding back
    // (RCAT_VOICE_FX, in the board's .cmake file).
    return false;
#endif
    if (!started && speaker_chain == NULL)
    {
        speaker_chain = voice_fx_chain_new();
        comm_chain = voice_fx_chain_new();
    }
    if (speaker_chain == NULL || comm_chain == NULL)
    {
        return false;
    }
    if (!started && mic_start())
    {
        make_decimator();
        started = mic_add_listener(mic_cb, NULL);
    }
    return started;
}

bool voice_fx_available(void)
{
    return started;
}

void voice_fx_set_preset(size_t index)
{
    wanted_preset = (index < voice_fx_preset_count()) ? (int)index : 0;
}

void voice_fx_listen_to_speaker(bool speaker)
{
    listen_to_speaker = speaker;
}

void voice_fx_set_comm_preset(int index)
{
    wanted_comm_preset = (index >= 0 && (size_t)index < voice_fx_preset_count()) ? index : -1;
}

/* The gate's level in a loud room, for each of its levels: see the loud
 * room's note in voice_fx_chain.c. */
static const float loud_levels_db[VOICE_FX_LOUD_LEVELS] = { -40.0f, -36.0f, -32.0f, -28.0f };

void voice_fx_set_loud_room(int level)
{
    float min_db = level > 0 ? loud_levels_db[(level > VOICE_FX_LOUD_LEVELS ? VOICE_FX_LOUD_LEVELS : level) - 1] : 0;
    voice_fx_chain_set_loud_room(level > 0, min_db);
}

float voice_fx_noise_floor_db(void)
{
    return voice_fx_chain_noise_floor_db();
}

void voice_fx_set_comm_sending(bool on)
{
    comm_sending = on;
}

bool voice_fx_comm_has_own(void)
{
    int comm_preset = wanted_comm_preset;
    return comm_preset >= 0 && comm_preset != wanted_preset && !listen_to_speaker;
}

void voice_fx_set_speaker(bool on)
{
    if (on && !speaker_start())
    {
        return;     // no speaker to play on
    }
    if (on)
    {
        // Start from now, not from whatever was left in the buffer.
        speaker_read = __atomic_load_n(&speaker_write, __ATOMIC_ACQUIRE);
    }
    speaker_on = on;
}

static float volume_db(float percent)
{
    return 10.0f + (percent - 50) * 0.5f;
}

void voice_fx_set_volume(uint8_t percent)
{
    speaker_gain = percent == 0 ? 0.0f : powf(10.0f, volume_db(percent) / 20.0f);
}

void voice_fx_feedback_test(bool on)
{
    if (on)
    {
        test_gain = 0.0f;
        test_tripped = false;
        __atomic_store_n(&test_sum_sq, 0, __ATOMIC_RELAXED);
        __atomic_store_n(&test_n, 0, __ATOMIC_RELAXED);
    }
    feedback_test = on;
    voice_fx_chain_skip_gate(on);
}

void voice_fx_feedback_test_gain(float db_over_full)
{
    test_gain = powf(10.0f, (volume_db(100) + voice_fx_preset_speaker_db(0) + db_over_full) / 20.0f);
}

bool voice_fx_feedback_tripped(void)
{
    return test_tripped;
}

float voice_fx_feedback_take_level(void)
{
    uint64_t sum = __atomic_exchange_n(&test_sum_sq, 0, __ATOMIC_RELAXED);
    uint32_t n = __atomic_exchange_n(&test_n, 0, __ATOMIC_RELAXED);
    return n == 0 ? 0.0f : (float)((double)sum / n / (32768.0 * 32768.0));
}

float voice_fx_natural_full_db(float hz)
{
    // Natural's filters, and its speaker trim, at 100%
    return volume_db(100) + voice_fx_preset_speaker_db(0) + voice_fx_natural_filter_db(hz);
}

bool voice_fx_speaker_on(void)
{
    return speaker_on;
}

void voice_fx_set_listener(voice_fx_listener_t cb, void *user_data)
{
    if (cb != NULL)
    {
        listener_user_data = user_data;
    }
    __atomic_store_n(&listener_cb, cb, __ATOMIC_RELEASE);
}
