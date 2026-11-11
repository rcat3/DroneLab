/*
 * The battery log: the battery's voltage once a minute, kept in flash, for
 * working out the board's real discharge curve. Start it with a full
 * battery, unplug USB and leave the board running until it switches off.
 * tools/battery_log.py then reads the log back over USB.
 *
 * It only records in the session it was started in: after the board's been
 * off, the log is kept as it was, until it's started again.
 */
#ifndef RCAT_BATTERY_LOG_H
#define RCAT_BATTERY_LOG_H

#include <stdbool.h>
#include <stdint.h>

/* Whether the board can keep a log. Call it before the others: it also
 * loads the last log. */
bool battery_log_available(void);

/* Throw away the old log and start a new one. */
void battery_log_start(void);

bool battery_log_running(void);

/* How long the log covers, in seconds: the one running, or else the last. */
uint32_t battery_log_seconds(void);

#endif
