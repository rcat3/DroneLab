/*
 * A feature's "Others" page (see others_page.h), dark like the Toys
 * feature's pages: a title, who's taken (Off, Ask or Anyone) and what's
 * ignored, by the wearer's rules (app/rules.h), with a button to switch it
 * Off here; who's allowed, and a line saying who sent the last one. The
 * rest is changed in the wearer's app, which gives the unit its rules.
 */
#include "ui/others_page.h"

#include <stdio.h>
#include <string.h>

#include "app/direct.h"
#include "app/rules.h"

#define POLL_MS             200

#define COLOR_SURFACE       lv_color_hex(0x1c1c1c)
#define COLOR_OUTLINE       lv_color_hex(0x3a3a3a)
#define COLOR_MUTED         lv_color_hex(0x8a8a8a)
#define COLOR_ALLOWED       lv_palette_main(LV_PALETTE_GREEN)
#define COLOR_OFF           lv_palette_main(LV_PALETTE_RED)

typedef struct
{
    lv_obj_t *page;
    lv_obj_t *policy;       // Off, Ask or Anyone
    lv_obj_t *ignore;       // what's ignored, if anything
    lv_obj_t *off;          // switch it off here
    lv_obj_t *names[RULES_PEOPLE_MAX];
    lv_obj_t *status;
    int32_t list_y;         // the middle of the list, where the status goes while it's empty
    uint32_t shown_changes;
    uint32_t shown_age_s;
} others_page_t;

static others_page_t *pages[OTHERS_KIND_COUNT];    // out of internal RAM, as they're made
static lv_timer_t *timer;

static void show(others_kind_t kind, bool always)
{
    others_page_t *p = pages[kind];
    uint32_t age = 0;
    const char *last = others_last(kind, lv_tick_get(), &age);
    uint32_t age_s = last != NULL ? age / 1000 : UINT32_MAX;
    if (!always && others_changes() == p->shown_changes && age_s == p->shown_age_s)
    {
        return;
    }
    p->shown_changes = others_changes();
    p->shown_age_s = age_s;

    others_permission_t permission = others_permission(kind);
    lv_label_set_text(p->policy, permission == OTHERS_OFF      ? "Off"
                                 : permission == OTHERS_ACCEPT ? "Anyone"
                                                               : "Ask");
    lv_obj_set_style_text_color(p->policy, permission == OTHERS_OFF ? COLOR_OFF : COLOR_ALLOWED, 0);
    lv_obj_set_hidden(p->off, permission == OTHERS_OFF);
    uint8_t ignore = others_ignoring(kind);
    lv_label_set_text(p->ignore, permission == OTHERS_OFF ? ""
                                 : (ignore & OTHERS_IGNORE_EVERYONE) && (ignore & OTHERS_IGNORE_CHANNEL)
                                     ? "Ignores broadcasts and channels"
                                 : (ignore & OTHERS_IGNORE_EVERYONE) ? "Ignores broadcasts"
                                 : (ignore & OTHERS_IGNORE_CHANNEL)  ? "Ignores whole channels"
                                                                     : "");

    // Who's allowed, when it's Ask
    uint16_t bit = (uint16_t)(1u << others_class(kind));
    int n = 0;
    for (int i = 0; permission == OTHERS_ASK && i < rules_people_count(); i++)
    {
        const rules_person_t *r = rules_person_at(i);
        if ((r->allowed & bit) && !(r->flags & RULES_MUTED))
        {
            lv_label_set_text_fmt(p->names[n], LV_SYMBOL_OK " %s", r->name[0] ? r->name : "?");
            n++;
        }
    }
    for (int i = 0; i < RULES_PEOPLE_MAX; i++)
    {
        lv_obj_set_hidden(p->names[i], i >= n);
    }

    if (permission == OTHERS_OFF)
    {
        lv_label_set_text(p->status, "Switch it on in the app");
    }
    else if (last != NULL && age_s < 60)
    {
        lv_label_set_text_fmt(p->status, "%s, %lus ago", last, (unsigned long)age_s);
    }
    else if (permission == OTHERS_ACCEPT)
    {
        lv_label_set_text(p->status, "Taken from everyone");
    }
    else if (n == 0)
    {
        lv_label_set_text(p->status, "Nobody allowed yet");
    }
    else
    {
        lv_label_set_text(p->status, "Change them in the app");
    }
    // With nobody listed, in the middle of the empty list; else under it
    lv_obj_align(p->status, LV_ALIGN_CENTER, 0, n == 0 ? p->list_y : ui_px(88));
}

