#ifndef RCAT_TOY_DRIVER_H
#define RCAT_TOY_DRIVER_H

/*
 * What toys.c needs from the driver for a maker's toys: which of the
 * Bluetooth devices found are theirs, how to find out which model one is
 * (its outputs), and how to send it its outputs' levels. toys.c finds and
 * connects to them, keeps the levels, and stops and disconnects them; a
 * driver only speaks their language.
 *
 * Each driver is listed in toys.c's drivers[]. Everything is called from
 * toys_poll(), on the UI loop.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "app/toys.h"

#define TOY_DRIVER_STATE    96      // bytes a driver can keep for each toy

/* A toy, as a driver sees it */
typedef struct
{
    toy_t *toy;             // its outputs and battery are the driver's to fill in
    int link;               // its HAL Bluetooth link
    uint32_t now;           // the time of this poll, in ms
    void *state;            // TOY_DRIVER_STATE bytes, zeroed as it connects
} toy_link_t;

typedef struct
{
    const char *maker;

    /* Whether a device found by its advertised name is one of theirs. */
    bool (*claims)(const char *name);

    /* Whether a GATT service is the one to talk to it on. */
    bool (*service)(const uint8_t uuid[16]);

    /* Connected: find out which model it is, by asking it, and fill in
     * toy->model and its outputs (kind and max). Called each poll until it
     * returns true. */
    bool (*identify)(toy_link_t *t);

    /* Connected and known: read what it says, and send the outputs' levels
     * that have changed (toy->outputs[i].level), as fast as it takes them. */
    void (*poll)(toy_link_t *t);

    /* Set every output to 0 straight away, ahead of disconnecting. */
    void (*stop)(toy_link_t *t);
} toy_driver_t;

/* The drivers */
extern const toy_driver_t toy_lovense;

#endif
