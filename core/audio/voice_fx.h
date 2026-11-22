#ifndef RCAT_VOICE_FX_H
#define RCAT_VOICE_FX_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * Voice effects, run on the microphone as it comes in. They're ports of the
 * effects in tools/voice_monitor.py, with the same presets, and run at
 * VOICE_FX_SAMPLE_RATE, which is plenty for speech.
 *
 * The result goes to the voice lab stream (so voice_monitor.py --listen
 * effect can play it), to a listener such as the comm channel, and, if
 * switched on, to the speaker.
 */
#define VOICE_FX_SAMPLE_RATE 16000

/* Start listening to the microphone. Returns false without one, or on a
 * board built without voice effects (RCAT_VOICE_FX). */
bool voice_fx_start(void);

/* True once voice_fx_start() has succeeded. */
bool voice_fx_available(void);

/* The presets. 0 is "Natural", your own voice. */
size_t voice_fx_preset_count(void);
const char *voice_fx_preset_name(size_t index);

/* Choose a preset. Safe to call from the UI loop. */
void voice_fx_set_preset(size_t index);

/* The comm channel's own preset, for what it sends (the listener), or -1 for
 * the same as the speaker's. The voice goes through one effect at a time, as
 * the processor hasn't time for two of the heavier ones: while it's
 * different, and the comm channel sends (voice_fx_set_comm_sending), the
 * listener gets the comm channel's and the speaker goes quiet; the rest of
 * the time both get the speaker's. */
void voice_fx_set_comm_preset(int index);

/* Whether the comm channel's sending, for voice_fx_set_comm_preset */
void voice_fx_set_comm_sending(bool on);

/* Whether the comm channel has an effect of its own, different from the
 * speaker's, so the speaker goes quiet while it sends */
bool voice_fx_comm_has_own(void);

/* Hand the listener the speaker's effect instead of the comm channel's own,
 * as for recording what the speaker plays. */
void voice_fx_listen_to_speaker(bool speaker);

/* How loud it is on the speaker, in percent: 50 is 10 dB up from the
 * microphone, and each step 0.5 dB more or less, with a limiter. 0 is silent. */
void voice_fx_set_volume(uint8_t percent);

/* The seal test's feedback check: while on, the speaker plays Natural without
 * its gate, so the microphones' own hiss goes round the loop, at
 * voice_fx_feedback_test_gain (silent until it's set), whatever the preset
 * and Effect Volume. Once the speaker stays loud (a howl) it goes silent by
 * itself, and voice_fx_feedback_tripped says so, until it's switched on
 * again. The speaker still has to be switched on (voice_fx_set_speaker). */
void voice_fx_feedback_test(bool on);
void voice_fx_feedback_test_gain(float db_over_full);  // dB over Natural at 100%
bool voice_fx_feedback_tripped(void);

/* The mean square of what the feedback check played since the last call, as
 * a fraction of full scale squared. */
float voice_fx_feedback_take_level(void);

/* Natural's gain from the microphones to the speaker at 100%, at hz, in dB */
float voice_fx_natural_full_db(float hz);

/* Play the processed voice on the speaker instead of the sound player. */
void voice_fx_set_speaker(bool on);
bool voice_fx_speaker_on(void);

/* Also hand the processed voice to cb, in blocks of mono samples at
 * VOICE_FX_SAMPLE_RATE, on the microphone's task (so cb has to be quick and
 * must not call LVGL). While there's a listener, the effect runs even with
 * the speaker off. NULL takes it away. There's room for one. */
typedef void (*voice_fx_listener_t)(const int16_t *samples, size_t count, void *user_data);
void voice_fx_set_listener(voice_fx_listener_t cb, void *user_data);

/* For the speaker: up to max_frames frames of the processed voice as
 * stereo, at VOICE_FX_SAMPLE_RATE. Called on the speaker's task. */
size_t voice_fx_speaker_fill(int16_t *frames, size_t max_frames, uint32_t *sample_rate);

#endif
