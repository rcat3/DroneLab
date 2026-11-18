/*
 * Hands the speaker to the voice effect or the sound player, mixes in the
 * sync beep, and lets the visualizer see what it plays.
 */
#include <math.h>
#include <string.h>

#include "app/settings.h"
#include "audio/audio_player.h"
#include "audio/audio_tap.h"
#include "audio/speaker.h"
#include "audio/voice_fx.h"
#include "hal.h"

static volatile bool beep_wanted;      // set by any task
static uint32_t beep_count;             // published atomically by the speaker's task
static bool beeping;                    // the rest only by the speaker's task
static uint32_t beep_pos;               // samples into the beep, lead included
static uint32_t beep_rate;
static volatile bool muted;             // set by any task
static volatile bool test_noise;        // set by any task
static float mute_gain = 1.0f;          // by the speaker's task: 1 playing, 0 silent

#define MUTE_FADE_MS    10

/* Fade the block towards silence, or back, while muted changes. */
static void apply_mute(int16_t *frames, size_t count, uint32_t rate)
{
    float target = muted ? 0.0f : 1.0f;
    if (mute_gain == target)
    {
        if (target == 0.0f)
        {
            memset(frames, 0, count * 2 * sizeof(int16_t));
        }
        return;
    }
    float step = 1000.0f / (MUTE_FADE_MS * (float)(rate > 0 ? rate : 16000));
    for (size_t i = 0; i < count; i++)
    {
        mute_gain = target > mute_gain ? fminf(target, mute_gain + step) : fmaxf(target, mute_gain - step);
        frames[2 * i] = (int16_t)(frames[2 * i] * mute_gain);
        frames[2 * i + 1] = (int16_t)(frames[2 * i + 1] * mute_gain);
    }
}

/* Add the beep to a block, or play it alone if there's nothing else. */
static size_t mix_beep(int16_t *frames, size_t count, size_t max_frames, uint32_t rate)
{
    if (!beeping)
    {
        if (!beep_wanted)
        {
            return count;
        }
        beep_wanted = false;
        beeping = true;
        beep_pos = 0;
        beep_rate = rate > 0 ? rate : 16000;
    }
    // Keep to the rate it started at: the rest of the beep is short, and
    // whatever's playing rarely changes rate in the middle of it.
    uint32_t lead = beep_rate * SPEAKER_BEEP_LEAD_MS / 1000;
    uint32_t total = lead + beep_rate * SPEAKER_BEEP_MS / 1000;
    if (count == 0)
    {
        count = total - beep_pos < max_frames ? total - beep_pos : max_frames;
        memset(frames, 0, count * 2 * sizeof(int16_t));
    }
    const float step = 2.0f * (float)M_PI * SPEAKER_BEEP_HZ / beep_rate;
    for (size_t i = 0; i < count && beep_pos < total; i++, beep_pos++)
    {
        if (beep_pos == lead)
        {
            __atomic_add_fetch(&beep_count, 1, __ATOMIC_RELEASE);
        }
        if (beep_pos >= lead)
        {
            uint32_t pos = beep_pos - lead;
            int32_t s = (int32_t)(sinf(step * pos) * speaker_beep_envelope(pos, beep_rate) * SPEAKER_BEEP_LEVEL *
                                  32767.0f);
            for (int c = 0; c < 2; c++)
            {
                int32_t v = frames[2 * i + c] + s;
                frames[2 * i + c] = (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v);
            }
        }
    }
    if (beep_pos >= total)
    {
        beeping = false;
    }
    return count;
}

/* The seal test's noise: pink, like speech and music have more low than high,
 * with the lows the small speaker can't play taken out, at a steady level.
 * Pink from white by Paul Kellet's filter, white from a xorshift. */
#define TEST_NOISE_RATE     32000
#define TEST_NOISE_LEVEL    0.1f    // RMS, of full scale: -20 dBFS
#define TEST_NOISE_HP_HZ    200.0f

static size_t fill_test_noise(int16_t *frames, size_t max_frames, uint32_t *sample_rate)
{
    static uint32_t seed = 0x2545F491;
    static float b0, b1, b2, hp_in, hp_out;
    const float hp = 1.0f / (1.0f + 2.0f * (float)M_PI * TEST_NOISE_HP_HZ / TEST_NOISE_RATE);
    *sample_rate = TEST_NOISE_RATE;
    for (size_t i = 0; i < max_frames; i++)
    {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        float white = (float)(int32_t)seed / 2147483648.0f;      // -1 to 1, RMS 0.58
        b0 = 0.99765f * b0 + white * 0.0990f;
        b1 = 0.96300f * b1 + white * 0.2965f;
        b2 = 0.57000f * b2 + white * 1.0526f;
        float pink = b0 + b1 + b2 + white * 0.1848f;
        // A one-pole high-pass
        hp_out = hp * (hp_out + pink - hp_in);
        hp_in = pink;
        float v = hp_out * (TEST_NOISE_LEVEL / 1.19f) * 32767.0f;     // the filtered noise has an RMS of 1.19
        int16_t s = (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v);
        frames[2 * i] = s;
        frames[2 * i + 1] = s;
    }
    return max_frames;
}

static size_t fill_cb(int16_t *frames, size_t max_frames, uint32_t *sample_rate, void *user_data)
{
    size_t count;
    if (test_noise)
    {
        count = fill_test_noise(frames, max_frames, sample_rate);
    }
    else if (voice_fx_speaker_on())
    {
        count = voice_fx_speaker_fill(frames, max_frames, sample_rate);
    }
    else
    {
        count = audio_player_fill(frames, max_frames, sample_rate);
    }
    apply_mute(frames, count, *sample_rate);
    count = mix_beep(frames, count, max_frames, *sample_rate);     // the beep's heard anyway
    audio_tap_speaker(frames, count, *sample_rate);     // for the visualizer
    return count;
}

bool speaker_start(void)
{
    static bool started;
    static bool tried;
    if (!tried)
    {
        tried = true;
        // Not in a housing without one (the low-profile model), though the
        // board itself could play to one
        started = settings_speaker_fitted() && rcat_hal_audio_out_start(fill_cb, NULL);
    }
    return started;
}

void speaker_set_muted(bool m)
{
    muted = m;
}

void speaker_set_test_noise(bool on)
{
    if (speaker_start())
    {
        test_noise = on;
    }
}

void speaker_beep(void)
{
    if (speaker_start())
    {
        beep_wanted = true;
    }
}

uint32_t speaker_beep_count(void)
{
    return __atomic_load_n(&beep_count, __ATOMIC_ACQUIRE);
}
