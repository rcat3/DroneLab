/*
 * Hands the speaker to the voice effect or the sound player, and lets the
 * visualizer see what it plays.
 */
#include "audio/audio_player.h"
#include "audio/audio_tap.h"
#include "audio/speaker.h"
#include "audio/voice_fx.h"
#include "hal.h"

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
