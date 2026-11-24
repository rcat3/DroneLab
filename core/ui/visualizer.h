#ifndef RCAT_VISUALIZER_H
#define RCAT_VISUALIZER_H

/*
 * The visualizers: ways of showing the wearer's voice, and whatever the
 * speaker is playing. The Visualizer feature (feature_visualizer.c) shows
 * one at a time on a full screen canvas, and analyses the sound for them
 * once a frame (vis_audio.c). Each one is a visualizer_t in its own
 * vis_<name>.c, listed in feature_visualizer.c.
 *
 * They draw straight into the canvas's RGB565 pixels with the helpers here
 * (vis_draw.c), which is much quicker than LVGL objects for this many
 * changing shapes. Positions are in screen pixels, from the top left.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Memory for a visualizer's buffers, zeroed, from PSRAM first (LVGL's
 * allocator): internal RAM is what WiFi and Bluetooth need, so the
 * visualizers keep their big buffers out of it. Never freed. NULL if
 * there's no room. */
void *vis_alloc(size_t size);

/* ----- What the sound is doing, updated once a frame ----- */

#define VIS_BANDS       48      // spectrum bands, log spaced, lowest first
#define VIS_WAVE_LEN    512     // waveform samples, at VIS_WAVE_RATE
#define VIS_WAVE_RATE   16000

typedef enum
{
    VIS_MIC,
    VIS_SPEAKER,
    VIS_SOURCES
} vis_source_t;

typedef struct
{
    float dt;                       // seconds since the last frame
    float time;                     // seconds since the visualizer started

    // 0 to 1, rising at once and falling back smoothly: the microphone level
    // (as the voice ring uses) or the speaker's, whichever is louder.
    float level;

    // Each band 0 (background) to 1 (as loud as it's been lately), the
    // louder of the two sources, smoothed like the level.
    float bands[VIS_BANDS];
    float loudest_band;             // 0 to 1 across the bands: where the loudest one is

    // The newest sound from each source, -1 to 1, scaled so recent loud
    // sounds fill the range. wave_on is false while a source is silent (the
    // speaker isn't playing), and its wave is all zero.
    bool wave_on[VIS_SOURCES];
    float wave[VIS_SOURCES][VIS_WAVE_LEN];
} vis_audio_t;

/* Reset the trackers, for a fresh start. */
void vis_audio_reset(void);

/* Bring a up to date with the newest sound. */
void vis_audio_update(vis_audio_t *a, float dt);

/* ----- The canvas ----- */

typedef struct
{
    uint16_t *px;       // RGB565
    int32_t stride;     // pixels from one row to the next
    int32_t w, h;
    int32_t cx, cy;     // the middle
    int32_t size;       // the smaller of w and h: the round screen's diameter
} vis_canvas_t;

/* RGB565 from 0xRRGGBB */
static inline uint16_t vis_rgb(uint32_t rgb)
{
    return (uint16_t)(((rgb >> 8) & 0xf800) | ((rgb >> 5) & 0x07e0) | ((rgb >> 3) & 0x001f));
}

/* A color scaled by k/256 */
uint16_t vis_dim(uint16_t color, uint32_t k);

/* Fill lut with a gradient through the colors (0xRRGGBB), evenly spaced. */
void vis_gradient(uint16_t *lut, int lut_size, const uint32_t *stops, int stop_count);

/* Black out a square of side `side` around the middle (the whole canvas if
 * it's bigger). */
void vis_clear(vis_canvas_t *c, int32_t side);

/* Darken the same square, for trails: each frame keeps 1/2 (shift 1), 3/4
 * (shift 2) or 7/8 (shift 3) of its brightness. */
void vis_fade(vis_canvas_t *c, int32_t side, int shift);

/* The same, but fading towards a background picture instead of black: bg is
 * as big as the canvas, with its stride, and the canvas must only ever have
 * been added to over it (vis_add and the like). */
void vis_fade_to(vis_canvas_t *c, int32_t side, int shift, const uint16_t *bg);

/* Plain drawing, clipped to the canvas. */
void vis_pixel(vis_canvas_t *c, int32_t x, int32_t y, uint16_t color);
void vis_fill(vis_canvas_t *c, int32_t x, int32_t y, int32_t w, int32_t h, uint16_t color);
void vis_vline(vis_canvas_t *c, int32_t x, int32_t y1, int32_t y2, uint16_t color);

/* Additive drawing: adds the color to what's there, so overlapping light
 * gets brighter. */
void vis_add(vis_canvas_t *c, int32_t x, int32_t y, uint16_t color);
void vis_add_line(vis_canvas_t *c, int32_t x0, int32_t y0, int32_t x1, int32_t y1, uint16_t color);

/* A glowing line: a bright core width pixels wide with a dim halo round it. */
void vis_glow_line(vis_canvas_t *c, int32_t x0, int32_t y0, int32_t x1, int32_t y1, int32_t width,
                   uint16_t core, uint16_t halo);

/* A circle's outline, width pixels thick (added), and a filled disc (added). */
void vis_add_ring(vis_canvas_t *c, int32_t cx, int32_t cy, int32_t r, int32_t width, uint16_t color);
void vis_add_disc(vis_canvas_t *c, int32_t cx, int32_t cy, int32_t r, uint16_t color);

/* ----- A visualizer ----- */

typedef struct
{
    const char *name;

    /* The square around the middle it draws in, as a percentage of the
     * screen. Only that much is sent to the display each frame. */
    uint8_t extent;

    /* Optional. Called when it comes on, after the canvas is cleared. */
    void (*start)(vis_canvas_t *c);

    /* Draw a frame. Return false if nothing changed, so it isn't sent. */
    bool (*draw)(vis_canvas_t *c, const vis_audio_t *a);
} visualizer_t;

extern const visualizer_t vis_kitt;
extern const visualizer_t vis_terrain;
extern const visualizer_t vis_scope;
extern const visualizer_t vis_halo;
extern const visualizer_t vis_aurora;
extern const visualizer_t vis_orbit;
extern const visualizer_t vis_ripples;

#endif
