#ifndef RCAT_DIRECT_H
#define RCAT_DIRECT_H

/*
 * Direct comms: the comm channel's voice, board to board over the radio
 * (rcat_hal_direct_*, ESP-NOW on the ESP32 boards), with no internet, phone
 * or server in between, for where there's no signal. Each board broadcasts
 * the wearer's voice, as the same Opus packets the comm channel sends its
 * phone, and passes on what it hears from the others to its phone, which
 * plays it with the server's voices (see comm.h, 0x07 and 0x08).
 *
 * Boards talk in a group: a key (from the group's name and passphrase, set in
 * the app) that everything's encrypted with, so only the group hears it.
 * Boards that haven't been given one are in the open group, which any board
 * can hear.
 *
 * Each broadcast:
 *   header (sent as it is, and checked):
 *     'D', DIRECT_VERSION, the group's id (4 bytes: the first of the key's
 *     SHA-256), the sender's id (4, random each time it starts), a counter
 *     (4, little endian, goes up with every broadcast), hops left (1, 0 for
 *     now: nothing's passed on)
 *   then, encrypted with AES-128-GCM, the nonce being the sender's id,
 *   counter and the group's id:
 *     voice: 01, seq (2, little endian), flags (bit 0 first, bit 1 last),
 *            the Opus packet's length (1), then the Opus packet: as the comm
 *            channel's sound (comm.h); then, but for the first, up to two
 *            packets before it again, newest first, each its length (1) then
 *            it, so two lost in a row come back from the next
 *     hello: 02, flags (bit 0 talking), then the board's name, in UTF-8,
 *            every couple of seconds, and as it starts
 *   then an 8-byte tag.
 * A board ignores the group's broadcasts from a sender whose counter hasn't
 * gone up, so a recorded one can't be played back.
 *
 * And, from boards in a group with a key, every couple of seconds, not
 * encrypted, so that boards outside it can see it's there and ask to join:
 *   beacon: 'G', DIRECT_VERSION, the group's id (4), the sender's id (4),
 *           then the group's name.
 * Joining takes the group's passphrase: the app makes the key from the name
 * and passphrase (direct_key), and checks it gives the group's id before
 * using it. It's slow to make on purpose, so that guessing passphrases
 * against an id heard over the air is slow too.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define DIRECT_VERSION          3
#define DIRECT_KEY_LEN          16
#define DIRECT_NAME_MAX         16      // with its terminating zero
#define DIRECT_PEERS_MAX        12
#define DIRECT_GROUPS_MAX       8
#define DIRECT_KEY_ROUNDS       20000   // PBKDF2's, for direct_key

#define DIRECT_FIRST            0x01    // voice flags, as the comm channel's
#define DIRECT_LAST             0x02

/* Set it up, and start it if it was on when the board was last switched
 * off. Call it once at startup. */
void direct_init(void);

/* True on boards with the radio for it. */
bool direct_available(void);

/* Switch it on or off. Remembered for the next startup. */
bool direct_start(void);
void direct_stop(void);
bool direct_running(void);

/* The group: its key (NULL for the open group), its name to show, and this
 * board's name in it ("" for the board's own, comm_name()). Remembered. */
void direct_set_group(const uint8_t *key, const char *group, const char *name);
const char *direct_group_name(void);    // "Open" for the open group
const char *direct_own_name(void);

/* A group's key, from its name and passphrase: PBKDF2-HMAC-SHA256, the
 * salt "dronelab-direct\n" and the name, DIRECT_KEY_ROUNDS rounds, 16 bytes.
 * The app makes it the same way. Slow: a second or so. */
void direct_key(const char *group, const char *passphrase, uint8_t key[DIRECT_KEY_LEN]);

/* Broadcast one packet of the wearer's voice. From any one task. */
void direct_send_voice(uint16_t seq, uint8_t flags, const uint8_t *opus, size_t len);

/* Called with each packet of the others' voice, on direct comms' own task:
 * quick, and no LVGL. */
typedef void (*direct_voice_cb_t)(uint32_t sender, uint16_t seq, uint8_t flags, const uint8_t *opus, size_t len,
                                  void *user_data);
void direct_set_voice_cb(direct_voice_cb_t cb, void *user_data);

/* Boards heard lately, strongest first. From any task. */
typedef struct
{
    uint32_t id;
    char name[DIRECT_NAME_MAX];
    int8_t rssi;            // dBm
    bool talking;
} direct_peer_t;
int direct_peers(direct_peer_t *out, int max);

/* The group this board's in: its id (the first 4 bytes of its key's
 * SHA-256). */
void direct_group_id(uint8_t out[4]);

/* Groups heard about over the air, from their beacons, the board's own
 * included if others in it are about. From any task. */
typedef struct
{
    uint8_t id[4];
    char name[DIRECT_NAME_MAX];
    int8_t rssi;            // the strongest lately, dBm
    int boards;             // how many boards are in it
} direct_group_t;
int direct_groups(direct_group_t *out, int max);

#endif
