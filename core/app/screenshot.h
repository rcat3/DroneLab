#ifndef RCAT_SCREENSHOT_H
#define RCAT_SCREENSHOT_H

/*
 * Screenshots: what's on the display, saved to the SD card as a BMP file
 * when PWR is held and BOOT pressed (rcat_hal_screenshot_pressed()), in
 * screenshots/ on the card, numbered shot_0001.bmp and on.
 *
 * The picture is taken by having LVGL draw the whole screen again and
 * copying each part on its way to the display, so it's exactly what's shown,
 * with anything drawn over the pages (the dots, a pairing code), the right
 * way up for the Rotation setting.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Start watching the buttons. storage_path is where the SD card's mounted,
 * or NULL without one, when the buttons do nothing. */
void screenshot_init(const char *storage_path);

/* Take a picture of the screen: RGB565 pixels, a row at a time, w x h, in
 * memory from lv_malloc() for the caller to lv_free(). NULL if there isn't
 * the memory. Call it from the UI loop. */
uint16_t *screenshot_take(int32_t *w, int32_t *h);

/* Take one and save it to the card. Writes its file name to name (if not
 * NULL) and returns true if it was saved. */
bool screenshot_save(char *name, size_t cap);

#endif
