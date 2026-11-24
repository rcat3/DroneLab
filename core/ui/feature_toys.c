/*
 * Toys feature (boards with Bluetooth): HiveMind Control's toys on this
 * unit (app/toys.h), up to three at once, run by channel, on dark pages.
 *
 *   Toy Visualizer: what each channel a toy follows has run at over the last
 *             few seconds, as glowing traces scrolling across the screen,
 *             with STOP under them (toys_vis.h).
 *   Control:  a ring around the screen for each of the screen's controls,
 *             with the level on its knob: one for each channel a toy
 *             follows, or as the wearer lays them out in their app, each
 *             driving one or more channels together. Only the knobs can be
 *             dragged, so swipes anywhere else still move between pages. A
 *             Stop button in the middle stops everything as soon as it's
 *             touched.
 *   Devices:  looks for toys while it's on screen. Tap one to connect to
 *             it, or tap it again to stop it and disconnect.
 *   Patterns: plays a pattern on every channel, or on one control's. While
 *             one plays, each ring on the control page sets how high its
 *             channels go, and a thin ring inside it shows the level as it
 *             plays. The speed, of the channels picked, is under the list.
 *   React:    drives the channels from your voice or your movement (see
 *             reactive.h), on top of any pattern.
 *   Options:  Hold: on, a control keeps its level when you let go of its
 *             knob; off, it goes back to 0.
 *   Others:   who may send commands from the comm channel (see
 *             app/others.h and others_page.h).
 *
 * The connections keep running while you look at other features, so the
 * levels stay as they were set. Everything here can also be done from a
 * phone, with the phone remote in Settings (see remote.h), and the app maps
 * the toys' outputs to channels, and lays out the controls.
 */
#include <stdio.h>
#include <string.h>

#include "app/patterns.h"
#include "app/reactive.h"
#include "app/settings.h"
#include "app/toys.h"
#include "ui/others_page.h"
#include "ui/toys_vis.h"
#include "ui/ui_internal.h"

#define POLL_MS             50
#define NOTICE_MS           2500    // how long "Only 3 at once" and the like stay up

// Ring layout, in 240x240 design pixels. The rings sit inside one another,
// open at the bottom, each with a knob that's bigger than the ring.
#define RING_OUTER          220     // outer ring's diameter
#define RING_STEP           48      // each ring is this much smaller across
#define RING_WIDTH          12
#define KNOB_PAD            5       // how far a knob sticks out past its ring
#define KNOB_REACH          18      // a touch this close to a knob grabs it
#define RING_START          135     // degrees, clockwise from 3 o'clock
#define RING_SWEEP          270

// Dark theme colors
#define COLOR_TRACK         lv_color_hex(0x262626)
#define COLOR_SURFACE       lv_color_hex(0x1c1c1c)
#define COLOR_OUTLINE       lv_color_hex(0x3a3a3a)
#define COLOR_MUTED         lv_color_hex(0x8a8a8a)
#define COLOR_CONNECTED     lv_palette_main(LV_PALETTE_GREEN)

static bool build(ui_feature_t *feature);
static void on_navigate(void);

const ui_feature_def_t feature_toys = {
    .name = "Toys",
    .build = build,
    .on_navigate = on_navigate,
};

static const lv_palette_t ring_colors[TOYS_SCREEN_CONTROLS] = {
    LV_PALETTE_PINK, LV_PALETTE_PURPLE, LV_PALETTE_CYAN,
};

/* ----- Control page ----- */

static lv_obj_t *control_page;
static lv_obj_t *rings[TOYS_SCREEN_CONTROLS];
static lv_obj_t *live_rings[TOYS_SCREEN_CONTROLS];   // thin, inside each ring: the level while a pattern plays
static lv_obj_t *grips[TOYS_SCREEN_CONTROLS];        // invisible, over each knob, to drag it
static lv_obj_t *knob_labels[TOYS_SCREEN_CONTROLS];  // the level, on the grip
static lv_obj_t *kind_labels[TOYS_SCREEN_CONTROLS];
static lv_obj_t *name_label;
static lv_obj_t *battery_label;
static lv_obj_t *stop_button;
static lv_obj_t *nothing_label;
static lv_obj_t *nothing_title;     // says what the page is, while it's empty

static toys_control_t controls[TOYS_SCREEN_CONTROLS];
static int control_count;

// What the control page last showed, to redraw only on a change
static bool shown_valid;
static uint32_t shown_layout;
static int shown_count = -1;
static int shown_battery = -2;
static size_t shown_connected = (size_t)-1;
static uint8_t shown_levels[TOYS_SCREEN_CONTROLS];
static uint8_t shown_outs[TOYS_SCREEN_CONTROLS];
static bool shown_driven[TOYS_SCREEN_CONTROLS];
static int shown_pattern = -2;
static char shown_status[40];

/* ----- Devices page ----- */

static lv_obj_t *devices_page;
static lv_obj_t *device_rows[TOYS_MAX_DEVICES];
static lv_obj_t *device_row_labels[TOYS_MAX_DEVICES];
static lv_obj_t *devices_status;
static char row_texts[TOYS_MAX_DEVICES][48];
static uint32_t notice_until;
static bool no_bluetooth;

/* The first of a control's channels, which its ring shows. */
static uint8_t first_channel(uint8_t channels)
{
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        if (channels & (1u << c))
        {
            return c;
        }
    }
    return 0;
}

static bool any_driven(uint8_t channels)
{
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        if ((channels & (1u << c)) && toys_driven(c))
        {
            return true;
        }
    }
    return false;
}

