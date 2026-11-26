/*
 * Images feature: a page per image (from the SD card, then built in), then
 * the pictures others have sent (app/pictures.h), and a blank black page at
 * the end.
 *
 * A sent picture's page says it was received, for a moment each time it
 * comes on screen, as the navigation dots do; touching it offers to delete
 * it.
 */
#include <string.h>

#include "app/pictures.h"
#include "app/settings.h"
#include "media/media_library.h"
#include "ui/ui_internal.h"

#define MARK_SHOW_MS    1500        // as the navigation dots
#define MARK_FADE_MS    400

static bool build(ui_feature_t *feature);
static void on_navigate(void);

static ui_feature_t *images_feature;
static lv_obj_t *blank;
static lv_obj_t *mark;              // "Received", over a sent picture's page
static lv_obj_t *asking;            // whether to delete one, while it asks
static lv_obj_t *asking_page;
static lv_obj_t *last_page;

const ui_feature_def_t feature_images = {
    .name = "Images",
    .build = build,
    .on_navigate = on_navigate,
};

/* The picture on a page: an animated GIF, or a still one. */
static lv_obj_t *add_picture(lv_obj_t *page, const void *src, bool is_gif, uint16_t scale)
{
    lv_obj_t *img;
    if (is_gif)
    {
        img = lv_gif_create(page);
        // Decode straight to RGB565 to use half the RAM of the ARGB8888 default.
        lv_gif_set_color_format(img, LV_COLOR_FORMAT_RGB565);
        lv_gif_set_src(img, src);
        // Always loop forever. Some GIFs store a loop count, and LVGL (9.5, 9.6)
        // reads counts above 32767 as negative, which makes it stop after one pass.
        lv_gif_set_loop_count(img, 0);
        // GIFs from the SD card, or sent, may need scaling for this screen.
        if (scale != LV_SCALE_NONE)
        {
            lv_image_set_scale(img, scale);
        }
    }
    else
    {
        img = lv_image_create(page);
        lv_image_set_src(img, src);
    }
    lv_obj_align(img, LV_ALIGN_CENTER, 0, 0);
    return img;
}

/* The media list moves as pictures are saved to the card and deleted, so
 * its names can't be kept: a page keeps a copy of its own, freed with it,
 * and its startup choice another, which stays as the choices do. */
static void add_image_page(ui_feature_t *feature, const media_item_t *pic)
{
    lv_obj_t *page = ui_feature_add_page(feature, lv_strdup(pic->name), true);
    add_picture(page, pic->src, pic->is_gif, pic->scale);
    const char *choice = lv_strdup(pic->name);
    ui_add_startup_choice(feature, page, choice, choice);
}

bool feature_images_on_screen(void)
{
    return images_feature != NULL && ui_feature_is_current(images_feature);
}

lv_obj_t *feature_images_built_in_page(const char *name)
{
    if (images_feature == NULL)
    {
        return NULL;
    }
    // The built-in ones are the last of the media, after the SD card's
    size_t first = media_count() - media_built_in_count();
    for (size_t i = first; i < media_count(); i++)
    {
        if (strcmp(media_get(i)->name, name) == 0)
        {
            return ui_page_of(images_feature, i);
        }
    }
    return NULL;
}

/* ----- Pictures saved to the card, or deleted from it, while it runs ----- */

void feature_images_add_stored(size_t index)
{
    const media_item_t *pic = media_get(index);
    if (images_feature == NULL || pic == NULL)
    {
        return;
    }
    // No startup choice till the next start: the lists of them are fixed
    lv_obj_t *page = ui_feature_insert_page(images_feature, index, lv_strdup(pic->name), true);
    add_picture(page, pic->src, pic->is_gif, pic->scale);
}

void feature_images_remove_stored(size_t index)
{
    // Called before media_remove_file(), while the page's still there
    lv_obj_t *page = images_feature != NULL ? ui_page_of(images_feature, index) : NULL;
    if (page == NULL)
    {
        return;
    }
    ui_startup_choice_page_gone(page);
    if (last_page == page)
    {
        last_page = NULL;
    }
    void *name = lv_obj_get_user_data(page);
    ui_feature_remove_page(images_feature, page);
    lv_free(name);
}

/* ----- Deleting a sent one ----- */

static void close_asking(void)
{
    if (asking != NULL)
    {
        lv_obj_delete(asking);
        asking = NULL;
        asking_page = NULL;
    }
}

/* Done after the button's event, which can't delete what it's in. */
static void delete_later(void *arg)
{
    (void)arg;
    lv_obj_t *page = asking_page;   // NULL if it's gone meanwhile
    close_asking();
    if (page != NULL)
    {
        pictures_delete_page(page);
    }
}

static void keep_later(void *arg)
{
    (void)arg;
    close_asking();
}

static void delete_cb(lv_event_t *e)
{
    lv_async_call(delete_later, NULL);
}

static void keep_cb(lv_event_t *e)
{
    lv_async_call(keep_later, NULL);
}

