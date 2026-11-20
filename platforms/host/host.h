/*
 * What the virtual unit's HAL files share
 */
#ifndef RCAT_HOST_H
#define RCAT_HOST_H

#include <stdbool.h>
#include <stddef.h>

/* Chosen on the command line (see main.c) */
typedef struct
{
    int unit;                   // which virtual unit this is, 1 and up
    const char *sdcard;         // the folder to use as the SD card, or NULL for the unit's own
    bool no_mic;                // don't open the microphone
    bool no_speaker;            // or the speaker
    int scale;                  // the window's size, in screen pixels to each of the unit's
    bool show_toys;             // show the virtual toys' panel from the start
    char **argv;                // for restarting
} host_options_t;

extern host_options_t host_options;

/* The unit's own folder, where it keeps its settings:
 * ~/.local/share/io.github.rcat3.dronelab/unit (unit-2 for unit 2, ...),
 * made if it isn't there. */
const char *host_data_dir(void);

/* path, in the unit's own folder */
void host_data_path(char *out, size_t len, const char *name);

/* Presses from the keyboard, for the board's buttons (hal_system.c) */
void host_button_press(void);
void host_screenshot_press(void);

/* Close what a restart mustn't keep open (hal_peer.c) */
void host_peer_close(void);

#endif
