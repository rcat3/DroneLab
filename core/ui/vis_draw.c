/*
 * Drawing helpers for the visualizers (see visualizer.h), on RGB565 pixels.
 */
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "lvgl.h"
#include "ui/visualizer.h"

#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))

#define R_OF(c) (((c) >> 11) & 0x1f)
#define G_OF(c) (((c) >> 5) & 0x3f)
#define B_OF(c) ((c) & 0x1f)

void *vis_alloc(size_t size)
{
    return lv_malloc_zeroed(size);
}

uint16_t vis_dim(uint16_t color, uint32_t k)
{
    if (k >= 256)
    {
        return color;
    }
    uint32_t r = R_OF(color) * k >> 8;
    uint32_t g = G_OF(color) * k >> 8;
    uint32_t b = B_OF(color) * k >> 8;
    return (uint16_t)((r << 11) | (g << 5) | b);
}

void vis_gradient(uint16_t *lut, int lut_size, const uint32_t *stops, int stop_count)
{
    for (int i = 0; i < lut_size; i++)
    {
        float t = (float)i / (lut_size - 1) * (stop_count - 1);
        int s = (int)t;
        if (s >= stop_count - 1)
        {
            s = stop_count - 2;
        }
        float f = t - s;
        uint32_t a = stops[s];
        uint32_t b = stops[s + 1];
        uint32_t rgb = 0;
        for (int shift = 0; shift <= 16; shift += 8)
        {
            float ca = (a >> shift) & 0xff;
            float cb = (b >> shift) & 0xff;
            uint32_t v = (uint32_t)(ca + (cb - ca) * f + 0.5f);
            rgb |= v << shift;
        }
        lut[i] = vis_rgb(rgb);
    }
}

/* The rows and columns of a square of side `side` around the middle. */
static void square(const vis_canvas_t *c, int32_t side, int32_t *x0, int32_t *y0, int32_t *x1, int32_t *y1)
{
    *x0 = MAX(c->cx - side / 2, 0);
    *y0 = MAX(c->cy - side / 2, 0);
    *x1 = MIN(c->cx + (side + 1) / 2, c->w);
    *y1 = MIN(c->cy + (side + 1) / 2, c->h);
}

void vis_clear(vis_canvas_t *c, int32_t side)
{
    int32_t x0, y0, x1, y1;
    square(c, side, &x0, &y0, &x1, &y1);
    for (int32_t y = y0; y < y1; y++)
    {
        memset(&c->px[y * c->stride + x0], 0, (size_t)(x1 - x0) * sizeof(uint16_t));
    }
}

/* How much one fade step takes off two pixels' channels: a share of each
 * channel, and 1 more from any that isn't 0 yet, so they all get to black
 * (a shift alone leaves a channel of 1 at 1 for ever). It never takes off
 * more than a channel has, so it never borrows from the next one. */
static inline uint32_t fade_step(uint32_t v, int shift, uint32_t mask)
{
    uint32_t nonzero = (v | (v >> 1) | (v >> 2) | (v >> 3) | (v >> 4)) & 0x08210821u;
    return ((v >> shift) & mask) + nonzero;
}

void vis_fade(vis_canvas_t *c, int32_t side, int shift)
{
    static const uint16_t masks[4] = { 0, 0x7bef, 0x39e7, 0x18e3 };
    shift = shift < 1 ? 1 : shift > 3 ? 3 : shift;
    uint32_t mask2 = masks[shift] | ((uint32_t)masks[shift] << 16);

    int32_t x0, y0, x1, y1;
    square(c, side, &x0, &y0, &x1, &y1);
    for (int32_t y = y0; y < y1; y++)
    {
        // Two pixels at a time
        uint16_t *p = &c->px[y * c->stride + x0];
        uint16_t *end = &c->px[y * c->stride + x1];
        if (((uintptr_t)p & 2) && p < end)
        {
            *p -= (uint16_t)fade_step(*p, shift, mask2);
            p++;
        }
        uint32_t *p2 = (uint32_t *)p;
        uint32_t *end2 = (uint32_t *)(end - ((end - p) & 1));
        while (p2 < end2)
        {
            uint32_t v = *p2;
            *p2++ = v - fade_step(v, shift, mask2);
        }
        p = (uint16_t *)p2;
        if (p < end)
        {
            *p -= (uint16_t)fade_step(*p, shift, mask2);
        }
    }
}

void vis_pixel(vis_canvas_t *c, int32_t x, int32_t y, uint16_t color)
{
    if ((uint32_t)x < (uint32_t)c->w && (uint32_t)y < (uint32_t)c->h)
    {
        c->px[y * c->stride + x] = color;
    }
}

