/*****************************************************************************
* | File      	:   ui.c
* | Author      :   Waveshare team, Rubber Cat
* | Function    :   Feature and page navigation
* | Info        :   Originally based on the Waveshare LVGL demo
*----------------
* |	This version:   V1.0
* | Date        :   2023-12-23
* | Info        :
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documnetation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to  whom the Software is
# furished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS OR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
******************************************************************************/

#include <string.h>

#include "app/settings.h"
#include "lvgl.h"
#include "ui/nav_dots.h"
#include "ui/ui.h"
#include "ui/ui_internal.h"
#include "ui/update_screen.h"

// The features, top to bottom. Each one is defined in its own feature_*.c.
// All but settings are optional, and each platform picks which to build in
// its features.cmake.
extern const ui_feature_def_t feature_images;
extern const ui_feature_def_t feature_visualizer;
extern const ui_feature_def_t feature_voice;
extern const ui_feature_def_t feature_sound;
extern const ui_feature_def_t feature_comm;
extern const ui_feature_def_t feature_toys;
extern const ui_feature_def_t feature_terminal;
extern const ui_feature_def_t feature_settings;

static const ui_feature_def_t *const feature_defs[] = {
#if RCAT_FEATURE_IMAGES
    &feature_images,
#endif
#if RCAT_FEATURE_VISUALIZER
    &feature_visualizer,
#endif
#if RCAT_FEATURE_VOICE
    &feature_voice,
#endif
#if RCAT_FEATURE_SOUND
    &feature_sound,
#endif
#if RCAT_FEATURE_COMM
    &feature_comm,
#endif
#if RCAT_FEATURE_TERMINAL
    &feature_terminal,
#endif
#if RCAT_FEATURE_TOYS
    &feature_toys,
#endif
    &feature_settings,   // last, so it can list every feature's startup choices
};
#define FEATURE_COUNT       (sizeof(feature_defs) / sizeof(feature_defs[0]))
#define MAX_STARTUP_CHOICES 64

// The layout was designed for a 240x240 screen and is scaled up for bigger ones.
#define DESIGN_SIZE 240

struct ui_feature
{
    const ui_feature_def_t *def;
    lv_obj_t *row;          // this feature's tile in the up/down tile view
    lv_obj_t *pages;        // left/right tile view holding its pages
    uint8_t page_count;
};

typedef struct
{
    ui_feature_t *feature;
    lv_obj_t *page;
    const char *label;
    const char *value;
} startup_choice_t;

static lv_obj_t *features_view;     // up/down tile view
static ui_feature_t features[FEATURE_COUNT];
static uint8_t feature_count;
static startup_choice_t startup_choices[MAX_STARTUP_CHOICES];
static size_t startup_choice_count;
static int32_t screen_size;

#if !RCAT_FEATURE_VISUALIZER
// Without the feature, there are no visualizers for the phone remote to list.
size_t ui_visualizer_count(void)
{
    return 0;
}

const char *ui_visualizer_name(size_t index)
{
    return "";
}
#endif

static void setup_theme(void);
static void show_startup_page(void);
static void navigate_event_cb(lv_event_t *e);

int32_t ui_px(int32_t design_px)
{
    return design_px * screen_size / DESIGN_SIZE;
}

