#include <stdint.h>

#include "app.h"
#include "app/battery_log.h"
#include "app/comm.h"
#include "app/direct.h"
#include "app/others.h"
#include "app/patterns.h"
#include "app/settings.h"
#include "app/toys.h"
#include "app/updater.h"
#include "app/screenshot.h"
#include "app/console.h"
#include "audio/audio_level.h"
#include "audio/audio_player.h"
#include "audio/voice_lab.h"
#include "hal.h"
#include "media/media_library.h"
#include "lvgl.h"
#include "ui/ui.h"

// The logo is shown for at least this long at startup, while everything
// else (reading the SD card included) gets ready behind it.
#define SPLASH_MS           2000

// core/ui/assets/dronelab_logo.png, made by tools/gen_logo.py and converted
// for the screen by the build. It's drawn 480x480 and scaled to fit.
LV_IMAGE_DECLARE(dronelab_logo);
#define SPLASH_ART_SIZE     480

// The blinking cursor after its "> SYSTEM ONLINE" prompt: x, y, width,
// height in the 480x480 picture, as tools/gen_logo.py prints them
static const int32_t SPLASH_CURSOR[4] = { 322, 279, 8, 15 };
#define SPLASH_CURSOR_COLOR lv_color_hex(0x33ff33)   // the Terminal's phosphor green
#define SPLASH_BLINK_MS     500

typedef struct
{
    lv_obj_t *logo;
    lv_obj_t *cursor;
    lv_timer_t *blink;
    uint32_t shown_at;
} splash_t;

static void splash_blink_cb(lv_timer_t *timer)
{
    lv_obj_t *cursor = lv_timer_get_user_data(timer);
    lv_obj_set_hidden(cursor, !lv_obj_is_hidden(cursor));
}

/* Show the logo on a black screen, straight away, with its cursor. */
static void splash_show(splash_t *splash)
{
    lv_obj_t *screen = lv_screen_active();
    lv_obj_set_style_bg_color(screen, lv_color_black(), 0);
    splash->logo = lv_image_create(screen);
    lv_image_set_src(splash->logo, &dronelab_logo);
    lv_obj_center(splash->logo);

    // Placed where the prompt ends in the picture, scaled to the screen
    lv_display_t *disp = lv_display_get_default();
    int32_t w = lv_display_get_horizontal_resolution(disp);
    int32_t h = lv_display_get_vertical_resolution(disp);
    int32_t art = LV_MIN(w, h);
    splash->cursor = lv_obj_create(screen);
    lv_obj_remove_style_all(splash->cursor);
    lv_obj_set_style_bg_color(splash->cursor, SPLASH_CURSOR_COLOR, 0);
    lv_obj_set_style_bg_opa(splash->cursor, LV_OPA_COVER, 0);
    lv_obj_set_style_shadow_color(splash->cursor, SPLASH_CURSOR_COLOR, 0);
    lv_obj_set_style_shadow_width(splash->cursor, LV_MAX(2, art / 60), 0);
    lv_obj_set_style_shadow_opa(splash->cursor, LV_OPA_60, 0);
    lv_obj_set_pos(splash->cursor,
                   (w - art) / 2 + SPLASH_CURSOR[0] * art / SPLASH_ART_SIZE,
                   (h - art) / 2 + SPLASH_CURSOR[1] * art / SPLASH_ART_SIZE);
    lv_obj_set_size(splash->cursor, LV_MAX(1, SPLASH_CURSOR[2] * art / SPLASH_ART_SIZE),
                    LV_MAX(1, SPLASH_CURSOR[3] * art / SPLASH_ART_SIZE));
    splash->blink = lv_timer_create(splash_blink_cb, SPLASH_BLINK_MS, splash->cursor);

    lv_refr_now(NULL);
    splash->shown_at = lv_tick_get();
}

/* Keep the logo up, its cursor blinking, until SPLASH_MS after it appeared,
 * then take it down. */
static void splash_hide(splash_t *splash)
{
    while (lv_tick_elaps(splash->shown_at) < SPLASH_MS)
    {
        lv_timer_handler();
        rcat_hal_delay_ms(5);
    }
    lv_timer_delete(splash->blink);
    lv_obj_delete(splash->cursor);
    lv_obj_delete(splash->logo);
}

/* On a new board whose speaker plugs in, ask which housing it's in, before
 * anything that uses the speaker starts. The answer can be changed later, on
 * Settings' Speaker page. */
static volatile int speaker_answer;

static void speaker_answer_cb(lv_event_t *e)
{
    speaker_answer = (int)(intptr_t)lv_event_get_user_data(e);
}

