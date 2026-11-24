/*
 * A feature's "Others" page (see others_page.h), dark like the Toys
 * feature's pages: a title, who's taken (Off, Ask or Accept), a row for each
 * person who's sent commands of its kind, and a line saying who sent the
 * last one; and after it, what it ignores, whoever it's from: broadcasts,
 * and commands to a whole channel.
 */
#include "ui/others_page.h"

#include <stdio.h>
#include <string.h>

#include "app/direct.h"

#define POLL_MS             200

#define COLOR_SURFACE       lv_color_hex(0x1c1c1c)
#define COLOR_OUTLINE       lv_color_hex(0x3a3a3a)
#define COLOR_MUTED         lv_color_hex(0x8a8a8a)
#define COLOR_ALLOWED       lv_palette_main(LV_PALETTE_GREEN)
#define COLOR_CLASH         lv_palette_main(LV_PALETTE_DEEP_ORANGE)   // someone else using a listed name

typedef struct
{
    lv_obj_t *page;
    lv_obj_t *accept;       // Off, Ask and Accept
    lv_obj_t *rows[OTHERS_PEOPLE_MAX];
    lv_obj_t *names[OTHERS_PEOPLE_MAX];
    lv_obj_t *vias[OTHERS_PEOPLE_MAX];
    lv_obj_t *status;
    lv_obj_t *ignore_page;
    lv_obj_t *ignore_everyone;
    lv_obj_t *ignore_channel;
    int32_t list_y;         // the middle of the list, where the status goes while it's empty
    others_sender_t senders[OTHERS_PEOPLE_MAX];
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
    ui_check_choice(p->accept, (uint32_t)permission);
    uint8_t ignore = others_ignoring(kind);
    lv_obj_set_state(p->ignore_everyone, LV_STATE_CHECKED, (ignore & OTHERS_IGNORE_EVERYONE) != 0);
    lv_obj_set_state(p->ignore_channel, LV_STATE_CHECKED, (ignore & OTHERS_IGNORE_CHANNEL) != 0);
    int n = others_senders(kind, p->senders, OTHERS_PEOPLE_MAX);
    for (int i = 0; i < OTHERS_PEOPLE_MAX; i++)
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
        // Who they are is their key: its first bytes, and a warning if
        // they took the name of someone listed before them
        lv_label_set_text_fmt(p->vias[i], "%s%02x%02x", o->clash ? LV_SYMBOL_WARNING " " : "", o->key[0], o->key[1]);
        lv_obj_set_style_text_color(p->vias[i], o->clash ? COLOR_CLASH : COLOR_MUTED, 0);
        lv_obj_set_style_border_color(p->rows[i], o->allowed ? COLOR_ALLOWED : COLOR_OUTLINE, 0);
        lv_obj_set_style_text_color(p->names[i], o->allowed ? COLOR_ALLOWED : lv_color_white(), 0);
    }

    if (permission == OTHERS_OFF)
    {
        lv_label_set_text(p->status, "Ignoring everyone");
    }
    else if (last != NULL && age_s < 60)
    {
        lv_label_set_text_fmt(p->status, "%s, %lus ago", last, (unsigned long)age_s);
    }
    else if (permission == OTHERS_ACCEPT)
    {
        lv_label_set_text(p->status, "Accepting everyone");
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
        if (pages[k] != NULL && (pages[k]->page == current || pages[k]->ignore_page == current))
        {
            show((others_kind_t)k, false);
        }
    }
}

static const char *const permission_map[] = { "Off", "Ask", "Accept", "" };

static void permission_event_cb(lv_event_t *e)
{
    others_kind_t kind = (others_kind_t)(intptr_t)lv_event_get_user_data(e);
    uint32_t selected = lv_buttonmatrix_get_selected_button(lv_event_get_target_obj(e));
    if (selected <= OTHERS_ACCEPT)
    {
        others_set_permission(kind, (others_permission_t)selected);
    }
    show(kind, true);
}

static void ignore_event_cb(lv_event_t *e)
{
    others_kind_t kind = (others_kind_t)(intptr_t)lv_event_get_user_data(e);
    others_page_t *p = pages[kind];
    others_set_ignoring(kind, (lv_obj_has_state(p->ignore_everyone, LV_STATE_CHECKED) ? OTHERS_IGNORE_EVERYONE : 0)
                                  | (lv_obj_has_state(p->ignore_channel, LV_STATE_CHECKED) ? OTHERS_IGNORE_CHANNEL : 0));
    show(kind, true);
}

