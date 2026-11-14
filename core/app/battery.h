/*
 * The battery's charge, for showing to the user.
 *
 * It's worked out from the voltage, along the discharge curve the board's
 * learned (see app/battery_log.h), or until then its model's, smoothed so it
 * doesn't jump around as the load changes.
 */
#ifndef RCAT_BATTERY_H
#define RCAT_BATTERY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "hal.h"

typedef struct
{
    float volts;            // smoothed
    uint8_t percent;        // 0-100
    bool charging;          // only known on boards that can read their charger
    bool charging_known;
} battery_status_t;

/* Take a new reading. Call it about once a second. Returns false if the
 * board can't measure its battery. */
bool battery_update(battery_status_t *status);

/* The last reading battery_update() took, without taking another (the
 * phone remote shows it). Returns false before the first, or without a
 * battery to measure. */
bool battery_latest(battery_status_t *status);

/* The charge in percent for a voltage, from the curve the board's learned, or
 * else its default one. */
uint8_t battery_percent_from_volts(float volts);

/* The board's default curve, from before it's learned its own: the one
 * measured for its model, or a typical LiPo's. Returns how many points. */
size_t battery_default_curve(const rcat_battery_point_t **curve);

#endif
