#ifndef RCAT_STUDIO_INTERNAL_H
#define RCAT_STUDIO_INTERNAL_H

/*
 * What the studio chain's effects share (see studio.h). Each effect is a
 * struct with _init/_free/_reset and a _process that works on any number of
 * samples, in place, keeping its state from one call to the next. The ones
 * that work in frames (denoise, spectral, pitch) hand back the same number
 * of samples they're given, a fixed delay behind (their _latency).
 *
 * Plain C with floats in the per-sample code (no doubles), so the same code
 * could run on a board one day. Memory comes from STUDIO_CALLOC, which a
 * board build can point at PSRAM (lv_malloc).
 */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifndef STUDIO_CALLOC
#include <stdlib.h>
#define STUDIO_CALLOC(n, size) calloc((n), (size))
#define STUDIO_FREE(p) free(p)
#endif

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* ----- FFT of any power of two (sfft.c) ----- */

typedef struct
{
    float re;
    float im;
} studio_cpx_t;

typedef struct
{
    int n;
    int *bitrev;
    studio_cpx_t *twiddle;  // n / 2
} studio_fft_t;

bool studio_fft_init(studio_fft_t *f, int n);
void studio_fft_free(studio_fft_t *f);
/* In place; the inverse isn't scaled (divide by n). */
void studio_fft(const studio_fft_t *f, studio_cpx_t *x, bool inverse);

/* ----- Gain, gate, compressor, limiter (dynamics.c) ----- */

typedef struct
{
    int rate;
    float env_db;
    float gate_db;
    float hold;
    float comp_db;
    float lim;
    float prev_gain;
    float in_db;
    float out_db;
    bool gate_open;
} studio_dynamics_t;

void studio_dynamics_init(studio_dynamics_t *d, int rate);
void studio_dynamics_process(studio_dynamics_t *d, float *x, int n, float gain_db, float gate_db,
                             float ratio, bool mute);

/* ----- High and low pass, GStreamer's audiocheblimit (filters.c) ----- */

#define STUDIO_CHEB_POLES 4

typedef struct
{
    float b0, b1, b2, a1, a2;   // y = b0 x + b1 x1 + b2 x2 + a1 y1 + a2 y2
    float z1, z2;
} studio_biquad_t;

typedef struct
{
    int rate;
    bool highpass;
    float cutoff;
    int mode;           // 0 the filter, 1 passes everything, 2 passes nothing
    studio_biquad_t stage[STUDIO_CHEB_POLES / 2];
} studio_cheb_t;

void studio_cheb_init(studio_cheb_t *c, int rate, bool highpass);
void studio_cheb_set(studio_cheb_t *c, float cutoff_hz);
void studio_cheb_process(studio_cheb_t *c, float *x, int n);

/* ----- Spectral shift and robot (spectral.c) ----- */

enum
{
    STUDIO_FX_OFF = 0,
    STUDIO_FX_SHIFT = 1,
    STUDIO_FX_ROBOT = 2,
};

typedef struct studio_spectral studio_spectral_t;

studio_spectral_t *studio_spectral_new(int rate);
void studio_spectral_free(studio_spectral_t *s);
void studio_spectral_reset(studio_spectral_t *s);
void studio_spectral_process(studio_spectral_t *s, float *x, int n, int mode, float pitch, float formant,
                             float robot_hz, float robot_noise);
int studio_spectral_latency(const studio_spectral_t *s);

/* ----- Simple pitch: time stretch (WSOLA) read back faster or slower (pitch.c) ----- */

typedef struct studio_pitch studio_pitch_t;

studio_pitch_t *studio_pitch_new(int rate);
void studio_pitch_free(studio_pitch_t *p);
void studio_pitch_reset(studio_pitch_t *p);
void studio_pitch_process(studio_pitch_t *p, float *x, int n, float ratio);
int studio_pitch_latency(const studio_pitch_t *p, float ratio);

/* ----- Echo, GStreamer's audioecho (echo.c) ----- */

typedef struct
{
    int rate;
    float *buf;
    int size;
    int pos;
} studio_echo_t;

bool studio_echo_init(studio_echo_t *e, int rate, float max_s);
void studio_echo_free(studio_echo_t *e);
void studio_echo_process(studio_echo_t *e, float *x, int n, float delay_ms, float feedback, float mix);

/* ----- Reverb, GStreamer's freeverb, mono in, stereo out (reverb.c) ----- */

typedef struct studio_reverb studio_reverb_t;

studio_reverb_t *studio_reverb_new(int rate);
void studio_reverb_free(studio_reverb_t *r);
/* x mono in, lr interleaved stereo out (n frames). */
void studio_reverb_process(studio_reverb_t *r, const float *x, float *lr, int n, float room, float damp,
                           float level);

/* ----- Noise removal, RNNoise, 48 kHz only (denoise.c) ----- */

typedef struct studio_denoise studio_denoise_t;

studio_denoise_t *studio_denoise_new(void);
void studio_denoise_free(studio_denoise_t *d);
void studio_denoise_reset(studio_denoise_t *d);
void studio_denoise_process(studio_denoise_t *d, float *x, int n);
int studio_denoise_latency(void);

#endif
