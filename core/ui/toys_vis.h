#ifndef RCAT_TOYS_VIS_H
#define RCAT_TOYS_VIS_H

/*
 * The Toy Visualizer, the Toys feature's first page (not the Visualizer
 * feature's pictures of the sound): what each channel a toy follows has
 * been running at over the last few seconds, as glowing traces that scroll
 * across the screen, over a purple glow. See toys_vis.c.
 */

#include <stdbool.h>

#include "lvgl.h"

/* Fill page (a black page of the Toys feature) with the Toy Visualizer, under
 * anything added to the page after it. Returns false if there's no room
 * for its canvas. */
bool toys_vis_add(lv_obj_t *page);

#endif
