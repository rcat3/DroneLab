/*
 * Firmware updates from the app, over Bluetooth (comm.c, message 0x0E).
 *
 * The app carries the firmware of its own release, and sends it to a board
 * with older firmware when the wearer says so. The phone's already paired,
 * so only the wearer's phone can do it. The update's checked to be for this
 * board (the board looks for its own name's marker in it, rather than take
 * the app's word), to fit, and to be whole, and it's written beside the
 * running firmware, which carries on until it's done. The board then
 * restarts into the new one. If that doesn't get as far as updater_init()'s
 * confirmation, the board goes back to the old one the next time it's
 * restarted.
 */
#ifndef RCAT_UPDATER_H
#define RCAT_UPDATER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define UPDATER_MIN_BATTERY_PERCENT 20

/* Call once the UI is up. It confirms the firmware works a little later. */
void updater_init(void);

/* Whether an LVGL timer is the updater's own, to keep running while the
 * rest are paused for an update (update_screen.c). */
typedef struct _lv_timer_t lv_timer_t;
bool updater_owns_timer(const lv_timer_t *t);

typedef enum
{
    UPDATE_OK = 0,
    UPDATE_WRONG_BOARD,     // not this board's firmware
    UPDATE_TOO_BIG,         // or no length
    UPDATE_LOW_BATTERY,     // below UPDATER_MIN_BATTERY_PERCENT
    UPDATE_CANT_START,
    UPDATE_NOT_STARTED,     // data or an end with no start
    UPDATE_WRITE_FAILED,
    UPDATE_INCOMPLETE,      // ended before it was all there
    UPDATE_DAMAGED,         // not a whole firmware for this chip
} update_result_t;

/* Whether the app can update this board: updater_app_begin() can work. */
bool updater_app_available(void);

/* Start one of length bytes, for board (RCAT_BOARD_NAME), of the firmware
 * version given ("" if the app didn't say). From the UI loop, as are the
 * rest. */
update_result_t updater_app_begin(size_t length, const char *board, const char *version);

/* The next bytes, at offset: anything not at updater_app_received() is
 * left out, for the app to send again from there. */
update_result_t updater_app_write(size_t offset, const void *data, size_t len);
size_t updater_app_received(void);

/* It's all come: check it, and restart into it shortly if it's good. If it
 * was kept in PSRAM, it's only checked for now, and installed after the app's
 * been answered (updater_app_installing): updater_app_outcome() says if that
 * fails, and if it works the board restarts. */
update_result_t updater_app_finish(void);
bool updater_app_installing(void);

/* How an install that failed went, once: true and the result if there's one
 * for the app. */
bool updater_app_outcome(update_result_t *out);

/* Throw away one that's going, as when the phone goes. */
void updater_app_cancel(void);

/* How an update's going, for the screen. */
typedef enum
{
    UPDATE_SHOW_NONE,           // nothing to show
    UPDATE_SHOW_RECEIVING,      // coming in from the app
    UPDATE_SHOW_INSTALLING,     // being written to flash
    UPDATE_SHOW_RESTARTING,     // done: restarting into it
} update_show_t;

typedef struct
{
    update_show_t show;
    size_t done, total;         // bytes received, or written while installing
    uint32_t bytes_per_s;       // coming in, lately; 0 while installing
    const char *from, *to;      // the running firmware's version, and the new one's ("" if not said)
} update_progress_t;

void updater_progress(update_progress_t *out);

#endif
