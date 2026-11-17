#include "screenshot.h"

#include <stdio.h>
#include <string.h>

#include "lvgl.h"
#include "lvgl_private.h"   // the display's buffer, as it's flushed (LVGL is a pinned submodule)

#include "hal.h"

#if RCAT_HAVE_FILESYSTEM
#include <sys/stat.h>
#endif

#define POLL_MS         50
#define NOTICE_MS       1500
#define MAX_SHOTS       9999

static const char *storage;

/* The picture being taken, filled in as LVGL flushes each part of the
 * screen */
static uint16_t *frame;
static int32_t frame_w, frame_h;

static void flush_start_cb(lv_event_t *e)
{
    lv_display_t *disp = lv_event_get_target(e);
    const lv_area_t *area = lv_event_get_param(e);
    const lv_draw_buf_t *buf = disp->buf_act;
    if (frame == NULL || area == NULL || buf == NULL)
    {
        return;
    }
    int32_t w = lv_area_get_width(area);
    for (int32_t y = area->y1; y <= area->y2; y++)
    {
        if (y < 0 || y >= frame_h)
        {
            continue;
        }
        const uint16_t *src = (const uint16_t *)(buf->data + (size_t)(y - area->y1) * buf->header.stride);
        for (int32_t x = 0; x < w; x++)
        {
            int32_t fx = area->x1 + x;
            if (fx >= 0 && fx < frame_w)
            {
                frame[(size_t)y * frame_w + fx] = src[x];
            }
        }
    }
}

uint16_t *screenshot_take(int32_t *w, int32_t *h)
{
    lv_display_t *disp = lv_display_get_default();
    if (disp == NULL)
    {
        return NULL;
    }
    // The size as the pages are laid out, after Rotation
    frame_w = lv_display_get_horizontal_resolution(disp);
    frame_h = lv_display_get_vertical_resolution(disp);
    frame = lv_malloc((size_t)frame_w * frame_h * sizeof(uint16_t));
    if (frame == NULL)
    {
        return NULL;
    }
    memset(frame, 0, (size_t)frame_w * frame_h * sizeof(uint16_t));

    // Draw everything again, and catch it on its way out
    lv_display_add_event_cb(disp, flush_start_cb, LV_EVENT_FLUSH_START, NULL);
    lv_obj_invalidate(lv_display_get_screen_active(disp));
    lv_obj_invalidate(lv_display_get_layer_top(disp));
    lv_obj_invalidate(lv_display_get_layer_sys(disp));
    lv_refr_now(disp);
    lv_display_remove_event_cb_with_user_data(disp, flush_start_cb, NULL);

    uint16_t *done = frame;
    frame = NULL;
    *w = frame_w;
    *h = frame_h;
    return done;
}

#if RCAT_HAVE_FILESYSTEM

static void put16(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
}

static void put32(uint8_t *p, uint32_t v)
{
    put16(p, (uint16_t)v);
    put16(p + 2, (uint16_t)(v >> 16));
}

/* A 24-bit BMP, which anything can open */
static bool write_bmp(const char *path, const uint16_t *px, int32_t w, int32_t h)
{
    FILE *f = fopen(path, "wb");
    if (f == NULL)
    {
        return false;
    }
    uint32_t row = ((uint32_t)w * 3 + 3) & ~3u;
    uint8_t header[54] = { 'B', 'M' };
    put32(header + 2, 54 + row * (uint32_t)h);
    put32(header + 10, 54);
    put32(header + 14, 40);
    put32(header + 18, (uint32_t)w);
    put32(header + 22, (uint32_t)h);
    put16(header + 26, 1);
    put16(header + 28, 24);
    put32(header + 34, row * (uint32_t)h);
    bool ok = fwrite(header, 1, sizeof(header), f) == sizeof(header);

    uint8_t *line = lv_malloc(row);
    ok = ok && line != NULL;
    // Rows go bottom to top, each blue, green, red
    for (int32_t y = h - 1; ok && y >= 0; y--)
    {
        memset(line, 0, row);
        for (int32_t x = 0; x < w; x++)
        {
            uint16_t c = px[(size_t)y * w + x];
            uint8_t r = (uint8_t)((c >> 11) & 0x1f), g = (uint8_t)((c >> 5) & 0x3f), b = (uint8_t)(c & 0x1f);
            line[x * 3 + 0] = (uint8_t)((b << 3) | (b >> 2));
            line[x * 3 + 1] = (uint8_t)((g << 2) | (g >> 4));
            line[x * 3 + 2] = (uint8_t)((r << 3) | (r >> 2));
        }
        ok = fwrite(line, 1, row, f) == row;
    }
    lv_free(line);
    ok = (fclose(f) == 0) && ok;
    if (!ok)
    {
        remove(path);
    }
    return ok;
}

bool screenshot_save(char *name, size_t cap)
{
    if (storage == NULL)
    {
        return false;
    }
    char dir[96], path[128];
    snprintf(dir, sizeof(dir), "%s/screenshots", storage);
    mkdir(dir, 0777);

    // The next number that isn't taken
    int n;
    struct stat st;
    for (n = 1; n <= MAX_SHOTS; n++)
    {
        snprintf(path, sizeof(path), "%s/shot_%04d.bmp", dir, n);
        if (stat(path, &st) != 0)
        {
            break;
        }
    }
    if (n > MAX_SHOTS)
    {
        return false;
    }

    int32_t w, h;
    uint16_t *px = screenshot_take(&w, &h);
    if (px == NULL)
    {
        return false;
    }
    bool ok = write_bmp(path, px, w, h);
    lv_free(px);
    printf("screenshot: %s %s\n", path, ok ? "saved" : "couldn't be saved");
    if (ok && name != NULL)
    {
        snprintf(name, cap, "shot_%04d.bmp", n);
    }
    return ok;
}

#else

bool screenshot_save(char *name, size_t cap)
{
    (void)name;
    (void)cap;
    return false;
}

#endif

/* ----- The buttons ----- */

static void notice_done_cb(lv_timer_t *t)
{
    lv_obj_delete(lv_timer_get_user_data(t));
}

/* A word on the screen to say how it went, after the picture's taken */
static void notice(const char *text)
{
    lv_obj_t *label = lv_label_create(lv_layer_top());
    lv_label_set_text(label, text);
    lv_obj_set_style_text_color(label, lv_color_white(), 0);
    lv_obj_set_style_bg_color(label, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(label, LV_OPA_80, 0);
    lv_obj_set_style_pad_all(label, 8, 0);
    lv_obj_set_style_radius(label, 8, 0);
    lv_obj_align(label, LV_ALIGN_BOTTOM_MID, 0, -lv_display_get_vertical_resolution(NULL) / 6);
    lv_timer_t *t = lv_timer_create(notice_done_cb, NOTICE_MS, label);
    lv_timer_set_repeat_count(t, 1);
}

static void poll_cb(lv_timer_t *t)
{
    (void)t;
    if (!rcat_hal_screenshot_pressed())
    {
        return;
    }
    char name[24];
    if (storage == NULL)
    {
        notice("No SD card");
    }
    else if (screenshot_save(name, sizeof(name)))
    {
        notice(name);
    }
    else
    {
        notice("Screenshot failed");
    }
}

void screenshot_init(const char *storage_path)
{
    storage = storage_path;
    lv_timer_create(poll_cb, POLL_MS, NULL);
}
