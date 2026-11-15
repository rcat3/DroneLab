/*
 * KITT style voice box: three columns of red segments that light up from the
 * middle outwards with the level. The middle column is taller and reacts a
 * little more than the side ones.
 */
#include <stdlib.h>

#include "ui/visualizer.h"

// Layout, in 240x240 design pixels
#define COLUMNS             3
#define CENTER_SEGMENTS     15      // odd, so there's a middle segment
#define SIDE_SEGMENTS       11
#define SEGMENT_WIDTH       44
#define SEGMENT_HEIGHT      7
#define SEGMENT_PITCH       10      // height plus the gap below it
#define COLUMN_SPACING      60
#define DESIGN_SIZE         240

#define SIDE_LEVEL_PERCENT  80      // side columns show a bit less than the middle

#define COLOR_LIT           0xff2010
#define COLOR_UNLIT         0x2a0404

static const uint8_t column_segments[COLUMNS] = { SIDE_SEGMENTS, CENTER_SEGMENTS, SIDE_SEGMENTS };

// Lit segments per column: 0 is none, 1 is just the middle one, 2 adds the
// ones above and below it, and so on.
static uint8_t lit_steps[COLUMNS];

static int32_t px(const vis_canvas_t *c, int32_t design_px)
{
    return design_px * c->size / DESIGN_SIZE;
}

static void draw_column(vis_canvas_t *c, int column, uint8_t steps)
{
    int count = column_segments[column];
    int middle = count / 2;
    int32_t w = px(c, SEGMENT_WIDTH);
    int32_t h = px(c, SEGMENT_HEIGHT);
    int32_t x = c->cx + (column - 1) * px(c, COLUMN_SPACING) - w / 2;

    for (int i = 0; i < count; i++)
    {
        bool lit = abs(i - middle) < steps;
        int32_t y = c->cy + (i - middle) * px(c, SEGMENT_PITCH) - h / 2;
        vis_fill(c, x, y, w, h, vis_rgb(lit ? COLOR_LIT : COLOR_UNLIT));
    }
    lit_steps[column] = steps;
}

static void start(vis_canvas_t *c)
{
    for (int column = 0; column < COLUMNS; column++)
    {
        draw_column(c, column, 0);
    }
}

static bool draw(vis_canvas_t *c, const vis_audio_t *a)
{
    bool changed = false;
    for (int column = 0; column < COLUMNS; column++)
    {
        float level = (column == 1) ? a->level : a->level * SIDE_LEVEL_PERCENT / 100;
        uint32_t max_steps = column_segments[column] / 2 + 1;
        uint32_t steps = (uint32_t)(level * max_steps + 0.5f);

        if (steps > max_steps)
        {
            steps = max_steps;
        }
        if (steps != lit_steps[column])
        {
            draw_column(c, column, (uint8_t)steps);
            changed = true;
        }
    }
    return changed;
}

const visualizer_t vis_kitt = {
    .name = "KITT",
    .extent = 72,
    .start = start,
    .draw = draw,
};
