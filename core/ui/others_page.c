/*
 * A feature's "Others" page (see others_page.h), dark like the Lovense
 * feature's pages: a title, the Accept switch, a row for each person who's
 * sent commands of its kind, and a line saying who sent the last one.
 */
#include "ui/others_page.h"

#include <stdio.h>
#include <string.h>

#include "app/direct.h"

#define POLL_MS             200

#define COLOR_TRACK         lv_color_hex(0x262626)
#define COLOR_SURFACE       lv_color_hex(0x1c1c1c)
#define COLOR_OUTLINE       lv_color_hex(0x3a3a3a)
#define COLOR_MUTED         lv_color_hex(0x8a8a8a)
#define COLOR_ALLOWED       lv_palette_main(LV_PALETTE_GREEN)

typedef struct
{
    lv_obj_t *page;
    lv_obj_t *accept;
    lv_obj_t *unnamed;      // the Terminal's: unnamed messages shown, or NULL
    lv_obj_t *rows[OTHERS_SENDERS_MAX];
    lv_obj_t *names[OTHERS_SENDERS_MAX];
    lv_obj_t *vias[OTHERS_SENDERS_MAX];
    lv_obj_t *status;
    int32_t list_y;         // the middle of the list, where the status goes while it's empty
    others_sender_t senders[OTHERS_SENDERS_MAX];
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

    bool accepting = others_accepting(kind);
    lv_obj_set_state(p->accept, LV_STATE_CHECKED, accepting);
    if (p->unnamed != NULL)
    {
        lv_obj_set_state(p->unnamed, LV_STATE_CHECKED, others_unnamed_shown());
    }
    int n = others_senders(kind, p->senders, OTHERS_SENDERS_MAX);
    for (int i = 0; i < OTHERS_SENDERS_MAX; i++)
    {
        lv_obj_set_hidden(p->rows[i], i >= n);
        if (i >= n)
        {
            continue;
        }
        const others_sender_t *o = &p->senders[i];
        if (o->allowed)
        {
            lv_label_set_text_fmt(p->names[i], LV_SYMBOL_OK " %s", o->name);
        }
        else
        {
            lv_label_set_text(p->names[i], o->name);
        }
        lv_label_set_text(p->vias[i], o->via == COMM_TALK_DIRECT ? "direct" : "server");
        lv_obj_set_style_border_color(p->rows[i], o->allowed ? COLOR_ALLOWED : COLOR_OUTLINE, 0);
        lv_obj_set_style_text_color(p->names[i], o->allowed ? COLOR_ALLOWED : lv_color_white(), 0);
    }

    if (!accepting)
    {
        lv_label_set_text(p->status, "Ignoring everyone");
    }
    else if (last != NULL && age_s < 60)
    {
        lv_label_set_text_fmt(p->status, "%s, %lus ago", last, (unsigned long)age_s);
    }
    else if (n == 0)
    {
        lv_label_set_text(p->status, "None received.");
    }
    else
    {
        lv_label_set_text(p->status, "Tap to allow, hold to forget");
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

static void accept_event_cb(lv_event_t *e)
{
    others_kind_t kind = (others_kind_t)(intptr_t)lv_event_get_user_data(e);
    others_set_accepting(kind, lv_obj_has_state(lv_event_get_target_obj(e), LV_STATE_CHECKED));
    show(kind, true);
}

static void unnamed_event_cb(lv_event_t *e)
{
    others_set_unnamed_shown(lv_obj_has_state(lv_event_get_target_obj(e), LV_STATE_CHECKED));
    show(OTHERS_TERMINAL, true);
}

/* A label and a switch, side by side, top_px down. */
static lv_obj_t *add_switch(lv_obj_t *page, const char *text, int32_t top_px, lv_event_cb_t cb, void *user_data)
{
    lv_obj_t *label = lv_label_create(page);
    lv_label_set_text(label, text);
    lv_obj_align(label, LV_ALIGN_TOP_MID, ui_px(-34), ui_px(top_px + 5));
    lv_obj_t *sw = lv_switch_create(page);
    lv_obj_set_size(sw, ui_px(56), ui_px(28));
    lv_obj_set_style_bg_color(sw, COLOR_TRACK, LV_PART_MAIN);
    lv_obj_set_style_bg_color(sw, lv_palette_main(LV_PALETTE_PINK), LV_PART_INDICATOR | LV_STATE_CHECKED);
    lv_obj_align(sw, LV_ALIGN_TOP_MID, ui_px(38), ui_px(top_px));
    lv_obj_add_event_cb(sw, cb, LV_EVENT_VALUE_CHANGED, user_data);
    return sw;
}

static void row_event_cb(lv_event_t *e)
{
    int at = (int)(intptr_t)lv_event_get_user_data(e);
    others_kind_t kind = (others_kind_t)(at / OTHERS_SENDERS_MAX);
    const others_sender_t *o = &pages[kind]->senders[at % OTHERS_SENDERS_MAX];
    if (lv_event_get_code(e) == LV_EVENT_LONG_PRESSED)
    {
        others_forget(kind, o->via, o->name);
    }
    else
    {
        others_allow(kind, o->via, o->name, !o->allowed);
    }
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
    lv_label_set_text(title, kind == OTHERS_LOVENSE ? "Hive Commands" : "Hive Messages");
    lv_obj_set_style_text_color(title, COLOR_MUTED, 0);
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, ui_px(28));

    p->accept = add_switch(p->page, "Accept", 55, accept_event_cb, (void *)(intptr_t)kind);
    // The Terminal's: whether messages that don't say who they're from show
    bool more = kind == OTHERS_TERMINAL;
    if (more)
    {
        p->unnamed = add_switch(p->page, "Unnamed", 88, unnamed_event_cb, NULL);
    }

    // Who may send them, under its heading
    lv_obj_t *heading = lv_label_create(p->page);
    lv_label_set_text(heading, "Permissions");
    lv_obj_set_style_text_color(heading, COLOR_MUTED, 0);
    lv_obj_align(heading, LV_ALIGN_TOP_MID, 0, ui_px(more ? 122 : 89));

    lv_obj_t *list = lv_obj_create(p->page);
    lv_obj_remove_style_all(list);
    lv_obj_set_size(list, ui_px(180), ui_px(more ? 56 : 84));
    p->list_y = ui_px(more ? 50 : 34);
    lv_obj_align(list, LV_ALIGN_CENTER, 0, p->list_y);
    lv_obj_set_flex_flow(list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(list, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_row(list, ui_px(8), 0);
    lv_obj_set_scroll_dir(list, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(list, LV_SCROLLBAR_MODE_OFF);

    for (int i = 0; i < OTHERS_SENDERS_MAX; i++)
    {
        lv_obj_t *row = lv_button_create(list);
        lv_obj_set_size(row, ui_px(176), ui_px(30));
        lv_obj_set_style_radius(row, LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_bg_color(row, COLOR_SURFACE, 0);
        lv_obj_set_style_bg_color(row, COLOR_OUTLINE, LV_STATE_PRESSED);
        lv_obj_set_style_border_width(row, LV_MAX(1, ui_px(1)), 0);
        lv_obj_set_style_border_color(row, COLOR_OUTLINE, 0);
        lv_obj_set_style_shadow_width(row, 0, 0);
        void *at = (void *)(intptr_t)(kind * OTHERS_SENDERS_MAX + i);
        lv_obj_add_event_cb(row, row_event_cb, LV_EVENT_SHORT_CLICKED, at);
        lv_obj_add_event_cb(row, row_event_cb, LV_EVENT_LONG_PRESSED, at);
        p->names[i] = lv_label_create(row);
        lv_label_set_long_mode(p->names[i], LV_LABEL_LONG_MODE_DOTS);
        lv_obj_set_width(p->names[i], ui_px(104));
        lv_obj_align(p->names[i], LV_ALIGN_LEFT_MID, ui_px(4), 0);
        p->vias[i] = lv_label_create(row);
        lv_obj_set_style_text_color(p->vias[i], COLOR_MUTED, 0);
        lv_obj_align(p->vias[i], LV_ALIGN_RIGHT_MID, ui_px(-4), 0);
        lv_obj_set_hidden(row, true);
        p->rows[i] = row;
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
