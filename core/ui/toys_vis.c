/*
 * The Toy Visualizer, the Toys feature's first page (toys_vis.h): each
 * channel a connected toy follows, as a trace of what it's run at over the
 * last few seconds, scrolling from right to left, with what it runs at now
 * at a glowing head on the right. Each channel has a color of its own, pinks and purples
 * first, with a soft glow under its trace, and while a pattern or reaction
 * drives it, a dotted line shows how high it can go (its level). Faint lines
 * mark the levels, a quarter of the way apart, and the seconds, which scroll
 * with the traces. Over the top, each channel's name and what it runs at
 * now; under them, STOP, as on the Control page.
 *
 * It's drawn as the Sound Visualizer's styles are (visualizer.h): straight
 * into a canvas's pixels, over a background painted once, and only the traces' box is drawn
 * and sent to the display each frame. It keeps the channels' history while
 * it's off screen too, so it shows the last few seconds as soon as it's back.
 */
#if RCAT_FEATURE_TOYS

#include <math.h>
#include <stdio.h>
#include <string.h>

#include "app/toys.h"
#include "ui/toys_vis.h"
#include "ui/ui_internal.h"
#include "ui/visualizer.h"

#define FRAME_MS        33
#define SAMPLE_MS       40          // one sample of each channel this often
#define HISTORY         160         // samples kept: 6.4 s
#define SECOND_SAMPLES  (1000 / SAMPLE_MS)

// The traces' box, in screen sizes from the middle
#define HALF_SPAN       0.40f       // to the left and right
#define TOP             0.22f       // the top level, above the middle
#define BASE            0.20f       // level 0, below the middle
#define GLOW            0.14f       // how far the glow reaches under a trace
#define FILL_STEPS      32

#define GLASS_MIDDLE    0x2a0b3e
#define GLASS_LOW       0x3c0c38    // warmer, low down
#define GLASS_EDGE      0x050108
#define GRID            0x2e1446
#define GRID_BASE       0x5a2674
#define RIM             0x7a2c96
#define SECONDS         0x1c0a28
#define STAR            0x34264c

static const uint32_t channel_colors[TOYS_CHANNELS] = {
    0xff3d9a,   // V1 hot pink
    0xb35cff,   // V2 violet
    0x58d0ff,   // V3 cyan
    0xff8a6b,   // V4 coral
    0xe6a8ff,   // V5 lilac
    0x7f7bff,   // V6 periwinkle
};

static lv_obj_t *canvas;
static vis_canvas_t pixels;
static uint16_t *background;        // as big as the canvas
static lv_obj_t *legend[TOYS_CHANNELS];
static char legend_shown[TOYS_CHANNELS][8];
static lv_obj_t *nothing_label;
static lv_obj_t *stop_button;

// The traces' box, in pixels: level 0 at base_y, the top level at top_y
static int32_t left_x, right_x, top_y, base_y, glow_px;
static int32_t band_y0, band_y1, band_x0, band_x1;     // what's redrawn each frame

static uint16_t cores[TOYS_CHANNELS], halos[TOYS_CHANNELS], fills[TOYS_CHANNELS][FILL_STEPS];

// What each channel ran at, a sample every SAMPLE_MS, oldest first from next
static uint8_t history[HISTORY][TOYS_CHANNELS];
static uint32_t history_next;
static uint32_t samples;            // taken so far, to place the seconds by
static uint32_t since_sample;       // ms since the newest
static uint32_t last_tick;
static bool was_visible;

/* a to b, t of the way (0xRRGGBB). */
static uint32_t lerp_rgb(uint32_t a, uint32_t b, float t)
{
    uint32_t rgb = 0;
    for (int shift = 0; shift <= 16; shift += 8)
    {
        float ca = (a >> shift) & 0xff;
        float cb = (b >> shift) & 0xff;
        rgb |= (uint32_t)(ca + (cb - ca) * t + 0.5f) << shift;
    }
    return rgb;
}

/* 0xRRGGBB to RGB565, with ordered dithering at (x, y) so a smooth gradient
 * doesn't show RGB565's steps as rings. */
static uint16_t dithered(uint32_t rgb, int32_t x, int32_t y)
{
    static const uint8_t bayer[4][4] = { { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 } };
    float d = (bayer[y & 3][x & 3] + 0.5f) / 16.0f;
    static const int bits[3] = { 5, 6, 5 };        // blue, green, red
    uint16_t color = 0;
    int at = 0;
    for (int k = 0; k < 3; k++)
    {
        float max = (float)((1 << bits[k]) - 1);
        float v = ((rgb >> (8 * k)) & 0xff) / 255.0f * max + d;
        uint32_t q = v >= max ? (uint32_t)max : (uint32_t)v;
        color |= (uint16_t)(q << at);
        at += bits[k];
    }
    return color;
}

