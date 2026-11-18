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
 *   header (sent as it is, and all but the hops checked):
 *     'D', DIRECT_VERSION, the group's id (4 bytes: the first of the key's
 *     SHA-256), the sender's id (4, random each time it starts), a counter
 *     (4, little endian, goes up with every broadcast), hops left (1: how
 *     many more times it may be passed on)
 *   then, encrypted with AES-128-GCM, the nonce being the sender's id,
 *   counter and the group's id:
 *     voice: 01, seq (2, little endian), flags (bit 0 first, bit 1 last),
 *            the Opus packet's length (1), then the Opus packet: as the comm
 *            channel's sound (comm.h); then, but for the first, up to two
 *            packets before it again, newest first, each its length (1) then
 *            it, so two lost in a row come back from the next
 *     hello: 02, flags (bit 0 talking, bit 1 asks for pieces of an avatar),
 *            if it asks: whose (the sender's id, 4), its version (1), and
 *            which pieces (16 bytes, a bit each, from bit 0 of the first);
 *            then its firmware's version's length (1) and the version
 *            (rcat_hal_firmware_version), then the length (1) and version
 *            of the app on the phone linked to it, after what the phone is
 *            ("Android 1.2.0", from comm_app_os and comm_app_version; 0 long
 *            with none), each UTF-8 and at most DIRECT_VERSION_MAX - 1
 *            bytes; then the board's name, in UTF-8. Every couple of
 *            seconds, and
 *            as it starts. A board asked for pieces of its avatar sends
 *            them, between its other broadcasts
 *     avatar: 03, its version (1, never 0), the piece (1), how many pieces
 *            (1), then 100 of the pixels of the wearer's avatar
 *            (DIRECT_AVATAR_PX square), RGB565, little endian. The pixels go
 *            every 8th each way first, then every 4th, every 2nd and the
 *            rest, so that what's come shows all of it, coarse at first.
 *            All of it soon after a new board's heard and every few
 *            minutes, and the coarsest two layers every half minute; a
 *            piece at a time, and never while talking
 *     command: 04, how many boards it's for (1, 0 for every board in the
 *            group), their ids (4 bytes each), then a command for the
 *            others (see others.h). Sent three times, 100 ms apart, as nothing
 *            says it came; the command says which it is, so it's only done
 *            once
 *   then an 8-byte tag.
 * A board ignores the group's broadcasts from a sender whose counter hasn't
 * gone up, so a recorded one can't be played back.
 *
 * Relaying: a board that hears one of its group's broadcasts weakly, as if
 * from far off, passes it on, as it is but for one hop fewer, after a short,
 * random wait, unless it hears another board pass it on first. So boards
 * just out of each other's range still hear each other, through one in
 * between, without everyone repeating everything.
 *
 * And, from boards in a group with a key, every couple of seconds, not
 * encrypted, so that boards outside it can see it's there and ask to join:
 *   beacon: 'G', DIRECT_VERSION, the group's id (4), the sender's id (4),
 *           its channel (1), flags (1: bit 0 Long Range), then the group's
 *           name.
 * A board only hears what's on its own channel; direct_scan() listens on
 * each of them in turn, to hear the groups on the others.
 * Joining takes the group's passphrase: the app makes the key from the name
 * and passphrase (direct_key), and checks it gives the group's id before
 * using it. It's slow to make on purpose, so that guessing passphrases
 * against an id heard over the air is slow too.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define DIRECT_VERSION          7       // 7: the hello has the firmware's and app's versions
#define DIRECT_KEY_LEN          16
#define DIRECT_NAME_MAX         16      // with its terminating zero
#define DIRECT_VERSION_MAX      32      // a firmware or app version, with its terminating zero
#define DIRECT_PEERS_MAX        12
#define DIRECT_GROUPS_MAX       8
#define DIRECT_KEY_ROUNDS       20000   // PBKDF2's, for direct_key
#define DIRECT_AVATAR_PX        112     // the avatars sent over the air
#define DIRECT_COMMAND_TARGETS  DIRECT_PEERS_MAX    // boards a command's for, at most
#define DIRECT_CHANNEL_DEFAULT  6       // and the open group's

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

/* The group: its key (NULL for the open group), its name to show, this
 * board's name in it ("" for the board's own, comm_name()), and its radio:
 * channel 1, 6 or 11, and Long Range (rcat_hal_direct_set_radio). The open
 * group's always on DIRECT_CHANNEL_DEFAULT, in Long Range. Remembered. */
void direct_set_group(const uint8_t *key, const char *group, const char *name, uint8_t channel, bool long_range);
uint8_t direct_channel(void);
bool direct_long_range(void);

/* Listen on each channel in turn, a couple of seconds each, to hear about
 * the groups on the others (direct_groups); what's on this board's own
 * channel is missed meanwhile. Not while the hotspot's on. */
void direct_scan(void);
bool direct_scanning(void);

/* The wearer's avatar, to send to the others: pixels px square, RGB565,
 * scaled to DIRECT_AVATAR_PX. NULL for none. From the UI loop. */
void direct_set_avatar(const uint16_t *pixels, int px);

/* A board's avatar, by the name it goes by: DIRECT_AVATAR_PX square, as much
 * as has come, the rest filled in from what has; or NULL if none has.
 * *version changes as more comes. */
const uint16_t *direct_avatar(const char *name, uint8_t *version);
const char *direct_group_name(void);    // "Open" for the open group
const char *direct_own_name(void);

/* A group's key, from its name and passphrase: PBKDF2-HMAC-SHA256, the
 * salt "dronelab-direct\n" and the name, DIRECT_KEY_ROUNDS rounds, 16 bytes.
 * The app makes it the same way. Slow: a second or so. */
void direct_key(const char *group, const char *passphrase, uint8_t key[DIRECT_KEY_LEN]);

/* Broadcast one packet of the wearer's voice. From any one task. */
void direct_send_voice(uint16_t seq, uint8_t flags, const uint8_t *opus, size_t len);

/* Send a command for others (others.h) to the boards with these ids
 * (direct_peer_t's), or, with count 0, to every board in the group. From the
 * UI loop. Returns false if it can't go: not running, or a few are waiting
 * to go already. */
bool direct_send_command(const uint32_t *targets, int count, const uint8_t *cmd, size_t len);

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
    char firmware[DIRECT_VERSION_MAX];      // its version, "" until its hello
    char app[DIRECT_VERSION_MAX];           // its phone's app's, "" for none
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
    uint8_t channel;
    bool long_range;
} direct_group_t;
int direct_groups(direct_group_t *out, int max);

#endif
