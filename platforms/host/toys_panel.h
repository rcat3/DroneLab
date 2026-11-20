/*
 * The virtual toys' panel, beside the screen (toys_panel.c)
 */
#ifndef RCAT_HOST_TOYS_PANEL_H
#define RCAT_HOST_TOYS_PANEL_H

#include <X11/Xlib.h>

#define TOYS_PANEL_WIDTH    300

/* Draw it in window, from panel_left across, panel_height high */
void toys_panel_init(Display *display, Window window, int panel_left, int panel_height);

/* Draw it again now (it's been uncovered), or when anything's changed */
void toys_panel_redraw(void);
void toys_panel_tick(void);

/* A click at px, py in it */
void toys_panel_click(int px, int py);

#endif
