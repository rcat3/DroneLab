/*
 * Settings feature: settings that apply to the whole display, one per page.
 * Settings that belong to a single feature live with that feature instead.
 *
 * On boards that have the comm channel, the pages after Brightness are the
 * Phone App (the app's Bluetooth link, see app/comm.h) and the phones paired
 * with it. The comm channel's own settings and its talk button are in the
 * Comm feature (feature_comm.c). Then, on boards with WiFi, the WiFi hotspot
 * remote (see app/remote.h): a switch for its hotspot, the QR code that
 * joins it, a new password, and whether it switches itself on at power-up.
 * Then Rotation, the Level, Startup and the battery log, and last, firmware
 * updates.
 */
#include <stdio.h>
#include <string.h>

#include "app/battery.h"
#include "app/battery_log.h"
#include "app/comm.h"
#include "app/remote.h"
#include "app/settings.h"
#include "app/talk_button.h"
#include "app/updater.h"
#include "hal.h"
#include "ui/ui_internal.h"

#define BATTERY_UPDATE_MS 1000
#define REMOTE_POLL_MS    50
#define COMM_POLL_MS      20      // quick, so the Comm screen keeps up with the phone
#define LOG_UPDATE_MS     1000
#define UPTIME_UPDATE_MS  1000
#define UPDATE_POLL_MS    200
#define COLOR_MUTED       lv_palette_main(LV_PALETTE_GREY)

static bool build(ui_feature_t *feature);
static void on_navigate(void);

const ui_feature_def_t feature_settings = {
    .name = "Settings",
    .build = build,
    .on_navigate = on_navigate,
};

static lv_obj_t *battery_label;
static lv_obj_t *brightness_value_label;
static lv_obj_t *brightness_slider;

#define SYNC_MS 250     // how often the pages catch up with the phone remote

/* ----- Brightness (and the battery) ----- */

static void brightness_slider_event_cb(lv_event_t *e)
{
    uint8_t brightness = lv_slider_get_value(brightness_slider);

    lv_label_set_text_fmt(brightness_value_label, "%d%%", brightness);
    lv_obj_align_to(brightness_value_label, brightness_slider, LV_ALIGN_OUT_BOTTOM_MID, 0, ui_px(10));
    rcat_hal_backlight_set(brightness);
    settings_set_brightness(brightness);
}

static const char *battery_symbol(const battery_status_t *b)
{
    if (b->charging)
    {
        return LV_SYMBOL_CHARGE;
    }
    if (b->percent >= 85)
    {
        return LV_SYMBOL_BATTERY_FULL;
    }
    if (b->percent >= 60)
    {
        return LV_SYMBOL_BATTERY_3;
    }
    if (b->percent >= 35)
    {
        return LV_SYMBOL_BATTERY_2;
    }
    if (b->percent >= 10)
    {
        return LV_SYMBOL_BATTERY_1;
    }
    return LV_SYMBOL_BATTERY_EMPTY;
}

static void battery_timer_cb(lv_timer_t *t)
{
    battery_status_t b;
    char label_text[32];

    if (battery_update(&b))
    {
        snprintf(label_text, sizeof(label_text), "%s %d%%  %.2fV", battery_symbol(&b), b.percent, b.volts);
        lv_label_set_text(battery_label, label_text);
    }
    else
    {
        lv_label_set_text(battery_label, "No battery");
    }
}

static lv_obj_t *uptime_label;

/* rcat_hal_firmware_built()'s "Nov 15 2026 01:52:12" as "2026-11-15 01:52". */
static void firmware_built_short(char *out, size_t len)
{
    static const char months[] = "JanFebMarAprMayJunJulAugSepOctNovDec";
    char mon[4] = "";
    int day = 0, year = 0, hour = 0, minute = 0;
    const char *built = rcat_hal_firmware_built();
    if (sscanf(built, "%3s %d %d %d:%d", mon, &day, &year, &hour, &minute) != 5)
    {
        snprintf(out, len, "%s", built);
        return;
    }
    const char *m = strstr(months, mon);
    int month = m != NULL ? (int)(m - months) / 3 + 1 : 0;
    snprintf(out, len, "%04d-%02d-%02d %02d:%02d", year % 10000, month % 100, day % 100, hour % 100, minute % 100);
}

static void uptime_timer_cb(lv_timer_t *t)
{
    // Since the board started; lv_tick_get wraps after 49 days.
    uint32_t minutes = lv_tick_get() / 60000;
    uint32_t hours = minutes / 60;
    if (hours >= 24)
    {
        lv_label_set_text_fmt(uptime_label, "Uptime  %lud %luh %02lum", (unsigned long)(hours / 24),
                              (unsigned long)(hours % 24), (unsigned long)(minutes % 60));
    }
    else
    {
        lv_label_set_text_fmt(uptime_label, "Uptime  %luh %02lum", (unsigned long)hours,
                              (unsigned long)(minutes % 60));
    }
}

