#ifndef RCAT_UI_H
#define RCAT_UI_H

#include <stdbool.h>
#include <stddef.h>

/* Build the tile view: one tile per image, a black tile, then the settings tiles. */
void ui_init(void);

/*
 * Moving around from outside the UI (the phone remote). Features are counted
 * top to bottom, and the pages in each one left to right, as on screen.
 * Only call these from the UI loop.
 */
size_t ui_feature_count(void);
const char *ui_feature_name(size_t feature);
size_t ui_page_count(size_t feature);
const char *ui_page_name(size_t feature, size_t page);

/* Which feature and page are on screen. */
void ui_current(size_t *feature, size_t *page);

/* Bring a page on screen, as if it had been swiped to. */
void ui_show(size_t feature, size_t page);

/* Move one page, as a swipe would: dx = 1 to the next page of the feature,
 * -1 to the one before; dy = 1 to the next feature down, -1 to the one up,
 * which shows the page it was left on. False at an edge, or with neither. */
bool ui_step(int dx, int dy);

/* A page's object (an lv_obj_t), to compare with what a feature keeps, or
 * NULL if there's no such page. */
void *ui_page_object(size_t feature, size_t page);

/* Bring a page on screen for others (others.h's Display commands), and go
 * back to what was on screen before after seconds, or with ui_go_back();
 * 0 seconds stays until the wearer moves on, though ui_go_back() still goes
 * back. Once the wearer moves on, it's left where it is. Another, while the
 * first's still showing, goes back to what was before the first. */
void ui_show_for(size_t feature, size_t page, uint32_t seconds);
void ui_go_back(void);

/* On a new unit, just set up: ask whether to pair a phone now. Does nothing
 * with the Phone App off, or without one. Call after ui_init(). */
void ui_offer_first_pairing(void);

/* The Sound Visualizer feature's name (feature_visualizer.c), not to be
 * mixed up with the Toys feature's Toy Visualizer. */
#define UI_SOUND_VISUALIZER "Sound Visualizer"

/* The Sound Visualizer's styles, by the index saved in settings_t.visualizer.
 * None without the feature or a microphone. */
size_t ui_visualizer_count(void);
const char *ui_visualizer_name(size_t index);

/* Show style index for a sound others sent, speaker only, until it's played. */
void ui_visualizer_show_for_sound(size_t index);

#endif