static void timer_cb(lv_timer_t *t)
{
    lv_obj_t *current = ui_current_page();
    for (int k = 0; k < OTHERS_KIND_COUNT; k++)
    {
        if (pages[k] != NULL && pages[k]->page == current)
        {
            show((others_kind_t)k, false);
        }
    }
}

static void off_event_cb(lv_event_t *e)
{
    others_kind_t kind = (others_kind_t)(intptr_t)lv_event_get_user_data(e);
    rules_set_off(others_class(kind));
    show(kind, true);
}

lv_obj_t *ui_others_page_add(ui_feature_t *feature, others_kind_t kind)
{
    if (!comm_available() && !direct_available())
    {
        return NULL;    // nobody can send any
    }
    others_page_t *p = lv_malloc_zeroed(sizeof(others_page_t));
    if (p == NULL)
    {
        return NULL;
    }
    pages[kind] = p;
    p->page = ui_feature_add_page(feature, "Others", true);
    lv_obj_set_scrollable(p->page, false);
    lv_obj_set_style_text_color(p->page, lv_color_white(), 0);

    lv_obj_t *title = lv_label_create(p->page);
    lv_label_set_text(title, kind == OTHERS_VIBE ? "Hive Commands" : "Hive Display");
    lv_obj_set_style_text_color(title, COLOR_MUTED, 0);
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, ui_px(28));

    // Who's taken, and what's ignored
    p->policy = lv_label_create(p->page);
    lv_obj_align(p->policy, LV_ALIGN_TOP_MID, 0, ui_px(50));
    p->ignore = lv_label_create(p->page);
    lv_obj_set_style_text_color(p->ignore, COLOR_MUTED, 0);
    lv_obj_align(p->ignore, LV_ALIGN_TOP_MID, 0, ui_px(70));

    // Off, here: on again is the app's
    p->off = lv_button_create(p->page);
    lv_obj_set_size(p->off, ui_px(96), ui_px(28));
    lv_obj_set_style_radius(p->off, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(p->off, COLOR_SURFACE, 0);
    lv_obj_set_style_bg_color(p->off, COLOR_OUTLINE, LV_STATE_PRESSED);
    lv_obj_set_style_border_width(p->off, LV_MAX(1, ui_px(1)), 0);
    lv_obj_set_style_border_color(p->off, COLOR_OFF, 0);
    lv_obj_set_style_shadow_width(p->off, 0, 0);
    lv_obj_align(p->off, LV_ALIGN_TOP_MID, 0, ui_px(92));
    lv_obj_add_event_cb(p->off, off_event_cb, LV_EVENT_CLICKED, (void *)(intptr_t)kind);
    lv_obj_t *off_label = lv_label_create(p->off);
    lv_label_set_text(off_label, "Turn off");
    lv_obj_set_style_text_color(off_label, COLOR_OFF, 0);
    lv_obj_center(off_label);

    // Who's allowed
    lv_obj_t *list = lv_obj_create(p->page);
    lv_obj_remove_style_all(list);
    lv_obj_set_size(list, ui_px(180), ui_px(60));
    p->list_y = ui_px(46);
    lv_obj_align(list, LV_ALIGN_CENTER, 0, p->list_y);
    lv_obj_set_flex_flow(list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(list, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_row(list, ui_px(4), 0);
    lv_obj_set_scroll_dir(list, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(list, LV_SCROLLBAR_MODE_OFF);
    for (int i = 0; i < RULES_PEOPLE_MAX; i++)
    {
        p->names[i] = lv_label_create(list);
        lv_label_set_long_mode(p->names[i], LV_LABEL_LONG_MODE_DOTS);
        lv_obj_set_width(p->names[i], ui_px(160));
        lv_obj_set_style_text_align(p->names[i], LV_TEXT_ALIGN_CENTER, 0);
        lv_obj_set_style_text_color(p->names[i], COLOR_ALLOWED, 0);
        lv_obj_set_hidden(p->names[i], true);
    }

    p->status = lv_label_create(p->page);
    lv_label_set_text(p->status, "");
    lv_label_set_long_mode(p->status, LV_LABEL_LONG_MODE_DOTS);
    lv_obj_set_width(p->status, ui_px(170));
    lv_obj_set_style_text_align(p->status, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(p->status, COLOR_MUTED, 0);
    lv_obj_align(p->status, LV_ALIGN_CENTER, 0, ui_px(88));

    show(kind, true);
    if (timer == NULL)
    {
        timer = lv_timer_create(timer_cb, POLL_MS, NULL);
    }
    return p->page;
}
