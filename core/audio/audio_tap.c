/*
 * A ring of the newest samples from each source. The audio task writes and
 * then publishes how far it's written; the UI copies out the samples just
 * behind that. The ring is twice as long as the longest read, so the
 * writer doesn't catch up with a read in progress.
 *
 * The rings are allocated when the visualizer starts, with LVGL's allocator,
 * which takes PSRAM first on the ESP32 boards: internal RAM is what WiFi and
 * Bluetooth need to start. Until then the speaker's samples are dropped.
 */
#include <string.h>

#include "audio/audio_tap.h"
#include "audio/mic.h"
#include "lvgl.h"

#define RING_SAMPLES    4096        // a power of two, at least twice AUDIO_TAP_MAX_READ
#define STALE_MS        150         // silent for this long counts as not playing

typedef struct
{
    int16_t samples[RING_SAMPLES];
    volatile uint32_t written;      // total samples written; the ring index is this mod RING_SAMPLES
    volatile uint32_t sample_rate;
    volatile uint32_t last_ms;      // when it was last written to (lv_tick_get())
} ring_t;

static ring_t *rings;          // AUDIO_TAP_SOURCES of them, once started
static bool mic_tapped;

static void ring_write(ring_t *ring, const int16_t *samples, size_t count, size_t step)
{
    uint32_t w = ring->written;
    for (size_t i = 0; i < count; i++)
    {
        ring->samples[(w + i) & (RING_SAMPLES - 1)] = samples[i * step];
    }
    __atomic_store_n(&ring->written, w + (uint32_t)count, __ATOMIC_RELEASE);
    ring->last_ms = lv_tick_get();
}

static ring_t *get_ring(audio_tap_source_t source)
{
    ring_t *all = __atomic_load_n(&rings, __ATOMIC_ACQUIRE);
    return all != NULL ? &all[source] : NULL;
}

static void mic_cb(const int16_t *samples, size_t count, void *user_data)
{
    ring_t *ring = get_ring(AUDIO_TAP_MIC);
    ring->sample_rate = MIC_SAMPLE_RATE;
    ring_write(ring, samples, count, 1);
}

void audio_tap_speaker(const int16_t *frames, size_t count, uint32_t sample_rate)
{
    ring_t *ring = get_ring(AUDIO_TAP_SPEAKER);
    if (ring == NULL || count == 0)
    {
        return;
    }
    ring->sample_rate = sample_rate;

    // Mix the two channels down, in pieces so it needs no buffer.
    int16_t mono[64];
    while (count > 0)
    {
        size_t n = count < 64 ? count : 64;
        for (size_t i = 0; i < n; i++)
        {
            mono[i] = (int16_t)(((int32_t)frames[2 * i] + frames[2 * i + 1]) / 2);
        }
        ring_write(ring, mono, n, 1);
        frames += 2 * n;
        count -= n;
    }
}

bool audio_tap_start(void)
{
    if (rings == NULL)
    {
        ring_t *all = lv_malloc_zeroed(AUDIO_TAP_SOURCES * sizeof(ring_t));
        if (all == NULL)
        {
            return false;
        }
        __atomic_store_n(&rings, all, __ATOMIC_RELEASE);    // filled in before the audio tasks see it
    }
    if (!mic_tapped && mic_start())
    {
        mic_tapped = mic_add_listener(mic_cb, NULL);
    }
    return mic_tapped;
}

bool audio_tap_read(audio_tap_source_t source, int16_t *out, size_t count, uint32_t *sample_rate)
{
    ring_t *ring = get_ring(source);
    if (ring == NULL)
    {
        return false;
    }
    uint32_t written = __atomic_load_n(&ring->written, __ATOMIC_ACQUIRE);
    if (written < count || lv_tick_elaps(ring->last_ms) > STALE_MS || count > AUDIO_TAP_MAX_READ)
    {
        return false;
    }

    uint32_t start = (written - (uint32_t)count) & (RING_SAMPLES - 1);
    size_t first = RING_SAMPLES - start;
    if (first >= count)
    {
        memcpy(out, &ring->samples[start], count * sizeof(int16_t));
    }
    else
    {
        memcpy(out, &ring->samples[start], first * sizeof(int16_t));
        memcpy(out + first, ring->samples, (count - first) * sizeof(int16_t));
    }
    *sample_rate = ring->sample_rate;
    return true;
}
