/*
 * Sound Visualizer feature (boards with a microphone): a full screen picture of
 * the wearer's voice, and of whatever the speaker is playing, in one of
 * several styles (see visualizer.h). Its pages are the visualizer, a page to
 * choose the style, and the voice ring's settings (feature_voice.c), as the
 * ring is a picture of the voice too. Tapping the visualizer moves on to the
 * next style.
 *
 * The visualizer draws into a canvas the size of the screen, a frame at a
 * time while it's on screen, and only the part it draws in is sent to the
 * display.
 */
#include <string.h>

#include "app/settings.h"
#include "audio/audio_level.h"
#include "audio/audio_player.h"
#include "audio/audio_tap.h"
#include "ui/ui.h"
#include "ui/ui_internal.h"
#include "ui/visualizer.h"

#define FRAME_MS        33      // 30 frames a second, if the display keeps up
#define SYNC_MS         250     // how often the chooser catches up with the phone remote
#define MAX_DT_S        0.1f    // longer gaps (a slow frame) count as this long
#define OVERRIDE_MS     100     // how often a sound others sent is checked on
#define OVERRIDE_START_MS   2000    // how long its sound has to start playing
#define OVERRIDE_SHOWN_MS   500     // before then, the page may still be sliding in
#define OVERRIDE_LIMIT_MS   (AUDIO_SENT_MAX_MS + 2000)  // however long it goes on

// The styles, in the order they're listed. New ones go on the end, so the
// saved choice still means the same one.
static const visualizer_t *const visualizers[] = {
    &vis_kitt, &vis_terrain, &vis_scope, &vis_halo, &vis_aurora, &vis_orbit, &vis_ripples,
};
#define VISUALIZER_COUNT (sizeof(visualizers) / sizeof(visualizers[0]))

static bool build(ui_feature_t *feature);

static void on_navigate(void)
{
#if RCAT_FEATURE_VOICE
    feature_voice_on_navigate();    // the voice ring, on its own page
#endif
}

const ui_feature_def_t feature_visualizer = {
    .name = UI_SOUND_VISUALIZER,
    .build = build,
    .on_navigate = on_navigate,
};

static lv_obj_t *canvas;
static lv_obj_t *roller;
static vis_canvas_t pixels;
static vis_audio_t *audio;      // allocated, to keep it out of internal RAM
static size_t current;
static bool running;            // false to start the current one afresh on the next frame
static uint32_t last_frame;

// A sound others sent can bring the visualizer on screen, in the style they
// chose and drawing only the sound, until it's been played (see
// ui_visualizer_show_for_sound). The saved choice isn't touched.
static bool override_on;
static bool override_started;   // its sound has been heard playing
static uint32_t override_since;

static size_t saved_choice(void)
{
    uint8_t index = settings_get()->visualizer;
    return index < VISUALIZER_COUNT ? index : 0;
}

static void choose(size_t index, bool save)
{
    current = index;
    running = false;
    if (save)
    {
        settings_set_visualizer((uint8_t)index);
    }
    if (roller != NULL && !lv_obj_has_state(roller, LV_STATE_PRESSED) && lv_roller_get_selected(roller) != index)
    {
        lv_roller_set_selected(roller, (uint32_t)index, LV_ANIM_OFF);
    }
}

/* Tell LVGL a square around the middle of the canvas has changed. */
static void invalidate(uint8_t extent)
{
    int32_t side = pixels.size * extent / 100;
    lv_area_t coords;
    lv_obj_get_coords(canvas, &coords);
    int32_t x = coords.x1 + pixels.cx - side / 2;
    int32_t y = coords.y1 + pixels.cy - side / 2;
    lv_area_t area = {
        .x1 = LV_MAX(x, coords.x1),
        .y1 = LV_MAX(y, coords.y1),
        .x2 = LV_MIN(x + side - 1, coords.x2),
        .y2 = LV_MIN(y + side - 1, coords.y2),
    };
    lv_obj_invalidate_area(canvas, &area);
}

/* Stop showing a sound others sent: all the sound again, in the saved style. */
static void end_override(void)
{
    override_on = false;
    vis_audio_speaker_only(false);
    choose(saved_choice(), false);
}

static void frame_timer_cb(lv_timer_t *t)
{
    // Nothing to do while the page is scrolled off screen. It starts afresh
    // when it's back.
    if (!lv_obj_is_visible(canvas))
    {
        running = false;
        return;
    }

    const visualizer_t *vis = visualizers[current];
    uint32_t now = lv_tick_get();
    if (!running)
    {
        vis_clear(&pixels, LV_MAX(pixels.w, pixels.h));
        vis_audio_reset();
        memset(audio, 0, sizeof(*audio));
        if (vis->start != NULL)
        {
            vis->start(&pixels);
        }
        lv_obj_invalidate(canvas);
        running = true;
        last_frame = now;
    }

    float dt = lv_tick_diff(now, last_frame) / 1000.0f;
    last_frame = now;
    dt = dt > MAX_DT_S ? MAX_DT_S : dt <= 0.0f ? FRAME_MS / 1000.0f : dt;
    vis_audio_update(audio, dt);
    if (vis->draw(&pixels, audio))
    {
        invalidate(vis->extent);
    }
}

