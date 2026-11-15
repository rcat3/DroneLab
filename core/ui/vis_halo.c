/*
 * Halo: the spectrum bent into a ring that slowly turns. The bands go round
 * one half of the circle from the top and mirror round the other, lows at
 * the top and highs meeting at the bottom, each a spoke growing outwards.
 * The spokes run from teal (low) through blue and violet to magenta (high),
 * brighter as they get louder, with gold peak markers that fall back slowly.
 * The middle glows with the level.
 */
#include <math.h>

#include "ui/visualizer.h"

#define SPOKES          (2 * VIS_BANDS)
#define INNER           0.17f       // in screen sizes: where the spokes start
#define LENGTH          0.27f       // the longest spoke
#define TURN_PER_S      0.03f       // turns a second
#define PEAK_FALL_PER_S 0.5f

static uint16_t band_colors[VIS_BANDS];
static float peaks[VIS_BANDS];
static float turn;

static const uint32_t stops[] = { 0x00e0c6, 0x2f7bff, 0x8a4dff, 0xff3dbe };

static void start(vis_canvas_t *c)
{
    vis_gradient(band_colors, VIS_BANDS, stops, 4);
    for (int b = 0; b < VIS_BANDS; b++)
    {
        peaks[b] = 0.0f;
    }
    turn = 0.0f;
}

static bool draw(vis_canvas_t *c, const vis_audio_t *a)
{
    int32_t side = c->size * 96 / 100;
    vis_fade(c, side, 1);

    const float size = (float)c->size;
    turn += TURN_PER_S * a->dt;
    turn -= floorf(turn);

    // The glow in the middle
    float inner = size * INNER;
    vis_add_disc(c, c->cx, c->cy, (int32_t)(inner * (0.35f + 0.5f * a->level)), vis_rgb(0x1c0a36));
    vis_add_disc(c, c->cx, c->cy, (int32_t)(inner * (0.15f + 0.4f * a->level)), vis_rgb(0x2a1050));
    vis_add_ring(c, c->cx, c->cy, (int32_t)(inner - 4), 2, vis_rgb(0x0a3a40));

    for (int b = 0; b < VIS_BANDS; b++)
    {
        peaks[b] = fmaxf(a->bands[b], peaks[b] - PEAK_FALL_PER_S * a->dt);
    }

    int32_t width = c->size / 160 + 1;
    uint16_t peak_color = vis_rgb(0xffc857);
    for (int s = 0; s < SPOKES; s++)
    {
        int b = s < VIS_BANDS ? s : SPOKES - 1 - s;
        float v = a->bands[b];
        float angle = 2.0f * (float)M_PI * (turn + (s + 0.5f) / SPOKES);
        float dx = sinf(angle);
        float dy = -cosf(angle);
        float r1 = inner + size * LENGTH * (0.03f + 0.97f * v);

        uint16_t core = vis_dim(band_colors[b], (uint32_t)(90 + 166 * v));
        vis_glow_line(c, (int32_t)(c->cx + dx * inner), (int32_t)(c->cy + dy * inner),
                      (int32_t)(c->cx + dx * r1), (int32_t)(c->cy + dy * r1), width, core, vis_dim(core, 60));

        if (peaks[b] > 0.04f)
        {
            float rp = inner + size * LENGTH * (0.03f + 0.97f * peaks[b]) + width * 2;
            vis_add_disc(c, (int32_t)(c->cx + dx * rp), (int32_t)(c->cy + dy * rp), width,
                         vis_dim(peak_color, (uint32_t)(120 + 136 * peaks[b])));
        }
    }
    return true;
}

const visualizer_t vis_halo = {
    .name = "Halo",
    .extent = 96,
    .start = start,
    .draw = draw,
};
