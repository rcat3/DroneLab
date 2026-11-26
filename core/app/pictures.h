#ifndef RCAT_PICTURES_H
#define RCAT_PICTURES_H

/*
 * Pictures others show on the Display unit's screen (others.h's 0x12
 * picture): one built into the firmware, by its name, or one they've sent,
 * by its SHA-256.
 *
 * A sent picture comes over the server, to the wearer's app, which gives it
 * to this unit (comm.h 0x1A) once the command to show it's been taken. It
 * may come before the command or after it: one that comes first waits
 * PICTURES_WAIT_MS for its command, and a command waits as long for its
 * picture. Shown, it's kept, with a page of its own at the end of the
 * Images feature, after the SD card's pictures and the built-in ones, for
 * the wearer to swipe back to: the last PICTURES_KEPT of them, the oldest
 * going first, in memory (PSRAM) only, so they're gone when it restarts.
 * The wearer can delete them there.
 *
 * Sent pictures are JPEGs, made for the screen by the sender's app, or
 * GIFs, as they are.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define PICTURES_HASH_LEN       32
#define PICTURES_KEPT           3
#define PICTURES_WAITING        2               // come before their commands, at most
#define PICTURES_MAX_BYTES      (256 * 1024)    // the most a sent one can be
#define PICTURES_WAIT_MS        30000

#define PICTURES_JPEG           0               // what a sent one is
#define PICTURES_GIF            1

/* A sent picture, from the phone: started with its length, what it is and
 * its SHA-256, then its bytes in order, then finished, when it's checked
 * against the hash. Each returns false if it's gone wrong. From the UI
 * loop. */
bool pictures_begin(uint32_t length, uint8_t kind, const uint8_t hash[PICTURES_HASH_LEN]);
bool pictures_write(const uint8_t *data, size_t len);
bool pictures_finish(void);
uint32_t pictures_received(void);    // bytes of it so far

/* Show a picture, for so many seconds (0: until the wearer moves on): a
 * sent one, by its hash, which waits for it to come if it hasn't; or a
 * built-in one, by its name (UTF-8, len bytes). From the UI loop. */
void pictures_show_sent(const uint8_t hash[PICTURES_HASH_LEN], uint16_t seconds);
void pictures_show_built_in(const char *name, size_t len, uint16_t seconds);

/* The wearer's deleting the kept picture whose page this is (the Images
 * feature's). */
void pictures_delete_page(const void *page);

/* Whether a page (an lv_obj_t) is one of those: a sent picture the wearer
 * can delete. */
bool pictures_page_kept(const void *page);

/* Now and then, from the UI loop: drops what's waited too long. */
void pictures_poll(uint32_t now_ms);

#endif
