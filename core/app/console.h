#ifndef RCAT_CONSOLE_H
#define RCAT_CONSOLE_H

/*
 * A console on the USB serial port, for development: built only with
 * -DRCAT_SERIAL_CONSOLE=1, and does nothing otherwise. tools/screenshots.py
 * uses it to step through the pages and take pictures of them for the
 * documentation, with no SD card or buttons. A line at a time:
 *
 *   api GET /api/info              any of the remote's API requests (see
 *   api POST /api/show?f=1&p=0     remote.h), answered with a line
 *   api POST /api/message hello    "CONSOLE: <json>", or "CONSOLE: -1".
 *                                  After the target, the rest is the body.
 *   shot                           a picture of the screen, as lines
 *                                  "SHOT: BEGIN <w> <h> <lines>", then
 *                                  "SHOT: <line> <crc32> <base64>" of its
 *                                  RGB565 pixels, little-endian, a row at
 *                                  a time, and "SHOT: END"
 *   line <n>                       that line of the last picture again,
 *                                  for one that didn't arrive whole
 *   save                           a screenshot to the SD card, as the
 *                                  buttons do, answered "CONSOLE: <name>"
 */

/* Start reading the port. Call it once the UI is up. */
void console_init(void);

#endif
