/*
 * The virtual unit's microphone and speaker: the computer's own, through
 * miniaudio (PulseAudio, PipeWire or ALSA, whichever's there)
 */

#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#include "miniaudio.h"

#include <stdio.h>
#include <string.h>

#include "hal.h"
#include "host.h"

#define MIC_BLOCK_MS        5           // as the board passes them on
#define MIC_MAX_BLOCK       (48000 * MIC_BLOCK_MS / 1000)

#define SPK_RATE            48000
#define SPK_BLOCK_FRAMES    256         // asked for at a time, as on the board
#define SPK_MAX_RATIO       6           // up to this many frames out for each frame in (8 kHz sound)
#define SPK_RING_FRAMES     (SPK_RATE / 4)
#define SPK_AHEAD_FRAMES    (SPK_RATE * 60 / 1000)  // kept ready to play: about what the board buffers
#define SPK_IDLE_POLL_MS    20

/*
 * The microphone
 */

static ma_device mic;
static bool mic_running;
static rcat_hal_audio_block_cb_t mic_cb;
static void *mic_user_data;
static uint32_t mic_rate;
static int16_t mic_block[MIC_MAX_BLOCK];
static size_t mic_have;

static void mic_data(ma_device *d, void *out, const void *in, ma_uint32 frames)
{
    // Passed on in blocks of the board's size, whatever the computer's are
    const int16_t *s = in;
    size_t block = mic_rate * MIC_BLOCK_MS / 1000;
    for (ma_uint32 i = 0; i < frames; i++)
    {
        mic_block[mic_have++] = s[i];
        if (mic_have == block)
        {
            mic_cb(mic_block, block, mic_user_data);
            mic_have = 0;
        }
    }
}

/* Without a microphone, silence, at the same pace, so the comm channel still
 * works for listening: a board always has its microphone. */
static void silence_task(void *arg)
{
    size_t block = mic_rate * MIC_BLOCK_MS / 1000;
    memset(mic_block, 0, sizeof(mic_block));
    uint32_t next = rcat_hal_millis();
    while (1)
    {
        mic_cb(mic_block, block, mic_user_data);
        next += MIC_BLOCK_MS;
        int32_t wait = (int32_t)(next - rcat_hal_millis());
        if (wait > 0)
        {
            rcat_hal_delay_ms((uint32_t)wait);
        }
    }
}

static bool start_silence(const char *why)
{
    printf("%s: the microphone hears silence\n", why);
    mic_running = rcat_hal_task_start("silence", silence_task, NULL, 8192);
    return mic_running;
}

bool rcat_hal_audio_in_start(uint32_t sample_rate, rcat_hal_audio_block_cb_t cb, void *user_data)
{
    if (mic_running || sample_rate > 48000)
    {
        return false;
    }
    mic_cb = cb;
    mic_user_data = user_data;
    mic_rate = sample_rate;
    if (host_options.no_mic)
    {
        return start_silence("--no-mic");
    }
    ma_device_config config = ma_device_config_init(ma_device_type_capture);
    config.capture.format = ma_format_s16;
    config.capture.channels = 1;
    config.sampleRate = sample_rate;
    config.periodSizeInMilliseconds = MIC_BLOCK_MS * 2;
    config.performanceProfile = ma_performance_profile_low_latency;
    config.dataCallback = mic_data;
    config.pulse.pStreamNameCapture = "Virtual unit";
    if (ma_device_init(NULL, &config, &mic) != MA_SUCCESS)
    {
        return start_silence("No microphone");
    }
    if (ma_device_start(&mic) != MA_SUCCESS)
    {
        ma_device_uninit(&mic);
        return start_silence("The microphone didn't start");
    }
    printf("Microphone: %s, at %u Hz\n", mic.capture.name, (unsigned)sample_rate);
    mic_running = true;
    return true;
}

/*
 * The speaker. A task asks for sound, at whatever rate it comes, and puts it
 * in a ring at the computer's rate, for the computer to play from.
 */

static ma_device spk;
static ma_pcm_rb ring;
static bool spk_running;
static rcat_hal_audio_fill_cb_t spk_cb;
static void *spk_user_data;