/* The lowest battery of the connected toys, or -1. */
static int lowest_battery(void)
{
    int lowest = -1;
    for (size_t i = 0; i < TOYS_MAX_DEVICES; i++)
    {
        const toy_t *t = toys_device(i);
        if (t != NULL && t->state == TOY_CONNECTED && t->battery >= 0 && (lowest < 0 || t->battery < lowest))
        {
            lowest = t->battery;
        }
    }
    return lowest;
}

/* The pattern every channel the controls drive is playing, or -1. */
static int controls_pattern(void)
{
    int pattern = -2;
    for (int i = 0; i < control_count; i++)
    {
        for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
        {
            if (controls[i].channels & (1u << c))
            {
                int p = toys_channel(c)->pattern;
                if (pattern == -2)
                {
                    pattern = p;
                }
                else if (pattern != p)
                {
                    return -1;
                }
            }
        }
    }
    return pattern < 0 ? -1 : pattern;
}

/* ----- Ring geometry ----- */

static int32_t ring_mid_radius(uint8_t i)
{
    return ui_px(RING_OUTER - RING_STEP * i) / 2 - ui_px(RING_WIDTH) / 2;
}

/* Where ring i's knob is, as an offset from the screen's center. */
static void knob_offset(uint8_t i, int32_t *x, int32_t *y)
{
    int32_t max = lv_arc_get_max_value(rings[i]);
    int32_t value = lv_arc_get_value(rings[i]);
    int32_t angle = RING_START + (max > 0 ? RING_SWEEP * value / max : 0);
    int32_t r = ring_mid_radius(i);
    *x = (r * lv_trigo_cos(angle)) >> LV_TRIGO_SHIFT;
    *y = (r * lv_trigo_sin(angle)) >> LV_TRIGO_SHIFT;
}

/* The level for a touch at p (screen coordinates) on ring i. In the gap at
 * the bottom it sticks to whichever end is nearer, so dragging past an end
 * doesn't jump to the other one. */
static int32_t level_at(uint8_t i, const lv_point_t *p)
{
    lv_area_t a;
    lv_obj_get_coords(rings[i], &a);
    int32_t dx = p->x - (a.x1 + a.x2) / 2;
    int32_t dy = p->y - (a.y1 + a.y2) / 2;
    int32_t max = lv_arc_get_max_value(rings[i]);
    if (dx == 0 && dy == 0)
    {
        return lv_arc_get_value(rings[i]);
    }
    int32_t angle = ((int32_t)lv_atan2(dy, dx) - RING_START + 720) % 360;   // 0 at the ring's start
    if (angle > RING_SWEEP)
    {
        return angle < RING_SWEEP + (360 - RING_SWEEP) / 2 ? max : 0;
    }
    return (angle * max + RING_SWEEP / 2) / RING_SWEEP;
}

/* ----- Control page ----- */

/* Move ring i's grip (and the level on it) to its knob. */
static void place_knob_label(uint8_t i)
{
    int32_t x, y;
    knob_offset(i, &x, &y);
    lv_label_set_text_fmt(knob_labels[i], "%d", (int)lv_arc_get_value(rings[i]));
    lv_obj_align(grips[i], LV_ALIGN_CENTER, x, y);
}

/* Lay out the middle for the space the rings leave. */
static void layout_middle(int count)
{
    int32_t inner = ui_px(RING_OUTER - RING_STEP * (count > 0 ? count - 1 : 0)) / 2 - ui_px(RING_WIDTH + KNOB_PAD + 4);
    int32_t stop_size = inner * 85 / 100;
    lv_obj_set_size(stop_button, stop_size, stop_size);
    lv_obj_align(stop_button, LV_ALIGN_CENTER, 0, inner * 30 / 100);

    int32_t name_y = -inner * 52 / 100;
    lv_obj_set_width(name_label, inner * 2 - ui_px(8));
    lv_obj_align(name_label, LV_ALIGN_CENTER, 0, name_y);
    lv_obj_align(battery_label, LV_ALIGN_CENTER, 0, name_y + ui_px(17));
    // There's no room for the battery inside three rings.
    lv_obj_set_hidden(battery_label, count >= 3);
}

