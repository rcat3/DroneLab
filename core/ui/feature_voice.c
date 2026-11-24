/*
 * Voice feature (boards with a microphone): the voice effect and its volume,
 * the seal test (boards that can measure the speaker's echo), and the voice
 * lab (boards with WiFi).
 *
 * The voice ring's settings page is the last of the Sound Visualizer's pages, as
 * the ring is a picture of the voice too (feature_voice_add_ring_page). It
 * only comes here if the Sound Visualizer is left out of a board with a
 * microphone, which none is now.
 *
 * The voice ring itself is drawn over the images feature, and over its own
 * settings page so the color can be previewed.
 */
#include <stdio.h>
#include <string.h>

#include "app/settings.h"
#include "audio/audio_level.h"
#include "audio/seal_test.h"
#include "audio/speaker.h"
#include "audio/voice_fx.h"
#include "audio/voice_lab.h"
#include "hal.h"
#include "ui/ui_internal.h"
#include "ui/voice_ring.h"

static bool build(ui_feature_t *feature);
static void on_navigate(void);

const ui_feature_def_t feature_voice = {
    .name = "Voice",
    .build = build,
    .on_navigate = on_navigate,
};

static lv_obj_t *ring_page;
static lv_obj_t *ring_switch;
static lv_obj_t *ring_roller;
static lv_obj_t *lab_status_label;
static lv_obj_t *lab_switch;
static lv_obj_t *volume_value_label;
static lv_obj_t *effect_roller;
static lv_obj_t *speaker_switch;
static lv_obj_t *volume_slider;
static lv_obj_t *loud_buttons;

#define LAB_POLL_MS 250
#define SYNC_MS     250     // how often the effect pages catch up with the phone remote
#define BUTTON_MS   20      // how often the board's button is checked

/********************************************************************************
function:	Show the voice ring if it's switched on and the page on screen is one
            it belongs on
parameter:
********************************************************************************/
static void on_navigate(void)
{
#if RCAT_FEATURE_IMAGES
    bool on_page = feature_images_on_screen() || ui_current_page() == ring_page;
#else
    bool on_page = ui_current_page() == ring_page;
#endif

    voice_ring_set_color(settings_get()->voice_ring_color);
    voice_ring_set_visible(settings_get()->voice_ring && on_page);
}

static void ring_settings_event_cb(lv_event_t *e)
{
    settings_set_voice_ring(lv_obj_has_state(ring_switch, LV_STATE_CHECKED),
                            lv_roller_get_selected(ring_roller));
    on_navigate();
}

static void add_ring_settings_page(ui_feature_t *feature)
{
    ring_page = ui_feature_add_page(feature, "Voice Ring", false);

    lv_obj_t *title = lv_label_create(ring_page);
    lv_label_set_text(title, "Voice Ring");
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, ui_px(32));

    // Big, so it's easy to hit with a gloved finger
    ring_switch = lv_switch_create(ring_page);
    lv_obj_set_size(ring_switch, ui_px(76), ui_px(38));
    lv_obj_set_ext_click_area(ring_switch, ui_px(8));
    if (settings_get()->voice_ring)
    {
        lv_obj_add_state(ring_switch, LV_STATE_CHECKED);
    }
    lv_obj_align_to(ring_switch, title, LV_ALIGN_OUT_BOTTOM_MID, 0, ui_px(8));
    lv_obj_add_event_cb(ring_switch, ring_settings_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

    uint8_t color = settings_get()->voice_ring_color;
    if (color >= voice_ring_color_count())
    {
        color = 0;
    }
    ring_roller = lv_roller_create(ring_page);
    lv_roller_set_options(ring_roller, voice_ring_color_options(), LV_ROLLER_MODE_NORMAL);
    lv_roller_set_visible_row_count(ring_roller, 3);
    lv_roller_set_selected(ring_roller, color, LV_ANIM_OFF);
    lv_obj_align(ring_roller, LV_ALIGN_CENTER, 0, ui_px(38));      // below the big switch
    lv_obj_add_event_cb(ring_roller, ring_settings_event_cb, LV_EVENT_VALUE_CHANGED, NULL);
}

/* ----- Voice effect ----- */

static void effect_roller_event_cb(lv_event_t *e)
{
    uint32_t preset = lv_roller_get_selected(lv_event_get_target_obj(e));
    voice_fx_set_preset(preset);
    settings_set_voice_effect(preset);
}