static void spk_data(ma_device *d, void *out, const void *in, ma_uint32 frames)
{
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
        memcpy(o + done * 2, p, n * 2 * sizeof(int16_t));
        ma_pcm_rb_commit_read(&ring, n);
        done += n;
    }
    memset(o + done * 2, 0, (frames - done) * 2 * sizeof(int16_t));
}

/* Resample stereo sound from in_rate to SPK_RATE, by straight lines between
 * the samples, carrying on smoothly from the last block. Returns how many
 * frames were written to out. */
static size_t resample(const int16_t *in, size_t count, uint32_t in_rate, int16_t *out, size_t max_frames)
{
    static float phase;
    static int16_t last[2];

    float step = (float)in_rate / SPK_RATE;
    size_t n = 0;
    for (size_t i = 0; i < count; i++)
    {
        const int16_t *next = in + 2 * i;
        while (phase < 1.0f && n < max_frames)
        {
            out[2 * n] = (int16_t)(last[0] + (next[0] - last[0]) * phase);
            out[2 * n + 1] = (int16_t)(last[1] + (next[1] - last[1]) * phase);
            n++;
            phase += step;
        }
        phase -= 1.0f;
        last[0] = next[0];
        last[1] = next[1];
    }
    return n;
}

static void ring_write(const int16_t *frames, size_t count)
{
    size_t done = 0;
    while (done < count)
    {
        ma_uint32 n = (ma_uint32)(count - done);
        void *p;
        if (ma_pcm_rb_acquire_write(&ring, &n, &p) != MA_SUCCESS || n == 0)
        {
            rcat_hal_delay_ms(5);       // full: wait for it to play
            continue;
        }
        memcpy(p, frames + done * 2, n * 2 * sizeof(int16_t));
        ma_pcm_rb_commit_write(&ring, n);
        done += n;
    }
}

static void speaker_task(void *arg)
{
    static int16_t frames[SPK_BLOCK_FRAMES * 2];
    static int16_t out[SPK_BLOCK_FRAMES * SPK_MAX_RATIO * 2];
    uint32_t rate = SPK_RATE;

    while (1)
    {
        if (ma_pcm_rb_available_read(&ring) > SPK_AHEAD_FRAMES)
        {
            rcat_hal_delay_ms(5);
            continue;
        }
        uint32_t block_rate = rate;
        size_t count = spk_cb(frames, SPK_BLOCK_FRAMES, &block_rate, spk_user_data);
        if (block_rate > 0)
        {
            rate = block_rate;
        }
        if (count == 0)
        {
            rcat_hal_delay_ms(SPK_IDLE_POLL_MS);
            continue;
        }
        size_t n = resample(frames, count, rate, out, SPK_BLOCK_FRAMES * SPK_MAX_RATIO);
        ring_write(out, n);
    }
}

bool rcat_hal_audio_out_start(rcat_hal_audio_fill_cb_t cb, void *user_data)
{
    if (spk_running || host_options.no_speaker)
    {
        return false;
    }
    if (ma_pcm_rb_init(ma_format_s16, 2, SPK_RING_FRAMES, NULL, NULL, &ring) != MA_SUCCESS)
    {
        return false;
    }
    spk_cb = cb;
    spk_user_data = user_data;
    ma_device_config config = ma_device_config_init(ma_device_type_playback);
    config.playback.format = ma_format_s16;
    config.playback.channels = 2;
    config.sampleRate = SPK_RATE;
    config.periodSizeInMilliseconds = 10;
    config.performanceProfile = ma_performance_profile_low_latency;
    config.dataCallback = spk_data;
    config.pulse.pStreamNamePlayback = "Virtual unit";
    if (ma_device_init(NULL, &config, &spk) != MA_SUCCESS)
    {
        ma_pcm_rb_uninit(&ring);
        fprintf(stderr, "No speaker\n");
        return false;
    }
    if (ma_device_start(&spk) != MA_SUCCESS || !rcat_hal_task_start("speaker", speaker_task, NULL, 24 * 1024))
    {
        ma_device_uninit(&spk);
        ma_pcm_rb_uninit(&ring);
        fprintf(stderr, "The speaker didn't start\n");
        return false;
    }
    printf("Speaker: %s\n", spk.playback.name);
    spk_running = true;
    return true;
}
