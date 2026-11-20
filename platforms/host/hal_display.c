/*
 * The virtual unit's screen: a window on the X11 desktop (XWayland will do),
 * showing the 1.75" board's round 466x466 screen, with the mouse for touch
 * and a couple of keys for the board's buttons, and beside it, while T's
 * pressed or --toy says, the virtual Lovense toys' panel (toys_panel.c)
 */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>

#include "hal.h"
#include "host.h"
#include "lvgl.h"
#include "toys_panel.h"

#define LCD_RES         466
#define BEZEL           0x161616    // outside the round screen
#define POLL_MS         5

static Display *x;
static Window window;
static GC gc;
static XImage *image;
static uint32_t *frame;             // what's in the window, scale times the size each way
static int scale = 1;
static Atom wm_delete;

static lv_display_t *display;
static uint8_t *draw_buf1, *draw_buf2, *rotate_buf;
static uint32_t palette[65536];     // RGB565 to the window's pixels, at the brightness
static uint8_t brightness = 100;
static int16_t round_from[LCD_RES]; // in each row, where the round screen starts; it ends as far from the right

static lv_point_t pointer;
static bool pressed;                // a finger's down on the screen
static bool panel_shown;

static void make_palette(void)
{
    for (uint32_t c = 0; c < 65536; c++)
    {
        uint32_t r = (c >> 11) & 0x1F, g = (c >> 5) & 0x3F, b = c & 0x1F;
        r = ((r << 3) | (r >> 2)) * brightness / 100;
        g = ((g << 2) | (g >> 4)) * brightness / 100;
        b = ((b << 3) | (b >> 2)) * brightness / 100;
        palette[c] = (r << 16) | (g << 8) | b;
    }
}

static void make_round(void)
{
    float radius = LCD_RES / 2.0f;
    for (int y = 0; y < LCD_RES; y++)
    {
        float dy = y + 0.5f - radius;
        float half = dy * dy < radius * radius ? sqrtf(radius * radius - dy * dy) : 0;
        round_from[y] = (int16_t)(radius - half + 0.5f);
    }
}

static int window_width(void)
{
    return LCD_RES * scale + (panel_shown ? TOYS_PANEL_WIDTH : 0);
}

/* The window's one size: the screen, and the panel if it's shown */
static void fix_size(void)
{
    XSizeHints *hints = XAllocSizeHints();
    hints->flags = PMinSize | PMaxSize;
    hints->min_width = hints->max_width = window_width();
    hints->min_height = hints->max_height = LCD_RES * scale;
    XSetWMNormalHints(x, window, hints);
    XFree(hints);
}

