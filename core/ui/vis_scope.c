/*
 * Scope: the waveform, like an oscilloscope with a glowing phosphor trace.
 * The voice is aqua and the speaker coral, its complement, and both brighten
 * towards white as they get louder. Each trace starts where the wave
 * crosses zero going up, so a held note stands still, and it tapers off
 * towards the edges of the round screen. Earlier frames fade out behind it.
 */
#include <math.h>

#include "ui/visualizer.h"

#define SHOWN           320         // samples across the screen: 20 ms
#define HALF_WIDTH      0.43f       // in screen sizes
#define AMPLITUDE       0.30f
#define LEVELS          32

static uint16_t colors[VIS_SOURCES][LEVELS];

static const uint32_t mic_stops[] = { 0x0f8f8a, 0x19d3c5, 0xb8fff4 };
static const uint32_t speaker_stops[] = { 0x9c2f3a, 0xff6b5b, 0xffd8b8 };

static void start(vis_canvas_t *c)
{
    vis_gradient(colors[VIS_MIC], LEVELS, mic_stops, 3);
    vis_gradient(colors[VIS_SPEAKER], LEVELS, speaker_stops, 3);
}

/* Where to start showing the wave: the first rising zero crossing, after a
 * dip below the line, that leaves room for the rest of the trace. */
static int trigger(const float *wave)
{
    float low = 0.0f;
    for (int i = 1; i < VIS_WAVE_LEN - SHOWN; i++)
    {
        low = fminf(low * 0.95f, wave[i - 1]);
        if (wave[i - 1] < 0.0f && wave[i] >= 0.0f && low < -0.08f)
        {
            return i;
        }
    }
    return VIS_WAVE_LEN - SHOWN;    // the newest
}

static bool draw(vis_canvas_t *c, const vis_audio_t *a)
{
    int32_t side = c->size * 92 / 100;
    vis_fade(c, side, 1);

    const float size = (float)c->size;
    int32_t width = c->size / 150 + 1;
    float half = size * HALF_WIDTH;

    // A faint center line
    vis_fill(c, (int32_t)(c->cx - half), c->cy, (int32_t)(2 * half), 1, vis_rgb(0x0b2a33));

    for (int s = 0; s < VIS_SOURCES; s++)
    {
        if (!a->wave_on[s])
        {
            continue;
        }
        const float *wave = a->wave[s];
        int start = trigger(wave);
        int level = (int)(a->level * (LEVELS - 1));
        uint16_t core = colors[s][level];
        uint16_t halo = vis_dim(core, 70);

        int32_t px = 0, py = 0;
        for (int i = 0; i < SHOWN; i++)
        {
            float t = (float)i / (SHOWN - 1);
            float taper = fmaxf(sinf((float)M_PI * t), 0.0f);     // sinf(pi) can come out just below 0
            int32_t x = (int32_t)(c->cx - half + 2.0f * half * t);
            int32_t y = (int32_t)(c->cy - wave[start + i] * size * AMPLITUDE * sqrtf(taper));
            if (i > 0)
            {
                vis_glow_line(c, px, py, x, y, width, core, halo);
            }
            px = x;
            py = y;
        }
    }
    return true;
}

const visualizer_t vis_scope = {
    .name = "Scope",
    .extent = 92,
    .start = start,
    .draw = draw,
};
