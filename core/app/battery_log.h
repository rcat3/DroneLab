/*
 * The battery log, and the board learning its own discharge curve from it.
 *
 * The board records the battery's voltage once a minute, all the time it's
 * on, into a block of flash. When it starts up, it looks back at the last
 * run: if that went from a full battery to flat, without charging in between,
 * it works out the discharge curve from it and uses that for the percentage
 * from then on (see app/battery.h). Each later complete run is blended in, so
 * the curve keeps up as the battery ages.
 *
 * The last run stays in flash until the new one has been going ten minutes,
 * so a board that's run flat can be plugged in and read with
 * tools/battery_log.py before it's lost.
 */
#ifndef RCAT_BATTERY_LOG_H
#define RCAT_BATTERY_LOG_H

#include <stdbool.h>
#include <stdint.h>

typedef enum
{
    BATTERY_RUN_NONE,           // no last run
    BATTERY_RUN_LEARNED,        // the curve was learned from it
    BATTERY_RUN_SHORT,          // under an hour
    BATTERY_RUN_NOT_FULL,       // the battery wasn't full at the start
    BATTERY_RUN_NOT_EMPTY,      // it was switched off before the battery ran flat
    BATTERY_RUN_GAUGE,          // the board has a fuel gauge, so needs no curve
} battery_run_t;

/* Look at the last run, learn from it if it was a complete one, and start
 * recording. Call it once, after settings_init() and lv_init(). */
void battery_log_init(void);

/* Whether the board is keeping a log at all. */
bool battery_log_available(void);

/* How long this run's been going, and how long the last one went, in
 * seconds, and what became of the last one. */
uint32_t battery_log_seconds(void);
uint32_t battery_log_last_seconds(void);
battery_run_t battery_log_last_run(void);

#endif