int rcat_hal_init(void)
{
    x = XOpenDisplay(NULL);
    if (x == NULL)
    {
        fprintf(stderr, "Can't open the display: the virtual unit needs a desktop (X11 or XWayland)\n");
        return -1;
    }
    scale = host_options.scale;
    int size = LCD_RES * scale;
    int screen = DefaultScreen(x);
    Visual *visual = DefaultVisual(x, screen);
    int depth = DefaultDepth(x, screen);
    if (depth < 24)
    {
        fprintf(stderr, "The display needs to be in 24-bit colour\n");
        return -1;
    }

    window = XCreateSimpleWindow(x, RootWindow(x, screen), 0, 0, size, size, 0, 0, BEZEL);
    char title[64];
    if (host_options.unit == 1)
    {
        snprintf(title, sizeof(title), "DroneLab: Virtual Display Unit");
    }
    else
    {
        snprintf(title, sizeof(title), "DroneLab: Virtual Display Unit %d", host_options.unit);
    }
    XStoreName(x, window, title);
    XClassHint class_hint = { .res_name = "dronelab-unit", .res_class = "DroneLab" };
    XSetClassHint(x, window, &class_hint);
    panel_shown = host_options.show_toys;
    fix_size();
    wm_delete = XInternAtom(x, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(x, window, &wm_delete, 1);
    XSelectInput(x, window, ExposureMask | ButtonPressMask | ButtonReleaseMask | PointerMotionMask | KeyPressMask);
    gc = XCreateGC(x, window, 0, NULL);

    frame = calloc((size_t)size * size, sizeof(uint32_t));
    image = XCreateImage(x, visual, depth, ZPixmap, 0, (char *)frame, size, size, 32, 0);
    if (frame == NULL || image == NULL)
    {
        return -1;
    }
    for (int i = 0; i < size * size; i++)
    {
        frame[i] = BEZEL;
    }
    make_palette();
    make_round();
    toys_panel_init(x, window, size, size);
    if (panel_shown)
    {
        XResizeWindow(x, window, (unsigned)window_width(), (unsigned)size);
    }
    XMapWindow(x, window);
    XFlush(x);
    return 0;
}

/* Show part of the frame */
static void show(int x1, int y1, int w, int h)
{
    XPutImage(x, window, gc, image, x1 * scale, y1 * scale, x1 * scale, y1 * scale, w * scale, h * scale);
    XFlush(x);
}

static void flush_cb(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map)
{
    lv_display_rotation_t rotation = lv_display_get_rotation(disp);
    lv_area_t phys = *area;
    const uint16_t *px = (const uint16_t *)px_map;

    if (rotation != LV_DISPLAY_ROTATION_0)
    {
        // As the board does it
        int32_t w = lv_area_get_width(area);
        int32_t h = lv_area_get_height(area);
        int32_t rotated_w = (rotation == LV_DISPLAY_ROTATION_180) ? w : h;
        uint32_t src_stride = lv_draw_buf_width_to_stride(w, LV_COLOR_FORMAT_RGB565);
        uint32_t dest_stride = lv_draw_buf_width_to_stride(rotated_w, LV_COLOR_FORMAT_RGB565);
        lv_draw_sw_rotate(px_map, rotate_buf, w, h, src_stride, dest_stride, rotation, LV_COLOR_FORMAT_RGB565);
        lv_display_rotate_area(disp, &phys);
        px = (const uint16_t *)rotate_buf;
    }

    int w = lv_area_get_width(&phys);
    int stride = LCD_RES * scale;
    for (int y = phys.y1; y <= phys.y2; y++)
    {
        int from = round_from[y], to = LCD_RES - round_from[y];
        for (int xx = phys.x1; xx <= phys.x2; xx++)
        {
            uint32_t c = (xx >= from && xx < to) ? palette[px[(y - phys.y1) * w + (xx - phys.x1)]] : BEZEL;
            uint32_t *out = frame + (size_t)y * scale * stride + (size_t)xx * scale;
            for (int sy = 0; sy < scale; sy++)
            {
                for (int sx = 0; sx < scale; sx++)
                {
                    out[sy * stride + sx] = c;
                }
            }
        }
    }
    if (lv_display_flush_is_last(disp))
    {
        show(0, 0, LCD_RES, LCD_RES);
    }
    lv_display_flush_ready(disp);
}

static void poll_events(void)
{
    while (XPending(x) > 0)
    {
        XEvent e;
        XNextEvent(x, &e);
        switch (e.type)
        {
            case Expose:
                if (e.xexpose.count == 0)
                {
                    show(0, 0, LCD_RES, LCD_RES);
                    if (panel_shown)
                    {
                        toys_panel_redraw();
                    }
                }
                break;
            case ButtonPress:
            case ButtonRelease:
                if (e.xbutton.button != Button1)
                {
                    break;
                }
                if (e.type == ButtonPress && e.xbutton.x >= LCD_RES * scale)
                {
                    if (panel_shown)
                    {
                        toys_panel_click(e.xbutton.x - LCD_RES * scale, e.xbutton.y);
                    }
                    break;
                }
                pressed = e.type == ButtonPress;
                pointer.x = LV_CLAMP(0, e.xbutton.x / scale, LCD_RES - 1);
                pointer.y = LV_CLAMP(0, e.xbutton.y / scale, LCD_RES - 1);
                break;
            case MotionNotify:
                pointer.x = LV_CLAMP(0, e.xmotion.x / scale, LCD_RES - 1);
                pointer.y = LV_CLAMP(0, e.xmotion.y / scale, LCD_RES - 1);
                break;
            case KeyPress:
            {
                KeySym key = XLookupKeysym(&e.xkey, 0);
                if (key == XK_b)
                {
                    host_button_press();
                }
                else if (key == XK_F12)
                {
                    host_screenshot_press();
                }
                else if (key == XK_t)
                {
                    panel_shown = !panel_shown;
                    fix_size();
                    XResizeWindow(x, window, (unsigned)window_width(), (unsigned)(LCD_RES * scale));
                }
                break;
            }
            case ClientMessage:
                if ((Atom)e.xclient.data.l[0] == wm_delete)
                {
                    host_peer_close();
                    exit(0);
                }
                break;
        }
    }
}

static void poll_timer_cb(lv_timer_t *timer)
{
    poll_events();
    if (panel_shown)
    {
        toys_panel_tick();
    }
}

static void pointer_read_cb(lv_indev_t *indev, lv_indev_data_t *data)
{
    poll_events();
    data->point = pointer;
    data->state = pressed ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;
}

static uint32_t tick_cb(void)
{
    return rcat_hal_millis();
}

void rcat_hal_lvgl_register(void)
{
    lv_tick_set_cb(tick_cb);

    size_t bytes = LCD_RES * LCD_RES * 2;
    draw_buf1 = malloc(bytes);
    draw_buf2 = malloc(bytes);
    rotate_buf = malloc(bytes);
    display = lv_display_create(LCD_RES, LCD_RES);
    lv_display_set_color_format(display, LV_COLOR_FORMAT_RGB565);
    lv_display_set_flush_cb(display, flush_cb);
    lv_display_set_buffers(display, draw_buf1, draw_buf2, bytes, LV_DISPLAY_RENDER_MODE_PARTIAL);

    lv_indev_t *indev = lv_indev_create();
    lv_indev_set_type(indev, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(indev, pointer_read_cb);

    // The window's own events, such as being uncovered, whether or not the
    // pointer's being read
    lv_timer_create(poll_timer_cb, POLL_MS, NULL);
}

void rcat_hal_display_set_rotation(uint8_t quarter_turns)
{
    // LVGL counts rotation counter-clockwise, so 90 degrees clockwise is its ROTATION_270
    static const lv_display_rotation_t rotations[4] = {
        LV_DISPLAY_ROTATION_0,
        LV_DISPLAY_ROTATION_270,
        LV_DISPLAY_ROTATION_180,
        LV_DISPLAY_ROTATION_90,
    };
    lv_display_set_rotation(display, rotations[quarter_turns & 3]);
}

void rcat_hal_backlight_set(uint8_t percent)
{
    brightness = percent > 100 ? 100 : percent;
    if (x == NULL)
    {
        return;
    }
    make_palette();
    if (display != NULL)
    {
        lv_obj_invalidate(lv_display_get_screen_active(display));
    }
}
