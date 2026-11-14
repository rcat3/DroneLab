#ifndef RCAT_VOICE_RING_H
#define RCAT_VOICE_RING_H

#include <stdbool.h>
#include <stdint.h>

#include "lvgl.h"

/* A ring around the edge of the screen whose brightness follows the
 * microphone level. It's drawn on LVGL's top layer, over the tiles. Needs
 * audio_level_start() first. */
void voice_ring_create(void);

void voice_ring_set_visible(bool visible);
void voice_ring_set_color(uint8_t color_index);

/* True once voice_ring_create() has made it. */
bool voice_ring_available(void);

/* The available colors, as roller options ("Red\nOrange\n...") and a count,
 * and each one's name and 0xRRGGBB. */
const char *voice_ring_color_options(void);
uint8_t voice_ring_color_count(void);
const char *voice_ring_color_name(uint8_t index);
uint32_t voice_ring_color_rgb(uint8_t index);

#endif