static void effect_speaker_event_cb(lv_event_t *e)
{
    voice_fx_set_speaker(lv_obj_has_state(lv_event_get_target_obj(e), LV_STATE_CHECKED));
}

static void add_effect_page(ui_feature_t *feature)
{
    lv_obj_t *page = ui_feature_add_page(feature, "Voice Effect", false);

    lv_obj_t *title = lv_label_create(page);
    // Which it sets: the speaker's, or, without one, what HiveMind hears
    lv_label_set_text(title, settings_speaker_fitted() ? "Speaker Voice Effect" : "HiveMind Voice Effect");
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, ui_px(32));

    // The roller's options, one preset per line.
    static char options[256];
    options[0] = '\0';
    for (size_t i = 0; i < voice_fx_preset_count(); i++)
    {
        if (i > 0)
        {
            strncat(options, "\n", sizeof(options) - strlen(options) - 1);
        }
        strncat(options, voice_fx_preset_name(i), sizeof(options) - strlen(options) - 1);
    }

    uint8_t preset = settings_get()->voice_effect;
    if (preset >= voice_fx_preset_count())
    {
        preset = 0;
    }
    voice_fx_set_preset(preset);

    lv_obj_t *roller = lv_roller_create(page);
    effect_roller = roller;
    lv_roller_set_options(roller, options, LV_ROLLER_MODE_NORMAL);
    lv_roller_set_visible_row_count(roller, 3);
    lv_roller_set_selected(roller, preset, LV_ANIM_OFF);
    lv_obj_align(roller, LV_ALIGN_CENTER, 0, ui_px(-12));
    lv_obj_add_event_cb(roller, effect_roller_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

    // Not saved: with the speaker where it is, it feeds back, so it's always
    // off at startup. Not there at all without a speaker (the low-profile
    // model), where the effect is still what HiveMind sends.
    if (!speaker_start())
    {
        lv_obj_align(roller, LV_ALIGN_CENTER, 0, ui_px(10));
        return;
    }
    lv_obj_t *speaker_label = lv_label_create(page);
    lv_label_set_text(speaker_label, "Play on speaker");
    lv_obj_align(speaker_label, LV_ALIGN_CENTER, 0, ui_px(44));

    // Big, so it's easy to hit with a gloved finger
    speaker_switch = lv_switch_create(page);
    lv_obj_set_size(speaker_switch, ui_px(76), ui_px(38));
    lv_obj_set_ext_click_area(speaker_switch, ui_px(8));
    lv_obj_align(speaker_switch, LV_ALIGN_CENTER, 0, ui_px(76));
    lv_obj_add_event_cb(speaker_switch, effect_speaker_event_cb, LV_EVENT_VALUE_CHANGED, NULL);
}

static void volume_slider_event_cb(lv_event_t *e)
{
    uint8_t volume = lv_slider_get_value(lv_event_get_target_obj(e));
    lv_label_set_text_fmt(volume_value_label, "%d%%", volume);
    voice_fx_set_volume(volume);
    settings_set_voice_volume(volume);
}

static void loud_buttons_event_cb(lv_event_t *e)
{
    uint32_t level = lv_buttonmatrix_get_selected_button(loud_buttons);
    if (level <= VOICE_FX_LOUD_LEVELS)
    {
        voice_fx_set_loud_room((int)level);
        settings_set_voice_loud_room((uint8_t)level);
    }
}

static void add_volume_page(ui_feature_t *feature)
{
    lv_obj_t *page = ui_feature_add_page(feature, "Effect Volume", false);
    uint8_t volume = settings_get()->voice_volume;
    voice_fx_set_volume(volume);
    voice_fx_set_loud_room(settings_get()->voice_loud_room);

    lv_obj_t *title = lv_label_create(page);
    lv_label_set_text(title, "Effect Volume");
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, ui_px(32));

    lv_obj_t *slider = lv_slider_create(page);
    volume_slider = slider;
    lv_obj_set_size(slider, ui_px(160), ui_px(20));
    lv_slider_set_range(slider, 0, 100);
    lv_slider_set_value(slider, volume, LV_ANIM_OFF);
    lv_obj_align(slider, LV_ALIGN_CENTER, 0, ui_px(-30));
    lv_obj_add_event_cb(slider, volume_slider_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

    volume_value_label = lv_label_create(page);
    lv_label_set_text_fmt(volume_value_label, "%d%%", volume);
    lv_obj_align(volume_value_label, LV_ALIGN_CENTER, 0, ui_px(-4));

    // Keeps a loud room's noise out between words (voice_fx_set_loud_room):
    // off, or how loud a room
    lv_obj_t *loud_label = lv_label_create(page);
    lv_label_set_text(loud_label, "Loud room");
    lv_obj_align(loud_label, LV_ALIGN_CENTER, 0, ui_px(30));
    static const char *const levels[] = { "Off", "1", "2", "3", "Max", "" };
    loud_buttons = ui_add_choices(page, levels, ui_px(164), ui_px(36), ui_px(62));
    ui_check_choice(loud_buttons, settings_get()->voice_loud_room);
    lv_obj_add_event_cb(loud_buttons, loud_buttons_event_cb, LV_EVENT_VALUE_CHANGED, NULL);
}