static void show_control(void)
{
    uint32_t layout = toys_layout_changes();
    size_t connected = toys_connected_count();
    if (!shown_valid || layout != shown_layout || connected != shown_connected)
    {
        control_count = connected > 0 ? toys_screen_controls(controls) : 0;
    }
    int battery = lowest_battery();
    int pattern = controls_pattern();
    char status[40] = "";
    if (toys_reaction() != REACTIVE_OFF)
    {
        reactive_status((reactive_mode_t)toys_reaction(), status, sizeof(status));
    }
    bool changed = !shown_valid || layout != shown_layout || control_count != shown_count || battery != shown_battery
                   || connected != shown_connected || pattern != shown_pattern || strcmp(status, shown_status) != 0;
    for (int i = 0; !changed && i < control_count; i++)
    {
        const toy_channel_t *ch = toys_channel(first_channel(controls[i].channels));
        changed = ch->level != shown_levels[i] || ch->out != shown_outs[i]
                  || any_driven(controls[i].channels) != shown_driven[i];
    }
    if (!changed)
    {
        return;
    }
    bool relayout = !shown_valid || layout != shown_layout || control_count != shown_count
                    || connected != shown_connected;
    shown_valid = true;
    shown_layout = layout;
    shown_count = control_count;
    shown_battery = battery;
    shown_connected = connected;
    shown_pattern = pattern;
    strcpy(shown_status, status);

    bool any = control_count > 0;
    lv_obj_set_hidden(nothing_label, any);
    lv_obj_set_hidden(nothing_title, any);
    lv_obj_set_hidden(name_label, !any);
    lv_obj_set_hidden(stop_button, !any);
    if (!any)
    {
        lv_obj_set_hidden(battery_label, true);
    }

    for (int i = 0; i < TOYS_SCREEN_CONTROLS; i++)
    {
        bool used = i < control_count;
        bool driven = used && any_driven(controls[i].channels);
        lv_obj_set_hidden(rings[i], !used);
        lv_obj_set_hidden(live_rings[i], !driven);
        lv_obj_set_hidden(grips[i], !used);
        lv_obj_set_hidden(kind_labels[i], !used);
        if (!used)
        {
            continue;
        }
        // While a pattern or reaction drives it, the ring (dimmed) and its
        // knob set how high it goes, and the thin ring inside shows the level.
        const toy_channel_t *ch = toys_channel(first_channel(controls[i].channels));
        shown_levels[i] = ch->level;
        shown_outs[i] = ch->out;
        shown_driven[i] = driven;
        lv_arc_set_range(rings[i], 0, TOYS_LEVEL_TOP);
        if (lv_arc_get_value(rings[i]) != ch->level)
        {
            lv_arc_set_value(rings[i], ch->level);
        }
        lv_obj_set_style_arc_opa(rings[i], driven ? LV_OPA_40 : LV_OPA_COVER, LV_PART_INDICATOR);
        lv_arc_set_range(live_rings[i], 0, TOYS_LEVEL_TOP);
        lv_arc_set_value(live_rings[i], ch->out);
        place_knob_label((uint8_t)i);
        if (relayout)
        {
            lv_label_set_text(kind_labels[i], controls[i].label[0] != '\0' ? controls[i].label : "-");
            // At the ring's 0 end, inside the gap at the bottom
            int32_t r = ring_mid_radius((uint8_t)i);
            int32_t x = (r * lv_trigo_cos(RING_START)) >> LV_TRIGO_SHIFT;
            int32_t y = (r * lv_trigo_sin(RING_START)) >> LV_TRIGO_SHIFT;
            lv_obj_align(kind_labels[i], LV_ALIGN_LEFT_MID, ui_px(120) + x + ui_px(14), y);
        }
    }

    if (any)
    {
        if (relayout)
        {
            layout_middle(control_count);
        }
        // The toy's name, or how many
        const toy_t *only = NULL;
        for (size_t i = 0; i < TOYS_MAX_DEVICES && only == NULL; i++)
        {
            const toy_t *t = toys_device(i);
            only = t != NULL && t->state == TOY_CONNECTED ? t : NULL;
        }
        if (connected == 1 && only != NULL)
        {
            lv_label_set_text(name_label, only->model);
        }
        else
        {
            lv_label_set_text_fmt(name_label, "%u toys", (unsigned)connected);
        }
        if (status[0] != '\0')
        {
            lv_label_set_text(battery_label, status);
        }
        else if (pattern >= 0)
        {
            lv_label_set_text_fmt(battery_label, LV_SYMBOL_PLAY " %s", patterns_name((size_t)pattern));
        }
        else if (battery >= 0)
        {
            lv_label_set_text_fmt(battery_label, LV_SYMBOL_BATTERY_FULL " %d%%", battery);
        }
        else
        {
            lv_label_set_text(battery_label, "");
        }
    }
}

static void grip_event_cb(lv_event_t *e)
{
    int i = (int)(intptr_t)lv_event_get_user_data(e);
    if (i >= control_count)
    {
        return;
    }
    uint8_t channels = controls[i].channels;
    lv_event_code_t code = lv_event_get_code(e);
    if (code == LV_EVENT_PRESSING)
    {
        lv_point_t p;
        lv_indev_get_point(lv_indev_active(), &p);
        int32_t level = level_at((uint8_t)i, &p);
        if (level == lv_arc_get_value(rings[i]))
        {
            return;
        }
        lv_arc_set_value(rings[i], level);
        toys_set_level(channels, (uint8_t)level);
    }
    else if (settings_get()->toy_release_to_zero && !any_driven(channels))
    {
        // Let go, with Hold off: back to 0 (but a pattern or reaction keeps its level)
        lv_arc_set_value(rings[i], 0);
        toys_set_level(channels, 0);
    }
    place_knob_label((uint8_t)i);
    show_control();
}

static void stop_event_cb(lv_event_t *e)
{
    toys_stop_all();
    show_control();
}

/* A round, dark button that doesn't pass drags on to the page, so a finger
 * that moves a little still counts as a press. */
