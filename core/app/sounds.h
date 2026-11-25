#ifndef RCAT_SOUNDS_H
#define RCAT_SOUNDS_H

/*
 * Sounds others play from the Display unit's speaker (others.h's 0x13
 * sound), by its SHA-256.
 *
 * A sound comes over the server, to the wearer's app, which gives it to
 * this unit (comm.h 0x1B) once the command to play it's been taken; never
 * over direct comms, which hasn't the room. It may come before the command
 * or after it: one that comes first waits SOUNDS_WAIT_MS for its command,
 * and a command waits as long for its sound. Then it plays once, over
 * whatever the player's doing, with nothing on screen (BOOT stops it), and
 * is kept as a track in the Sound feature's player, after the SD card's
 * (audio_player.h: the last AUDIO_SENT_KEPT, in memory only), for the
 * wearer to play again or delete. It plays at the wearer's volume, for
 * AUDIO_SENT_MAX_MS at most.
 *
 * Sent sounds are Opus packets (AUDIO_SENT_OPUS: the sender's app's
 * recordings, and WAV files, coded by it), or WAV, MP3 or FLAC files as
 * they are (AUDIO_SENT_FILE).
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define SOUNDS_HASH_LEN         32
#define SOUNDS_MAX_BYTES        (96 * 1024)     // the most a sent one can be
#define SOUNDS_WAITING          2               // come before their commands, at most
#define SOUNDS_WAIT_MS          30000

/* A sent sound, from the phone: started with its length, what it is
 * (AUDIO_SENT_*) and its SHA-256, then its bytes in order, then finished,
 * when it's checked against the hash. Each returns false if it's gone
 * wrong. From the UI loop. */
bool sounds_begin(uint32_t length, uint8_t kind, const uint8_t hash[SOUNDS_HASH_LEN]);
bool sounds_write(const uint8_t *data, size_t len);
bool sounds_finish(void);
uint32_t sounds_received(void);     // bytes of it so far

/* Play a sent one, by its hash, from the one named, waiting for it to come
 * if it hasn't. From the UI loop. */
void sounds_play_sent(const uint8_t hash[SOUNDS_HASH_LEN], const char *from);

/* Whether sounds can be played here: there's a speaker. */
bool sounds_available(void);

/* Now and then, from the UI loop: drops what's waited too long. */
void sounds_poll(void);

#endif
