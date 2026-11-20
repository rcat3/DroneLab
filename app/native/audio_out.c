/*
 * Sound out on a computer (Linux for now), for lib/comm/audio_out.dart: the
 * app writes 16-bit mono blocks into a ring, and the sound card's own clock
 * plays them out of it, through miniaudio (PulseAudio or PipeWire, else
 * ALSA). The app keeps the ring a little ahead by how much it holds, so
 * nothing drifts between the computer's clock and the card's.
 */
#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#include "miniaudio.h"

#include <stdint.h>
#include <string.h>

#define EXPORT __attribute__((visibility("default")))

static ma_device device;
static ma_pcm_rb ring;
static int running;
static volatile uint32_t underruns;

static void play(ma_device *d, void *out, const void *in, ma_uint32 frames)
{
    (void)d;
    (void)in;
    int16_t *o = out;
    ma_uint32 done = 0;
    while (done < frames)
    {
        ma_uint32 n = frames - done;
        void *p;
        if (ma_pcm_rb_acquire_read(&ring, &n, &p) != MA_SUCCESS || n == 0)
        {
            break;
        }
        memcpy(o + done, p, n * sizeof(int16_t));
        ma_pcm_rb_commit_read(&ring, n);
        done += n;
    }
    if (done < frames)
    {
        memset(o + done, 0, (frames - done) * sizeof(int16_t));
        underruns++;
    }
}

/* Start playing at [rate], with room for [capacity] frames, the card asked
 * for a block every [period_ms]. 0 if it started. */
EXPORT int dl_audio_start(int rate, int capacity, int period_ms)
{
    if (running)
    {
        return 0;
    }
    if (ma_pcm_rb_init(ma_format_s16, 1, (ma_uint32)capacity, NULL, NULL, &ring) != MA_SUCCESS)
    {
        return -1;
    }
    ma_device_config config = ma_device_config_init(ma_device_type_playback);
    config.playback.format = ma_format_s16;
    config.playback.channels = 1;
    config.sampleRate = (ma_uint32)rate;
    config.periodSizeInMilliseconds = (ma_uint32)period_ms;
    config.performanceProfile = ma_performance_profile_low_latency;
    config.dataCallback = play;
    config.pulse.pStreamNamePlayback = "HiveMind";
    if (ma_device_init(NULL, &config, &device) != MA_SUCCESS)
    {
        ma_pcm_rb_uninit(&ring);
        return -2;
    }
    if (ma_device_start(&device) != MA_SUCCESS)
    {
        ma_device_uninit(&device);
        ma_pcm_rb_uninit(&ring);
        return -3;
    }
    underruns = 0;
    running = 1;
    return 0;
}

/* Frames waiting to be played. */
EXPORT int dl_audio_queued(void)
{
    return running ? (int)ma_pcm_rb_available_read(&ring) : 0;
}

/* Times the card found the ring empty, since it started. */
EXPORT int dl_audio_underruns(void)
{
    return (int)underruns;
}

/* Add [frames] to the ring: how many fitted. */
EXPORT int dl_audio_write(const int16_t *pcm, int frames)
{
    if (!running)
    {
        return 0;
    }
    ma_uint32 done = 0;
    while (done < (ma_uint32)frames)
    {
        ma_uint32 n = (ma_uint32)frames - done;
        void *p;
        if (ma_pcm_rb_acquire_write(&ring, &n, &p) != MA_SUCCESS || n == 0)
        {
            break;
        }
        memcpy(p, pcm + done, n * sizeof(int16_t));
        ma_pcm_rb_commit_write(&ring, n);
        done += n;
    }
    return (int)done;
}

EXPORT void dl_audio_stop(void)
{
    if (!running)
    {
        return;
    }
    running = 0;
    ma_device_uninit(&device);
    ma_pcm_rb_uninit(&ring);
}
