#ifndef RCAT_STORAGE_SAVE_H
#define RCAT_STORAGE_SAVE_H

/*
 * Pictures and sounds the app saves to the unit's SD card (comm.h 0x1D), and
 * deletes from it, so they can be used without taking the card out.
 *
 * One file comes at a time, in pieces, to "<name>.part", which is checked
 * against its SHA-256 and renamed once it's all there. Then it's put among
 * the unit's pictures (pictures: the Images feature) or tracks (sounds: the
 * Sound feature's player) as they are, and whatever's showing or playing
 * carries on. A file that's there already isn't written over: the app
 * deletes it first, if the wearer says to. "*.part" files left by a transfer
 * that didn't finish are deleted when the unit starts.
 *
 * Playing's paused while a sound comes, because the card's busy, and carries
 * on after.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define SAVE_PICTURE            0           // what a file is
#define SAVE_SOUND              1
#define SAVE_HASH_LEN           32
#define SAVE_NAME_MAX           64          // a file's name, with its extension
#define SAVE_PICTURE_MAX_BYTES  (2u * 1024 * 1024)
#define SAVE_SOUND_MAX_BYTES    (3u * 1024 * 1024)

/* What came of it, for the app (the ack's last byte, and /api/storage's
 * "result"). */
typedef enum
{
    SAVE_OK,
    SAVE_NO_CARD,           // no card, or it can't be written
    SAVE_BAD_NAME,          // a name or kind that isn't allowed
    SAVE_EXISTS,            // a file of that name is there
    SAVE_NO_ROOM,           // too big, the card's full, or the list is
    SAVE_FAILED,            // writing went wrong
    SAVE_BAD_HASH,          // it didn't come to its hash
    SAVE_BAD_FILE,          // it can't be shown or played
    SAVE_BUSY,              // not now: try again
} save_result_t;

/* With the card's mount point (NULL if there's none): deletes the "*.part"
 * files left. */
void storage_save_init(const char *storage_path);

/* A file coming from the phone: begin it (its length, kind, SHA-256 and
 * name, name_len bytes of ASCII), then give it its pieces in order, each
 * with where it goes, then finish. A piece that isn't where the file's got
 * to is left out (for the phone to send again from there: see
 * storage_save_received()), and isn't a failure. From the UI loop. */
save_result_t storage_save_begin(uint8_t kind, uint32_t length, const uint8_t hash[SAVE_HASH_LEN],
                                 const char *name, size_t name_len);
save_result_t storage_save_write(uint32_t offset, const uint8_t *data, size_t len);
save_result_t storage_save_finish(void);
uint32_t storage_save_received(void);       // bytes of it so far

/* Give up on the one that's coming, deleting what's there of it. */
void storage_save_abort(void);

/* The phone's said something: it's still there. */
void storage_save_touch(void);

/* Now and then, with rcat_hal_millis(): drops one that's gone quiet. */
void storage_save_poll(uint32_t now_ms);

/* Whether one's coming now. */
bool storage_save_busy(void);

/* Delete a file from the card, taking it out of the lists, stopping it if
 * it plays. */
save_result_t storage_save_delete(uint8_t kind, const char *name);

/* The card: whether there is one, and its room. */
bool storage_save_present(void);
bool storage_save_space(uint64_t *total, uint64_t *free_bytes);

/* Call each with the name of every picture or sound file on the card (with
 * its extension), for /api/storage. */
void storage_save_list(uint8_t kind, void (*each)(const char *name, void *user), void *user);

#endif
