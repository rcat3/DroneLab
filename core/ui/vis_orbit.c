/*
 * Orbit: a phase portrait. Each sample is plotted against the one a moment
 * before it, so a steady tone draws an ellipse, a voice draws looping knots
 * that change with every vowel, and silence shrinks to a point. The figure
 * turns slowly and leaves glowing trails. The voice is violet into ice blue,
 * the speaker amber into gold, brighter as they get louder, and where the
 * lines cross they add up to white.
 */
#include <math.h>

#include "ui/visualizer.h"

#define DELAY           20          // samples: 1.25 ms
#define RADIUS          0.30f       // in screen sizes, for a full scale wave
#define LIMIT           0.46f       // kept inside this, clear of the edge
#define TURN_RAD_PER_S  0.25f
#define LEVELS          32
#define LINE_DIM        220         // each segment's brightness, of 256: overlaps add up

static uint16_t colors[VIS_SOURCES][LEVELS];
static float angle;

static const uint32_t mic_stops[] = { 0x3a1c8c, 0x8f5bff, 0x7fe3ff };
static const uint32_t speaker_stops[] = { 0x7a3410, 0xff8f3c, 0xffe08a };

static void start(vis_canvas_t *c)
{
    vis_gradient(colors[VIS_MIC], LEVELS, mic_stops, 3);
    vis_gradient(colors[VIS_SPEAKER], LEVELS, speaker_stops, 3);
    angle = 0.0f;
}

static bool draw(vis_canvas_t *c, const vis_audio_t *a)
{
    int32_t side = c->size * 94 / 100;
    vis_fade(c, side, 2);

    angle += TURN_RAD_PER_S * a->dt;
    // A quarter turn more, so a sample against itself would be a diagonal
    float ca = cosf(angle + (float)M_PI / 4);
    float sa = sinf(angle + (float)M_PI / 4);
    const float scale = (float)c->size * RADIUS;
    const float limit = (float)c->size * LIMIT;

    for (int s = 0; s < VIS_SOURCES; s++)
    {
        if (!a->wave_on[s])
        {
            continue;
        }
        const float *wave = a->wave[s];
        uint16_t color = vis_dim(colors[s][(int)(a->level * (LEVELS - 1))], LINE_DIM);

        int32_t px = 0, py = 0;
        for (int i = 0; i + DELAY < VIS_WAVE_LEN; i++)
        {
            float u = wave[i + DELAY];
            float v = wave[i];
            float x = (u * ca - v * sa) * scale;
            float y = (u * sa + v * ca) * scale;
            float r = sqrtf(x * x + y * y);
            if (r > limit)
            {
                x *= limit / r;
                y *= limit / r;
            }
            int32_t sx = c->cx + (int32_t)x;
            int32_t sy = c->cy + (int32_t)y;
            if (i > 0)
            {
                vis_add_line(c, px, py, sx, sy, color);
            }
            px = sx;
            py = sy;
        }
    }
    return true;
}

const visualizer_t vis_orbit = {
    .name = "Orbit",
    .extent = 94,
    .start = start,
    .draw = draw,
};
