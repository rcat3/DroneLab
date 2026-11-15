/*
 * Aurora: a spectrogram folded into a mirror image, like an ink blot. Each
 * frame's spectrum is drawn as a line across the middle of the screen, low
 * frequencies in the center and high ones out to both sides, and the
 * history flows away from it, upwards and downwards. Quiet is black, and
 * louder goes through deep purple, magenta and orange to pale yellow (the
 * "magma" color map). Speech leaves symmetric, feathery patterns.
 */
#include <string.h>

#include "ui/visualizer.h"

#define LEVELS          128
#define STEP_DIVISOR    233         // the history moves size / this pixels a frame (2 at 466)
#define EXTENT          92
#define MAX_WIDTH       1024

static uint16_t palette[LEVELS];

static const uint32_t stops[] = {
    0x000004, 0x1c1044, 0x4f127b, 0x812581, 0xb5367a, 0xe55064, 0xfb8761, 0xfec287, 0xfcfdbf,
};

static void start(vis_canvas_t *c)
{
    vis_gradient(palette, LEVELS, stops, sizeof(stops) / sizeof(stops[0]));
}

static bool draw(vis_canvas_t *c, const vis_audio_t *a)
{
    int32_t side = c->size * EXTENT / 100;
    int32_t x0 = c->cx - side / 2 < 0 ? 0 : c->cx - side / 2;
    int32_t x1 = c->cx + side / 2 > c->w ? c->w : c->cx + side / 2;
    int32_t top = c->cy - side / 2 < 0 ? 0 : c->cy - side / 2;
    int32_t bottom = c->cy + side / 2 > c->h ? c->h : c->cy + side / 2;
    int32_t step = c->size / STEP_DIVISOR < 1 ? 1 : c->size / STEP_DIVISOR;
    size_t row_bytes = (size_t)(x1 - x0) * sizeof(uint16_t);

    // Move the top half up and the bottom half down, leaving the middle
    // rows to draw.
    for (int32_t y = top; y < c->cy - step; y++)
    {
        memcpy(&c->px[y * c->stride + x0], &c->px[(y + step) * c->stride + x0], row_bytes);
    }
    for (int32_t y = bottom - 1; y >= c->cy + step; y--)
    {
        memcpy(&c->px[y * c->stride + x0], &c->px[(y - step) * c->stride + x0], row_bytes);
    }

    // The newest line, mirrored about the middle
    static uint16_t *line;
    if (line == NULL && (line = vis_alloc(MAX_WIDTH * sizeof(uint16_t))) == NULL)
    {
        return false;
    }
    float half = (float)(x1 - x0) / 2.0f;
    for (int32_t x = x0; x < x1 && x - x0 < MAX_WIDTH; x++)
    {
        float d = (x - c->cx) / half;
        d = d < 0.0f ? -d : d;
        float t = d * (VIS_BANDS - 1);
        int b = (int)t;
        b = b >= VIS_BANDS - 1 ? VIS_BANDS - 2 : b;
        float f = t - b;
        float v = a->bands[b] + (a->bands[b + 1] - a->bands[b]) * f;
        v = v > 1.0f ? 1.0f : v;
        line[x - x0] = palette[(int)(v * (LEVELS - 1) + 0.5f)];
    }
    for (int32_t y = c->cy - step; y < c->cy + step; y++)
    {
        memcpy(&c->px[y * c->stride + x0], line, row_bytes);
    }
    return true;
}

const visualizer_t vis_aurora = {
    .name = "Aurora",
    .extent = EXTENT,
    .start = start,
    .draw = draw,
};
