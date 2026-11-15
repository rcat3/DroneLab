#ifndef RCAT_AUDIO_TAP_H
#define RCAT_AUDIO_TAP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * The most recent sound from the microphone and from the speaker, kept for
 * the visualizer. The audio tasks only copy their samples in; everything
 * else is done on the UI loop when it reads them.
 */
typedef enum
{
    AUDIO_TAP_MIC,
    AUDIO_TAP_SPEAKER,
    AUDIO_TAP_SOURCES
} audio_tap_source_t;

/* Most samples audio_tap_read() can give at once. */
#define AUDIO_TAP_MAX_READ 2048

/* Start keeping the microphone's samples. The speaker's are kept from the
 * start. Returns false without a microphone. */
bool audio_tap_start(void);

/* From the speaker's task: the frames (stereo) it's about to play. */
void audio_tap_speaker(const int16_t *frames, size_t count, uint32_t sample_rate);

/* Copy the newest count samples of a source (mono) into out, oldest first.
 * Returns false, leaving out alone, when the source has been silent for a
 * moment (the speaker isn't playing). *sample_rate is set to their rate. */
bool audio_tap_read(audio_tap_source_t source, int16_t *out, size_t count, uint32_t *sample_rate);

#endif
