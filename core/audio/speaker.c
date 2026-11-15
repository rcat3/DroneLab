/*
 * Hands the speaker to the voice effect or the sound player, mixes in the
 * sync beep, and lets the visualizer see what it plays.
 */
#include <math.h>
#include <string.h>

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

static size_t fill_cb(int16_t *frames, size_t max_frames, uint32_t *sample_rate, void *user_data)
{
    size_t count;
    if (voice_fx_speaker_on())
    {
        count = voice_fx_speaker_fill(frames, max_frames, sample_rate);
    }
    else
    {
        count = audio_player_fill(frames, max_frames, sample_rate);
    }
    count = mix_beep(frames, count, max_frames, *sample_rate);
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
        started = rcat_hal_audio_out_start(fill_cb, NULL);
    }
    return started;
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