static lv_obj_t *add_switch(others_page_t *p, others_kind_t kind, const char *text, int32_t y)
{
    lv_obj_t *label = lv_label_create(p->ignore_page);
    lv_label_set_text(label, text);
    lv_obj_align(label, LV_ALIGN_CENTER, ui_px(-30), y);
    lv_obj_t *sw = lv_switch_create(p->ignore_page);
    lv_obj_set_size(sw, ui_px(56), ui_px(28));
    lv_obj_align(sw, LV_ALIGN_CENTER, ui_px(64), y);
    lv_obj_add_event_cb(sw, ignore_event_cb, LV_EVENT_VALUE_CHANGED, (void *)(intptr_t)kind);
    return sw;
}

static void row_event_cb(lv_event_t *e)
{
    int at = (int)(intptr_t)lv_event_get_user_data(e);
    others_kind_t kind = (others_kind_t)(at / OTHERS_PEOPLE_MAX);
    const others_sender_t *o = &pages[kind]->senders[at % OTHERS_PEOPLE_MAX];
    if (lv_event_get_code(e) == LV_EVENT_LONG_PRESSED)
    {
        others_forget(kind, o->key);
    }
    else
    {
        others_allow(kind, o->key, !o->allowed);
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
    lv_label_set_text(title, kind == OTHERS_VIBE ? "Hive Commands" : "Hive Messages");
    lv_obj_set_style_text_color(title, COLOR_MUTED, 0);
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, ui_px(28));

    // Who's taken: nobody, those allowed in the list, or anyone
    p->accept = ui_add_choices(p->page, permission_map, ui_px(176), ui_px(28), ui_px(-51));
    lv_obj_add_event_cb(p->accept, permission_event_cb, LV_EVENT_VALUE_CHANGED, (void *)(intptr_t)kind);

    // Who may send them, under its heading
    lv_obj_t *heading = lv_label_create(p->page);
    lv_label_set_text(heading, "Permissions");
    lv_obj_set_style_text_color(heading, COLOR_MUTED, 0);
    lv_obj_align(heading, LV_ALIGN_TOP_MID, 0, ui_px(89));

    lv_obj_t *list = lv_obj_create(p->page);
    lv_obj_remove_style_all(list);
    lv_obj_set_size(list, ui_px(180), ui_px(84));
    p->list_y = ui_px(34);
    lv_obj_align(list, LV_ALIGN_CENTER, 0, p->list_y);
    lv_obj_set_flex_flow(list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(list, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_row(list, ui_px(8), 0);
    lv_obj_set_scroll_dir(list, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(list, LV_SCROLLBAR_MODE_OFF);

    for (int i = 0; i < OTHERS_PEOPLE_MAX; i++)
    {
        lv_obj_t *row = lv_button_create(list);
        lv_obj_set_size(row, ui_px(176), ui_px(30));
        lv_obj_set_style_radius(row, LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_bg_color(row, COLOR_SURFACE, 0);
        lv_obj_set_style_bg_color(row, COLOR_OUTLINE, LV_STATE_PRESSED);
        lv_obj_set_style_border_width(row, LV_MAX(1, ui_px(1)), 0);
        lv_obj_set_style_border_color(row, COLOR_OUTLINE, 0);
        lv_obj_set_style_shadow_width(row, 0, 0);
        void *at = (void *)(intptr_t)(kind * OTHERS_PEOPLE_MAX + i);
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

    // What's ignored, whoever it's from
    p->ignore_page = ui_feature_add_page(feature, "Ignore", true);
    lv_obj_set_scrollable(p->ignore_page, false);
    lv_obj_set_style_text_color(p->ignore_page, lv_color_white(), 0);
    lv_obj_t *t = lv_label_create(p->ignore_page);
    lv_label_set_text(t, kind == OTHERS_VIBE ? "Hive Commands" : "Hive Messages");
    lv_obj_set_style_text_color(t, COLOR_MUTED, 0);
    lv_obj_align(t, LV_ALIGN_TOP_MID, 0, ui_px(28));
    lv_obj_t *ignore_heading = lv_label_create(p->ignore_page);
    lv_label_set_text(ignore_heading, "Ignore, from anyone");
    lv_obj_align(ignore_heading, LV_ALIGN_CENTER, 0, ui_px(-56));
    p->ignore_everyone = add_switch(p, kind, "Broadcasts", ui_px(-14));
    p->ignore_channel = add_switch(p, kind, "To a whole\nchannel", ui_px(30));
    lv_obj_t *note = lv_label_create(p->ignore_page);
    lv_label_set_text(note, "The open direct\nchannel's count as\nbroadcasts");
    lv_obj_set_style_text_align(note, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(note, COLOR_MUTED, 0);
    lv_obj_align(note, LV_ALIGN_CENTER, 0, ui_px(84));

    show(kind, true);
    if (timer == NULL)
    {
        timer = lv_timer_create(timer_cb, POLL_MS, NULL);
    }
    return p->page;
}