static uint32_t star_hash(uint32_t n)
{
    n = n * 2654435761u + 0x9e3779b9u;
    n ^= n >> 15;
    n *= 2246822519u;
    n ^= n >> 13;
    return n;
}

/* The background: a purple glow, warmer low down and dark at the edge, a
 * few faint stars, a rim of light round the screen's edge, and the lines
 * for the levels. */
static void paint_background(void)
{
    const vis_canvas_t *c = &pixels;
    float radius = c->size / 2.0f;
    float rim = radius * 0.965f;
    float rim_width = c->size / 160.0f + 1.0f;

    for (int32_t y = 0; y < c->h; y++)
    {
        int32_t dy = y - c->cy;
        float low = 0.5f + dy / (float)c->size;
        low = low < 0 ? 0 : low > 1 ? 1 : low;
        uint32_t inner = lerp_rgb(GLASS_MIDDLE, GLASS_LOW, low * low);
        for (int32_t x = 0; x < c->w; x++)
        {
            int32_t dx = x - c->cx;
            float d = sqrtf((float)(dx * dx + dy * dy));
            float r = d / radius;
            uint32_t rgb = r < 1.0f ? lerp_rgb(inner, GLASS_EDGE, r * r) : 0;
            float off_rim = fabsf(d - rim) / rim_width;
            if (off_rim < 2.0f)
            {
                rgb = lerp_rgb(rgb, RIM, off_rim < 1.0f ? 0.8f : 0.8f * (2.0f - off_rim) * 0.4f);
            }
            background[y * c->stride + x] = dithered(rgb, x, y);
        }
    }

    // Stars, outside the traces' box
    uint16_t star = vis_rgb(STAR);
    for (uint32_t i = 0; i < 70; i++)
    {
        uint32_t h = star_hash(i);
        int32_t x = (int32_t)(h % (uint32_t)c->w);
        int32_t y = (int32_t)((h >> 12) % (uint32_t)c->h);
        int32_t dx = x - c->cx, dy = y - c->cy;
        bool in_box = x >= band_x0 && x < band_x1 && y >= band_y0 && y < band_y1;
        if (in_box || (float)(dx * dx + dy * dy) > rim * rim * 0.85f)
        {
            continue;
        }
        uint16_t color = (h >> 28) > 12 ? vis_dim(star, 400) : vis_dim(star, 160 + (h >> 24 & 0x3f));
        background[y * c->stride + x] = color;
    }

    // The levels: a solid line at 0, dotted ones a quarter of the way apart
    uint16_t grid = vis_rgb(GRID);
    uint16_t grid_base = vis_rgb(GRID_BASE);
    for (int q = 0; q <= 4; q++)
    {
        int32_t y = base_y - (base_y - top_y) * q / 4;
        for (int32_t x = left_x; x <= right_x; x++)
        {
            if (q == 0)
            {
                background[y * c->stride + x] = grid_base;
            }
            else if ((x - left_x) % 6 < 3)
            {
                background[y * c->stride + x] = grid;
            }
        }
    }
}

static void make_colors(void)
{
    for (int ch = 0; ch < TOYS_CHANNELS; ch++)
    {
        cores[ch] = vis_rgb(channel_colors[ch]);
        halos[ch] = vis_dim(cores[ch], 70);
        for (int k = 0; k < FILL_STEPS; k++)
        {
            float t = 1.0f - (float)k / FILL_STEPS;
            fills[ch][k] = vis_dim(cores[ch], (uint32_t)(60 * t * t));
        }
    }
}

/* ----- Keeping the history ----- */

static void take_samples(uint32_t now)
{
    uint32_t dt = now - last_tick;
    last_tick = now;
    if (dt > HISTORY * SAMPLE_MS)
    {
        dt = HISTORY * SAMPLE_MS;
    }
    since_sample += dt;
    while (since_sample >= SAMPLE_MS)
    {
        since_sample -= SAMPLE_MS;
        for (uint8_t ch = 0; ch < TOYS_CHANNELS; ch++)
        {
            history[history_next][ch] = toys_channel(ch)->out;
        }
        history_next = (history_next + 1) % HISTORY;
        samples++;
    }
}

/* What channel ch ran at, sample i of the history (0 the oldest). */
static uint8_t sample(uint32_t i, uint8_t ch)
{
    return history[(history_next + i) % HISTORY][ch];
}

/* ----- Drawing ----- */

static int32_t level_y(uint32_t out)
{
    return base_y - (int32_t)((base_y - top_y) * out / TOYS_LEVEL_TOP);
}

/* Where sample i of the history goes across, in 1/256 pixels: the newest a
 * little in from the right, as it's a little old. */