static lv_obj_t *add_round_button(lv_obj_t *page, const char *text, lv_color_t color)
{
    lv_obj_t *button = lv_button_create(page);
    lv_obj_set_style_radius(button, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(button, color, 0);
    lv_obj_set_style_shadow_width(button, 0, 0);
    lv_obj_set_scroll_chain(button, false);
    lv_obj_t *label = lv_label_create(button);
    lv_label_set_text(label, text);
    lv_obj_center(label);
    return button;
}

static lv_obj_t *add_ring(lv_obj_t *page, uint8_t index)
{
    lv_color_t color = lv_palette_main(ring_colors[index]);
    int32_t size = ui_px(RING_OUTER - RING_STEP * index);
    lv_obj_t *arc = lv_arc_create(page);
    lv_obj_set_size(arc, size, size);
    lv_arc_set_bg_angles(arc, RING_START, (RING_START + RING_SWEEP) % 360);
    lv_arc_set_value(arc, 0);
    lv_obj_set_style_pad_all(arc, 0, LV_PART_MAIN);
    lv_obj_set_style_arc_width(arc, ui_px(RING_WIDTH), LV_PART_MAIN);
    lv_obj_set_style_arc_width(arc, ui_px(RING_WIDTH), LV_PART_INDICATOR);
    lv_obj_set_style_arc_color(arc, COLOR_TRACK, LV_PART_MAIN);
    lv_obj_set_style_arc_color(arc, color, LV_PART_INDICATOR);
    lv_obj_set_style_bg_color(arc, lv_color_white(), LV_PART_KNOB);
    lv_obj_set_style_pad_all(arc, ui_px(KNOB_PAD), LV_PART_KNOB);
    lv_obj_set_style_shadow_width(arc, ui_px(8), LV_PART_KNOB);
    lv_obj_set_style_shadow_color(arc, color, LV_PART_KNOB);
    lv_obj_set_style_shadow_opa(arc, LV_OPA_60, LV_PART_KNOB);
    lv_obj_center(arc);
    // The ring only shows the level. Its grip (below) is what's dragged, so
    // swipes that start anywhere else move between pages.
    lv_obj_set_clickable(arc, false);
    return arc;
}

/* A thin ring along the middle of ring index, showing only its level. */
static lv_obj_t *add_live_ring(lv_obj_t *page, uint8_t index)
{
    int32_t inset = (ui_px(RING_WIDTH) - ui_px(4)) / 2;
    int32_t size = ui_px(RING_OUTER - RING_STEP * index) - 2 * inset;
    lv_obj_t *arc = lv_arc_create(page);
    lv_obj_set_size(arc, size, size);
    lv_arc_set_bg_angles(arc, RING_START, (RING_START + RING_SWEEP) % 360);
    lv_obj_set_style_pad_all(arc, 0, LV_PART_MAIN);
    lv_obj_set_style_arc_opa(arc, LV_OPA_TRANSP, LV_PART_MAIN);
    lv_obj_set_style_arc_width(arc, ui_px(4), LV_PART_INDICATOR);
    lv_obj_set_style_arc_color(arc, lv_palette_lighten(ring_colors[index], 3), LV_PART_INDICATOR);
    lv_obj_set_style_opa(arc, LV_OPA_TRANSP, LV_PART_KNOB);
    lv_obj_center(arc);
    lv_obj_set_clickable(arc, false);
    lv_obj_set_hidden(arc, true);
    return arc;
}

static lv_obj_t *add_dark_page(ui_feature_t *feature, const char *name)
{
    lv_obj_t *page = ui_feature_add_page(feature, name, true);
    lv_obj_set_scrollable(page, false);
    lv_obj_set_style_text_color(page, lv_color_white(), 0);
    return page;
}

static void add_control_page(ui_feature_t *feature)
{
    control_page = add_dark_page(feature, "Control");

    for (uint8_t i = 0; i < TOYS_SCREEN_CONTROLS; i++)
    {
        rings[i] = add_ring(control_page, i);
        live_rings[i] = add_live_ring(control_page, i);
        kind_labels[i] = lv_label_create(control_page);
        lv_obj_set_style_text_color(kind_labels[i], lv_palette_lighten(ring_colors[i], 1), 0);
    }
    // A grip over each knob, over all the rings, with the level on it. It
    // doesn't pass drags on to the page, so dragging it only turns the ring.
    for (uint8_t i = 0; i < TOYS_SCREEN_CONTROLS; i++)
    {
        grips[i] = lv_obj_create(control_page);
        lv_obj_remove_style_all(grips[i]);
        lv_obj_set_size(grips[i], ui_px(2 * KNOB_REACH), ui_px(2 * KNOB_REACH));
        lv_obj_set_scrollable(grips[i], false);
        lv_obj_set_scroll_chain(grips[i], false);
        lv_obj_add_event_cb(grips[i], grip_event_cb, LV_EVENT_PRESSING, (void *)(intptr_t)i);
        lv_obj_add_event_cb(grips[i], grip_event_cb, LV_EVENT_RELEASED, (void *)(intptr_t)i);
        lv_obj_add_event_cb(grips[i], grip_event_cb, LV_EVENT_PRESS_LOST, (void *)(intptr_t)i);
        knob_labels[i] = lv_label_create(grips[i]);
        lv_obj_set_style_text_color(knob_labels[i], lv_color_black(), 0);
        lv_obj_center(knob_labels[i]);
    }

    nothing_title = lv_label_create(control_page);
    lv_label_set_text(nothing_title, "Toys");
    lv_obj_align(nothing_title, LV_ALIGN_TOP_MID, 0, ui_px(32));

    nothing_label = lv_label_create(control_page);
    lv_label_set_text(nothing_label, "Nothing connected\n\nSwipe left to\nfind a toy");
    lv_obj_set_style_text_align(nothing_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(nothing_label, COLOR_MUTED, 0);
    lv_obj_center(nothing_label);

    name_label = lv_label_create(control_page);
    lv_label_set_long_mode(name_label, LV_LABEL_LONG_MODE_DOTS);
    lv_obj_set_style_text_align(name_label, LV_TEXT_ALIGN_CENTER, 0);

    battery_label = lv_label_create(control_page);
    lv_obj_set_style_text_color(battery_label, COLOR_MUTED, 0);

    // Stops on the touch itself rather than the release, so it can't be
    // lost to a swipe.
    stop_button = add_round_button(control_page, "STOP", lv_palette_darken(LV_PALETTE_RED, 1));
    lv_obj_add_event_cb(stop_button, stop_event_cb, LV_EVENT_PRESSED, NULL);
}

/* ----- Patterns page ----- */

static lv_obj_t *patterns_page;
static lv_obj_t *target_label;
static lv_obj_t *target_prev;
static lv_obj_t *target_next;
static lv_obj_t **pattern_rows;
static lv_obj_t **pattern_row_labels;
static int8_t *pattern_row_shown;      // -1 unknown, 0 stopped, 1 playing
static size_t pattern_row_count;
static lv_obj_t *speed_label;
static int target = -1;                // the control patterns play on, or -1 for every channel
static int shown_target = -2;
static size_t shown_target_connected = (size_t)-1;
static uint32_t pattern_notice_until;
static int shown_speed = -1;

/* The channels patterns play on: the target control's, or every channel. */
static uint8_t target_channels(void)
{
    return target >= 0 && target < control_count ? controls[target].channels : TOYS_ALL_CHANNELS;
}

/* Whether pattern p is playing on the target's channels: on every one a toy
 * follows, or on every one of the control's. */
static bool playing_on_target(int p)
{
    uint8_t channels = target_channels();
    if (target < 0)
    {
        channels &= toys_channels_mapped();
    }
    bool any = false;
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        if (channels & (1u << c))
        {
            if (toys_channel(c)->pattern != p)
            {
                return false;
            }
            any = true;
        }
    }
    return any;
}

static void show_patterns(void)
{
    size_t connected = toys_connected_count();
    if (connected == 0 || toys_layout_changes() != shown_layout)
    {
        control_count = connected > 0 ? toys_screen_controls(controls) : 0;
        shown_valid = false;
    }
    if (target >= control_count)
    {
        target = -1;
    }
    if ((target != shown_target || connected != shown_target_connected)
        && (int32_t)(lv_tick_get() - pattern_notice_until) >= 0)
    {
        shown_target = target;
        shown_target_connected = connected;
        if (connected == 0)
        {
            lv_label_set_text(target_label, "Nothing connected");
        }
        else if (target >= 0)
        {
            lv_label_set_text(target_label, controls[target].label);
        }
        else
        {
            lv_label_set_text(target_label, "Every channel");
        }
        lv_obj_set_hidden(target_prev, control_count < 2);
        lv_obj_set_hidden(target_next, control_count < 2);
    }

    for (size_t i = 0; i < pattern_row_count; i++)
    {
        int8_t playing = playing_on_target((int)i);
        if (playing == pattern_row_shown[i])
        {
            continue;
        }
        pattern_row_shown[i] = playing;
        if (playing)
        {
            lv_label_set_text_fmt(pattern_row_labels[i], LV_SYMBOL_PLAY "  %s", patterns_name(i));
        }
        else
        {
            lv_label_set_text(pattern_row_labels[i], patterns_name(i));
        }
        lv_color_t color = lv_palette_main(LV_PALETTE_PINK);
        lv_obj_set_style_border_color(pattern_rows[i], playing ? color : COLOR_OUTLINE, 0);
        lv_obj_set_style_text_color(pattern_row_labels[i], playing ? color : lv_color_white(), 0);
    }
    if (toys_speed(target_channels()) != shown_speed)
    {
        shown_speed = toys_speed(target_channels());
        lv_label_set_text_fmt(speed_label, "Speed %d%%", shown_speed);
    }
}

static void pattern_row_event_cb(lv_event_t *e)
{
    int p = (int)(intptr_t)lv_event_get_user_data(e);
    if (toys_connected_count() == 0)
    {
        lv_label_set_text(target_label, "Connect one first");
        pattern_notice_until = lv_tick_get() + NOTICE_MS;
        shown_target = -2;
        return;
    }
    toys_play(target_channels(), playing_on_target(p) ? -1 : p);
    show_patterns();
}

/* Every channel, then each control, and round again. */
static void target_event_cb(lv_event_t *e)
{
    int step = (int)(intptr_t)lv_event_get_user_data(e);
    int count = control_count + 1;
    target = (target + 1 + step + count) % count - 1;
    for (size_t i = 0; i < pattern_row_count; i++)
    {
        pattern_row_shown[i] = -1;
    }
    show_patterns();
}

static void speed_event_cb(lv_event_t *e)
{
    int step = (int)(intptr_t)lv_event_get_user_data(e);
    uint8_t channels = target_channels();
    toys_set_speed(channels, (uint16_t)LV_CLAMP(TOYS_SPEED_MIN, (int)toys_speed(channels) + step * 25, TOYS_SPEED_MAX));
    show_patterns();
}

static void add_patterns_page(ui_feature_t *feature)
{
    patterns_page = add_dark_page(feature, "Patterns");

    // Which channels: at the top, with arrows to step through the controls
    target_label = lv_label_create(patterns_page);
    lv_label_set_long_mode(target_label, LV_LABEL_LONG_MODE_DOTS);
    lv_obj_set_width(target_label, ui_px(110));
    lv_obj_set_style_text_align(target_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(target_label, COLOR_MUTED, 0);
    lv_obj_align(target_label, LV_ALIGN_TOP_MID, 0, ui_px(30));
    target_prev = add_round_button(patterns_page, LV_SYMBOL_LEFT, COLOR_SURFACE);
    lv_obj_set_size(target_prev, ui_px(24), ui_px(24));
    lv_obj_align(target_prev, LV_ALIGN_TOP_MID, ui_px(-70), ui_px(26));
    lv_obj_add_event_cb(target_prev, target_event_cb, LV_EVENT_CLICKED, (void *)(intptr_t)-1);
    target_next = add_round_button(patterns_page, LV_SYMBOL_RIGHT, COLOR_SURFACE);
    lv_obj_set_size(target_next, ui_px(24), ui_px(24));
    lv_obj_align(target_next, LV_ALIGN_TOP_MID, ui_px(70), ui_px(26));
    lv_obj_add_event_cb(target_next, target_event_cb, LV_EVENT_CLICKED, (void *)(intptr_t)1);

    lv_obj_t *list = lv_obj_create(patterns_page);
    lv_obj_remove_style_all(list);
    lv_obj_set_size(list, ui_px(180), ui_px(116));
    lv_obj_align(list, LV_ALIGN_CENTER, 0, ui_px(-6));
    lv_obj_set_flex_flow(list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(list, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_row(list, ui_px(8), 0);
    lv_obj_set_scroll_dir(list, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(list, LV_SCROLLBAR_MODE_OFF);

    pattern_row_count = patterns_count();
    pattern_rows = lv_malloc(pattern_row_count * sizeof(lv_obj_t *));
    pattern_row_labels = lv_malloc(pattern_row_count * sizeof(lv_obj_t *));
    pattern_row_shown = lv_malloc(pattern_row_count);
    if (pattern_rows == NULL || pattern_row_labels == NULL || pattern_row_shown == NULL)
    {
        pattern_row_count = 0;
    }
    for (size_t i = 0; i < pattern_row_count; i++)
    {
        lv_obj_t *row = lv_button_create(list);
        lv_obj_set_size(row, ui_px(176), ui_px(30));
        lv_obj_set_style_radius(row, LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_bg_color(row, COLOR_SURFACE, 0);
        lv_obj_set_style_bg_color(row, COLOR_OUTLINE, LV_STATE_PRESSED);
        lv_obj_set_style_border_width(row, LV_MAX(1, ui_px(1)), 0);
        lv_obj_set_style_border_color(row, COLOR_OUTLINE, 0);
        lv_obj_set_style_shadow_width(row, 0, 0);
        lv_obj_add_event_cb(row, pattern_row_event_cb, LV_EVENT_CLICKED, (void *)(intptr_t)i);
        lv_obj_t *label = lv_label_create(row);
        lv_label_set_long_mode(label, LV_LABEL_LONG_MODE_DOTS);
        lv_obj_set_width(label, ui_px(156));
        lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_CENTER, 0);
        lv_obj_center(label);
        pattern_rows[i] = row;
        pattern_row_labels[i] = label;
        pattern_row_shown[i] = -1;
    }

    // Speed, under the list
    lv_obj_t *slower = add_round_button(patterns_page, LV_SYMBOL_MINUS, COLOR_SURFACE);
    lv_obj_set_size(slower, ui_px(28), ui_px(28));
    lv_obj_align(slower, LV_ALIGN_CENTER, ui_px(-62), ui_px(76));
    lv_obj_add_event_cb(slower, speed_event_cb, LV_EVENT_CLICKED, (void *)(intptr_t)-1);
    lv_obj_t *faster = add_round_button(patterns_page, LV_SYMBOL_PLUS, COLOR_SURFACE);
    lv_obj_set_size(faster, ui_px(28), ui_px(28));
    lv_obj_align(faster, LV_ALIGN_CENTER, ui_px(62), ui_px(76));
    lv_obj_add_event_cb(faster, speed_event_cb, LV_EVENT_CLICKED, (void *)(intptr_t)1);
    speed_label = lv_label_create(patterns_page);
    lv_obj_set_style_text_color(speed_label, COLOR_MUTED, 0);
    lv_obj_align(speed_label, LV_ALIGN_CENTER, 0, ui_px(76));
}

/* ----- React page ----- */

static lv_obj_t *react_page;
static lv_obj_t *react_rows[REACTIVE_COUNT];
static lv_obj_t *react_row_labels[REACTIVE_COUNT];
static lv_obj_t *react_status;
static uint32_t shown_reactions = UINT32_MAX;
static char shown_react_status[40];

/* Each reaction that's followed is lit: different channels may follow
 * different ones, from the app. */
static void show_react(void)
{
    uint32_t modes = toys_reactions();
    if (modes != shown_reactions)
    {
        shown_reactions = modes;
        for (int i = 0; i < REACTIVE_COUNT; i++)
        {
            if (react_rows[i] == NULL)
            {
                continue;
            }
            bool on = (modes & (1u << i)) != 0;
            lv_color_t color = lv_palette_main(LV_PALETTE_PINK);
            lv_obj_set_style_border_color(react_rows[i], on ? color : COLOR_OUTLINE, 0);
            lv_obj_set_style_text_color(react_row_labels[i], on ? color : lv_color_white(), 0);
        }
    }
    char status[40];
    uint8_t mode = toys_reaction();
    if (mode == REACTIVE_OFF)
    {
        snprintf(status, sizeof(status), "%s", toys_connected_count() > 0 ? "" : "Connect a toy first");
    }
    else
    {
        reactive_status((reactive_mode_t)mode, status, sizeof(status));
    }
    if (strcmp(status, shown_react_status) != 0)
    {
        strcpy(shown_react_status, status);
        lv_label_set_text(react_status, status);
    }
}

/* On every channel; tapping one that's followed stops it. */
static void react_row_event_cb(lv_event_t *e)
{
    reactive_mode_t mode = (reactive_mode_t)(intptr_t)lv_event_get_user_data(e);
    uint8_t followed = 0;
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        if (toys_channel(c)->react == mode)
        {
            followed |= 1u << c;
        }
    }
    if (followed != 0)
    {
        toys_react(followed, REACTIVE_OFF);
    }
    else
    {
        toys_react(TOYS_ALL_CHANNELS, mode);
    }
    show_react();
}

static void add_react_page(ui_feature_t *feature)
{
    react_page = add_dark_page(feature, "React");

    lv_obj_t *title = lv_label_create(react_page);
    lv_label_set_text(title, "React to");
    lv_obj_set_style_text_color(title, COLOR_MUTED, 0);
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, ui_px(28));

    lv_obj_t *list = lv_obj_create(react_page);
    lv_obj_remove_style_all(list);
    lv_obj_set_size(list, ui_px(180), ui_px(130));
    lv_obj_align(list, LV_ALIGN_CENTER, 0, ui_px(-2));
    lv_obj_set_flex_flow(list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(list, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_row(list, ui_px(8), 0);
    lv_obj_set_scroll_dir(list, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(list, LV_SCROLLBAR_MODE_OFF);

    // Off isn't listed: tapping the one that's on turns it off.
    for (int i = REACTIVE_OFF + 1; i < REACTIVE_COUNT; i++)
    {
        if (!reactive_available((reactive_mode_t)i))
        {
            continue;   // no microphone, or no accelerometer
        }
        lv_obj_t *row = lv_button_create(list);
        lv_obj_set_size(row, ui_px(176), ui_px(30));
        lv_obj_set_style_radius(row, LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_bg_color(row, COLOR_SURFACE, 0);
        lv_obj_set_style_bg_color(row, COLOR_OUTLINE, LV_STATE_PRESSED);
        lv_obj_set_style_border_width(row, LV_MAX(1, ui_px(1)), 0);
        lv_obj_set_style_border_color(row, COLOR_OUTLINE, 0);
        lv_obj_set_style_shadow_width(row, 0, 0);
        lv_obj_add_event_cb(row, react_row_event_cb, LV_EVENT_CLICKED, (void *)(intptr_t)i);
        lv_obj_t *label = lv_label_create(row);
        lv_label_set_text(label, reactive_name((reactive_mode_t)i));
        lv_obj_center(label);
        react_rows[i] = row;
        react_row_labels[i] = label;
    }

    react_status = lv_label_create(react_page);
    lv_label_set_text(react_status, "");
    lv_obj_set_style_text_color(react_status, COLOR_MUTED, 0);
    lv_obj_align(react_status, LV_ALIGN_CENTER, 0, ui_px(84));
}

/* ----- Devices page ----- */

static void show_notice(const char *text)
{
    lv_label_set_text(devices_status, text);
    notice_until = lv_tick_get() + NOTICE_MS;
}

static void show_devices(void)
{
    bool any = false;
    for (size_t i = 0; i < TOYS_MAX_DEVICES; i++)
    {
        const toy_t *d = toys_device(i);
        lv_obj_set_hidden(device_rows[i], d == NULL);
        if (d == NULL)
        {
            row_texts[i][0] = '\0';
            continue;
        }
        any = true;

        char text[sizeof(row_texts[0])];
        switch (d->state)
        {
        case TOY_CONNECTING:
            snprintf(text, sizeof(text), "%s  ...", d->name);
            break;
        case TOY_CONNECTED:
            if (d->battery >= 0)
            {
                snprintf(text, sizeof(text), LV_SYMBOL_OK "  %s  %d%%", d->model, d->battery);
            }
            else
            {
                snprintf(text, sizeof(text), LV_SYMBOL_OK "  %s", d->model);
            }
            break;
        case TOY_FAILED:
            snprintf(text, sizeof(text), "%s  failed", d->name);
            break;
        case TOY_LOST:
            snprintf(text, sizeof(text), "%s  lost", d->name);
            break;
        default:
            snprintf(text, sizeof(text), "%s", d->name);
            break;
        }
        if (strcmp(text, row_texts[i]) != 0)
        {
            strcpy(row_texts[i], text);
            lv_label_set_text(device_row_labels[i], text);
            bool on = d->state == TOY_CONNECTED;
            lv_obj_set_style_border_color(device_rows[i], on ? COLOR_CONNECTED : COLOR_OUTLINE, 0);
            lv_obj_set_style_text_color(device_row_labels[i], on ? COLOR_CONNECTED : lv_color_white(), 0);
        }
    }

    if ((int32_t)(lv_tick_get() - notice_until) < 0)
    {
        return;     // a notice is still up
    }
    if (no_bluetooth)
    {
        lv_label_set_text(devices_status, "No Bluetooth");
    }
    else if (toys_scanning())
    {
        lv_label_set_text(devices_status, any ? "Tap to connect" : "Searching...");
    }
    else
    {
        lv_label_set_text(devices_status, "");
    }
}

static void device_row_event_cb(lv_event_t *e)
{
    size_t slot = (size_t)(intptr_t)lv_event_get_user_data(e);
    const toy_t *d = toys_device(slot);
    if (d == NULL)
    {
        return;
    }
    bool connecting = d->state != TOY_CONNECTING && d->state != TOY_CONNECTED;
    if (!toys_toggle(slot) && connecting)
    {
        show_notice(toys_connected_count() >= TOYS_MAX_CONNECTED ? "Only 3 at once" : "Wait for the other one");
    }
    show_devices();
}

static void add_devices_page(ui_feature_t *feature)
{
    devices_page = add_dark_page(feature, "Devices");

    lv_obj_t *title = lv_label_create(devices_page);
    lv_label_set_text(title, "Devices");
    lv_obj_set_style_text_color(title, COLOR_MUTED, 0);
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, ui_px(28));

    lv_obj_t *list = lv_obj_create(devices_page);
    lv_obj_remove_style_all(list);
    lv_obj_set_size(list, ui_px(180), ui_px(136));
    lv_obj_align(list, LV_ALIGN_CENTER, 0, ui_px(-2));
    lv_obj_set_flex_flow(list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(list, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_row(list, ui_px(8), 0);
    lv_obj_set_scroll_dir(list, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(list, LV_SCROLLBAR_MODE_OFF);

    for (size_t i = 0; i < TOYS_MAX_DEVICES; i++)
    {
        lv_obj_t *row = lv_button_create(list);
        lv_obj_set_size(row, ui_px(176), ui_px(30));
        lv_obj_set_style_radius(row, LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_bg_color(row, COLOR_SURFACE, 0);
        lv_obj_set_style_bg_color(row, COLOR_OUTLINE, LV_STATE_PRESSED);
        lv_obj_set_style_border_width(row, LV_MAX(1, ui_px(1)), 0);
        lv_obj_set_style_border_color(row, COLOR_OUTLINE, 0);
        lv_obj_set_style_shadow_width(row, 0, 0);
        lv_obj_add_event_cb(row, device_row_event_cb, LV_EVENT_CLICKED, (void *)(intptr_t)i);
        device_row_labels[i] = lv_label_create(row);
        lv_label_set_long_mode(device_row_labels[i], LV_LABEL_LONG_MODE_DOTS);
        lv_obj_set_width(device_row_labels[i], ui_px(156));
        lv_obj_set_style_text_align(device_row_labels[i], LV_TEXT_ALIGN_CENTER, 0);
        lv_obj_center(device_row_labels[i]);
        lv_obj_set_hidden(row, true);
        device_rows[i] = row;
    }

    devices_status = lv_label_create(devices_page);
    lv_label_set_text(devices_status, "");
    lv_obj_set_style_text_color(devices_status, COLOR_MUTED, 0);
    lv_obj_align(devices_status, LV_ALIGN_CENTER, 0, ui_px(84));
}

/* ----- Options page ----- */

static void hold_event_cb(lv_event_t *e)
{
    bool hold = lv_obj_has_state(lv_event_get_target_obj(e), LV_STATE_CHECKED);
    settings_set_toy_release_to_zero(!hold);
}

static void add_options_page(ui_feature_t *feature)
{
    lv_obj_t *page = add_dark_page(feature, "Options");

    lv_obj_t *label = lv_label_create(page);
    lv_label_set_text(label, "Hold");
    lv_obj_align(label, LV_ALIGN_CENTER, 0, ui_px(-34));

    lv_obj_t *hold_switch = lv_switch_create(page);
    lv_obj_set_size(hold_switch, ui_px(96), ui_px(48));
    lv_obj_set_style_bg_color(hold_switch, COLOR_TRACK, LV_PART_MAIN);
    lv_obj_set_style_bg_color(hold_switch, lv_palette_main(LV_PALETTE_PINK), LV_PART_INDICATOR | LV_STATE_CHECKED);
    if (!settings_get()->toy_release_to_zero)
    {
        lv_obj_add_state(hold_switch, LV_STATE_CHECKED);
    }
    lv_obj_align(hold_switch, LV_ALIGN_CENTER, 0, ui_px(12));
    lv_obj_add_event_cb(hold_switch, hold_event_cb, LV_EVENT_VALUE_CHANGED, NULL);
}

/* ----- Running it ----- */

static void poll_timer_cb(lv_timer_t *t)
{
    uint32_t now = lv_tick_get();
    reactive_poll(now, toys_reactions());
    toys_poll(now);
    lv_obj_t *page = ui_current_page();
    if (page == control_page)
    {
        show_control();
    }
    else if (page == patterns_page)
    {
        show_patterns();
    }
    else if (page == react_page)
    {
        show_react();
    }
    else if (page == devices_page)
    {
        show_devices();
    }
}

/* Look for devices only while the devices page is on screen. */
static void on_navigate(void)
{
    if (ui_current_page() == devices_page)
    {
        if (!toys_scanning() && !toys_scan_start())
        {
            no_bluetooth = true;
        }
        show_devices();
    }
    else
    {
        toys_scan_stop();
        if (ui_current_page() == control_page)
        {
            shown_valid = false;    // redraw it all
            show_control();
        }
        else if (ui_current_page() == patterns_page)
        {
            shown_target = -2;
            show_patterns();
        }
    }
}

static bool build(ui_feature_t *feature)
{
    lv_obj_t *vis_page = add_dark_page(feature, "Toy Visualizer");
    if (!toys_vis_add(vis_page))
    {
        lv_obj_t *label = lv_label_create(vis_page);
        lv_label_set_text(label, "No room");
        lv_obj_center(label);
    }
    ui_add_startup_choice(feature, vis_page, "Toy Visualizer", SETTINGS_STARTUP_TOYS);
    add_control_page(feature);
    add_devices_page(feature);
    add_patterns_page(feature);
    add_react_page(feature);
    add_options_page(feature);
    ui_others_page_add(feature, OTHERS_VIBE);
    show_control();
    lv_timer_create(poll_timer_cb, POLL_MS, NULL);
    return true;
}
