/*
 * The virtual toys' panel, beside the unit's screen in its window: buttons
 * to switch toys on, and for each toy what it's doing, its motors as bars.
 * Drawn with plain Xlib, apart from LVGL, as it isn't part of the unit.
 */

#include <stdio.h>
#include <string.h>

#include "hal.h"
#include "toys_panel.h"
#include "toys.h"

#define PAD             10
#define LINE            16
#define BUTTON_H        22
#define BUTTONS_PER_ROW 4
#define GAP             6
#define BAR_ROW         18
#define FLASH_MS        400         // a command just sent shows bright this long
#define REDRAW_MS       250         // and the battery's looked at this often

#define COLOR_BG        0x101418
#define COLOR_CARD      0x1c2128
#define COLOR_BUTTON    0x2a3038
#define COLOR_TEXT      0xe6e6e6
#define COLOR_DIM       0x8a8f98
#define COLOR_ACCENT    0xff40c0    // the app's pink
#define COLOR_TRACK     0x30363f

typedef struct
{
    int x, y, w, h;
} rect_t;

static Display *x;
static Window window;
static GC gc;
static XFontStruct *font;
static Pixmap pixmap;
static int left, height;            // where it is in the window
static int depth;

static rect_t add_buttons[16];
static size_t add_count;
static rect_t off_buttons[TOY_MAX];
static size_t off_count;

static uint32_t drawn_changes;
static uint32_t drawn_at;
static bool flashing;

static uint32_t bar_color(const char *motor)
{
    if (strcmp(motor, "Rotate") == 0)
    {
        return 0x40c0ff;
    }
    if (strcmp(motor, "Air") == 0)
    {
        return 0x60e080;
    }
    if (strcmp(motor, "Thrust") == 0)
    {
        return 0xffb040;
    }
    return COLOR_ACCENT;
}

static void fill(uint32_t color, int rx, int ry, int w, int h)
{
    XSetForeground(x, gc, color);
    XFillRectangle(x, pixmap, gc, rx, ry, (unsigned)w, (unsigned)h);
}

/* Text with its baseline LINE - 4 below y */
static void text(uint32_t color, int tx, int ty, const char *s)
{
    XSetForeground(x, gc, color);
    XDrawString(x, pixmap, gc, tx, ty + LINE - 4, s, (int)strlen(s));
}

static int text_width(const char *s)
{
    return XTextWidth(font, s, (int)strlen(s));
}

static void button(rect_t r, const char *label, bool enabled)
{
    fill(enabled ? COLOR_BUTTON : COLOR_CARD, r.x, r.y, r.w, r.h);
    text(enabled ? COLOR_TEXT : COLOR_DIM, r.x + (r.w - text_width(label)) / 2, r.y + (r.h - LINE) / 2 + 1, label);
}

static bool inside(rect_t r, int px, int py)
{
    return px >= r.x && px < r.x + r.w && py >= r.y && py < r.y + r.h;
}

void toys_panel_init(Display *display, Window win, int panel_left, int panel_height)
{
    x = display;
    window = win;
    left = panel_left;
    height = panel_height;
    depth = DefaultDepth(x, DefaultScreen(x));
    gc = XCreateGC(x, window, 0, NULL);
    font = XLoadQueryFont(x, "6x13");
    if (font == NULL)
    {
        font = XLoadQueryFont(x, "fixed");
    }
    XSetFont(x, gc, font->fid);
    pixmap = XCreatePixmap(x, window, TOYS_PANEL_WIDTH, (unsigned)height, (unsigned)depth);
}