static int32_t sample_x256(uint32_t i)
{
    int64_t span = (int64_t)(right_x - left_x) * 256;
    int64_t age = (int64_t)(HISTORY - 1 - i) * SAMPLE_MS + since_sample;     // ms
    return (int32_t)(right_x * 256 - span * age / (HISTORY * SAMPLE_MS));
}

/* The glow under a trace, from (x0, y0) to (x1, y1), a column at a time. */
static void glow_under(int32_t x0, int32_t y0, int32_t x1, int32_t y1, uint8_t ch)
{
    vis_canvas_t *c = &pixels;
    for (int32_t x = x0 < left_x ? left_x : x0; x < x1 && x <= right_x; x++)
    {
        int32_t y = y0 + (y1 - y0) * (x - x0) / (x1 - x0);
        int32_t bottom = y + glow_px < base_y ? y + glow_px : base_y;
        for (int32_t py = y + 1; py < bottom; py++)
        {
            vis_add(c, x, py, fills[ch][(py - y) * FILL_STEPS / glow_px]);
        }
    }
}

static void draw_frame(uint8_t shown)
{
    vis_canvas_t *c = &pixels;
    memcpy(&c->px[band_y0 * c->stride], &background[band_y0 * c->stride],
           (size_t)(band_y1 - band_y0) * c->stride * sizeof(uint16_t));

    // The seconds, scrolling with the traces
    uint16_t second = vis_rgb(SECONDS);
    for (uint32_t i = 0; i < HISTORY; i++)
    {
        if ((samples - HISTORY + i) % SECOND_SAMPLES == 0)
        {
            int32_t x = sample_x256(i) / 256;
            for (int32_t y = top_y; y < base_y; y += 2)
            {
                vis_add(c, x, y, second);
            }
        }
    }

    int32_t width = c->size / 140 + 1;
    int32_t head = c->size / 70 + 2;
    for (uint8_t ch = 0; ch < TOYS_CHANNELS; ch++)
    {
        if (!(shown & (1u << ch)))
        {
            continue;
        }
        const toy_channel_t *state = toys_channel(ch);

        // How high it can go, while something drives it
        if (toys_driven(ch) && state->level > 0)
        {
            int32_t y = level_y(state->level);
            uint16_t dots = vis_dim(cores[ch], 110);
            for (int32_t x = left_x; x <= right_x; x++)
            {
                if ((x - left_x) % 8 < 3)
                {
                    vis_add(c, x, y, dots);
                }
            }
        }

        // The trace, oldest first, then on to what it runs at now
        int32_t px = 0, py = 0;
        for (uint32_t i = 0; i <= HISTORY; i++)
        {
            int32_t x = i < HISTORY ? sample_x256(i) / 256 : right_x;
            int32_t y = level_y(i < HISTORY ? sample(i, ch) : state->out);
            if (i > 0 && x > px)
            {
                glow_under(px, py, x, y, ch);
                vis_glow_line(c, px < left_x ? left_x : px, py, x, y, width, cores[ch], halos[ch]);
            }
            px = x;
            py = y;
        }
        vis_add_disc(c, right_x, py, head, halos[ch]);
        vis_add_disc(c, right_x, py, head / 2 + 1, cores[ch]);
    }
}

static void invalidate_band(void)
{
    lv_area_t coords;
    lv_obj_get_coords(canvas, &coords);
    lv_area_t area = {
        .x1 = coords.x1 + band_x0,
        .y1 = coords.y1 + band_y0,
        .x2 = coords.x1 + band_x1 - 1,
        .y2 = coords.y1 + band_y1 - 1,
    };
    lv_obj_invalidate_area(canvas, &area);
}

/* The channels to show: those a connected toy follows. */
static uint8_t shown_channels(void)
{
    return toys_connected_count() > 0 ? toys_channels_mapped() : 0;
}

static void show_legend(uint8_t shown)
{
    for (uint8_t ch = 0; ch < TOYS_CHANNELS; ch++)
    {
        bool on = (shown & (1u << ch)) != 0;
        lv_obj_set_hidden(legend[ch], !on);
        char text[8];
        snprintf(text, sizeof(text), "V%u %u", ch + 1, toys_channel(ch)->out);
        if (on && strcmp(text, legend_shown[ch]) != 0)
        {
            strcpy(legend_shown[ch], text);
            lv_label_set_text(legend[ch], text);
        }
    }
    lv_obj_set_hidden(nothing_label, toys_connected_count() > 0);
    lv_obj_set_hidden(stop_button, toys_connected_count() == 0);
}

