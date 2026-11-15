/*
 * Settings feature: settings that apply to the whole display, one per page.
 * Settings that belong to a single feature live with that feature instead.
 *
 * On boards that have the comm channel, the pages after Brightness are the
 * Phone App (the app's Bluetooth link, see app/comm.h), the phones paired
 * with it, and the talk button. Then, on boards with WiFi, the WiFi hotspot
 * remote (see app/remote.h): a switch for its hotspot, the QR code that
 * joins it, a new password, and whether it switches itself on at power-up.
 * The last page is firmware updates.
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
#define COMM_POLL_MS      50
#define LOG_UPDATE_MS     1000
#define UPTIME_UPDATE_MS  1000
#define UPDATE_POLL_MS    200
#define COLOR_MUTED       lv_palette_main(LV_PALETTE_GREY)

// Apply a new rotation only once the roller has been left alone this long, so
// flicking past options doesn't rotate the screen under your finger.
#define ROTATION_APPLY_DELAY_MS 1000

static bool build(ui_feature_t *feature);

const ui_feature_def_t feature_settings = {
    .name = "Settings",
    .build = build,
};

static lv_obj_t *battery_label;
static lv_obj_t *brightness_value_label;
static lv_obj_t *brightness_slider;
static lv_obj_t *rotation_roller;
static lv_obj_t *startup_roller;
static lv_timer_t *rotation_timer;
static uint8_t pending_rotation;
static bool rotation_pending;       // chosen, and waiting to be applied

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
    lv_obj_t *version_label = lv_label_create(page);
    lv_label_set_text_fmt(version_label, "%s\n%s", rcat_hal_firmware_version(), built);
    lv_obj_set_style_text_align(version_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(version_label, COLOR_MUTED, 0);
    lv_obj_align(version_label, LV_ALIGN_CENTER, 0, ui_px(78));

    // Kept up all the time, as on some boards the battery can be plugged in
    // while it's running
    lv_timer_t *timer = lv_timer_create(battery_timer_cb, BATTERY_UPDATE_MS, NULL);
    lv_timer_ready(timer);
}

/* ----- Rotation ----- */

static void rotation_apply_timer_cb(lv_timer_t *t)
{
    lv_timer_pause(t);
    rotation_pending = false;

    if (pending_rotation != settings_get()->rotation)
    {
        rcat_hal_display_set_rotation(pending_rotation);
        settings_set_rotation(pending_rotation);
    }
}

static void rotation_roller_event_cb(lv_event_t *e)
{
    // Roller options are 0, 90, 180 and 270 degrees.
    pending_rotation = lv_roller_get_selected(rotation_roller);
    rotation_pending = true;

    if (rotation_timer == NULL)
    {
        rotation_timer = lv_timer_create(rotation_apply_timer_cb, ROTATION_APPLY_DELAY_MS, NULL);
    }
    lv_timer_reset(rotation_timer);
    lv_timer_resume(rotation_timer);
}