static lv_obj_t *speaker_button(lv_obj_t *screen, const char *text, int answer, int32_t y, int32_t px,
                                const lv_font_t *font)
{
    lv_obj_t *button = lv_button_create(screen);
    lv_obj_set_size(button, 170 * px / 240, 44 * px / 240);
    lv_obj_set_style_radius(button, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(button, lv_color_hex(0xff40c0), 0);
    lv_obj_set_style_bg_opa(button, LV_OPA_COVER, 0);
    lv_obj_set_style_shadow_width(button, 0, 0);
    lv_obj_align(button, LV_ALIGN_CENTER, 0, y * px / 240);
    lv_obj_add_event_cb(button, speaker_answer_cb, LV_EVENT_CLICKED, (void *)(intptr_t)answer);
    lv_obj_t *label = lv_label_create(button);
    lv_label_set_text(label, text);
    lv_obj_set_style_text_font(label, font, 0);
    lv_obj_set_style_text_color(label, lv_color_white(), 0);
    lv_obj_center(label);
    return button;
}

static void ask_speaker(void)
{
    if (!settings_speaker_unasked())
    {
        return;
    }
    lv_display_t *disp = lv_display_get_default();
    int32_t px = LV_MIN(lv_display_get_horizontal_resolution(disp), lv_display_get_vertical_resolution(disp));
    const lv_font_t *font = LV_FONT_DEFAULT;
#if LV_FONT_MONTSERRAT_24
    if (px >= 360)
    {
        font = &lv_font_montserrat_24;
    }
#endif
    lv_obj_t *screen = lv_screen_active();
    lv_obj_set_style_bg_color(screen, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);

    lv_obj_t *title = lv_label_create(screen);
    lv_label_set_text(title, "Which model\nis this?");
    lv_obj_set_style_text_font(title, font, 0);
    lv_obj_set_style_text_color(title, lv_color_white(), 0);
    lv_obj_set_style_text_align(title, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(title, LV_ALIGN_CENTER, 0, -66 * px / 240);
    lv_obj_t *speaker = speaker_button(screen, "Speaker", SETTINGS_SPEAKER_FITTED, -8, px, font);
    lv_obj_t *low = speaker_button(screen, "Low-profile", SETTINGS_SPEAKER_NONE, 46, px, font);
    lv_obj_t *hint = lv_label_create(screen);
    lv_label_set_text(hint, "Change it later\nin Settings");
    lv_obj_set_style_text_color(hint, lv_color_hex(0x9e9e9e), 0);
    lv_obj_set_style_text_align(hint, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(hint, LV_ALIGN_CENTER, 0, 92 * px / 240);

    speaker_answer = SETTINGS_SPEAKER_ASK;
    while (speaker_answer == SETTINGS_SPEAKER_ASK)
    {
        lv_timer_handler();
        rcat_hal_delay_ms(5);
    }
    settings_set_speaker((uint8_t)speaker_answer);
    settings_save_now();
    lv_obj_delete(title);
    lv_obj_delete(speaker);
    lv_obj_delete(low);
    lv_obj_delete(hint);
}

/* Built-in images, plus any on the SD card (shown first). storage_path is
 * NULL without a card. Reading the card can take a moment, behind the logo. */
static void load_images(const char *storage_path)
{
    media_init();

    if (storage_path == NULL)
    {
        return;
    }

    lv_display_t *disp = lv_display_get_default();
    int32_t screen_size = LV_MIN(lv_display_get_horizontal_resolution(disp),
                                 lv_display_get_vertical_resolution(disp));
    media_load_folder(storage_path, screen_size);
}

void app_run(void)
{
    if (rcat_hal_init() != 0)
    {
        return;
    }
    settings_init();
    rcat_hal_backlight_set(settings_get()->brightness);

    lv_init();
    rcat_hal_lvgl_register();
    rcat_hal_display_set_rotation(settings_get()->rotation);
    ask_speaker();
    splash_t splash;
    splash_show(&splash);

    const char *storage_path;
    if (!rcat_hal_storage_mount(&storage_path))
    {
        storage_path = NULL;
    }
    load_images(storage_path);
    audio_level_start();                // does nothing on boards without a microphone
    audio_player_init(storage_path);    // or a speaker
    voice_lab_init(storage_path);
    patterns_init(storage_path);        // for the toys
    toys_init();
    others_init();                      // commands from others, over the comm channel
    comm_init();                        // before anything else starts Bluetooth
    direct_init();                      // board to board, over the radio

    battery_log_init();                 // learns the battery's curve from the last run

    splash_hide(&splash);
    ui_init();
    updater_init();
    screenshot_init(storage_path);      // PWR held and BOOT pressed
    console_init();                     // only with RCAT_SERIAL_CONSOLE

    while (1)
    {
        lv_timer_handler();
        rcat_hal_delay_ms(5);
    }
}
