/*
 * Firmware updates over WiFi, from tools/update.py on a computer.
 *
 * It has nothing to do with the phone remote's page: it's a server of its
 * own, on UPDATE_PORT, that only runs while updates are allowed from the
 * board's own Settings. Allowing them shows a new six digit code on the
 * screen, which the script has to send, so only someone who can get at the
 * screen can update the board. It also starts the hotspot, if it isn't on,
 * for the computer to join. It switches itself off after a while, after
 * three wrong codes, and when the board restarts.
 *
 * The update is checked to be whole and for this board, and written beside
 * the running firmware, which carries on until it's done. The board then
 * restarts into the new one. If that doesn't get as far as
 * updater_init()'s confirmation, the board goes back to the old one the next
 * time it's restarted.
 */
#ifndef RCAT_UPDATER_H
#define RCAT_UPDATER_H

#include <stdbool.h>

#define UPDATE_PORT 8070

/* Call once the UI is up. It confirms the firmware works a little later,
 * and runs the server while updates are allowed. */
void updater_init(void);

/* Whether the board can be updated over WiFi. */
bool updater_available(void);

void updater_allow(bool allow);
bool updater_allowed(void);

/* The code to give tools/update.py, while updates are allowed. */
const char *updater_code(void);

/* What it's doing, for the screen: waiting, how far an update's got, or why
 * the last one failed. */
const char *updater_status(void);

#endif