static void add_rotation_page(ui_feature_t *feature)
{
    lv_obj_t *page = ui_feature_add_page(feature, "Rotation", false);

    rotation_roller = lv_roller_create(page);
    lv_roller_set_options(rotation_roller, "0°\n90°\n180°\n270°", LV_ROLLER_MODE_NORMAL);
    lv_roller_set_visible_row_count(rotation_roller, 3);
    lv_roller_set_selected(rotation_roller, settings_get()->rotation, LV_ANIM_OFF);
    lv_obj_center(rotation_roller);
    lv_obj_add_event_cb(rotation_roller, rotation_roller_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

    lv_obj_t *rotation_label = lv_label_create(page);
    lv_label_set_text(rotation_label, "Rotation");
    lv_obj_align_to(rotation_label, rotation_roller, LV_ALIGN_OUT_TOP_MID, 0, ui_px(-10));
}

/* ----- Startup page ----- */

static void startup_roller_event_cb(lv_event_t *e)
{
    settings_set_startup_image(ui_startup_choice_value(lv_roller_get_selected(startup_roller)));
}

static void add_startup_page(ui_feature_t *feature)
{
    lv_obj_t *page = ui_feature_add_page(feature, "Startup", false);

    // Roller options: every feature's startup choices, separated by newlines.
    size_t len = 1;
    for (size_t i = 0; i < ui_startup_choice_count(); i++)
    {
        len += strlen(ui_startup_choice_label(i)) + 1;
    }
    char *options = lv_malloc(len);
    options[0] = '\0';
    for (size_t i = 0; i < ui_startup_choice_count(); i++)
    {
        if (i > 0)
        {
            strcat(options, "\n");
        }
        strcat(options, ui_startup_choice_label(i));
    }

    // Unknown values (e.g. an image that's since been removed) show the first choice.
    int selected = ui_find_startup_choice(settings_get()->startup_image);

    startup_roller = lv_roller_create(page);
    lv_roller_set_options(startup_roller, options, LV_ROLLER_MODE_NORMAL);
    lv_free(options);   // the roller keeps its own copy
    lv_roller_set_visible_row_count(startup_roller, 3);
    lv_roller_set_selected(startup_roller, (selected < 0) ? 0 : selected, LV_ANIM_OFF);
    lv_obj_center(startup_roller);
    lv_obj_add_event_cb(startup_roller, startup_roller_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

    lv_obj_t *startup_label = lv_label_create(page);
    lv_label_set_text(startup_label, "Startup");
    lv_obj_align_to(startup_label, startup_roller, LV_ALIGN_OUT_TOP_MID, 0, ui_px(-10));
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
static lv_obj_t *comm_modes;
static lv_obj_t *comm_talk;
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
    lv_obj_set_hidden(comm_hint, on);
    lv_obj_set_hidden(comm_modes, !on);
    lv_obj_set_hidden(comm_talk, !on);
    lv_obj_set_hidden(comm_name_label, !on);
    if (on)
    {
        // The phone can change the mode too
        if (!lv_buttonmatrix_has_button_ctrl(comm_modes, comm_mode(), LV_BUTTONMATRIX_CTRL_CHECKED))
        {
            lv_buttonmatrix_set_button_ctrl(comm_modes, comm_mode(), LV_BUTTONMATRIX_CTRL_CHECKED);
        }
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
    else if (!on)
    {
        comm_stop();
        lv_label_set_text(comm_hint, "The DroneLab app, over\nBluetooth: the comm channel\nand the remote");
    }
    show_comm();
}

static void comm_mode_event_cb(lv_event_t *e)
{
    uint32_t selected = lv_buttonmatrix_get_selected_button(comm_modes);
    if (selected < COMM_MODE_COUNT)
    {
        comm_set_mode((comm_mode_t)selected);
    }
}

static void comm_talk_event_cb(lv_event_t *e)
{
    lv_event_code_t code = lv_event_get_code(e);
    if (code == LV_EVENT_PRESSED)
    {
        comm_set_talk(true);
    }
    else if (code == LV_EVENT_RELEASED || code == LV_EVENT_PRESS_LOST)
    {
        comm_set_talk(false);
    }
}

static lv_obj_t *button_page;
static void show_button(void);
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
    if (button_page != NULL && ui_current_page() == button_page)
    {
        show_button();
    }
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
    lv_obj_align(comm_switch, LV_ALIGN_CENTER, 0, ui_px(-58));
    lv_obj_add_event_cb(comm_switch, comm_switch_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

    comm_hint = lv_label_create(comm_page);
    lv_label_set_text(comm_hint, "The DroneLab app, over\nBluetooth: the comm channel\nand the remote");
    lv_obj_set_style_text_align(comm_hint, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(comm_hint, COLOR_MUTED, 0);
    lv_obj_align(comm_hint, LV_ALIGN_CENTER, 0, ui_px(0));

    // Push to talk, or talk whenever it hears you. It changes when the
    // finger lifts (CLICK_TRIG), not when it lands, so that swiping to the
    // next page from here doesn't change it.
    static const char *const modes[] = { "Push to talk", "Voice", "" };
    comm_modes = lv_buttonmatrix_create(comm_page);
    lv_buttonmatrix_set_map(comm_modes, modes);
    lv_buttonmatrix_set_button_ctrl_all(comm_modes, LV_BUTTONMATRIX_CTRL_CHECKABLE | LV_BUTTONMATRIX_CTRL_CLICK_TRIG);
    lv_buttonmatrix_set_one_checked(comm_modes, true);
    // The chosen one is filled in, and the other dark: told apart by how
    // bright they are, not only by their color.
    lv_obj_set_style_bg_opa(comm_modes, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(comm_modes, 0, 0);
    lv_obj_set_style_pad_all(comm_modes, 0, 0);
    lv_obj_set_style_pad_column(comm_modes, ui_px(6), 0);
    lv_obj_set_style_radius(comm_modes, ui_px(10), LV_PART_ITEMS);
    lv_obj_set_style_border_width(comm_modes, 0, LV_PART_ITEMS);
    lv_obj_set_style_shadow_width(comm_modes, 0, LV_PART_ITEMS);
    lv_obj_set_style_bg_opa(comm_modes, LV_OPA_COVER, LV_PART_ITEMS);
    lv_obj_set_style_bg_color(comm_modes, lv_color_hex(0x2a2a2a), LV_PART_ITEMS);
    lv_obj_set_style_text_color(comm_modes, lv_color_hex(0x909090), LV_PART_ITEMS);
    lv_obj_set_style_bg_color(comm_modes, lv_palette_main(LV_PALETTE_PINK), LV_PART_ITEMS | LV_STATE_CHECKED);
    lv_obj_set_style_text_color(comm_modes, lv_color_white(), LV_PART_ITEMS | LV_STATE_CHECKED);
    lv_buttonmatrix_set_button_ctrl(comm_modes, comm_mode(), LV_BUTTONMATRIX_CTRL_CHECKED);
    lv_obj_set_size(comm_modes, ui_px(190), ui_px(40));
    lv_obj_align(comm_modes, LV_ALIGN_CENTER, 0, ui_px(-12));
    lv_obj_add_event_cb(comm_modes, comm_mode_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

    // For trying it out with the display in hand; in the mask, the phone or
    // a button paired with it does this
    comm_talk = lv_button_create(comm_page);
    lv_obj_set_size(comm_talk, ui_px(130), ui_px(36));
    lv_obj_set_style_radius(comm_talk, LV_RADIUS_CIRCLE, 0);
    lv_obj_align(comm_talk, LV_ALIGN_CENTER, 0, ui_px(38));
    lv_obj_add_event_cb(comm_talk, comm_talk_event_cb, LV_EVENT_ALL, NULL);
    lv_obj_t *text = lv_label_create(comm_talk);
    lv_label_set_text(text, "Hold to talk");
    lv_obj_center(text);

    comm_name_label = lv_label_create(comm_page);
    lv_label_set_text(comm_name_label, "");
    lv_obj_set_style_text_color(comm_name_label, COLOR_MUTED, 0);
    lv_obj_align(comm_name_label, LV_ALIGN_CENTER, 0, ui_px(80));

    show_comm();
    lv_timer_create(comm_timer_cb, COMM_POLL_MS, NULL);
}

/* ----- The comm channel's talk button ----- */

static lv_obj_t *button_title;
static lv_obj_t *button_status;
static lv_obj_t *button_action;
static lv_obj_t *button_action_label;
static lv_obj_t *button_hint;

static void show_button(void)
{
    talk_button_state_t st = talk_button_state();
    const char *status = "";
    const char *action = "Pair a button";
    const char *hint = "A Bluetooth camera remote,\nto hold to talk";
    switch (st)
    {
    case TALK_BUTTON_NONE:
        break;
    case TALK_BUTTON_OFF:
        status = "Works while Comm is on";
        action = "Forget it";
        hint = "";
        break;
    case TALK_BUTTON_WAITING:
        status = "Asleep: press it to wake it";
        action = "Forget it";
        hint = "";
        break;
    case TALK_BUTTON_CONNECTING:
        status = "Connecting...";
        action = "Forget it";
        hint = "";
        break;
    case TALK_BUTTON_CONNECTED:
        status = talk_button_held() ? LV_SYMBOL_AUDIO "  Pressed" : LV_SYMBOL_BLUETOOTH "  Connected";
        action = "Forget it";
        hint = "Hold it to talk";
        break;
    case TALK_BUTTON_FINDING:
        status = "Looking...";
        action = "Cancel";
        hint = "Put the button in pairing mode:\nswitch it on, or hold it down";
        break;
    case TALK_BUTTON_PAIRING:
        status = "Pairing...";
        action = "Cancel";
        hint = "";
        break;
    case TALK_BUTTON_NOT_FOUND:
        status = "No button found";
        action = "OK";
        hint = "Is it in pairing mode?";
        break;
    case TALK_BUTTON_FAILED:
        status = "Pairing didn't work";
        action = "OK";
        hint = "Try it again from pairing mode";
        break;
    }
    bool named = st != TALK_BUTTON_NONE && st != TALK_BUTTON_FINDING && st != TALK_BUTTON_NOT_FOUND;
    set_label(button_title, named ? talk_button_name() : "Talk Button");
    set_label(button_status, status);
    set_label(button_action_label, action);
    set_label(button_hint, hint);
}

static void button_action_cb(lv_event_t *e)
{
    switch (talk_button_state())
    {
    case TALK_BUTTON_NONE:
        if (!talk_button_pair())
        {
            set_label(button_hint, "Bluetooth didn't start");
            return;
        }
        break;
    case TALK_BUTTON_FINDING:
    case TALK_BUTTON_PAIRING:
    case TALK_BUTTON_NOT_FOUND:
    case TALK_BUTTON_FAILED:
        talk_button_cancel();
        break;
    default:
        talk_button_forget();
        break;
    }
    show_button();
}

static void add_button_page(ui_feature_t *feature)
{
    button_page = ui_feature_add_page(feature, "Talk Button", false);
    lv_obj_set_scrollable(button_page, false);

    button_title = lv_label_create(button_page);
    lv_label_set_text(button_title, "Talk Button");
    lv_obj_align(button_title, LV_ALIGN_TOP_MID, 0, ui_px(28));

    button_status = lv_label_create(button_page);
    lv_label_set_text(button_status, "");
    lv_obj_align(button_status, LV_ALIGN_CENTER, 0, ui_px(-50));

    button_action = lv_button_create(button_page);
    lv_obj_set_size(button_action, ui_px(150), ui_px(40));
    lv_obj_set_style_radius(button_action, LV_RADIUS_CIRCLE, 0);
    lv_obj_align(button_action, LV_ALIGN_CENTER, 0, 0);
    lv_obj_add_event_cb(button_action, button_action_cb, LV_EVENT_CLICKED, NULL);
    button_action_label = lv_label_create(button_action);
    lv_label_set_text(button_action_label, "");
    lv_obj_center(button_action_label);

    button_hint = lv_label_create(button_page);
    lv_label_set_text(button_hint, "");
    lv_obj_set_style_text_align(button_hint, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(button_hint, COLOR_MUTED, 0);
    lv_obj_align(button_hint, LV_ALIGN_CENTER, 0, ui_px(60));

    show_button();
}

/* ----- The phones paired with the app's Bluetooth link ----- */

#define FORGET_CONFIRM_MS   4000    // a second tap within this long forgets them

static lv_obj_t *paired_count;
static lv_obj_t *paired_button_label;
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
    lv_obj_align(paired_count, LV_ALIGN_CENTER, 0, ui_px(-44));

    lv_obj_t *forget = lv_button_create(paired_page);
    lv_obj_set_size(forget, ui_px(150), ui_px(40));
    lv_obj_set_style_radius(forget, LV_RADIUS_CIRCLE, 0);
    lv_obj_align(forget, LV_ALIGN_CENTER, 0, 0);
    lv_obj_add_event_cb(forget, forget_phones_cb, LV_EVENT_CLICKED, NULL);
    paired_button_label = lv_label_create(forget);
    lv_label_set_text(paired_button_label, "");
    lv_obj_center(paired_button_label);

    lv_obj_t *hint = lv_label_create(paired_page);
    lv_label_set_text(hint, "If a phone's lost: they'll\nhave to pair again, with\na code. Keeps the talk button");
    lv_obj_set_style_text_align(hint, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(hint, COLOR_MUTED, 0);
    lv_obj_align(hint, LV_ALIGN_CENTER, 0, ui_px(62));

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
    if (!rotation_pending && !lv_obj_has_state(rotation_roller, LV_STATE_PRESSED)
        && lv_roller_get_selected(rotation_roller) != s->rotation)
    {
        lv_roller_set_selected(rotation_roller, s->rotation, LV_ANIM_OFF);
        pending_rotation = s->rotation;
    }
    int startup = ui_find_startup_choice(s->startup_image);
    if (startup >= 0 && !lv_obj_has_state(startup_roller, LV_STATE_PRESSED)
        && lv_roller_get_selected(startup_roller) != (uint32_t)startup)
    {
        lv_roller_set_selected(startup_roller, startup, LV_ANIM_OFF);
    }
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
        add_button_page(feature);
    }
    if (remote_available())
    {
        add_remote_page(feature);
    }
#endif
    add_rotation_page(feature);
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
