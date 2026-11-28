#ifndef RCAT_STUDIO_H
#define RCAT_STUDIO_H

/*
 * The studio chain: the Guide's voice effects for HiveSight, at 48 kHz, from
 * EyeStream's sender (its presets are tools/hivesight-sender/presets.json).
 * Separate from the board's presets (core/audio/voice_fx_chain.c), which are
 * built for 16 kHz and the board's processor.
 *
 * In this order: denoise (RNNoise), high pass, low pass, gain / gate /
 * compressor / limiter, spectral shift or robot, simple pitch, echo, reverb.
 * Mono in, stereo out (the reverb is stereo). Denoise, the spectral effects
 * and simple pitch each add their delay only while they're on, and fade in
 * and out over 20 ms when they're switched.
 *
 * Settings can be changed from any thread; a change takes effect at the next
 * block. studio_process takes any number of samples and gives back as many.
 * Everything else is called from one thread.
 */
#include <stdbool.h>

#define STUDIO_RATE 48000

enum
{
    STUDIO_MUTE,
    STUDIO_DENOISE,
    STUDIO_GAIN_DB,
    STUDIO_GATE_DB,
    STUDIO_COMP_RATIO,
    STUDIO_HIGHPASS_HZ,
    STUDIO_LOWPASS_HZ,
    STUDIO_PITCH,
    STUDIO_FX_MODE,         // 0 off, 1 shift, 2 robot
    STUDIO_SHIFT_PITCH,
    STUDIO_SHIFT_FORMANT,
    STUDIO_ROBOT_HZ,
    STUDIO_ROBOT_NOISE,
    STUDIO_ECHO_MS,
    STUDIO_ECHO_FEEDBACK,
    STUDIO_ECHO_MIX,
    STUDIO_REVERB_ROOM,
    STUDIO_REVERB_DAMP,
    STUDIO_REVERB_MIX,
    STUDIO_KEYS
};

typedef struct studio studio_t;

/* NULL if there's no memory. Starts with the sender's defaults. */
studio_t *studio_new(void);
void studio_free(studio_t *s);

/* The key for a setting's name, as the sender's voice.* keys ("gain_db",
 * "fx_mode"...), or -1. */
int studio_key(const char *name);
void studio_set(studio_t *s, int key, float value);
float studio_get(const studio_t *s, int key);

/* n mono samples in, n stereo frames out (interleaved). */
void studio_process(studio_t *s, const float *in, int n, float *out_lr);

/* The microphone's level before the gain (the last block), the output's over
 * the last 100 ms, both RMS in dBFS, and whether the gate is open. */
void studio_meter(const studio_t *s, float *in_db, float *out_db, bool *gate_open);

/* The delay, in samples, for what's switched on now. */
int studio_latency(const studio_t *s);

/* Everything's state cleared, the settings kept. */
void studio_reset(studio_t *s);

#endif