static void frame_timer_cb(lv_timer_t *t)
{
    take_samples(lv_tick_get());
    if (!lv_obj_is_visible(canvas))
    {
        was_visible = false;
        return;
    }
    if (!was_visible)
    {
        // Back on screen: everything, background and all
        memcpy(pixels.px, background, (size_t)pixels.h * pixels.stride * sizeof(uint16_t));
        lv_obj_invalidate(canvas);
        was_visible = true;
    }
    uint8_t shown = shown_channels();
    show_legend(shown);
    draw_frame(shown);
    invalidate_band();
}

static void stop_event_cb(lv_event_t *e)
{
    toys_stop_all();
}

bool toys_vis_add(lv_obj_t *page)
{
    lv_display_t *disp = lv_display_get_default();
    int32_t w = lv_display_get_horizontal_resolution(disp);
    int32_t h = lv_display_get_vertical_resolution(disp);
    lv_draw_buf_t *buf = lv_draw_buf_create((uint32_t)w, (uint32_t)h, LV_COLOR_FORMAT_RGB565, LV_STRIDE_AUTO);
    if (buf == NULL)
    {
        return false;
    }
    pixels.px = (uint16_t *)buf->data;
    pixels.stride = (int32_t)(buf->header.stride / sizeof(uint16_t));
    pixels.w = w;
    pixels.h = h;
    pixels.cx = w / 2;
    pixels.cy = h / 2;
    pixels.size = LV_MIN(w, h);
    background = vis_alloc((size_t)h * pixels.stride * sizeof(uint16_t));
    if (background == NULL)
    {
        lv_draw_buf_destroy(buf);
        return false;
    }

    float size = (float)pixels.size;
    left_x = pixels.cx - (int32_t)(size * HALF_SPAN);
    right_x = pixels.cx + (int32_t)(size * HALF_SPAN);
    top_y = pixels.cy - (int32_t)(size * TOP);
    base_y = pixels.cy + (int32_t)(size * BASE);
    glow_px = (int32_t)(size * GLOW);
    int32_t pad = pixels.size / 35 + 4;     // the heads, and the lines' halos
    band_x0 = LV_MAX(left_x - pad, 0);
    band_x1 = LV_MIN(right_x + pad + 1, w);
    band_y0 = LV_MAX(top_y - pad, 0);
    band_y1 = LV_MIN(base_y + pad + 1, h);
    make_colors();
    paint_background();
    memcpy(pixels.px, background, (size_t)h * pixels.stride * sizeof(uint16_t));

    canvas = lv_canvas_create(page);
    lv_canvas_set_draw_buf(canvas, buf);
    lv_obj_center(canvas);

    // Each channel's name and what it runs at now, in its own color
    lv_obj_t *row = lv_obj_create(page);
    lv_obj_remove_style_all(row);
    lv_obj_set_size(row, ui_px(170), LV_SIZE_CONTENT);
    lv_obj_align(row, LV_ALIGN_TOP_MID, 0, ui_px(30));
    lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW_WRAP);
    lv_obj_set_flex_align(row, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(row, ui_px(12), 0);
    lv_obj_set_style_pad_row(row, ui_px(2), 0);
    lv_obj_set_clickable(row, false);
    for (uint8_t ch = 0; ch < TOYS_CHANNELS; ch++)
    {
        legend[ch] = lv_label_create(row);
        lv_obj_set_style_text_color(legend[ch], lv_color_hex(channel_colors[ch]), 0);
        lv_label_set_text(legend[ch], "");
        lv_obj_set_hidden(legend[ch], true);
    }

    nothing_label = lv_label_create(page);
    lv_label_set_text(nothing_label, "Nothing connected\n\nSwipe left twice\nto find a toy");
    lv_obj_set_style_text_align(nothing_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(nothing_label, lv_color_hex(0xc9a6dd), 0);
    lv_obj_center(nothing_label);

    // Stops on the touch itself rather than the release, so it can't be
    // lost to a swipe.
    stop_button = lv_button_create(page);
    lv_obj_set_size(stop_button, ui_px(84), ui_px(34));
    lv_obj_align(stop_button, LV_ALIGN_CENTER, 0, ui_px(84));
    lv_obj_set_style_radius(stop_button, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(stop_button, lv_palette_darken(LV_PALETTE_RED, 1), 0);
    lv_obj_set_style_shadow_width(stop_button, 0, 0);
    lv_obj_set_scroll_chain(stop_button, false);
    lv_obj_add_event_cb(stop_button, stop_event_cb, LV_EVENT_PRESSED, NULL);
    lv_obj_t *label = lv_label_create(stop_button);
    lv_label_set_text(label, "STOP");
    lv_obj_center(label);

    last_tick = lv_tick_get();
    show_legend(shown_channels());
    lv_timer_create(frame_timer_cb, FRAME_MS, NULL);
    return true;
}

#endif
