#ifndef RCAT_VOICE_FX_CHAIN_H
#define RCAT_VOICE_FX_CHAIN_H

#include <stdbool.h>
#include <stddef.h>

/*
 * The voice effects themselves, with no hardware: the presets, and a chain
 * of one preset's effects, built from it and run on blocks of the voice at
 * VOICE_FX_SAMPLE_RATE, as floats from -1 to 1, in place. The board runs
 * them on its microphone (voice_fx.c); the app runs the same ones on the
 * phone's microphone (app/native/voice_fx_app.c).
 *
 * A chain keeps its effects' state from one block to the next, so it's run
 * on one voice, in order. Blocks of up to 10 ms each.
 */
#define VOICE_FX_SAMPLE_RATE 16000

size_t voice_fx_preset_count(void);
const char *voice_fx_preset_name(size_t index);

/* The preset's trim on the board's speaker, in dB, so each feeds back at
 * about the same volume. */
float voice_fx_preset_speaker_db(size_t index);

typedef struct voice_fx_chain voice_fx_chain_t;

/* A chain with no effects (preset -1): NULL if there's no memory. */
voice_fx_chain_t *voice_fx_chain_new(void);

/* Build it afresh for a preset, from 0; -1 or out of range for none. */
void voice_fx_chain_build(voice_fx_chain_t *c, int preset);

/* No effects again, the memory they took freed. */
void voice_fx_chain_clear(voice_fx_chain_t *c);

/* The preset it's built for, or -1. */
int voice_fx_chain_preset(const voice_fx_chain_t *c);

void voice_fx_chain_run(voice_fx_chain_t *c, float *x, int n);
void voice_fx_chain_free(voice_fx_chain_t *c);

/* The gates in every chain: for a loud room, opening only well above the
 * room's noise (min_db, or over the noise floor, kept by track_noise from
 * the voice before any effect); or left out, for the seal test's feedback
 * check. Shared by all chains: the board's microphone's. */
void voice_fx_chain_set_loud_room(bool on, float min_db);
void voice_fx_chain_track_noise(const float *x, int n);
float voice_fx_chain_noise_floor_db(void);
void voice_fx_chain_skip_gate(bool skip);

/* The smallest piece the slowest effect (the resynthesis) hands on at once,
 * in samples. */
int voice_fx_chain_hop(void);

/* How Natural's filters take a frequency down, in dB. */
float voice_fx_natural_filter_db(float hz);

#endif
