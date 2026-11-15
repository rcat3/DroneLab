/*
 * Ripples: each syllable sends a ring out from the middle, like a drop in
 * still water. Louder ones are wider, brighter and faster, and every ring
 * fades as it spreads. A ring's color is where the sound's energy was when
 * it started, from teal for a low voice through blue, violet and pink to
 * gold for hiss and high notes. The middle glows with the level.
 */
#include <math.h>

#include "ui/visualizer.h"

#define MAX_RINGS       20
#define START_RADIUS    0.05f       // in screen sizes
#define END_RADIUS      0.50f
#define SPEED_MIN       0.22f       // screen sizes a second, for the quietest ring
#define SPEED_MAX       0.60f       // for the loudest
#define ONSET_RISE      0.12f       // the level jumping this far above its average is a new syllable
#define AVERAGE_TIME_S  0.4f
#define MIN_GAP_S       0.12f       // between rings
#define SUSTAIN_LEVEL   0.35f       // held sounds louder than this keep sending rings
#define SUSTAIN_GAP_S   0.30f
#define LEVELS          64

typedef struct
{
    bool active;
    float radius;       // screen sizes
    float speed;
    float strength;     // 0 to 1
    uint16_t color;
} ring_t;

static ring_t rings[MAX_RINGS];
static float average;
static float since_last;
static uint16_t palette[LEVELS];

static const uint32_t stops[] = { 0x00d1b2, 0x3d7bff, 0x9b5cff, 0xff4fa3, 0xffc24b };

static void start(vis_canvas_t *c)
{
    vis_gradient(palette, LEVELS, stops, 5);
    for (int i = 0; i < MAX_RINGS; i++)
    {
        rings[i].active = false;
    }
    average = 0.0f;
    since_last = 1.0f;
}

static void spawn(float strength, float where)
{
    // Reuse a free ring, or the one that's spread furthest.
    ring_t *ring = &rings[0];
    for (int i = 0; i < MAX_RINGS; i++)
    {
        if (!rings[i].active)
        {
            ring = &rings[i];
            break;
        }
        if (rings[i].radius > ring->radius)
        {
            ring = &rings[i];
        }
    }
    strength = strength > 1.0f ? 1.0f : strength;
    ring->active = true;
    ring->radius = START_RADIUS;
    ring->speed = SPEED_MIN + (SPEED_MAX - SPEED_MIN) * strength;
    ring->strength = strength;
    ring->color = palette[(int)(where * (LEVELS - 1) + 0.5f)];
}

static bool draw(vis_canvas_t *c, const vis_audio_t *a)
{
    vis_fade(c, c->size, 2);

    // A new syllable, or a held sound
    since_last += a->dt;
    average += (a->level - average) * (1.0f - expf(-a->dt / AVERAGE_TIME_S));
    if ((a->level - average > ONSET_RISE && since_last > MIN_GAP_S)
        || (a->level > SUSTAIN_LEVEL && since_last > SUSTAIN_GAP_S))
    {
        spawn(0.3f + a->level, a->loudest_band);
        since_last = 0.0f;
    }

    const float size = (float)c->size;
    for (int i = 0; i < MAX_RINGS; i++)
    {
        ring_t *ring = &rings[i];
        if (!ring->active)
        {
            continue;
        }
        ring->radius += ring->speed * a->dt;
        if (ring->radius >= END_RADIUS)
        {
            ring->active = false;
            continue;
        }
        float spread = (ring->radius - START_RADIUS) / (END_RADIUS - START_RADIUS);
        float fade = (1.0f - spread) * (0.35f + 0.65f * ring->strength);
        int32_t width = (int32_t)(size * (0.006f + 0.014f * ring->strength) * (1.0f - 0.5f * spread)) + 1;
        vis_add_ring(c, c->cx, c->cy, (int32_t)(ring->radius * size), width,
                     vis_dim(ring->color, (uint32_t)(fade * 200)));
    }

    // The glow in the middle, in the color of the sound now
    uint16_t glow = palette[(int)(a->loudest_band * (LEVELS - 1) + 0.5f)];
    vis_add_disc(c, c->cx, c->cy, (int32_t)(size * (0.03f + 0.06f * a->level)), vis_dim(glow, 40));
    vis_add_disc(c, c->cx, c->cy, (int32_t)(size * (0.01f + 0.035f * a->level)), vis_dim(glow, 30 + 120 * a->level));
    return true;
}

const visualizer_t vis_ripples = {
    .name = "Ripples",
    .extent = 100,
    .start = start,
    .draw = draw,
};
