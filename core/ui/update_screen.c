/*
 * While the app updates the firmware: a screen of its own over everything,
 * with how far it's got, the versions, and how fast it's coming, which says
 * whether the link's good (see app/updater.h).
 */
#include "ui/update_screen.h"

#include <stdio.h>

#include "app/updater.h"
#include "lvgl.h"
#include "ui/ui_internal.h"

#define POLL_MS     200

/* While an update's going, the unit's out of service: every other timer's
 * paused (the screens, the visualizer, toys, the battery log...) and the
 * page beneath hidden, so the loop spends its time on what comes in, and
 * draws only this. Those it paused go again if the update stops; if it
 * works, the unit restarts anyway. */
#define MAX_PAUSED  64
static lv_timer_t *own_timer;
static lv_timer_t *paused[MAX_PAUSED];
static size_t paused_count;
static lv_obj_t *hidden_screen;

static bool keep_running(lv_timer_t *t)
{
    if (t == own_timer || t == feature_settings_comm_timer() || updater_owns_timer(t))
    {
        return true;
    }
    for (lv_display_t *d = lv_display_get_next(NULL); d != NULL; d = lv_display_get_next(d))
    {
        if (t == lv_display_get_refr_timer(d))
        {
            return true;
        }
    }
    for (lv_indev_t *i = lv_indev_get_next(NULL); i != NULL; i = lv_indev_get_next(i))
    {
        if (t == lv_indev_get_read_timer(i))
        {
            return true;
        }
    }
    return false;
}

static void quiet_ui(bool on)
{
    if (on)
    {
        paused_count = 0;
        for (lv_timer_t *t = lv_timer_get_next(NULL); t != NULL; t = lv_timer_get_next(t))
        {
            if (!keep_running(t) && !lv_timer_get_paused(t) && paused_count < MAX_PAUSED)
            {
                lv_timer_pause(t);
                paused[paused_count++] = t;
            }
        }
        hidden_screen = lv_screen_active();
        lv_obj_set_hidden(hidden_screen, true);
    }
    else
    {
        for (size_t i = 0; i < paused_count; i++)
        {
            lv_timer_resume(paused[i]);
        }
        paused_count = 0;
        if (hidden_screen != NULL)
        {
            lv_obj_set_hidden(hidden_screen, false);
            hidden_screen = NULL;
        }
    }
}
#define COLOR_MUTED lv_palette_main(LV_PALETTE_GREY)

static lv_obj_t *panel;
static lv_obj_t *title;
static lv_obj_t *bar;
static lv_obj_t *percent;
static lv_obj_t *versions;
static lv_obj_t *rate;

/* The big text, where there's a big font, as the 1.75" board has. */
static void set_big(lv_obj_t *label)
{
#if LV_FONT_MONTSERRAT_32
    if (lv_display_get_horizontal_resolution(NULL) >= 360)
    {
        lv_obj_set_style_text_font(label, &lv_font_montserrat_32, 0);
    }
#else
    (void)label;
#endif
}

static lv_obj_t *add_label(lv_color_t color)
{
    lv_obj_t *label = lv_label_create(panel);
    lv_obj_set_width(label, ui_px(196));    // inside the round screen
    lv_label_set_long_mode(label, LV_LABEL_LONG_WRAP);
    lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(label, color, 0);
    lv_label_set_text(label, "");
    return label;
}

static void create(void)
{
    panel = lv_obj_create(lv_layer_top());
    lv_obj_set_size(panel, LV_PCT(100), LV_PCT(100));
    lv_obj_center(panel);
    lv_obj_set_style_bg_color(panel, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(panel, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(panel, 0, 0);
    lv_obj_set_style_radius(panel, 0, 0);
    lv_obj_set_scrollable(panel, false);
    lv_obj_set_clickable(panel, true);     // nothing beneath it reacts meanwhile
    // A column down the middle, whatever the text's size
    lv_obj_set_flex_flow(panel, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(panel, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_row(panel, ui_px(8), 0);

    title = add_label(lv_color_white());
    set_big(title);

    bar = lv_bar_create(panel);
    lv_obj_set_size(bar, ui_px(170), ui_px(14));
    lv_bar_set_range(bar, 0, 1000);
    lv_obj_set_style_bg_color(bar, lv_palette_darken(LV_PALETTE_GREY, 3), LV_PART_MAIN);
    lv_obj_set_style_bg_color(bar, lv_palette_main(LV_PALETTE_PINK), LV_PART_INDICATOR);

    percent = add_label(lv_color_white());
    set_big(percent);
    versions = add_label(COLOR_MUTED);
    rate = add_label(COLOR_MUTED);
}

static void poll_cb(lv_timer_t *t)
{
    update_progress_t p;
    updater_progress(&p);
    if (p.show == UPDATE_SHOW_NONE)
    {
        if (panel != NULL)
        {
            lv_obj_delete(panel);
            panel = NULL;
            quiet_ui(false);
        }
        return;
    }
    if (panel == NULL)
    {
        create();
        quiet_ui(true);
    }
    lv_label_set_text(title, p.show == UPDATE_SHOW_RECEIVING  ? "Downloading Firmware Update..."
                             : p.show == UPDATE_SHOW_INSTALLING ? "Installing Firmware Update..."
                                                                : "Restarting...");
    uint32_t permille = p.total > 0 ? (uint32_t)((uint64_t)p.done * 1000 / p.total) : 0;
    lv_bar_set_value(bar, (int32_t)permille, LV_ANIM_OFF);
    lv_label_set_text_fmt(percent, "%lu%%", (unsigned long)(permille / 10));
    lv_label_set_text_fmt(versions, "%s\n%s %s", p.from, LV_SYMBOL_RIGHT, p.to[0] != '\0' ? p.to : "new firmware");
    if (p.show == UPDATE_SHOW_RECEIVING)
    {
        lv_label_set_text_fmt(rate, "%lu.%lu KB/s", (unsigned long)(p.bytes_per_s / 1024),
                              (unsigned long)(p.bytes_per_s % 1024 * 10 / 1024));
    }
    else
    {
        lv_label_set_text(rate, "");
    }
}

void update_screen_create(void)
{
    own_timer = lv_timer_create(poll_cb, POLL_MS, NULL);
}
