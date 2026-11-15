/*
 * Terrain: a 3D spectrum. Frequency runs left to right (low to high), each
 * band's level is its height, and time runs into the distance: the newest
 * spectrum is at the front and older ones recede towards the horizon.
 *
 * It's drawn front to back with a floating horizon: for each screen column
 * it remembers the highest point drawn so far, and anything further back
 * only shows above that. Each ridge is a bright line over a dim fill, so the
 * rows in front hide the ones behind. Colors go from indigo in the valleys
 * to pink, orange and gold on the peaks, and dim with distance. When it's
 * quiet the flat rows make a perspective grid.
 */
#include <string.h>

#include "ui/visualizer.h"

#define ROWS            30          // about a second of history
#define DEPTH           1.7f        // the back row is 1 / (1 + DEPTH) the size of the front one
#define VANISH_Y        -0.34f      // where the rows would meet, in screen sizes from the middle
#define FRONT_Y         0.24f       // the front row's baseline
#define HALF_WIDTH      0.40f       // the front row's half width
#define HEIGHT          0.32f       // the front row's tallest peak
#define FAR_DIM         0.70f       // how much the back row is dimmed
#define FILL_DIM        64          // the fill under each ridge, of 256
#define LINE_PX         2
#define LEVELS          64          // colors in the palette
#define MAX_WIDTH       1024

// Allocated on first use, to keep them out of internal RAM
typedef struct
{
    float history[ROWS][VIS_BANDS];
    int16_t horizon[MAX_WIDTH];
} buffers_t;

static buffers_t *buf;
static int front;                   // the row in history that's at the front
static uint16_t palette[LEVELS];

static const uint32_t stops[] = { 0x1d1650, 0x3b2a9e, 0x8a2be2, 0xff2e88, 0xff8c42, 0xffe8a3 };

static void start(vis_canvas_t *c)
{
    vis_gradient(palette, LEVELS, stops, sizeof(stops) / sizeof(stops[0]));
    if (buf == NULL)
    {
        buf = vis_alloc(sizeof(buffers_t));
    }
    if (buf != NULL)
    {
        memset(buf->history, 0, sizeof(buf->history));
    }
    front = 0;
}

static bool draw(vis_canvas_t *c, const vis_audio_t *a)
{
    if (buf == NULL)
    {
        return false;
    }
    float (*history)[VIS_BANDS] = buf->history;
    int16_t *horizon = buf->horizon;

    // The newest spectrum goes in at the front.
    front = (front + ROWS - 1) % ROWS;
    for (int b = 0; b < VIS_BANDS; b++)
    {
        history[front][b] = a->bands[b];
    }

    int32_t side = c->size * 9 / 10;
    vis_clear(c, side);
    int32_t w = c->w < MAX_WIDTH ? c->w : MAX_WIDTH;
    for (int32_t x = 0; x < w; x++)
    {
        horizon[x] = (int16_t)c->h;
    }

    const float size = (float)c->size;
    for (int r = 0; r < ROWS; r++)
    {
        const float *row = history[(front + r) % ROWS];
        float z = (float)r / (ROWS - 1);
        float p = 1.0f / (1.0f + DEPTH * z);
        float base = c->cy + size * (VANISH_Y + (FRONT_Y - VANISH_Y) * p);
        float half = size * HALF_WIDTH * p;
        float height = size * HEIGHT * p;

        // This row's colors, dimmed for its distance.
        uint16_t line_colors[LEVELS];
        uint16_t fill_colors[LEVELS];
        uint32_t k = (uint32_t)(256.0f * (1.0f - FAR_DIM * z));
        for (int i = 0; i < LEVELS; i++)
        {
            line_colors[i] = vis_dim(palette[i], k);
            fill_colors[i] = vis_dim(line_colors[i], FILL_DIM);
        }

        int32_t x0 = (int32_t)(c->cx - half);
        int32_t x1 = (int32_t)(c->cx + half);
        int32_t base_y = (int32_t)base;
        float span = (float)(x1 - x0);
        for (int32_t x = x0 < 0 ? 0 : x0; x <= x1 && x < w; x++)
        {
            // The level here, between the two nearest bands.
            float t = (x - x0) / span * (VIS_BANDS - 1);
            int b = (int)t;
            b = b >= VIS_BANDS - 1 ? VIS_BANDS - 2 : b;
            float f = t - b;
            float v = row[b] + (row[b + 1] - row[b]) * f;

            int32_t y = (int32_t)(base - height * v);
            if (y >= horizon[x])
            {
                continue;       // hidden behind a nearer row
            }
            int level = (int)(v * (LEVELS - 1) + 0.5f);
            int32_t bottom = (horizon[x] < base_y + 1 ? horizon[x] : base_y + 1) - 1;
            vis_vline(c, x, y, y + LINE_PX - 1, line_colors[level]);
            if (bottom >= y + LINE_PX)
            {
                vis_vline(c, x, y + LINE_PX, bottom, fill_colors[level]);
            }
            horizon[x] = (int16_t)y;
        }
    }
    return true;
}

const visualizer_t vis_terrain = {
    .name = "Terrain",
    .extent = 90,
    .start = start,
    .draw = draw,
};