static void add_brightness_page(ui_feature_t *feature)
{
    lv_obj_t *page = ui_feature_add_page(feature, "Brightness", false);

    brightness_slider = lv_slider_create(page);
    lv_obj_set_size(brightness_slider, ui_px(180), ui_px(20));   // leaves room for the navigation dots
    lv_slider_set_range(brightness_slider, 1, 100);
    lv_slider_set_value(brightness_slider, settings_get()->brightness, LV_ANIM_OFF);
    lv_obj_center(brightness_slider);
    lv_obj_add_event_cb(brightness_slider, brightness_slider_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

    brightness_value_label = lv_label_create(page);
    lv_label_set_text_fmt(brightness_value_label, "%d%%", settings_get()->brightness);
    lv_obj_align_to(brightness_value_label, brightness_slider, LV_ALIGN_OUT_BOTTOM_MID, 0, ui_px(10));

    lv_obj_t *brightness_label = lv_label_create(page);
    lv_label_set_text(brightness_label, "Brightness");
    lv_obj_align_to(brightness_label, brightness_slider, LV_ALIGN_OUT_TOP_MID, 0, ui_px(-10));

    battery_label = lv_label_create(page);
    lv_label_set_text(battery_label, "");
    lv_obj_align(battery_label, LV_ALIGN_TOP_MID, 0, ui_px(35));

    uptime_label = lv_label_create(page);
    lv_obj_set_style_text_color(uptime_label, COLOR_MUTED, 0);
    lv_obj_align(uptime_label, LV_ALIGN_TOP_MID, 0, ui_px(57));
    lv_timer_t *uptime_timer = lv_timer_create(uptime_timer_cb, UPTIME_UPDATE_MS, NULL);
    lv_timer_ready(uptime_timer);

    // Which firmware this is, and when it was built, to the minute, as
    // 2026-11-15 01:52: short enough to fit low on a round screen
    char built[24];
    firmware_built_short(built, sizeof(built));
    // and the board's MAC address between them, to tell boards apart by
    lv_obj_t *version_label = lv_label_create(page);
    uint8_t mac[6];
    if (rcat_hal_mac_address(mac))
    {
        lv_label_set_text_fmt(version_label, "%s\n%02X:%02X:%02X:%02X:%02X:%02X\n%s", rcat_hal_firmware_version(),
                              mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], built);
    }
    else
    {
        lv_label_set_text_fmt(version_label, "%s\n%s", rcat_hal_firmware_version(), built);
    }
    lv_obj_set_style_text_align(version_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(version_label, COLOR_MUTED, 0);
    lv_obj_align(version_label, LV_ALIGN_CENTER, 0, ui_px(78));

    // Kept up all the time, as on some boards the battery can be plugged in
    // while it's running
    lv_timer_t *timer = lv_timer_create(battery_timer_cb, BATTERY_UPDATE_MS, NULL);
    lv_timer_ready(timer);
}

/* ----- Setup: rotation, model and the Level ----- */

static lv_obj_t *rotation_buttons;
static const char *const rotation_map[] = { "0°", "90°", "180°", "270°", "" };

static void rotation_event_cb(lv_event_t *e)
{
    uint8_t rotation = (uint8_t)lv_buttonmatrix_get_selected_button(rotation_buttons);
    if (rotation <= 3 && rotation != settings_get()->rotation)
    {
        rcat_hal_display_set_rotation(rotation);
        settings_set_rotation(rotation);
    }
}

#if RCAT_SPEAKER_OPTIONAL
// Which housing the board's in: the speaker model, or the low-profile model
// with no speaker. What uses the speaker is set up at startup, so a change
// takes a restart.
static lv_obj_t *model_buttons;
static uint8_t model_at_startup;
static const char *const model_map[] = { "Speaker", "Low-profile", "" };

static void model_restart_cb(lv_event_t *e)
{
    settings_save_now();
    rcat_hal_restart();
}

static void model_later_cb(lv_event_t *e)
{
    lv_msgbox_close(lv_event_get_user_data(e));
}

static void model_event_cb(lv_event_t *e)
{
    uint8_t speaker = lv_buttonmatrix_get_selected_button(model_buttons) == 0 ? SETTINGS_SPEAKER_FITTED
                                                                                : SETTINGS_SPEAKER_NONE;
    if (speaker == settings_get()->speaker)
    {
        return;
    }
    settings_set_speaker(speaker);
    if (speaker == model_at_startup)
    {
        return;     // back as it started
    }
    lv_obj_t *box = lv_msgbox_create(NULL);
    lv_msgbox_add_text(box, "Restart to change\nthe model?");
    lv_obj_t *restart = lv_msgbox_add_footer_button(box, "Restart");
    lv_obj_add_event_cb(restart, model_restart_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *later = lv_msgbox_add_footer_button(box, "Later");
    lv_obj_add_event_cb(later, model_later_cb, LV_EVENT_CLICKED, box);
}
#endif

#if RCAT_FEATURE_LEVEL
static void level_button_cb(lv_event_t *e)
{
    level_open();
}
#endif

static lv_obj_t *add_label(lv_obj_t *page, const char *text, int32_t y)
{
    lv_obj_t *label = lv_label_create(page);
    lv_label_set_text(label, text);
    lv_obj_align(label, LV_ALIGN_CENTER, 0, ui_px(y));
    return label;
}

static void add_setup_page(ui_feature_t *feature)
{
    lv_obj_t *page = ui_feature_add_page(feature, "Setup", false);
#if RCAT_SPEAKER_OPTIONAL
    bool model = true;
#else
    bool model = false;
#endif
#if RCAT_FEATURE_LEVEL
    bool level = level_available();
#else
    bool level = false;
#endif
    // Top to bottom, centered on the round screen
    int32_t y = model ? (level ? -84 : -62) : (level ? -60 : -26);

    add_label(page, "Rotation", y);
    rotation_buttons = ui_add_choices(page, rotation_map, ui_px(196), ui_px(34), ui_px(y + 26));
    ui_check_choice(rotation_buttons, settings_get()->rotation);
    lv_obj_add_event_cb(rotation_buttons, rotation_event_cb, LV_EVENT_VALUE_CHANGED, NULL);
    y += 62;

#if RCAT_SPEAKER_OPTIONAL
    model_at_startup = settings_get()->speaker;
    add_label(page, "Model", y);
    model_buttons = ui_add_choices(page, model_map, ui_px(196), ui_px(34), ui_px(y + 26));
    ui_check_choice(model_buttons, model_at_startup == SETTINGS_SPEAKER_NONE ? 1 : 0);
    lv_obj_add_event_cb(model_buttons, model_event_cb, LV_EVENT_VALUE_CHANGED, NULL);
    y += 62;
#endif

#if RCAT_FEATURE_LEVEL
    if (level)
    {
        lv_obj_t *button = lv_button_create(page);
        lv_obj_set_size(button, ui_px(120), ui_px(36));
        lv_obj_set_style_radius(button, LV_RADIUS_CIRCLE, 0);
        lv_obj_align(button, LV_ALIGN_CENTER, 0, ui_px(y + 12));
        lv_obj_add_event_cb(button, level_button_cb, LV_EVENT_CLICKED, NULL);
        lv_obj_t *text = lv_label_create(button);
        lv_label_set_text(text, "Level");
        lv_obj_center(text);
    }
#endif
}

/* ----- Startup page ----- */

// The features that can be shown at startup, as a grid of choices, and for
// the one with more than one choice (Images), a roller of them
#define MAX_GROUPS 6
static const char *group_map[MAX_GROUPS + 3];       // the names, a row break and the end
static const char *group_names[MAX_GROUPS];
static size_t group_count;
static lv_obj_t *group_buttons;
static lv_obj_t *startup_roller;
static size_t roller_choices[64];                   // the startup choice of each roller line
static size_t roller_count;
static int roller_group = -1;                       // the group the roller's for

static int group_of(size_t choice)
{
    const char *name = ui_startup_choice_group(choice);
    for (size_t g = 0; g < group_count; g++)
    {
        if (strcmp(group_names[g], name) == 0)
        {
            return (int)g;
        }
    }
    return -1;
}

static size_t group_first(int g)
{
    for (size_t i = 0; i < ui_startup_choice_count(); i++)
    {
        if (group_of(i) == g)
        {
            return i;
        }
    }
    return 0;
}

/* Show the saved choice: its group checked, and the roller if it's Images */
static void show_startup(void)
{
    int choice = ui_find_startup_choice(settings_get()->startup_image);
    if (choice < 0)
    {
        choice = 0;     // unknown values show the first choice, as at startup
    }
    int g = group_of((size_t)choice);
    if (g < 0)
    {
        return;
    }
    // The grid's index skips its row break
    ui_check_choice(group_buttons, (uint32_t)g);
    lv_obj_set_hidden(startup_roller, g != roller_group);
    for (size_t i = 0; i < roller_count; i++)
    {
        if (roller_choices[i] == (size_t)choice && lv_roller_get_selected(startup_roller) != i
            && !lv_obj_has_state(startup_roller, LV_STATE_PRESSED))
        {
            lv_roller_set_selected(startup_roller, i, LV_ANIM_OFF);
        }
    }
}

static void group_event_cb(lv_event_t *e)
{
    int g = (int)lv_buttonmatrix_get_selected_button(group_buttons);
    if (g < 0 || (size_t)g >= group_count)
    {
        return;
    }
    size_t choice = g == roller_group ? roller_choices[lv_roller_get_selected(startup_roller)] : group_first(g);
    settings_set_startup_image(ui_startup_choice_value(choice));
    show_startup();
}

static void startup_roller_event_cb(lv_event_t *e)
{
    settings_set_startup_image(ui_startup_choice_value(roller_choices[lv_roller_get_selected(startup_roller)]));
}

static void add_startup_page(ui_feature_t *feature)
{
    lv_obj_t *page = ui_feature_add_page(feature, "Startup", false);

    // The groups, in the order the features come
    for (size_t i = 0; i < ui_startup_choice_count(); i++)
    {
        if (group_of(i) < 0 && group_count < MAX_GROUPS)
        {
            group_names[group_count++] = ui_startup_choice_group(i);
        }
    }
    size_t n = 0;
    for (size_t g = 0; g < group_count; g++)
    {
        if (g > 0 && g % 2 == 0)
        {
            group_map[n++] = "\n";
        }
        group_map[n++] = group_names[g];
    }
    group_map[n] = "";

    // The group with more than one choice (Images, with its blank page)
    // gets the roller
    char *options = NULL;
    size_t len = 1;
    for (size_t g = 0; g < group_count && roller_group < 0; g++)
    {
        size_t count = 0;
        for (size_t i = 0; i < ui_startup_choice_count(); i++)
        {
            count += group_of(i) == (int)g;
        }
        if (count > 1)
        {
            roller_group = (int)g;
        }
    }
    for (size_t i = 0; i < ui_startup_choice_count(); i++)
    {
        if (group_of(i) == roller_group && roller_count < sizeof(roller_choices) / sizeof(roller_choices[0]))
        {
            roller_choices[roller_count++] = i;
            len += strlen(ui_startup_choice_label(i)) + 1;
        }
    }
    options = lv_malloc(len);
    options[0] = '\0';
    for (size_t i = 0; i < roller_count; i++)
    {
        if (i > 0)
        {
            strcat(options, "\n");
        }
        strcat(options, ui_startup_choice_label(roller_choices[i]));
    }

    add_label(page, "Startup", -86);
    size_t rows = (group_count + 1) / 2;
    group_buttons = ui_add_choices(page, group_map, ui_px(204), ui_px(rows > 1 ? 72 : 34),
                                   ui_px(rows > 1 ? -38 : -56));
    lv_obj_set_style_pad_row(group_buttons, ui_px(4), 0);
    lv_obj_add_event_cb(group_buttons, group_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

    startup_roller = lv_roller_create(page);
    lv_roller_set_options(startup_roller, options, LV_ROLLER_MODE_NORMAL);
    lv_free(options);   // the roller keeps its own copy
    lv_roller_set_visible_row_count(startup_roller, 2);
    lv_obj_set_width(startup_roller, ui_px(160));
    lv_obj_align(startup_roller, LV_ALIGN_CENTER, 0, ui_px(rows > 1 ? 44 : 20));
    lv_obj_add_event_cb(startup_roller, startup_roller_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

    show_startup();
}

/* ----- Battery log ----- */

static lv_obj_t *log_page;
static lv_obj_t *log_status;
static lv_obj_t *log_forget;

static void append_time(char *buf, size_t len, const char *what, uint32_t seconds)
{
    uint32_t minutes = seconds / 60;
    size_t used = strlen(buf);
    snprintf(buf + used, len - used, "%s  %luh %02lum\n", what, (unsigned long)(minutes / 60),
             (unsigned long)(minutes % 60));
}

static void show_log(void)
{
    static const char *const last_run_text[] = {
        [BATTERY_RUN_NONE] = "",
        [BATTERY_RUN_LEARNED] = "Learned from it",
        [BATTERY_RUN_SHORT] = "Too short to learn from",
        [BATTERY_RUN_NOT_FULL] = "Didn't start full",
        [BATTERY_RUN_NOT_EMPTY] = "Didn't run flat",
    };
    char text[160] = "";
    uint8_t runs = settings_get()->battery_curve_runs;
    battery_run_t last = battery_log_last_run();

    if (runs > 0)
    {
        snprintf(text, sizeof(text), "Curve learned from\n%u full run%s\n\n", runs, runs == 1 ? "" : "s");
    }
    else
    {
        strcpy(text, "Standard curve, until it\nruns flat from full once\n\n");
    }
    append_time(text, sizeof(text), "This run", battery_log_seconds());
    if (last != BATTERY_RUN_NONE)
    {
        append_time(text, sizeof(text), "Last run", battery_log_last_seconds());
        size_t used = strlen(text);
        snprintf(text + used, sizeof(text) - used, "%s", last_run_text[last]);
    }
    lv_label_set_text(log_status, text);
    lv_obj_set_hidden(log_forget, runs == 0);
}

static void log_forget_event_cb(lv_event_t *e)
{
    settings_set_battery_curve(NULL, 0, 0);
    show_log();
}

static void log_timer_cb(lv_timer_t *t)
{
    if (ui_current_page() == log_page)
    {
        show_log();
    }
}

static void add_log_page(ui_feature_t *feature)
{
    log_page = ui_feature_add_page(feature, "Battery Log", false);
    lv_obj_set_scrollable(log_page, false);

    lv_obj_t *title = lv_label_create(log_page);
    lv_label_set_text(title, "Battery Log");
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, ui_px(32));

    log_status = lv_label_create(log_page);
    lv_obj_set_style_text_align(log_status, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(log_status, COLOR_MUTED, 0);
    lv_obj_align(log_status, LV_ALIGN_CENTER, 0, ui_px(-8));

    // Held, not tapped, so it isn't thrown away by accident
    log_forget = lv_button_create(log_page);
    lv_obj_set_size(log_forget, ui_px(150), ui_px(32));
    lv_obj_set_style_radius(log_forget, LV_RADIUS_CIRCLE, 0);
    lv_obj_align(log_forget, LV_ALIGN_BOTTOM_MID, 0, ui_px(-34));
    lv_obj_add_event_cb(log_forget, log_forget_event_cb, LV_EVENT_LONG_PRESSED, NULL);
    lv_obj_t *text = lv_label_create(log_forget);
    lv_label_set_text(text, "Hold to forget");
    lv_obj_center(text);

    show_log();
    lv_timer_create(log_timer_cb, LOG_UPDATE_MS, NULL);
}

/* ----- Phone remote ----- */

#if RCAT_HAVE_NETWORK

static lv_obj_t *remote_page;
static lv_obj_t *remote_title;
static lv_obj_t *remote_switch;
static lv_obj_t *remote_qr;
static lv_obj_t *remote_hint;
static lv_obj_t *remote_name;
static lv_obj_t *remote_pass;
static lv_obj_t *remote_new;    // new password, while it's off
static lv_obj_t *remote_auto;   // start at power-up, while it's off
static lv_obj_t *remote_auto_switch;
static int shown_phones = -1;
static int shown_remote = -1;
static char shown_join[80];

static void show_remote(void)
{
    bool on = remote_running();
    if ((int)on != shown_remote)
    {
        shown_remote = on;
        lv_obj_set_state(remote_switch, LV_STATE_CHECKED, on);
        lv_obj_set_hidden(remote_qr, !on);
        lv_obj_set_hidden(remote_name, !on);
        lv_obj_set_hidden(remote_pass, !on);
        lv_obj_set_hidden(remote_hint, on);
        lv_obj_set_hidden(remote_new, on);
        lv_obj_set_hidden(remote_auto, on);
        shown_phones = -1;
    }
    // The phone can change it too
    bool autostart = settings_get()->remote_autostart != 0;
    if (lv_obj_has_state(remote_auto_switch, LV_STATE_CHECKED) != autostart)
    {
        lv_obj_set_state(remote_auto_switch, LV_STATE_CHECKED, autostart);
    }
    if (on && strcmp(remote_join_text(), shown_join) != 0)
    {
        // A new password, or the first time it's shown
        snprintf(shown_join, sizeof(shown_join), "%s", remote_join_text());
        lv_qrcode_update(remote_qr, shown_join, strlen(shown_join));
        lv_label_set_text(remote_name, remote_ssid());
        lv_label_set_text_fmt(remote_pass, "Password  %s", remote_password());
    }
    int phones = remote_phones();
    if (phones != shown_phones)
    {
        shown_phones = phones;
        if (!on)
        {
            lv_label_set_text(remote_title, "WiFi Hotspot Remote");
        }
        else if (phones == 0)
        {
            lv_label_set_text(remote_title, "Scan to join");
        }
        else
        {
            lv_label_set_text_fmt(remote_title, LV_SYMBOL_WIFI "  %d phone%s", phones, phones == 1 ? "" : "s");
        }
    }
}

static void remote_switch_event_cb(lv_event_t *e)
{
    bool on = lv_obj_has_state(remote_switch, LV_STATE_CHECKED);
    if (on && !remote_start())
    {
        lv_label_set_text(remote_hint, "WiFi didn't start");
    }
    else if (!on)
    {
        remote_stop();
        lv_label_set_text(remote_hint, "Control the display\nfrom a phone");
    }
    shown_remote = -1;
    show_remote();
}

static void remote_auto_event_cb(lv_event_t *e)
{
    settings_set_remote_autostart(lv_obj_has_state(remote_auto_switch, LV_STATE_CHECKED));
}

static void new_password_event_cb(lv_event_t *e)
{
    remote_new_password();
    lv_label_set_text_fmt(remote_hint, "New password:\n%s", remote_password());
}

/* The remote runs from here, whatever's on screen. */
static void remote_timer_cb(lv_timer_t *t)
{
    remote_poll(lv_tick_get());
    if (ui_current_page() == remote_page)
    {
        show_remote();
    }
}

static void add_remote_page(ui_feature_t *feature)
{
    remote_page = ui_feature_add_page(feature, "WiFi Hotspot Remote", false);
    lv_obj_set_scrollable(remote_page, false);

    remote_title = lv_label_create(remote_page);
    lv_label_set_text(remote_title, "WiFi Hotspot Remote");
    lv_obj_align(remote_title, LV_ALIGN_TOP_MID, 0, ui_px(28));

    remote_switch = lv_switch_create(remote_page);
    lv_obj_set_size(remote_switch, ui_px(64), ui_px(32));
    lv_obj_align(remote_switch, LV_ALIGN_CENTER, 0, ui_px(-58));
    lv_obj_add_event_cb(remote_switch, remote_switch_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

    // For a phone's camera: "join this network"
    remote_qr = lv_qrcode_create(remote_page);
    lv_qrcode_set_size(remote_qr, ui_px(92));
    lv_qrcode_set_dark_color(remote_qr, lv_color_black());
    lv_qrcode_set_light_color(remote_qr, lv_color_white());
    lv_qrcode_set_quiet_zone(remote_qr, true);
    lv_obj_align(remote_qr, LV_ALIGN_CENTER, 0, ui_px(8));

    remote_hint = lv_label_create(remote_page);
    lv_label_set_text(remote_hint, "Control the display\nfrom a phone");
    lv_obj_set_style_text_align(remote_hint, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(remote_hint, COLOR_MUTED, 0);
    lv_obj_align(remote_hint, LV_ALIGN_CENTER, 0, ui_px(-10));

    // Shuts out anyone who had the old one
    remote_new = lv_button_create(remote_page);
    lv_obj_set_size(remote_new, ui_px(130), ui_px(32));
    lv_obj_set_style_radius(remote_new, LV_RADIUS_CIRCLE, 0);
    lv_obj_align(remote_new, LV_ALIGN_CENTER, 0, ui_px(30));
    lv_obj_add_event_cb(remote_new, new_password_event_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *text = lv_label_create(remote_new);
    lv_label_set_text(text, "New password");
    lv_obj_center(text);

    // Switch it on by itself at power-up, a label and a small switch in a row
    remote_auto = lv_obj_create(remote_page);
    lv_obj_remove_style_all(remote_auto);
    lv_obj_set_size(remote_auto, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(remote_auto, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(remote_auto, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(remote_auto, ui_px(8), 0);
    lv_obj_set_scrollable(remote_auto, false);
    lv_obj_align(remote_auto, LV_ALIGN_CENTER, 0, ui_px(70));
    lv_obj_t *auto_label = lv_label_create(remote_auto);
    lv_label_set_text(auto_label, "At power-up");
    lv_obj_set_style_text_color(auto_label, COLOR_MUTED, 0);
    remote_auto_switch = lv_switch_create(remote_auto);
    lv_obj_set_size(remote_auto_switch, ui_px(44), ui_px(22));
    lv_obj_set_state(remote_auto_switch, LV_STATE_CHECKED, settings_get()->remote_autostart != 0);
    lv_obj_add_event_cb(remote_auto_switch, remote_auto_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

    remote_name = lv_label_create(remote_page);
    lv_label_set_text(remote_name, "");
    lv_obj_align(remote_name, LV_ALIGN_CENTER, 0, ui_px(66));

    remote_pass = lv_label_create(remote_page);
    lv_label_set_text(remote_pass, "");
    lv_obj_set_style_text_color(remote_pass, COLOR_MUTED, 0);
    lv_obj_align(remote_pass, LV_ALIGN_CENTER, 0, ui_px(84));

    if (settings_get()->remote_autostart && !remote_start())
    {
        lv_label_set_text(remote_hint, "WiFi didn't start");
    }
    show_remote();
    lv_timer_create(remote_timer_cb, REMOTE_POLL_MS, NULL);
}

/* ----- Comm channel ----- */

static lv_obj_t *comm_page;
static lv_obj_t *comm_title;
static lv_obj_t *comm_switch;
static lv_obj_t *comm_hint;
static lv_obj_t *comm_name_label;

/* Set a label's text only if it's changed, so it isn't redrawn every time. */
static void set_label(lv_obj_t *label, const char *text)
{
    if (strcmp(lv_label_get_text(label), text) != 0)
    {
        lv_label_set_text(label, text);
    }
}

static void show_comm(void)
{
    bool on = comm_running();
    lv_obj_set_state(comm_switch, LV_STATE_CHECKED, on);
    lv_obj_set_hidden(comm_name_label, !on);
    if (on)
    {
        // The board's name, and the app's version once it's said
        char text[64];
        const char *app = comm_app_version();
        snprintf(text, sizeof(text), app[0] ? "%s, app %s" : "%s%s", comm_name(), app);
        set_label(comm_name_label, text);
    }

    if (!on)
    {
        set_label(comm_title, "Phone App");
    }
    else if (comm_sending())
    {
        // Say when it's the phone, which keeps talking until it says stop
        set_label(comm_title, comm_phone_talking() ? LV_SYMBOL_AUDIO "  Phone talking" : LV_SYMBOL_AUDIO "  Talking");
    }
    else if (!comm_phone_connected())
    {
        set_label(comm_title, comm_voice_heard() ? "No phone  " LV_SYMBOL_AUDIO : "Waiting for a phone");
    }
    else
    {
        set_label(comm_title, LV_SYMBOL_BLUETOOTH "  Phone connected");
    }
}

static void comm_switch_event_cb(lv_event_t *e)
{
    bool on = lv_obj_has_state(comm_switch, LV_STATE_CHECKED);
    if (on && !comm_start())
    {
        lv_label_set_text(comm_hint, "Bluetooth didn't start");
    }
    else if (on)
    {
        comm_allow_pairing(true, lv_tick_get());    // it's in hand: a new phone may pair
    }
    else if (!on)
    {
        comm_stop();
        lv_label_set_text(comm_hint, "The DroneLab app, over\nBluetooth: HiveMind\nand the remote");
    }
    show_comm();
}

static lv_obj_t *paired_page;
static void show_paired(void);

/* While a phone pairs, its code, over whatever's on screen. */
static lv_obj_t *pair_panel;
static lv_obj_t *pair_code;

static void show_pairing_code(void)
{
    int32_t code = rcat_hal_ble_peer_passkey();
    if (code < 0)
    {
        if (pair_panel != NULL)
        {
            lv_obj_delete(pair_panel);
            pair_panel = pair_code = NULL;
        }
        return;
    }
    if (pair_panel == NULL)
    {
        pair_panel = lv_obj_create(lv_layer_top());
        lv_obj_set_size(pair_panel, ui_px(280), ui_px(150));
        lv_obj_center(pair_panel);
        lv_obj_set_style_bg_color(pair_panel, lv_color_black(), 0);
        lv_obj_set_style_bg_opa(pair_panel, LV_OPA_COVER, 0);
        lv_obj_set_style_border_color(pair_panel, lv_palette_main(LV_PALETTE_PINK), 0);
        lv_obj_set_style_border_width(pair_panel, ui_px(3), 0);
        lv_obj_set_style_radius(pair_panel, ui_px(20), 0);
        lv_obj_set_scrollable(pair_panel, false);
        lv_obj_t *title = lv_label_create(pair_panel);
        lv_label_set_text(title, "Pairing a phone: type in");
        lv_obj_align(title, LV_ALIGN_TOP_MID, 0, ui_px(4));
        pair_code = lv_label_create(pair_panel);
        lv_obj_set_style_text_font(pair_code, &lv_font_montserrat_24, 0);
        lv_obj_set_style_text_letter_space(pair_code, ui_px(4), 0);
        lv_obj_set_style_transform_scale(pair_code, 384, 0);   // 1.5 times
        lv_obj_set_style_transform_pivot_x(pair_code, LV_PCT(50), 0);
        lv_obj_set_style_transform_pivot_y(pair_code, LV_PCT(50), 0);
        lv_obj_align(pair_code, LV_ALIGN_CENTER, 0, ui_px(14));
    }
    char text[12];
    snprintf(text, sizeof(text), "%03ld %03ld", (long)(code / 1000), (long)(code % 1000));
    set_label(pair_code, text);
}

/* The channel answers the phone from here, whatever's on screen, and
 * pairing a talk button goes on. */
static void comm_timer_cb(lv_timer_t *t)
{
    comm_poll(lv_tick_get());
    talk_button_poll(lv_tick_get());
    show_pairing_code();
    if (paired_page != NULL && ui_current_page() == paired_page)
    {
        show_paired();
    }
    if (ui_current_page() == comm_page)
    {
        show_comm();
    }
}

static void add_comm_page(ui_feature_t *feature)
{
    comm_page = ui_feature_add_page(feature, "Phone App (Bluetooth)", false);
    lv_obj_set_scrollable(comm_page, false);

    comm_title = lv_label_create(comm_page);
    lv_label_set_text(comm_title, "Phone App");
    lv_obj_align(comm_title, LV_ALIGN_TOP_MID, 0, ui_px(28));

    comm_switch = lv_switch_create(comm_page);
    lv_obj_set_size(comm_switch, ui_px(64), ui_px(32));
    lv_obj_align(comm_switch, LV_ALIGN_CENTER, 0, ui_px(-40));
    lv_obj_add_event_cb(comm_switch, comm_switch_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

    // Off, what it's for; on, which board this is
    comm_hint = lv_label_create(comm_page);
    lv_label_set_text(comm_hint, "The DroneLab app, over\nBluetooth: HiveMind\nand the remote");
    lv_obj_set_style_text_align(comm_hint, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(comm_hint, COLOR_MUTED, 0);
    lv_obj_align(comm_hint, LV_ALIGN_CENTER, 0, ui_px(14));

    comm_name_label = lv_label_create(comm_page);
    lv_label_set_text(comm_name_label, "");
    lv_obj_set_style_text_color(comm_name_label, COLOR_MUTED, 0);
    lv_obj_align(comm_name_label, LV_ALIGN_CENTER, 0, ui_px(56));

    show_comm();
    lv_timer_create(comm_timer_cb, COMM_POLL_MS, NULL);
}

/* ----- The phones paired with the app's Bluetooth link ----- */

#define FORGET_CONFIRM_MS   4000    // a second tap within this long forgets them

static lv_obj_t *paired_count;
static lv_obj_t *paired_button_label;
static lv_obj_t *pair_button;
static lv_obj_t *pair_button_label;
static uint32_t forget_armed_at;    // when the first tap came, 0 if it hasn't

static void show_paired(void)
{
    rcat_hal_ble_device_t button;
    int n = rcat_hal_ble_peer_paired(talk_button_paired(&button) ? &button : NULL);
    char text[40];
    if (n < 0)
    {
        snprintf(text, sizeof(text), "Switch the Phone App on\nto see them");
    }
    else
    {
        snprintf(text, sizeof(text), n == 0 ? "None" : n == 1 ? "1 phone" : "%d phones", n);
    }
    set_label(paired_count, text);
    if (forget_armed_at != 0 && lv_tick_get() - forget_armed_at > FORGET_CONFIRM_MS)
    {
        forget_armed_at = 0;
    }
    set_label(paired_button_label, forget_armed_at != 0 ? "Tap to confirm" : "Forget them");

    // Pairing a new phone: open for a couple of minutes, counting down
    uint32_t left = comm_pairing_left(lv_tick_get());
    if (left > 0)
    {
        unsigned s = (unsigned)((left + 999) / 1000);
        snprintf(text, sizeof(text), "Open %u:%02u", s / 60, s % 60);
    }
    else
    {
        snprintf(text, sizeof(text), "Pair a phone");
    }
    set_label(pair_button_label, text);
    lv_obj_set_state(pair_button, LV_STATE_CHECKED, left > 0);
    lv_obj_set_state(pair_button, LV_STATE_DISABLED, !comm_running());
}

static void pair_phone_cb(lv_event_t *e)
{
    uint32_t now = lv_tick_get();
    comm_allow_pairing(comm_pairing_left(now) == 0, now);     // a second tap shuts it
    show_paired();
}

static void forget_phones_cb(lv_event_t *e)
{
    if (forget_armed_at == 0)
    {
        forget_armed_at = lv_tick_get() | 1;    // a second tap forgets them
    }
    else
    {
        forget_armed_at = 0;
        rcat_hal_ble_device_t button;
        rcat_hal_ble_peer_forget_all(talk_button_paired(&button) ? &button : NULL);
    }
    show_paired();
}

static void add_paired_page(ui_feature_t *feature)
{
    paired_page = ui_feature_add_page(feature, "Paired Phones", false);
    lv_obj_set_scrollable(paired_page, false);

    lv_obj_t *title = lv_label_create(paired_page);
    lv_label_set_text(title, "Paired Phones");
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, ui_px(28));

    paired_count = lv_label_create(paired_page);
    lv_label_set_text(paired_count, "");
    lv_obj_set_style_text_align(paired_count, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(paired_count, LV_ALIGN_CENTER, 0, ui_px(-54));

    // Only phones paired already can connect, unless this is open: a new
    // one's code would show on a screen that faces the world
    pair_button = lv_button_create(paired_page);
    lv_obj_set_size(pair_button, ui_px(150), ui_px(38));
    lv_obj_set_style_radius(pair_button, LV_RADIUS_CIRCLE, 0);
    lv_obj_align(pair_button, LV_ALIGN_CENTER, 0, ui_px(-14));
    lv_obj_add_event_cb(pair_button, pair_phone_cb, LV_EVENT_CLICKED, NULL);
    pair_button_label = lv_label_create(pair_button);
    lv_label_set_text(pair_button_label, "");
    lv_obj_center(pair_button_label);

    lv_obj_t *forget = lv_button_create(paired_page);
    lv_obj_set_size(forget, ui_px(150), ui_px(38));
    lv_obj_set_style_radius(forget, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(forget, lv_color_hex(0x3a3a3a), 0);
    lv_obj_align(forget, LV_ALIGN_CENTER, 0, ui_px(32));
    lv_obj_add_event_cb(forget, forget_phones_cb, LV_EVENT_CLICKED, NULL);
    paired_button_label = lv_label_create(forget);
    lv_label_set_text(paired_button_label, "");
    lv_obj_center(paired_button_label);

    lv_obj_t *hint = lv_label_create(paired_page);
    lv_label_set_text(hint, "Forget them if a phone's\nlost. Keeps the talk button");
    lv_obj_set_style_text_align(hint, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(hint, COLOR_MUTED, 0);
    lv_obj_align(hint, LV_ALIGN_CENTER, 0, ui_px(76));

    show_paired();
}

/* ----- Firmware update ----- */

static lv_obj_t *update_page;
static lv_obj_t *update_switch;
static lv_obj_t *update_code;
static lv_obj_t *update_join;
static lv_obj_t *update_status;

static void show_update(void)
{
    bool on = updater_allowed();
    lv_obj_set_state(update_switch, LV_STATE_CHECKED, on);
    lv_obj_set_hidden(update_code, !on);
    lv_obj_set_hidden(update_join, !on);
    if (on)
    {
        lv_label_set_text(update_code, updater_code());
        lv_label_set_text_fmt(update_join, "%s\n%s", remote_ssid(), remote_password());
    }
    const char *status = updater_status();
    lv_label_set_text(update_status, status[0] != '\0' ? status : "Update from a computer\nwith tools/update.py");
}

static void update_switch_event_cb(lv_event_t *e)
{
    updater_allow(lv_obj_has_state(update_switch, LV_STATE_CHECKED));
    show_update();
}

static void update_timer_cb(lv_timer_t *t)
{
    if (ui_current_page() == update_page)
    {
        show_update();
    }
}

static void add_update_page(ui_feature_t *feature)
{
    update_page = ui_feature_add_page(feature, "Firmware Update", false);
    lv_obj_set_scrollable(update_page, false);

    lv_obj_t *title = lv_label_create(update_page);
    lv_label_set_text(title, "Firmware Update");
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, ui_px(28));

    update_switch = lv_switch_create(update_page);
    lv_obj_set_size(update_switch, ui_px(64), ui_px(32));
    lv_obj_align(update_switch, LV_ALIGN_CENTER, 0, ui_px(-58));
    lv_obj_add_event_cb(update_switch, update_switch_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

    // The code for tools/update.py, big enough to read off easily
    update_code = lv_label_create(update_page);
    lv_obj_set_style_text_font(update_code, &lv_font_montserrat_24, 0);
    lv_label_set_text(update_code, "");
    lv_obj_align(update_code, LV_ALIGN_CENTER, 0, ui_px(-12));

    // The hotspot to join, and its password
    update_join = lv_label_create(update_page);
    lv_obj_set_style_text_align(update_join, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(update_join, COLOR_MUTED, 0);
    lv_label_set_text(update_join, "");
    lv_obj_align(update_join, LV_ALIGN_CENTER, 0, ui_px(30));

    update_status = lv_label_create(update_page);
    lv_obj_set_style_text_align(update_status, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(update_status, LV_ALIGN_CENTER, 0, ui_px(72));

    show_update();
    lv_timer_create(update_timer_cb, UPDATE_POLL_MS, NULL);
}

#endif  // RCAT_HAVE_NETWORK

/* ----- Changes from the phone remote ----- */

/* Show what the phone changed, leaving alone anything that's being touched
 * or a rotation that's about to be applied. */
static void sync_timer_cb(lv_timer_t *t)
{
    const settings_t *s = settings_get();
    if (!lv_slider_is_dragged(brightness_slider) && lv_slider_get_value(brightness_slider) != s->brightness)
    {
        lv_slider_set_value(brightness_slider, s->brightness, LV_ANIM_OFF);
        lv_label_set_text_fmt(brightness_value_label, "%d%%", s->brightness);
        lv_obj_align_to(brightness_value_label, brightness_slider, LV_ALIGN_OUT_BOTTOM_MID, 0, ui_px(10));
    }
    ui_check_choice(rotation_buttons, s->rotation);
    show_startup();
}

static bool build(ui_feature_t *feature)
{
    add_brightness_page(feature);
#if RCAT_HAVE_NETWORK
    // The app over Bluetooth first: it leaves the phone on the internet,
    // which the WiFi hotspot's remote can't
    if (comm_available())
    {
        add_comm_page(feature);
        add_paired_page(feature);
    }
    if (remote_available())
    {
        add_remote_page(feature);
    }
#endif
    add_setup_page(feature);            // rotation, model and the Level, for lining the display up
    add_startup_page(feature);
    lv_timer_create(sync_timer_cb, SYNC_MS, NULL);
    if (battery_log_available())
    {
        add_log_page(feature);
    }
#if RCAT_HAVE_NETWORK
    if (updater_available())
    {
        add_update_page(feature);
    }
#endif
    return true;
}

static void on_navigate(void)
{
}