/* Show what the phone remote chose. */
static void sync_timer_cb(lv_timer_t *t)
{
    if (!override_on && saved_choice() != current)
    {
        choose(saved_choice(), false);
    }
}

/* Watch for the end of the sound shown. chiming only turns true a little
 * after it's handed to the speaker's task, so it's waited for first. */
static void override_timer_cb(lv_timer_t *t)
{
    if (!override_on)
    {
        return;
    }
    uint32_t elapsed = lv_tick_diff(lv_tick_get(), override_since);
    if (audio_player_chiming())
    {
        override_started = true;
    }
    bool done = elapsed > OVERRIDE_LIMIT_MS || (override_started ? !audio_player_chiming() : elapsed > OVERRIDE_START_MS);
    if (done)
    {
        end_override();
        ui_go_back();       // only goes back if this is still what's showing
    }
    else if (elapsed > OVERRIDE_SHOWN_MS && !lv_obj_is_visible(canvas))
    {
        end_override();     // swiped away: the sound finishes on its own
    }
}

static void canvas_clicked_cb(lv_event_t *e)
{
    if (override_on)
    {
        // Their choice is the wearer's now: keep the screen, and all the sound
        override_on = false;
        vis_audio_speaker_only(false);
    }
    choose((current + 1) % VISUALIZER_COUNT, true);
}

static void roller_event_cb(lv_event_t *e)
{
    choose(lv_roller_get_selected(roller), true);
}

static bool add_visualizer_page(ui_feature_t *feature)
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
    vis_clear(&pixels, LV_MAX(w, h));

    lv_obj_t *page = ui_feature_add_page(feature, UI_SOUND_VISUALIZER, true);
    canvas = lv_canvas_create(page);
    lv_canvas_set_draw_buf(canvas, buf);
    lv_obj_center(canvas);
    lv_obj_set_clickable(canvas, true);
    lv_obj_add_event_cb(canvas, canvas_clicked_cb, LV_EVENT_CLICKED, NULL);
    ui_add_startup_choice(feature, page, UI_SOUND_VISUALIZER, SETTINGS_STARTUP_VISUALIZER);
    return true;
}

static void add_chooser_page(ui_feature_t *feature)
{
    lv_obj_t *page = ui_feature_add_page(feature, "Choose Sound Visualizer", false);

    lv_obj_t *title = lv_label_create(page);
    lv_label_set_text(title, "Sound Visualizer");
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, ui_px(32));

    static char options[128];
    options[0] = '\0';
    for (size_t i = 0; i < VISUALIZER_COUNT; i++)
    {
        if (i > 0)
        {
            strncat(options, "\n", sizeof(options) - strlen(options) - 1);
        }
        strncat(options, visualizers[i]->name, sizeof(options) - strlen(options) - 1);
    }

    roller = lv_roller_create(page);
    lv_roller_set_options(roller, options, LV_ROLLER_MODE_NORMAL);
    lv_roller_set_visible_row_count(roller, 3);
    lv_roller_set_selected(roller, (uint32_t)current, LV_ANIM_OFF);
    lv_obj_align(roller, LV_ALIGN_CENTER, 0, ui_px(-4));
    lv_obj_add_event_cb(roller, roller_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

    lv_obj_t *help = lv_label_create(page);
    lv_label_set_text(help, "Or tap the visualizer\nto change it");
    lv_obj_set_style_text_align(help, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(help, lv_palette_main(LV_PALETTE_GREY), 0);
    lv_obj_align(help, LV_ALIGN_CENTER, 0, ui_px(66));
}

static bool build(ui_feature_t *feature)
{
    if (!audio_level_available() || !audio_tap_start())
    {
        return false;
    }

    current = saved_choice();
    audio = vis_alloc(sizeof(vis_audio_t));
    if (audio == NULL || !add_visualizer_page(feature))
    {
        return false;
    }
    add_chooser_page(feature);
#if RCAT_FEATURE_VOICE
    feature_voice_add_ring_page(feature);
#endif
    lv_timer_create(frame_timer_cb, FRAME_MS, NULL);
    lv_timer_create(sync_timer_cb, SYNC_MS, NULL);
    lv_timer_create(override_timer_cb, OVERRIDE_MS, NULL);
    return true;
}

size_t ui_visualizer_count(void)
{
    return canvas != NULL ? VISUALIZER_COUNT : 0;
}

const char *ui_visualizer_name(size_t index)
{
    return index < ui_visualizer_count() ? visualizers[index]->name : "";
}

void ui_visualizer_show_for_sound(size_t index)
{
    if (canvas == NULL || index >= VISUALIZER_COUNT)
    {
        return;
    }
    override_on = true;
    override_started = false;
    override_since = lv_tick_get();
    choose(index, false);       // not saved: it's only for this sound
    vis_audio_speaker_only(true);
    // The canvas sits straight on its page. Zero seconds: it stays until the
    // timer above sends it back.
    ui_show_page_for(lv_obj_get_parent(canvas), 0);
}
