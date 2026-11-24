#ifndef RCAT_PATTERNS_H
#define RCAT_PATTERNS_H

/*
 * Patterns for the toys' channels (toys.h): levels that change over time.
 * A few are built in, and more can be put on the SD card, in a folder called
 * "patterns", as text files in Lovense's pattern format:
 *
 *   V:1;F:v;S:100#0;4;8;12;16;20;16;12;8;4
 *
 * F lists the motors the levels drive, as Lovense's letters (v vibrate, r
 * rotate, p the air pump, t, f or o thrusting) with a number after the
 * letter for the channel, whatever the letter: v2 drives V2. A letter
 * without a number, or no F, drives every channel the pattern's played on.
 * S is the time each level lasts, in milliseconds (100 or more). The levels
 * run from 0 to 20 and repeat. A file can hold several of these, one after
 * another, each driving its own channels and repeating at its own length.
 */

#include <stddef.h>
#include <stdint.h>

#include "app/toys.h"

#define PATTERNS_FOLDER     "patterns"

/* Load the built-in patterns, then any on the card. storage_path is where the
 * card is mounted, or NULL without one. */
void patterns_init(const char *storage_path);

size_t patterns_count(void);
const char *patterns_name(size_t index);

/* How hard a channel (0 for V1) should run, 0 to 1, t_ms into the pattern.
 * Returns -1 if the pattern doesn't drive this channel. */
float patterns_level(size_t index, uint8_t channel, uint32_t t_ms);

#endif