static lv_obj_t *add_button(lv_obj_t *parent, const char *text, bool pink, lv_event_cb_t cb)
{
    lv_obj_t *b = lv_button_create(parent);
    lv_obj_set_size(b, ui_px(84), ui_px(36));
    if (!pink)
    {
        lv_obj_set_style_bg_color(b, lv_color_hex(0x2a2a2a), 0);
    }
    lv_obj_add_event_cb(b, cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *l = lv_label_create(b);
    lv_label_set_text(l, text);
    lv_obj_center(l);
    return b;
}

/* Touched: ask whether to delete it, over it. */
static void received_touched_cb(lv_event_t *e)
{
    lv_obj_t *page = lv_event_get_current_target(e);
    if (asking != NULL || page != ui_current_page())
    {
        return;
    }
    asking_page = page;
    asking = lv_obj_create(page);
    lv_obj_remove_style_all(asking);
    lv_obj_set_size(asking, lv_pct(100), lv_pct(100));
    lv_obj_set_style_bg_color(asking, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(asking, LV_OPA_70, 0);
    lv_obj_set_clickable(asking, true);     // so touching round the buttons doesn't ask again

    lv_obj_t *q = lv_label_create(asking);
    lv_label_set_text(q, "Delete this picture?");
    lv_obj_set_style_text_color(q, lv_color_white(), 0);
    lv_obj_align(q, LV_ALIGN_CENTER, 0, -ui_px(30));

    lv_obj_t *del = add_button(asking, "Delete", true, delete_cb);
    lv_obj_align(del, LV_ALIGN_CENTER, -ui_px(46), ui_px(20));
    lv_obj_t *keep = add_button(asking, "Keep", false, keep_cb);
    lv_obj_align(keep, LV_ALIGN_CENTER, ui_px(46), ui_px(20));
}

/* ----- Sent ones' pages ----- */

lv_obj_t *feature_images_add_received(const void *src, bool is_gif, uint16_t scale)
{
    if (images_feature == NULL)
    {
        return NULL;
    }
    // Before the blank page, the last
    size_t at = ui_feature_page_count(images_feature) - 1;
    lv_obj_t *page = ui_feature_insert_page(images_feature, at, "Received", true);
    add_picture(page, src, is_gif, scale);
    lv_obj_set_clickable(page, true);
    lv_obj_add_event_cb(page, received_touched_cb, LV_EVENT_SHORT_CLICKED, NULL);
    lv_obj_add_event_cb(page, received_touched_cb, LV_EVENT_LONG_PRESSED, NULL);
    lv_obj_set_user_data(lv_obj_get_child(page, 0), (void *)1);    // marks it as sent
    return page;
}

void feature_images_remove_received(lv_obj_t *page)
{
    if (images_feature == NULL || page == NULL)
    {
        return;
    }
    if (asking_page == page)
    {
        close_asking();
    }
    if (last_page == page)
    {
        last_page = NULL;
    }
    ui_feature_remove_page(images_feature, page);
}

static bool is_received(lv_obj_t *page)
{
    return page != NULL && page != blank && lv_obj_get_child_count(page) > 0
           && lv_obj_get_user_data(lv_obj_get_child(page, 0)) == (void *)1;
}

/* Say it was received, for a moment, each time a sent one comes on. */
static void on_navigate(void)
{
    lv_obj_t *page = feature_images_on_screen() ? ui_current_page() : NULL;
    if (page == last_page)
    {
        return;
    }
    last_page = page;
    close_asking();
    if (mark == NULL)
    {
        return;
    }
    lv_anim_delete(mark, NULL);
    lv_obj_set_hidden(mark, !is_received(page));
    if (is_received(page))
    {
        lv_obj_set_style_opa(mark, LV_OPA_COVER, 0);
        lv_obj_fade_out(mark, MARK_FADE_MS, MARK_SHOW_MS);
    }
}

static bool build(ui_feature_t *feature)
{
    images_feature = feature;

    for (size_t i = 0; i < media_count(); i++)
    {
        add_image_page(feature, media_get(i));
    }

    blank = ui_feature_add_page(feature, "Blank", true);
    ui_add_startup_choice(feature, blank, "Blank", SETTINGS_STARTUP_BLANK);

    // A pill like the navigation dots', at the top
    mark = lv_label_create(lv_layer_top());
    lv_label_set_text(mark, "Received");
    lv_obj_set_style_text_color(mark, lv_color_white(), 0);
    lv_obj_set_style_bg_color(mark, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(mark, LV_OPA_50, 0);
    lv_obj_set_style_radius(mark, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_pad_hor(mark, ui_px(8), 0);
    lv_obj_set_style_pad_ver(mark, ui_px(3), 0);
    lv_obj_set_clickable(mark, false);
    lv_obj_align(mark, LV_ALIGN_TOP_MID, 0, ui_px(14));
    lv_obj_set_hidden(mark, true);
    return true;
}