/* Show what the phone remote changed, leaving alone anything that's being
 * touched. */
static void ring_sync(void)
{
    const settings_t *s = settings_get();
    bool changed = false;
    if (lv_obj_has_state(ring_switch, LV_STATE_CHECKED) != (s->voice_ring != 0))
    {
        if (s->voice_ring)
        {
            lv_obj_add_state(ring_switch, LV_STATE_CHECKED);
        }
        else
        {
            lv_obj_remove_state(ring_switch, LV_STATE_CHECKED);
        }
        changed = true;
    }
    if (!lv_obj_has_state(ring_roller, LV_STATE_PRESSED) && s->voice_ring_color < voice_ring_color_count()
        && lv_roller_get_selected(ring_roller) != s->voice_ring_color)
    {
        lv_roller_set_selected(ring_roller, s->voice_ring_color, LV_ANIM_OFF);
        changed = true;
    }
    if (changed)
    {
        on_navigate();
    }
}

static void sync_timer_cb(lv_timer_t *t)
{
    ring_sync();
    const settings_t *s = settings_get();
    if (effect_roller != NULL && !lv_obj_has_state(effect_roller, LV_STATE_PRESSED)
        && s->voice_effect < voice_fx_preset_count() && lv_roller_get_selected(effect_roller) != s->voice_effect)
    {
        lv_roller_set_selected(effect_roller, s->voice_effect, LV_ANIM_OFF);
    }
    if (speaker_switch != NULL && lv_obj_has_state(speaker_switch, LV_STATE_CHECKED) != voice_fx_speaker_on())
    {
        if (voice_fx_speaker_on())
        {
            lv_obj_add_state(speaker_switch, LV_STATE_CHECKED);
        }
        else
        {
            lv_obj_remove_state(speaker_switch, LV_STATE_CHECKED);
        }
    }
    if (loud_buttons != NULL)
    {
        ui_check_choice(loud_buttons, s->voice_loud_room);     // the phone remote can change it too
    }
    if (volume_slider != NULL && !lv_slider_is_dragged(volume_slider)
        && lv_slider_get_value(volume_slider) != s->voice_volume)
    {
        lv_slider_set_value(volume_slider, s->voice_volume, LV_ANIM_OFF);
        lv_label_set_text_fmt(volume_value_label, "%d%%", s->voice_volume);
    }
}

/* The board's spare button (BOOT) switches Play on speaker on and off, to
 * stop feedback quickly without finding the switch. */
static void button_timer_cb(lv_timer_t *t)
{
    if (rcat_hal_button_pressed())
    {
        voice_fx_set_speaker(!voice_fx_speaker_on());
        sync_timer_cb(NULL);
    }
}

/* ----- Seal test ----- */

static lv_obj_t *seal_page;
static lv_obj_t *seal_status_label;
static lv_obj_t *seal_big_label;
static lv_obj_t *seal_button_label;
static lv_obj_t *seal_mode_label;
static seal_mode_t seal_mode;
static bool seal_results_up;    // the last test's results are showing, until Done