void vis_fill(vis_canvas_t *c, int32_t x, int32_t y, int32_t w, int32_t h, uint16_t color)
{
    int32_t x1 = MIN(x + w, c->w);
    int32_t y1 = MIN(y + h, c->h);
    x = MAX(x, 0);
    y = MAX(y, 0);
    for (; y < y1; y++)
    {
        uint16_t *p = &c->px[y * c->stride];
        for (int32_t i = x; i < x1; i++)
        {
            p[i] = color;
        }
    }
}

void vis_vline(vis_canvas_t *c, int32_t x, int32_t y1, int32_t y2, uint16_t color)
{
    if ((uint32_t)x >= (uint32_t)c->w)
    {
        return;
    }
    y1 = MAX(y1, 0);
    y2 = MIN(y2, c->h - 1);
    uint16_t *p = &c->px[y1 * c->stride + x];
    for (int32_t y = y1; y <= y2; y++, p += c->stride)
    {
        *p = color;
    }
}

static inline uint16_t add565(uint16_t a, uint16_t b)
{
    uint32_t r = R_OF(a) + R_OF(b);
    uint32_t g = G_OF(a) + G_OF(b);
    uint32_t bl = B_OF(a) + B_OF(b);
    r = r > 0x1f ? 0x1f : r;
    g = g > 0x3f ? 0x3f : g;
    bl = bl > 0x1f ? 0x1f : bl;
    return (uint16_t)((r << 11) | (g << 5) | bl);
}

void vis_add(vis_canvas_t *c, int32_t x, int32_t y, uint16_t color)
{
    if ((uint32_t)x < (uint32_t)c->w && (uint32_t)y < (uint32_t)c->h)
    {
        uint16_t *p = &c->px[y * c->stride + x];
        *p = add565(*p, color);
    }
}

static void add_span(vis_canvas_t *c, int32_t y, int32_t x0, int32_t x1, uint16_t color)
{
    if ((uint32_t)y >= (uint32_t)c->h)
    {
        return;
    }
    x0 = MAX(x0, 0);
    x1 = MIN(x1, c->w - 1);
    uint16_t *p = &c->px[y * c->stride];
    for (int32_t x = x0; x <= x1; x++)
    {
        p[x] = add565(p[x], color);
    }
}

/* Bresenham, leaving out the last point so the lines of a polyline don't
 * add up twice where they meet. */
void vis_add_line(vis_canvas_t *c, int32_t x0, int32_t y0, int32_t x1, int32_t y1, uint16_t color)
{
    // Ends far off the canvas would take ages to walk along, so leave them
    // out. They only come from a bad number.
    int32_t far = 2 * (c->w + c->h);
    if (abs(x0) > far || abs(y0) > far || abs(x1) > far || abs(y1) > far)
    {
        return;
    }
    int32_t dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
    int32_t dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
    int32_t err = dx + dy;
    while (x0 != x1 || y0 != y1)
    {
        vis_add(c, x0, y0, color);
        int32_t e2 = 2 * err;
        if (e2 >= dy)
        {
            err += dy;
            x0 += sx;
        }
        if (e2 <= dx)
        {
            err += dx;
            y0 += sy;
        }
    }
}

void vis_glow_line(vis_canvas_t *c, int32_t x0, int32_t y0, int32_t x1, int32_t y1, int32_t width,
                   uint16_t core, uint16_t halo)
{
    // Thicken across the line: up and down for a flat line, sideways for a steep one.
    bool flat = abs(x1 - x0) >= abs(y1 - y0);
    int32_t lo = -(width - 1) / 2;
    int32_t hi = width / 2;
    for (int32_t o = lo - 1; o <= hi + 1; o++)
    {
        uint16_t color = (o < lo || o > hi) ? halo : core;
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

void vis_add_ring(vis_canvas_t *c, int32_t cx, int32_t cy, int32_t r, int32_t width, uint16_t color)
{
    int32_t ro = r + width / 2;
    int32_t ri = ro - width;
    float ro2 = (float)ro * ro;
    float ri2 = (float)ri * ri;
    for (int32_t y = -ro; y <= ro; y++)
    {
        float y2 = (float)y * y;
        int32_t xo = (int32_t)sqrtf(ro2 - y2);
        if (ri > 0 && y2 < ri2)
        {
            int32_t xi = (int32_t)sqrtf(ri2 - y2) + 1;
            if (xi <= xo)
            {
                add_span(c, cy + y, cx - xo, cx - xi, color);
                add_span(c, cy + y, cx + xi, cx + xo, color);
            }
        }
        else
        {
            add_span(c, cy + y, cx - xo, cx + xo, color);
        }
    }
}

void vis_add_disc(vis_canvas_t *c, int32_t cx, int32_t cy, int32_t r, uint16_t color)
{
    float r2 = (float)r * r;
    for (int32_t y = -r; y <= r; y++)
    {
        int32_t x = (int32_t)sqrtf(r2 - (float)y * y);
        add_span(c, cy + y, cx - x, cx + x, color);
    }
}