/********************************************************************************
function:	Build every feature that the board supports and show the startup
            page
parameter:
********************************************************************************/
void ui_init(void)
{
    setup_theme();

    features_view = lv_tileview_create(lv_screen_active());
    lv_obj_set_scrollbar_mode(features_view, LV_SCROLLBAR_MODE_OFF);
    lv_obj_set_style_bg_color(features_view, lv_color_black(), 0);
    lv_obj_add_event_cb(features_view, navigate_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

    for (size_t i = 0; i < FEATURE_COUNT; i++)
    {
        ui_feature_t *feature = &features[feature_count];
        feature->def = feature_defs[i];
        feature->row = lv_tileview_add_tile(features_view, 0, feature_count, LV_DIR_VER);
        feature->pages = lv_tileview_create(feature->row);
        lv_obj_set_scrollbar_mode(feature->pages, LV_SCROLLBAR_MODE_OFF);
        lv_obj_set_style_bg_color(feature->pages, lv_color_black(), 0);     // the dark theme's is grey
        lv_obj_add_event_cb(feature->pages, navigate_event_cb, LV_EVENT_VALUE_CHANGED, NULL);
        feature->page_count = 0;

        if (feature->def->build(feature) && feature->page_count > 0)
        {
            lv_tileview_set_tile_by_index(feature->pages, 0, 0, LV_ANIM_OFF);
            feature_count++;
        }
        else
        {
            lv_obj_delete(feature->row);
        }
    }

    nav_dots_create();      // after the features, so it's drawn over the voice ring
    update_screen_create(); // and over everything, while there's an update
    show_startup_page();
    navigate_event_cb(NULL);
}

/********************************************************************************
function:	The theme: dark, with pink controls, scaled (font, padding) to the
            screen size
parameter:
********************************************************************************/
static void setup_theme(void)
{
    lv_display_t *disp = lv_display_get_default();
    screen_size = LV_MIN(lv_display_get_horizontal_resolution(disp),
                         lv_display_get_vertical_resolution(disp));

    // The theme sizes its padding and knobs from the DPI. The defaults are
    // what the layout was designed with.
    if (screen_size != DESIGN_SIZE)
    {
        lv_display_set_dpi(disp, ui_px(LV_DPI_DEF));
    }

    const lv_font_t *font = LV_FONT_DEFAULT;
#if LV_FONT_MONTSERRAT_24
    if (screen_size >= 360)
    {
        font = &lv_font_montserrat_24;
    }
#endif
    lv_theme_t *theme = lv_theme_default_init(disp, lv_palette_main(LV_PALETTE_PINK),
                                              lv_palette_main(LV_PALETTE_PURPLE),
                                              true, font);
    lv_display_set_theme(disp, theme);
}

/* Each page where its place in the row says, after one's been put in or
 * taken out. */
static void lay_out_pages(ui_feature_t *feature)
{
    uint32_t n = lv_obj_get_child_count(feature->pages);
    for (uint32_t i = 0; i < n; i++)
    {
        lv_obj_set_pos(lv_obj_get_child(feature->pages, (int32_t)i), lv_pct((int32_t)i * 100), 0);
    }
    // Where each is now, before anything's shown by it: otherwise a new
    // page is still at 0 till the next refresh, and showing it shows the first
    lv_obj_update_layout(feature->pages);
}

lv_obj_t *ui_feature_insert_page(ui_feature_t *feature, size_t at, const char *name, bool black)
{
    lv_obj_t *current = lv_tileview_get_tile_active(feature->pages);
    lv_obj_t *page = ui_feature_add_page(feature, name, black);
    if (at < (size_t)feature->page_count - 1)
    {
        lv_obj_move_to_index(page, (int32_t)at);
    }
    lay_out_pages(feature);
    if (current != NULL)
    {
        lv_tileview_set_tile(feature->pages, current, LV_ANIM_OFF);     // it may have moved along
    }
    if (ui_feature_is_current(feature))
    {
        navigate_event_cb(NULL);    // for the dots
    }
    return page;
}

static lv_obj_t *back_page;         // where ui_show_for() goes back to
static lv_obj_t *shown_page;        // what it showed
static lv_timer_t *back_timer;

void ui_feature_remove_page(ui_feature_t *feature, lv_obj_t *page)
{
    if (lv_obj_get_parent(page) != feature->pages || feature->page_count <= 1)
    {
        return;
    }
    lv_obj_t *current = lv_tileview_get_tile_active(feature->pages);
    if (current == page)
    {
        // Onto the next page, or the one before if it's the last
        int32_t i = lv_obj_get_index(page);
        current = lv_obj_get_child(feature->pages, i + 1 < feature->page_count ? i + 1 : i - 1);
    }
    if (back_page == page)
    {
        back_page = NULL;
    }
    if (shown_page == page)
    {
        shown_page = NULL;
    }
    lv_obj_delete(page);
    feature->page_count--;
    lay_out_pages(feature);
    lv_tileview_set_tile(feature->pages, current, LV_ANIM_OFF);
    if (ui_feature_is_current(feature))
    {
        navigate_event_cb(NULL);
    }
}

size_t ui_feature_page_count(const ui_feature_t *feature)
{
    return feature->page_count;
}

lv_obj_t *ui_page_of(ui_feature_t *feature, size_t page)
{
    return page < feature->page_count ? lv_obj_get_child(feature->pages, (int32_t)page) : NULL;
}

/* Forget where to go back to: the wearer's moved on, or it's been. */
static void forget_back(void)
{
    back_page = NULL;
    shown_page = NULL;
    if (back_timer != NULL)
    {
        lv_timer_delete(back_timer);
        back_timer = NULL;
    }
}

void ui_go_back(void)
{
    lv_obj_t *to = back_page;
    bool still = shown_page != NULL && ui_current_page() == shown_page;
    forget_back();
    if (to != NULL && still)
    {
        ui_show_page(to);
    }
}

static void back_timer_cb(lv_timer_t *timer)
{
    (void)timer;
    back_timer = NULL;      // it's gone after this, as it only runs once
    ui_go_back();
}

bool ui_show_page_for(lv_obj_t *page, uint32_t seconds)
{
    lv_obj_t *current = ui_current_page();
    // What's on screen now, to go back to, unless it's what an earlier one
    // showed, still waiting to go back
    lv_obj_t *back = back_page != NULL && current == shown_page ? back_page : current;
    forget_back();
    if (!ui_show_page(page))
    {
        return false;
    }
    back_page = back != page ? back : NULL;
    shown_page = page;
    if (seconds > 0 && back_page != NULL)
    {
        back_timer = lv_timer_create(back_timer_cb, seconds * 1000, NULL);
        lv_timer_set_repeat_count(back_timer, 1);
    }
    return true;
}

void ui_show_for(size_t feature, size_t page, uint32_t seconds)
{
    if (page < ui_page_count(feature))
    {
        ui_show_page_for(lv_obj_get_child(features[feature].pages, (int32_t)page), seconds);
    }
}

lv_obj_t *ui_feature_add_page(ui_feature_t *feature, const char *name, bool black)
{
    lv_obj_t *page = lv_tileview_add_tile(feature->pages, feature->page_count++, 0, LV_DIR_HOR);
    lv_obj_set_user_data(page, (void *)name);
    if (black)
    {
        lv_obj_set_style_bg_color(page, lv_color_black(), 0);
        lv_obj_set_style_bg_opa(page, LV_OPA_COVER, 0);
    }
    return page;
}

bool ui_feature_is_current(const ui_feature_t *feature)
{
    return lv_tileview_get_tile_active(features_view) == feature->row;
}

lv_obj_t *ui_current_page(void)
{
    lv_obj_t *row = lv_tileview_get_tile_active(features_view);
    for (uint8_t i = 0; i < feature_count; i++)
    {
        if (features[i].row == row)
        {
            return lv_tileview_get_tile_active(features[i].pages);
        }
    }
    return NULL;
}

size_t ui_feature_count(void)
{
    return feature_count;
}

const char *ui_feature_name(size_t feature)
{
    return feature < feature_count ? features[feature].def->name : "";
}

size_t ui_page_count(size_t feature)
{
    return feature < feature_count ? features[feature].page_count : 0;
}

const char *ui_page_name(size_t feature, size_t page)
{
    if (page >= ui_page_count(feature))
    {
        return "";
    }
    const char *name = lv_obj_get_user_data(lv_obj_get_child(features[feature].pages, (int32_t)page));
    return name != NULL ? name : "";
}

void ui_current(size_t *feature, size_t *page)
{
    *feature = 0;
    *page = 0;
    lv_obj_t *row = lv_tileview_get_tile_active(features_view);
    for (uint8_t i = 0; i < feature_count; i++)
    {
        if (features[i].row == row)
        {
            *feature = i;
            *page = (size_t)lv_obj_get_index(lv_tileview_get_tile_active(features[i].pages));
        }
    }
}

void ui_show(size_t feature, size_t page)
{
    if (page >= ui_page_count(feature))
    {
        return;
    }
    lv_tileview_set_tile(features_view, features[feature].row, LV_ANIM_OFF);
    lv_tileview_set_tile(features[feature].pages, lv_obj_get_child(features[feature].pages, (int32_t)page),
                         LV_ANIM_OFF);
    navigate_event_cb(NULL);    // as a swipe would
}

bool ui_step(int dx, int dy)
{
    size_t f, p;
    ui_current(&f, &p);
    if (dy != 0)
    {
        long to = (long)f + (dy > 0 ? 1 : -1);
        if (to < 0 || to >= (long)feature_count)
        {
            return false;
        }
        f = (size_t)to;
        p = (size_t)lv_obj_get_index(lv_tileview_get_tile_active(features[f].pages));    // where it was left
    }
    else if (dx != 0)
    {
        long to = (long)p + (dx > 0 ? 1 : -1);
        if (to < 0 || to >= (long)ui_page_count(f))
        {
            return false;
        }
        p = (size_t)to;
    }
    else
    {
        return false;
    }
    ui_show(f, p);
    return true;
}

void *ui_page_object(size_t feature, size_t page)
{
    return page < ui_page_count(feature) ? lv_obj_get_child(features[feature].pages, (int32_t)page) : NULL;
}

bool ui_show_page(lv_obj_t *page)
{
    for (uint8_t i = 0; i < feature_count; i++)
    {
        if (lv_obj_get_parent(page) == features[i].pages)
        {
            ui_show(i, (size_t)lv_obj_get_index(page));
            return true;
        }
    }
    return false;
}

/* A row of choices, the chosen one filled in and the others dark: told apart
 * by how bright they are, not only by their color. It changes when the
 * finger lifts (CLICK_TRIG), not when it lands, so that swiping to the next
 * page from here doesn't change it. */
lv_obj_t *ui_add_choices(lv_obj_t *parent, const char *const *map, int32_t w, int32_t h, int32_t y)
{
    lv_obj_t *m = lv_buttonmatrix_create(parent);
    lv_buttonmatrix_set_map(m, map);
    lv_buttonmatrix_set_button_ctrl_all(m, LV_BUTTONMATRIX_CTRL_CHECKABLE | LV_BUTTONMATRIX_CTRL_CLICK_TRIG);
    lv_buttonmatrix_set_one_checked(m, true);
    lv_obj_set_style_bg_opa(m, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(m, 0, 0);
    lv_obj_set_style_pad_all(m, 0, 0);
    lv_obj_set_style_pad_column(m, ui_px(4), 0);
    lv_obj_set_style_radius(m, ui_px(10), LV_PART_ITEMS);
    lv_obj_set_style_border_width(m, 0, LV_PART_ITEMS);
    lv_obj_set_style_shadow_width(m, 0, LV_PART_ITEMS);
    lv_obj_set_style_bg_opa(m, LV_OPA_COVER, LV_PART_ITEMS);
    lv_obj_set_style_bg_color(m, lv_color_hex(0x2a2a2a), LV_PART_ITEMS);
    lv_obj_set_style_text_color(m, lv_color_hex(0x909090), LV_PART_ITEMS);
    lv_obj_set_style_bg_color(m, lv_palette_main(LV_PALETTE_PINK), LV_PART_ITEMS | LV_STATE_CHECKED);
    lv_obj_set_style_text_color(m, lv_color_white(), LV_PART_ITEMS | LV_STATE_CHECKED);
    lv_obj_set_size(m, w, h);
    lv_obj_align(m, LV_ALIGN_CENTER, 0, y);
    return m;
}

void ui_check_choice(lv_obj_t *m, uint32_t index)
{
    if (!lv_buttonmatrix_has_button_ctrl(m, index, LV_BUTTONMATRIX_CTRL_CHECKED))
    {
        lv_buttonmatrix_set_button_ctrl(m, index, LV_BUTTONMATRIX_CTRL_CHECKED);
    }
}

void ui_add_startup_choice(ui_feature_t *feature, lv_obj_t *page, const char *label, const char *value)
{
    if (startup_choice_count < MAX_STARTUP_CHOICES)
    {
        startup_choices[startup_choice_count++] = (startup_choice_t){ feature, page, label, value };
    }
}

void ui_startup_choice_page_gone(const lv_obj_t *page)
{
    // The choice stays, so the Settings roller and the remote's list keep their
    // places till the next start; it just has nowhere to go
    for (size_t i = 0; i < startup_choice_count; i++)
    {
        if (startup_choices[i].page == page)
        {
            startup_choices[i].page = NULL;
        }
    }
}

size_t ui_startup_choice_count(void)
{
    return startup_choice_count;
}

const char *ui_startup_choice_label(size_t index)
{
    return startup_choices[index].label;
}

const char *ui_startup_choice_value(size_t index)
{
    return startup_choices[index].value;
}

const char *ui_startup_choice_group(size_t index)
{
    return startup_choices[index].feature->def->name;
}

int ui_find_startup_choice(const char *value)
{
    for (size_t i = 0; i < startup_choice_count; i++)
    {
        if (strcmp(startup_choices[i].value, value) == 0)
        {
            return (int)i;
        }
    }
    return -1;
}

/********************************************************************************
function:	Show the saved startup page. Unknown values (e.g. an image that's
            since been removed) fall back to the first page.
parameter:
********************************************************************************/
static void show_startup_page(void)
{
    int index = ui_find_startup_choice(settings_get()->startup_image);
    if (index < 0)
    {
        if (startup_choice_count == 0)
        {
            return;
        }
        index = 0;
    }

    startup_choice_t *choice = &startup_choices[index];
    if (choice->page == NULL)
    {
        return;     // a picture deleted since
    }
    lv_tileview_set_tile(features_view, choice->feature->row, LV_ANIM_OFF);
    lv_tileview_set_tile(choice->feature->pages, choice->page, LV_ANIM_OFF);
}

/* A different feature or page came on screen. */
static void navigate_event_cb(lv_event_t *e)
{
    // Moved on from what ui_show_for() showed: it stays where it is
    if (shown_page != NULL && ui_current_page() != shown_page)
    {
        forget_back();
    }

    lv_obj_t *row = lv_tileview_get_tile_active(features_view);
    for (uint8_t i = 0; i < feature_count; i++)
    {
        if (features[i].row == row)
        {
            lv_obj_t *page = lv_tileview_get_tile_active(features[i].pages);
            nav_dots_show(i, feature_count, lv_obj_get_index(page), features[i].page_count);
        }
    }

    for (uint8_t i = 0; i < feature_count; i++)
    {
        if (features[i].def->on_navigate != NULL)
        {
            features[i].def->on_navigate();
        }
    }
}