static void seal_show(seal_phase_t phase, int seconds_left)
{
    if (phase == SEAL_DONE && !seal_results_up)
    {
        phase = SEAL_IDLE;      // back to choosing a test
    }
    switch (phase)
    {
    // While it runs, big and short, to read in a mirror with the mask on
    case SEAL_QUIET:
    case SEAL_NOISE:
    case SEAL_BANDS:
    case SEAL_LOUD:
    case SEAL_FEEDBACK:
        lv_label_set_text(seal_big_label, "Quiet");
        lv_obj_set_style_text_color(seal_big_label, lv_color_white(), 0);
        lv_label_set_text_fmt(seal_status_label, "%d", seconds_left);
        break;
    case SEAL_VOICE:
        lv_label_set_text(seal_big_label, "Say\n\"aaah\"");
        lv_obj_set_style_text_color(seal_big_label, lv_palette_main(LV_PALETTE_PINK), 0);
        lv_label_set_text_fmt(seal_status_label, "%d", seconds_left);
        break;
    case SEAL_DONE:
    {
        const seal_result_t *r = seal_test_result();
        char balance[24];
        if (r->balance == SEAL_SKIPPED)
        {
            snprintf(balance, sizeof(balance), "-");
        }
        else
        {
            snprintf(balance, sizeof(balance), "%+.0f dB %s", r->balance_db, seal_test_grade_name(r->balance));
        }
        if (r->leak == SEAL_SKIPPED)
        {
            lv_label_set_text(seal_status_label, r->advice);
        }
        else if (r->mode == SEAL_TEST_FULL)
        {
            // The spare's what's graded: the leak and echo are there to
            // compare. The bands are in the serial log and the phone
            // remote's API.
            char text[240];
            char where[24] = "";
            if (r->worst_band >= 0)
            {
                snprintf(where, sizeof(where), " (%.1f kHz)", r->bands[r->worst_band].hz / 1000.0f);
            }
            snprintf(text, sizeof(text), "Spare %+.0f dB %s%s\nLeak %+.0f dB (%+.0f..%+.0f)\nEcho %+.0f dB (%+.0f..%+.0f)\n"
                     "Loud %+.0f dB %s\nMics %s\n\n%s",
                     r->spare_db, seal_test_grade_name(r->spare), where, r->leak_db, r->leak_min, r->leak_max,
                     r->cancelled_db, r->cancelled_min, r->cancelled_max, r->loud_cancelled_db,
                     seal_test_grade_name(r->loud), balance, r->advice);
            lv_label_set_text(seal_status_label, text);
        }
        else
        {
            // LVGL's own formatting has no floats
            char text[200];
            snprintf(text, sizeof(text), "Spare %+.0f dB %s\nLeak %+.0f dB\nEcho %+.0f dB\nMics %s\n\n%s", r->spare_db,
                     seal_test_grade_name(r->spare), r->leak_db, r->cancelled_db, balance, r->advice);
            lv_label_set_text(seal_status_label, text);
        }
        break;
    }
    default:
        switch (seal_mode)
        {
        case SEAL_TEST_FULL:
            lv_label_set_text(seal_status_label, "Five times over, band by\nband, then loud: about a\nminute. Put the mask on\nsomewhere quiet.");
            break;
        case SEAL_TEST_FEEDBACK:
            lv_label_set_text(seal_status_label, "Turns Natural up until\nit feeds back, then stops.\nIt squeals briefly.\nStay quiet.");
            break;
        default:
            lv_label_set_text(seal_status_label, "How loud it can go\nbefore it feeds back.\nPut the mask on\nsomewhere quiet.");
            break;
        }
        break;
    }
    if (phase == SEAL_FEEDBACK)
    {
        lv_label_set_text_fmt(seal_status_label, "%+d dB", (int)seal_test_feedback_gain_db());
    }
    bool running = phase != SEAL_IDLE && phase != SEAL_DONE;
    lv_label_set_text(seal_button_label, running ? "Stop" : phase == SEAL_DONE ? "Done" : "Start");
    // Tap the line under the title for the other tests. The results have
    // the screen to themselves.
    char mode[48];
    snprintf(mode, sizeof(mode), running ? "%s" : "< %s >", seal_test_mode_name(running ? seal_test_result()->mode : seal_mode));
    lv_label_set_text(seal_mode_label, mode);
    lv_obj_set_hidden(lv_obj_get_parent(seal_mode_label), phase == SEAL_DONE);
    // While it runs, the countdown's as big as the instruction above it
    if (running)
    {
        lv_obj_set_style_text_font(seal_status_label, lv_obj_get_style_text_font(seal_big_label, 0), 0);
    }
    else
    {
        lv_obj_remove_local_style_prop(seal_status_label, LV_STYLE_TEXT_FONT, 0);
    }
    if (running)
    {
        lv_obj_set_hidden(seal_big_label, false);
        lv_obj_align(seal_status_label, LV_ALIGN_CENTER, 0, ui_px(40));
    }
    else
    {
        lv_obj_set_hidden(seal_big_label, true);
        lv_obj_align(seal_status_label, LV_ALIGN_CENTER, 0, ui_px(-10));
    }
}

