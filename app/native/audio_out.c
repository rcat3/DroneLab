/*
 * Sound out on a computer (Linux for now), for lib/comm/audio_out.dart: the
 * app writes 16-bit mono blocks into a ring, and the sound card's own clock
 * plays them out of it, through miniaudio (PulseAudio or PipeWire, else
 * ALSA). The app keeps the ring a little ahead by how much it holds, so
 * nothing drifts between the computer's clock and the card's.
 *
 * Tones (a call's ringback and the like) come whole, and are mixed in here,
 * on the card's own thread: fed through the ring, a moment's hold-up on the
 * app's side, which the ring's few tens of ms don't cover, made them choppy.
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
#include <time.h>

#define EXPORT __attribute__((visibility("default")))

#define TONE_MAX        (48000 * 8)     // samples of tones waiting: 8 s at 48 kHz

static ma_device device;
static ma_spinlock tone_lock;
static int16_t tone_buf[TONE_MAX];
static ma_uint32 tone_len, tone_pos;
static ma_pcm_rb ring;
static int running;
static volatile uint32_t underruns;
static volatile int playing;            // the last block had sound in it
static volatile uint32_t burst_max;     // the most asked for in one burst, in frames
static uint64_t burst_frames;           // asked for in this burst
static uint64_t last_ask_us;

static uint64_t now_us(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000u + (uint64_t)t.tv_nsec / 1000u;
}

static void play(ma_device *d, void *out, const void *in, ma_uint32 frames)
{
    (void)d;
    (void)in;
    int16_t *o = out;
    ma_uint32 done = 0;
    // How much the card takes at a time: calls close together are one burst
    uint64_t now = now_us();
    burst_frames = now - last_ask_us < 2000 ? burst_frames + frames : frames;
    last_ask_us = now;
    if (burst_frames > burst_max)
    {
        burst_max = (uint32_t)burst_frames;
    }
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
        // Counted while it's playing: the app keeps it fed with silence
        // between sounds, so running dry means the app fell behind
        if (playing)
        {
            underruns++;
        }
    }
    playing = done > 0;

    // The tones over it
    ma_spinlock_lock(&tone_lock);
    ma_uint32 n = tone_len - tone_pos;
    if (n > frames)
    {
        n = frames;
    }
    for (ma_uint32 i = 0; i < n; i++)
    {
        int32_t v = (int32_t)o[i] + tone_buf[tone_pos + i];
        o[i] = (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v);
    }
    tone_pos += n;
    if (tone_pos == tone_len)
    {
        tone_pos = tone_len = 0;
    }
    ma_spinlock_unlock(&tone_lock);
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

/* Play [frames] of a tone after those already waiting, over what's playing:
 * 0 if it doesn't fit, or it isn't playing. */
EXPORT int dl_audio_tone(const int16_t *pcm, int frames)
{
    if (!running || frames <= 0)
    {
        return 0;
    }
    int ok = 0;
    ma_spinlock_lock(&tone_lock);
    if (tone_pos > 0)
    {
        memmove(tone_buf, tone_buf + tone_pos, (tone_len - tone_pos) * sizeof(int16_t));
        tone_len -= tone_pos;
        tone_pos = 0;
    }
    if (tone_len + (ma_uint32)frames <= TONE_MAX)
    {
        memcpy(tone_buf + tone_len, pcm, (size_t)frames * sizeof(int16_t));
        tone_len += (ma_uint32)frames;
        ok = 1;
    }
    ma_spinlock_unlock(&tone_lock);
    return ok;
}

/* Stop the tones, and drop those waiting. */
EXPORT void dl_audio_tones_stop(void)
{
    ma_spinlock_lock(&tone_lock);
    tone_pos = tone_len = 0;
    ma_spinlock_unlock(&tone_lock);
}

/* The most the card's taken in one burst, in frames. */
EXPORT int dl_audio_burst(void)
{
    return (int)burst_max;
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
    tone_pos = tone_len = 0;
    ma_pcm_rb_uninit(&ring);
}
