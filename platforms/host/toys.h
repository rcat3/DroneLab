/*
 * Virtual Lovense toys (hal_ble.c): pretend devices the virtual unit finds
 * and connects to as if over Bluetooth, which take Lovense's own commands,
 * so the Lovense feature, and the app's remote for it, can be tried without
 * a toy. The panel beside the screen (toys_panel.c) makes them and shows
 * what they're doing.
 */
#ifndef RCAT_HOST_TOYS_H
#define RCAT_HOST_TOYS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define TOY_MAX         3       // as many as the Lovense feature connects to
#define TOY_MAX_MOTORS  3

typedef enum
{
    TOY_WAITING,        // advertising, waiting to be found and connected
    TOY_CONNECTING,
    TOY_CONNECTED,
} toy_state_t;

typedef struct
{
    const char *name;           // "Vibrate", "Rotate", "Air", "Thrust"
    uint8_t max;
    uint8_t level;
} toy_motor_t;

/* A copy of a toy, to show */
typedef struct
{
    char name[16];              // as advertised, "LVS-S01"
    const char *model;          // "Lush"
    toy_state_t state;
    uint8_t battery;            // percent
    uint8_t motor_count;
    toy_motor_t motors[TOY_MAX_MOTORS];
    char last[24];              // the last command it was sent
    uint32_t last_ms;           // when
} toy_view_t;

/* The models a toy can be */
size_t toy_model_count(void);
const char *toy_model_name(size_t model);

/* Make a toy of a model, by its index or its name (any case). False if
 * there are TOY_MAX already, or there's no such model. */
bool toy_add(size_t model);
bool toy_add_named(const char *model);

/* Take a toy away, as if it were switched off: a connection to it drops. */
void toy_remove(size_t index);

/* How many toys there are, and a copy of one. */
size_t toy_count(void);
bool toy_get(size_t index, toy_view_t *view);

/* Goes up whenever anything about the toys changes, to know when to redraw */
uint32_t toy_changes(void);

#endif