/* Runs the test, however it was started (here, or by the phone remote) */
static void seal_timer_cb(lv_timer_t *t)
{
    static seal_phase_t shown = SEAL_IDLE;
    static int shown_left = -1;
    static float shown_gain;
    int left;
    seal_phase_t phase = seal_test_tick(&left);
    if (phase == shown && (phase == SEAL_DONE || phase == SEAL_IDLE ||
                           (left == shown_left && (phase != SEAL_FEEDBACK || seal_test_feedback_gain_db() == shown_gain))))
    {
        return;
    }
    shown_left = left;
    shown_gain = seal_test_feedback_gain_db();
    if (phase == SEAL_DONE || phase == SEAL_IDLE)
    {
        sync_timer_cb(NULL);    // the speaker switch is back as it was
    }
    else if (shown == SEAL_IDLE || shown == SEAL_DONE)
    {
        ui_show_page(seal_page);    // started by the phone remote: show it
    }
    if (phase != SEAL_IDLE)
    {
        seal_results_up = true;     // however it was started
    }
    shown = phase;
    seal_show(phase, left);
}

static void seal_button_event_cb(lv_event_t *e)
{
    seal_phase_t phase = seal_test_phase();
    if (phase == SEAL_DONE && seal_results_up)
    {
        seal_results_up = false;    // Done: back to choosing a test
    }
    else if (phase == SEAL_IDLE || phase == SEAL_DONE)
    {
        seal_test_start(seal_mode);
        seal_results_up = true;
    }
    else
    {
        seal_test_cancel();
        sync_timer_cb(NULL);
    }
    seal_show(seal_test_phase(), seal_test_seconds_left());
}

static void seal_mode_event_cb(lv_event_t *e)
{
    seal_phase_t phase = seal_test_phase();
    if (phase == SEAL_IDLE || (phase == SEAL_DONE && !seal_results_up))
    {
        seal_mode = (seal_mode + 1) % SEAL_TEST_MODES;
        seal_show(SEAL_IDLE, 0);
    }
}

static void add_seal_page(ui_feature_t *feature)
{
    lv_obj_t *page = ui_feature_add_page(feature, "Seal Test", false);
    seal_page = page;

    lv_obj_t *title = lv_label_create(page);
    lv_label_set_text(title, "Seal Test");
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, ui_px(32));

    // Which test: tap to change. A big target, for a finger.
    lv_obj_t *mode = lv_obj_create(page);
    lv_obj_remove_style_all(mode);
    lv_obj_set_size(mode, ui_px(160), ui_px(30));
    lv_obj_align(mode, LV_ALIGN_TOP_MID, 0, ui_px(52));
    lv_obj_set_clickable(mode, true);
    lv_obj_add_event_cb(mode, seal_mode_event_cb, LV_EVENT_CLICKED, NULL);
    seal_mode_label = lv_label_create(mode);
    lv_obj_set_style_text_color(seal_mode_label, lv_palette_main(LV_PALETTE_PINK), 0);
    lv_obj_center(seal_mode_label);

    seal_status_label = lv_label_create(page);
    lv_label_set_long_mode(seal_status_label, LV_LABEL_LONG_MODE_WRAP);
    lv_obj_set_width(seal_status_label, ui_px(190));
    lv_obj_set_style_text_align(seal_status_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(seal_status_label, LV_ALIGN_CENTER, 0, ui_px(-10));

    // The instruction while it runs, as big as the board has
    seal_big_label = lv_label_create(page);
    lv_obj_set_style_text_align(seal_big_label, LV_TEXT_ALIGN_CENTER, 0);
#if LV_FONT_MONTSERRAT_48
    if (ui_px(240) >= 360)
    {
        lv_obj_set_style_text_font(seal_big_label, &lv_font_montserrat_48, 0);
    }
#endif
    lv_obj_align(seal_big_label, LV_ALIGN_CENTER, 0, ui_px(-12));
    lv_obj_set_hidden(seal_big_label, true);

    lv_obj_t *button = lv_button_create(page);
    lv_obj_set_size(button, ui_px(120), ui_px(38));
    lv_obj_set_style_radius(button, LV_RADIUS_CIRCLE, 0);
    lv_obj_align(button, LV_ALIGN_BOTTOM_MID, 0, ui_px(-26));
    lv_obj_add_event_cb(button, seal_button_event_cb, LV_EVENT_CLICKED, NULL);
    seal_button_label = lv_label_create(button);
    lv_obj_center(seal_button_label);

    lv_timer_create(seal_timer_cb, SEAL_TICK_MS, NULL);
    seal_show(SEAL_IDLE, 0);
}

