#ifndef RCAT_REACTIVE_H
#define RCAT_REACTIVE_H

/*
 * Reactions for the toys' channels: a factor from 0 to 1, worked out from
 * the microphone or the accelerometer, that scales whatever's driving the
 * channels that follow it (a pattern, or their levels).
 *
 *   Voice    follows how loud you're talking
 *   Moving   on while you move, off soon after you stop
 *   Still    on only once you've held still, with the screen upright
 *   Motion   the more you move, the stronger
 *   Tilt     the further you tilt from upright, the stronger
 *
 * "Upright" is the picture standing upright, as the Level feature measures
 * it, so set the display's rotation first.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum
{
    REACTIVE_OFF,
    REACTIVE_VOICE,
    REACTIVE_MOVING,
    REACTIVE_STILL,
    REACTIVE_MOTION,
    REACTIVE_TILT,
    REACTIVE_COUNT
} reactive_mode_t;

/* Whether the board has what a mode needs (a microphone or an
 * accelerometer). */
bool reactive_available(reactive_mode_t mode);

const char *reactive_name(reactive_mode_t mode);

/* Read the sensors and work out the factor, 0 to 1, of each of the modes in
 * [modes] (a bit for each, 1 << mode): several can be followed at once, by
 * different channels. A mode that's just come into [modes] starts afresh.
 * Call every 50 ms or so with a millisecond clock. */
void reactive_poll(uint32_t now_ms, uint32_t modes);

/* A mode's factor, as the last poll worked it out: 1 for Off. */
float reactive_factor(reactive_mode_t mode);

/* A few words on what a mode's sensing now, e.g. "Hold still..." or
 * "Tilt 12°", for showing on screen. */
void reactive_status(reactive_mode_t mode, char *text, size_t len);

#endif
