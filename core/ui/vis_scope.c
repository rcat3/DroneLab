/*
 * Scope: the waveform, like an old CRT oscilloscope. A green phosphor trace
 * glows over a faintly lit screen with a graticule: a grid of divisions,
 * and center lines with tick marks. The voice is the classic P1 green and
 * the speaker a yellower green, and both brighten towards white as they get
 * louder. Each trace starts where the wave crosses zero going up, so a held
 * note stands still, and it tapers off towards the edges of the round
 * screen. Earlier frames fade back into the screen behind it, like the
 * phosphor's afterglow.
 */
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "ui/visualizer.h"

#define SHOWN           320         // samples across the screen: 20 ms
#define HALF_WIDTH      0.43f       // in screen sizes
#define AMPLITUDE       0.30f
#define LEVELS          32
#define EXTENT          92          // percent of the screen
#define DIVISIONS       10          // across the screen
#define TICKS           5           // per division, on the center lines

static uint16_t colors[VIS_SOURCES][LEVELS];
static uint16_t *screen;            // the lit screen and graticule, as big as the canvas

static const uint32_t mic_stops[] = { 0x158a22, 0x40ff50, 0xdcffd8 };
static const uint32_t speaker_stops[] = { 0x5c8a12, 0xb8ff3d, 0xf4ffd8 };

#define SCREEN_MIDDLE   0x062a12    // the glass's glow, brightest in the middle
#define SCREEN_EDGE     0x010a04
#define GRID            0x0c3d1c
#define AXES            0x16602e

/* a to b, t of the way, with ordered dithering at (x, y) so a smooth
 * gradient doesn't show RGB565's steps as rings. */
static uint16_t mix(uint32_t a, uint32_t b, float t, int32_t x, int32_t y)
{
    static const uint8_t bayer[4][4] = { { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 } };
    float d = (bayer[y & 3][x & 3] + 0.5f) / 16.0f;
    static const int bits[3] = { 5, 6, 5 };        // blue, green, red
    uint16_t color = 0;
    int at = 0;
    for (int k = 0; k < 3; k++)
    {
        float ca = (a >> (8 * k)) & 0xff;
        float cb = (b >> (8 * k)) & 0xff;
        float max = (float)((1 << bits[k]) - 1);
        float v = (ca + (cb - ca) * t) / 255.0f * max + d;
        uint32_t q = v >= max ? (uint32_t)max : (uint32_t)v;
        color |= (uint16_t)(q << at);
        at += bits[k];
    }
    return color;
}

/* Paint the screen: the glow, then the graticule over it. */
static void paint_screen(const vis_canvas_t *c)
{
    float radius = c->size * EXTENT / 200.0f;
    int32_t div = c->size / DIVISIONS;
    int32_t tick = c->size / 90 + 1;
    uint16_t grid = vis_rgb(GRID);
    uint16_t axes = vis_rgb(AXES);

    for (int32_t y = 0; y < c->h; y++)
    {
        int32_t dy = y - c->cy;
        for (int32_t x = 0; x < c->w; x++)
        {
            int32_t dx = x - c->cx;
            float r = sqrtf((float)(dx * dx + dy * dy)) / radius;
            uint16_t color = 0;
            if (r < 1.0f)
            {
                color = mix(SCREEN_MIDDLE, SCREEN_EDGE, r * r, x, y);
                bool on_axis = dx == 0 || dy == 0;
                bool on_grid = dx % div == 0 || dy % div == 0;
                bool on_tick = (abs(dy) < tick && dx % (div / TICKS) == 0) ||
                               (abs(dx) < tick && dy % (div / TICKS) == 0);
                if (on_axis || on_tick)
                {
                    color = axes;
                }
                else if (on_grid)
                {
                    color = grid;
                }
            }
            screen[y * c->stride + x] = color;
        }
    }
}

static void start(vis_canvas_t *c)
{
    vis_gradient(colors[VIS_MIC], LEVELS, mic_stops, 3);
    vis_gradient(colors[VIS_SPEAKER], LEVELS, speaker_stops, 3);
    if (screen == NULL)
    {
        screen = vis_alloc((size_t)c->h * c->stride * sizeof(uint16_t));
        if (screen != NULL)
        {
            paint_screen(c);
        }
    }
    if (screen != NULL)
    {
        memcpy(c->px, screen, (size_t)c->h * c->stride * sizeof(uint16_t));
    }
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

/* The beam: a bright core with the phosphor's bloom round it, in two rings. */
static void beam(vis_canvas_t *c, int32_t x0, int32_t y0, int32_t x1, int32_t y1, int32_t width,
                 uint16_t core, uint16_t near, uint16_t far)
{
    bool flat = abs(x1 - x0) >= abs(y1 - y0);
    int32_t lo = -(width - 1) / 2;
    int32_t hi = width / 2;
    for (int32_t o = lo - 2; o <= hi + 2; o++)
    {
        uint16_t color = (o < lo - 1 || o > hi + 1) ? far : (o < lo || o > hi) ? near : core;
        if (flat)
        {
            vis_add_line(c, x0, y0 + o, x1, y1 + o, color);
        }
        else
        {
            vis_add_line(c, x0 + o, y0, x1 + o, y1, color);
        }
    }
}

static bool draw(vis_canvas_t *c, const vis_audio_t *a)
{
    int32_t side = c->size * EXTENT / 100;
    if (screen != NULL)
    {
        vis_fade_to(c, side, 1, screen);
    }
    else
    {
        vis_fade(c, side, 1);
    }

    const float size = (float)c->size;
    int32_t width = c->size / 150 + 1;
    float half = size * HALF_WIDTH;

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
        uint16_t near = vis_dim(colors[s][LEVELS / 2], 90);
        uint16_t far = vis_dim(colors[s][LEVELS / 2], 35);

        int32_t px = 0, py = 0;
        for (int i = 0; i < SHOWN; i++)
        {
            float t = (float)i / (SHOWN - 1);
            float taper = fmaxf(sinf((float)M_PI * t), 0.0f);     // sinf(pi) can come out just below 0
            int32_t x = (int32_t)(c->cx - half + 2.0f * half * t);
            int32_t y = (int32_t)(c->cy - wave[start + i] * size * AMPLITUDE * sqrtf(taper));
            if (i > 0)
            {
                beam(c, px, py, x, y, width, core, near, far);
            }
            px = x;
            py = y;
        }
    }
    return true;
}

const visualizer_t vis_scope = {
    .name = "Scope",
    .extent = EXTENT,
    .start = start,
    .draw = draw,
};