/* ----- Voice lab ----- */

static void lab_timer_cb(lv_timer_t *t)
{
    if (!voice_lab_running())
    {
        // Stopped by something else that needed the WiFi (the phone remote)
        lv_obj_remove_state(lab_switch, LV_STATE_CHECKED);
        lv_timer_pause(t);
    }
    voice_lab_poll(lv_tick_get());

    char text[64];
    voice_lab_status(text, sizeof(text));
    if (strcmp(lv_label_get_text(lab_status_label), text) != 0)
    {
        lv_label_set_text(lab_status_label, text);
    }
}

static void lab_switch_event_cb(lv_event_t *e)
{
    lv_obj_t *sw = lv_event_get_target_obj(e);
    lv_timer_t *timer = lv_event_get_user_data(e);

    if (lv_obj_has_state(sw, LV_STATE_CHECKED))
    {
        const char *error = voice_lab_start();
        if (error != NULL)
        {
            lv_obj_remove_state(sw, LV_STATE_CHECKED);
            lv_label_set_text(lab_status_label, error);
            return;
        }
        lv_timer_resume(timer);
    }
    else
    {
        voice_lab_stop();
        lv_timer_pause(timer);
    }
    lab_timer_cb(timer);
}

static void add_lab_page(ui_feature_t *feature)
{
    lv_obj_t *page = ui_feature_add_page(feature, "Voice Lab", false);

    lv_obj_t *title = lv_label_create(page);
    lv_label_set_text(title, "Voice Lab");
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, ui_px(32));

    lv_obj_t *help = lv_label_create(page);
    lv_label_set_text(help, "Streams the microphone to\nvoice_monitor.py over WiFi");
    lv_obj_set_style_text_align(help, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(help, lv_palette_main(LV_PALETTE_GREY), 0);
    lv_obj_align(help, LV_ALIGN_CENTER, 0, ui_px(-52));

    lv_timer_t *timer = lv_timer_create(lab_timer_cb, LAB_POLL_MS, NULL);
    lv_timer_pause(timer);

    // Big, like the others, so it's easy to hit
    lv_obj_t *sw = lv_switch_create(page);
    lab_switch = sw;
    lv_obj_set_size(sw, ui_px(76), ui_px(38));
    lv_obj_set_ext_click_area(sw, ui_px(8));
    lv_obj_align(sw, LV_ALIGN_CENTER, 0, ui_px(-2));
    lv_obj_add_event_cb(sw, lab_switch_event_cb, LV_EVENT_VALUE_CHANGED, timer);

    lab_status_label = lv_label_create(page);
    lv_label_set_text(lab_status_label, "Off");
    lv_label_set_long_mode(lab_status_label, LV_LABEL_LONG_MODE_WRAP);
    lv_obj_set_width(lab_status_label, ui_px(170));
    lv_obj_set_style_text_align(lab_status_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(lab_status_label, LV_ALIGN_CENTER, 0, ui_px(46));
}

static bool ring_added;

bool feature_voice_add_ring_page(ui_feature_t *feature)
{
    if (ring_added || !audio_level_available())
    {
        return false;
    }
    voice_ring_create();
    add_ring_settings_page(feature);
    ring_added = true;
    return true;
}

void feature_voice_on_navigate(void)
{
    if (ring_added)
    {
        on_navigate();
    }
}

static bool build(ui_feature_t *feature)
{
    if (!audio_level_available())
    {
        return false;
    }

    bool any = feature_voice_add_ring_page(feature);   // unless the Sound Visualizer has it
    if (voice_fx_start())
    {
        any = true;
        add_effect_page(feature);
        if (speaker_start())
        {
            add_volume_page(feature);
        }
        if (seal_test_available())
        {
            add_seal_page(feature);
        }
        lv_timer_create(button_timer_cb, BUTTON_MS, NULL);
    }
    lv_timer_create(sync_timer_cb, SYNC_MS, NULL);
    if (voice_lab_available())
    {
        add_lab_page(feature);
        any = true;
    }
    return any;     // left out if the Sound Visualizer has the ring and there's nothing else
}