static void draw(void)
{
    uint32_t now = rcat_hal_millis();
    int w = TOYS_PANEL_WIDTH;
    fill(COLOR_BG, 0, 0, w, height);
    int y = PAD;
    text(COLOR_TEXT, PAD, y, "Virtual Lovense toys");
    y += LINE;
    text(COLOR_DIM, PAD, y, "For the Lovense feature to find");
    y += LINE + GAP;

    // A button for each model
    size_t toys = toy_count();
    size_t models = toy_model_count();
    int bw = (w - 2 * PAD - (BUTTONS_PER_ROW - 1) * GAP) / BUTTONS_PER_ROW;
    add_count = 0;
    for (size_t m = 0; m < models && add_count < sizeof(add_buttons) / sizeof(add_buttons[0]); m++)
    {
        int col = (int)(m % BUTTONS_PER_ROW), row = (int)(m / BUTTONS_PER_ROW);
        rect_t r = { PAD + col * (bw + GAP), y + row * (BUTTON_H + GAP), bw, BUTTON_H };
        add_buttons[add_count++] = r;
        button(r, toy_model_name(m), toys < TOY_MAX);
    }
    y += (int)((models + BUTTONS_PER_ROW - 1) / BUTTONS_PER_ROW) * (BUTTON_H + GAP) + GAP;

    if (toys == 0)
    {
        text(COLOR_DIM, PAD, y, "Switch a toy on, then scan for it");
        text(COLOR_DIM, PAD, y + LINE, "in the Lovense feature, on the unit");
        text(COLOR_DIM, PAD, y + 2 * LINE, "or on its remote in the app.");
    }

    // A card for each toy
    off_count = 0;
    flashing = false;
    for (size_t i = 0; i < toys; i++)
    {
        toy_view_t t;
        if (!toy_get(i, &t))
        {
            break;
        }
        int card_h = 2 * LINE + t.motor_count * BAR_ROW + 2 * GAP;
        fill(COLOR_CARD, PAD, y, w - 2 * PAD, card_h);
        int cx = PAD + GAP, cy = y + GAP / 2;
        int inner = w - 2 * PAD - 2 * GAP;

        char line[64];
        snprintf(line, sizeof(line), "%s  %s", t.model, t.name);
        text(COLOR_TEXT, cx, cy, line);
        rect_t off = { PAD + w - 2 * PAD - GAP - 30, cy + 1, 30, LINE - 2 };
        off_buttons[off_count++] = off;
        button(off, "Off", true);
        cy += LINE;

        const char *state = t.state == TOY_CONNECTED ? "Connected" : t.state == TOY_CONNECTING ? "Connecting" : "Waiting";
        snprintf(line, sizeof(line), "%s  %u%%", state, t.battery);
        text(t.state == TOY_CONNECTED ? 0x60e080 : COLOR_DIM, cx, cy, line);
        if (t.last[0] != '\0')
        {
            bool fresh = now - t.last_ms < FLASH_MS;
            flashing |= fresh;
            text(fresh ? COLOR_ACCENT : COLOR_DIM, cx + inner - text_width(t.last), cy, t.last);
        }
        cy += LINE;

        for (int m = 0; m < t.motor_count; m++)
        {
            const toy_motor_t *motor = &t.motors[m];
            text(COLOR_DIM, cx, cy, motor->name);
            snprintf(line, sizeof(line), "%u/%u", motor->level, motor->max);
            int value_w = text_width("20/20");
            int bar_x = cx + text_width("Vibrate") + GAP;
            int bar_w = inner - (bar_x - cx) - value_w - GAP;
            int bar_y = cy + 4, bar_h = BAR_ROW - 8;
            fill(COLOR_TRACK, bar_x, bar_y, bar_w, bar_h);
            fill(bar_color(motor->name), bar_x, bar_y, bar_w * motor->level / (motor->max ? motor->max : 1), bar_h);
            text(motor->level > 0 ? COLOR_TEXT : COLOR_DIM, cx + inner - text_width(line), cy, line);
            cy += BAR_ROW;
        }
        y += card_h + GAP;
    }

    XCopyArea(x, pixmap, window, gc, 0, 0, TOYS_PANEL_WIDTH, (unsigned)height, left, 0);
    XFlush(x);
    drawn_at = now;
}

void toys_panel_redraw(void)
{
    drawn_changes = toy_changes();
    draw();
}

void toys_panel_tick(void)
{
    uint32_t changes = toy_changes();
    uint32_t now = rcat_hal_millis();
    if (changes != drawn_changes || now - drawn_at >= (flashing ? 50 : REDRAW_MS))
    {
        toys_panel_redraw();
    }
}

void toys_panel_click(int px, int py)
{
    for (size_t i = 0; i < off_count; i++)
    {
        if (inside(off_buttons[i], px, py))
        {
            toy_remove(i);
            toys_panel_redraw();
            return;
        }
    }
    for (size_t i = 0; i < add_count; i++)
    {
        if (inside(add_buttons[i], px, py))
        {
            toy_add(i);
            toys_panel_redraw();
            return;
        }
    }
}
