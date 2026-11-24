#ifndef RCAT_PATTERNS_H
#define RCAT_PATTERNS_H

/*
 * Patterns for the toys' channels (toys.h): levels that change over time.
 *
 * Six are built in, worked out from the time as they play. The others are
 * custom patterns, made in the wearer's app or someone else's, each known by
 * its hash: the first PATTERNS_HASH_LEN bytes of the SHA-256 of its
 * definition. A pattern has up to PATTERNS_ROWS rows, and played on some
 * channels, its first row drives the first of them (the lowest), its second
 * the next, and so on. The built-in ones run the second, fourth and sixth
 * half a cycle behind the others, so a pattern played on two channels takes
 * turns.
 *
 * A custom pattern's definition, as it's sent (others.h):
 *   the format (1), the name's length (1 to PATTERNS_NAME_MAX), the name in
 *   UTF-8, how many blocks (1 to PATTERNS_ROWS), then for each block:
 *     how long each step lasts, in ms (2, little endian, 100 to 60000),
 *     the rows it drives (a bit for each, row 1 the lowest; 0 for all of
 *     them), how many steps (2, little endian, 1 or more), then the steps'
 *     levels (0 to 20), 5 bits each, the lowest bits first, the last byte
 *     filled out with 0s.
 *   Each block repeats at its own length. Where two drive one row, the last
 *   wins.
 *
 * Patterns go in slots, by index: the built-in ones first, then the
 * wearer's favourites, from their app, kept in flash; then those others
 * have sent, kept until there's no room for more (the one played longest
 * ago goes, but never one that's playing). The favourites, then the
 * built-in ones, are listed for the wearer: on the Toys feature's Patterns
 * page, and the WiFi remote's.
 *
 * The favourites come from the app as one document (comm.h's 0x19), at
 * most RCAT_HAL_PATTERNS_SIZE bytes: how many (0 to PATTERNS_FAVOURITES),
 * then for each, its definition's length (2, little endian) and the
 * definition.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "app/toys.h"

#define PATTERNS_HASH_LEN       8
#define PATTERNS_NAME_MAX       24      // bytes of UTF-8
#define PATTERNS_ROWS           TOYS_CHANNELS
#define PATTERNS_FORMAT         1
#define PATTERNS_PART_MAX       106     // a definition's bytes in one part (others.h)
#define PATTERNS_PARTS_MAX      6
#define PATTERNS_DEF_MAX        (PATTERNS_PART_MAX * PATTERNS_PARTS_MAX)
#define PATTERNS_BUILT_IN       6
#define PATTERNS_FAVOURITES     32
#define PATTERNS_RECEIVED       8
#define PATTERNS_RECEIVED_AT    (PATTERNS_BUILT_IN + PATTERNS_FAVOURITES)
#define PATTERNS_SLOTS          (PATTERNS_RECEIVED_AT + PATTERNS_RECEIVED)

/* Set up the slots, and the built-in patterns. */
void patterns_init(void);

/* How many are listed for the wearer, and the slot of each: the
 * favourites, then the built-in ones. -1 past the end. */
size_t patterns_count(void);
int patterns_listed(size_t position);

/* A pattern's name, by its index (any slot); "" for an empty one. */
const char *patterns_name(size_t index);

/* A built-in pattern by its name, in UTF-8; -1 if there's none. */
int patterns_built_in(const uint8_t *name, size_t len);

/* A custom pattern by its hash, a favourite or one received; -1 if it isn't
 * here. Finding one counts as playing it, for which to keep. */
int patterns_find(const uint8_t hash[PATTERNS_HASH_LEN]);

/* A definition's hash. */
void patterns_hash(const uint8_t *def, size_t len, uint8_t out[PATTERNS_HASH_LEN]);

/* A part of a definition someone's sent: once all its parts are here, and
 * they come to the hash, it's kept. Returns its index then, or if it's here
 * already; -1 till then, or if it's no good. */
int patterns_part(const uint8_t hash[PATTERNS_HASH_LEN], uint8_t part, uint8_t count, const uint8_t *data, size_t len,
                  uint32_t now_ms);

/* A piece of the favourites' document, from the app: the first starts it
 * afresh; with the last, it's checked, kept in flash, and takes the place
 * of the favourites there were. A channel playing one that's still there
 * carries on; one that's gone, it stops. Returns false if it was no good. */
bool patterns_receive_favourites(bool first, bool last, const uint8_t *piece, size_t len);

/* The favourites' document's FNV-1a hash, as the app works it out, for
 * /version: that of an empty one (a 0) with none. */
uint32_t patterns_favourites_hash(void);

/* Goes up when the listed patterns change, for the screen to redraw. */
uint32_t patterns_changes(void);

/* How hard a row (0 for the first) should run, 0 to 1, t_ms into the
 * pattern. Returns -1 if the pattern doesn't drive that row. */
float patterns_level(size_t index, uint8_t row, uint32_t t_ms);

#endif
