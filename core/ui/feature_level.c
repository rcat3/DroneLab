/*
 * The Level (boards with an accelerometer): a spirit level for lining the
 * display up when it's mounted on the mask, opened from Settings' Setup page.
 * It covers the whole screen, and a swipe in any direction closes it. A line
 * across the screen stays level with the ground, and turns green once the
 * screen is within a degree of it. It assumes the wearer is sitting or
 * standing upright.
 */
#include <math.h>
#include <stdio.h>

#include "hal.h"
#include "ui/ui_internal.h"

#define LEVEL_UPDATE_MS     50
#define LEVEL_SMOOTHING     0.2f    // how much of each new reading to take, to steady the line
#define LEVEL_OK_DEG        1.0f    // green within this
#define LEVEL_CLOSE_DEG     3.0f    // amber within this
#define LEVEL_MIN_G         0.5f    // below this the screen is facing too far up or down to tell

static lv_obj_t *level;            // over everything, while it's open
static lv_obj_t *horizon;
static lv_obj_t *marks[2];
static lv_obj_t *angle_label;
static lv_timer_t *level_timer;
static lv_point_precise_t horizon_points[2];
static float up_x;
static float up_y = -1.0f;

static void set_color(lv_color_t color)
{
    lv_obj_set_style_line_color(horizon, color, 0);
    for (int i = 0; i < 2; i++)
    {
        lv_obj_set_style_bg_color(marks[i], color, 0);
    }
    lv_obj_set_style_text_color(angle_label, color, 0);
}

/********************************************************************************
function:	Read the accelerometer and turn the line to match
parameter:
********************************************************************************/
static void level_timer_cb(lv_timer_t *t)
{
    float x, y, z;
    if (level == NULL || !rcat_hal_accel_read(&x, &y, &z))
    {
        return;
    }

    // At rest the accelerometer points up, away from the ground.
    up_x += (x - up_x) * LEVEL_SMOOTHING;
    up_y += (y - up_y) * LEVEL_SMOOTHING;
    float g = sqrtf(up_x * up_x + up_y * up_y);
    if (g < LEVEL_MIN_G)
    {
        lv_obj_set_hidden(horizon, true);
        lv_label_set_text(angle_label, "Hold upright");
        set_color(lv_color_white());
        return;
    }

    // The line runs at right angles to "up", centered on the screen.
    float half = lv_obj_get_width(level) * 0.4f;
    float dx = -up_y / g * half;
    float dy = up_x / g * half;
    float cx = lv_obj_get_width(level) / 2.0f;
    float cy = lv_obj_get_height(level) / 2.0f;
    horizon_points[0] = (lv_point_precise_t){ cx - dx, cy - dy };
    horizon_points[1] = (lv_point_precise_t){ cx + dx, cy + dy };
    lv_line_set_points(horizon, horizon_points, 2);
    lv_obj_set_hidden(horizon, false);

    float degrees = fabsf(atan2f(up_x, -up_y)) * 180.0f / (float)M_PI;
    char text[16];
    snprintf(text, sizeof(text), "%.1f°", degrees);
    lv_label_set_text(angle_label, text);

    if (degrees <= LEVEL_OK_DEG)
    {
        set_color(lv_palette_main(LV_PALETTE_GREEN));
    }
    else if (degrees <= LEVEL_CLOSE_DEG)
    {
        set_color(lv_palette_main(LV_PALETTE_AMBER));
    }
    else
    {
        set_color(lv_color_white());
    }
}

/* A swipe in any direction closes it: LVGL's gesture, and in case that's
 * missed, the finger having moved far enough by the time it lifts */
static lv_point_t pressed_at;

static void touch_cb(lv_event_t *e)
{
    lv_point_t p;
    lv_indev_get_point(lv_indev_active(), &p);
    switch (lv_event_get_code(e))
    {
    case LV_EVENT_PRESSED:
        pressed_at = p;
        break;
    case LV_EVENT_RELEASED:
        if (LV_ABS(p.x - pressed_at.x) > ui_px(40) || LV_ABS(p.y - pressed_at.y) > ui_px(40))
        {
            level_close();
        }
        break;
    case LV_EVENT_GESTURE:
        level_close();
        break;
    default:
        break;
    }
}

bool level_available(void)
{
#if RCAT_FEATURE_LEVEL
    float x, y, z;
    return rcat_hal_accel_read(&x, &y, &z);
#else
    return false;
#endif
}

bool level_is_open(void)
{
    return level != NULL;
}

void level_open(void)
{
    float x, y, z;
    if (level != NULL || !rcat_hal_accel_read(&x, &y, &z))
    {
        return;
    }
    up_x = x;
    up_y = y;

    // Over the features, so swipes come here, not to the pages under it
    level = lv_obj_create(lv_layer_top());
    lv_obj_remove_style_all(level);
    lv_obj_set_size(level, LV_PCT(100), LV_PCT(100));
    lv_obj_set_style_bg_color(level, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(level, LV_OPA_COVER, 0);
    lv_obj_set_scrollable(level, false);
    lv_obj_set_clickable(level, true);
    // Above the pages, it doesn't get their font from the theme
    lv_obj_set_style_text_font(level, lv_obj_get_style_text_font(lv_screen_active(), 0), 0);
    lv_obj_set_gesture_bubble(level, false);   // or swipes go to the screen under it
    lv_obj_add_event_cb(level, touch_cb, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(level, touch_cb, LV_EVENT_RELEASED, NULL);
    lv_obj_add_event_cb(level, touch_cb, LV_EVENT_GESTURE, NULL);

    // Marks at each side show where the line sits when the screen is level.
    for (int i = 0; i < 2; i++)
    {
        marks[i] = lv_obj_create(level);
        lv_obj_remove_style_all(marks[i]);
        lv_obj_set_size(marks[i], ui_px(16), ui_px(4));
        lv_obj_set_style_bg_opa(marks[i], LV_OPA_COVER, 0);
        lv_obj_align(marks[i], i == 0 ? LV_ALIGN_LEFT_MID : LV_ALIGN_RIGHT_MID, i == 0 ? ui_px(12) : ui_px(-12), 0);
    }

    horizon = lv_line_create(level);
    lv_obj_set_style_line_width(horizon, ui_px(4), 0);
    lv_obj_set_style_line_rounded(horizon, true, 0);

    angle_label = lv_label_create(level);
    lv_label_set_text(angle_label, "");
    lv_obj_align(angle_label, LV_ALIGN_CENTER, 0, ui_px(40));

    lv_obj_t *title = lv_label_create(level);
    lv_label_set_text(title, "Level");
    lv_obj_set_style_text_color(title, lv_palette_main(LV_PALETTE_GREY), 0);
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, ui_px(32));

    lv_obj_t *hint = lv_label_create(level);
    lv_label_set_text(hint, "Swipe to close");
    lv_obj_set_style_text_color(hint, lv_palette_main(LV_PALETTE_GREY), 0);
    lv_obj_align(hint, LV_ALIGN_BOTTOM_MID, 0, ui_px(-32));

    set_color(lv_color_white());
    if (level_timer == NULL)
    {
        level_timer = lv_timer_create(level_timer_cb, LEVEL_UPDATE_MS, NULL);
    }
    lv_timer_resume(level_timer);
    lv_timer_ready(level_timer);
}

void level_close(void)
{
    if (level == NULL)
    {
        return;
    }
    lv_timer_pause(level_timer);
    lv_obj_delete_async(level);     // it may be closing from its own event
    level = NULL;
}
