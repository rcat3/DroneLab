/*
 * The battery's charge, for showing to the user.
 *
 * Boards with a fuel gauge report it themselves. On the others it's worked
 * out from the voltage, along the discharge curve of a single LiPo cell,
 * smoothed so it doesn't jump around as the load changes.
 */
#ifndef RCAT_BATTERY_H
#define RCAT_BATTERY_H

#include <stdbool.h>
#include <stdint.h>

typedef struct
{
    float volts;            // smoothed
    uint8_t percent;        // 0-100
    bool charging;          // only known on boards with a fuel gauge
    bool charging_known;
} battery_status_t;

/* Take a new reading. Call it about once a second. Returns false if the
 * board can't measure its battery. */
bool battery_update(battery_status_t *status);

/* The charge in percent for a voltage, from the LiPo discharge curve. */
uint8_t battery_percent_from_volts(float volts);

#endif
