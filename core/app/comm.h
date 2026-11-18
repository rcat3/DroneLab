#ifndef RCAT_COMM_H
#define RCAT_COMM_H

/*
 * The comm channel: the board sends the wearer's voice, after the voice
 * effect, to a phone over Bluetooth LE, and the phone passes it on to the
 * group (a Mumble server). The board only sends while the wearer talks: while
 * push to talk is held, or, in voice mode, while it hears them speak.
 *
 * The board is a Bluetooth peripheral the phone connects to, advertising
 * COMM_SERVICE_UUID under the phone remote's name (DroneLab- and four
 * letters). The service has two characteristics:
 *
 *   COMM_TO_PHONE_UUID (notify): messages from the board
 *     0x01 sound:  01, seq (2 bytes), flags, then one Opus packet: 20 ms of
 *                  mono at 16 kHz. seq counts packets, little endian, and
 *                  wraps. flags bit 0 marks the first packet of a
 *                  transmission, bit 1 the last; the last one has no Opus
 *                  data, and only says it's over.
 *     0x02 status: 02, version (COMM_VERSION), mode (comm_mode_t), flags
 *                  (bit 0 sending, bit 1 voice heard, bit 2 the talk button
 *                  is connected, see talk_button.h; bit 3 recording), when the phone turns
 *                  notifications on, when any of it changes, and every few
 *                  seconds.
 *
 *   COMM_FROM_PHONE_UUID (write): messages from the phone
 *     0x01 talk:   01, then 1 to talk or 0 to stop (push to talk from the
 *                  phone, or a button paired with it)
 *     0x02 mode:   02, then a comm_mode_t
 *     0x0A record: 0A, 1 to start recording or 0 to stop, flags (bit 0 the
 *                  speaker's voice effect rather than the comm voice, bit 1
 *                  a sync beep to start). While it records, the board sends
 *                  what it hears, the whole time, as 0x0A below, at a higher
 *                  bitrate, and nothing else: no talking, to the server or
 *                  direct, and nothing heard directly passed on. It stops if
 *                  the phone goes. With the beep, the speaker beeps, and the
 *                  same beep's in the recording, as the Voice Lab's.
 *     0x04 server: 04, flags (bit 0 connected to the server, bit 1
 *                  connecting, bit 2 the voice is going over UDP), how many
 *                  others are in the channel, the wearer's own avatar's slot
 *                  (COMM_AVATAR_NONE for none), then the channel's name, in
 *                  UTF-8. When any of it changes, and when the board's
 *                  status first comes.
 *     0x05 hearing: 05, then for each of those talking on the channel, in
 *                  the order they started: their avatar's slot, how they're
 *                  heard (comm_transport_t: the server or direct), and their
 *                  name, in UTF-8, ending in a newline. The app cuts them
 *                  down to fit, and ends with a "+3" (slot COMM_AVATAR_NONE)
 *                  for three more that didn't. Just 05 when nobody is. When
 *                  it changes, as above.
 *     0x06 avatar: 06, slot (below COMM_AVATAR_SLOTS), flags (bit 0 the
 *                  first piece, bit 1 the last, bit 2 asks for an ack), then
 *                  a piece of the picture: comm_avatar_size() pixels square,
 *                  RGB565, little endian, a row at a time from the top. The
 *                  pieces of a picture come in order; a first piece starts
 *                  the slot afresh. The phone sends them without waiting
 *                  for a response, a few at a time, waiting for the ack of
 *                  the last of each few, so as not to overrun the board.
 *     0x0B command: 0B, flags (bit 0 from the server), then a command for
 *                  the others (see others.h). From the server: who it's from,
 *                  their name's length (1) then their name, in UTF-8, then
 *                  the command, for this board's devices. Otherwise it's
 *                  the wearer's, to send over direct comms: how many boards
 *                  it's for (1, 0 for all of them), their ids (4 bytes each,
 *                  little endian, as 0x08's), then the command.
 *   Messages from the phone are at most RCAT_HAL_BLE_PEER_MSG_MAX bytes (244),
 *   and no more than the MTU allows; before COMM_VERSION 3, 64.
 *
 *   COMM_TO_PHONE_UUID, as well:
 *     0x06 avatar ack: 06, slot, flags (bit 0 the picture's all there, bit
 *                  1 it's the right size), then how many bytes have come,
 *                  32 bits little endian. For each piece that asks, and for
 *                  the last.
 *     0x0A recorded sound: as 0x01 sound, while recording, at 48 kb/s.
 *     0x07 direct sound: 07, the sender's id (32 bits, little endian), seq
 *                  (16), flags, then the Opus packet: another board's voice,
 *                  heard over direct comms (see direct.h), as 0x01's.
 *     0x08 direct peer: 08, a board's id (32), how strong it's heard (dBm,
 *                  signed), flags (bit 0 talking, bit 1 versions follow),
 *                  then, with bit 1, its firmware's version's length (1) and
 *                  the version, and its phone's app's (0 long for none), then
 *                  its name: each board heard over direct comms, every couple
 *                  of seconds.
 *     0x0C message: 0C, flags (bit 0 heard over direct comms, bit 1 for the
 *                  app only, not shown on the display), the sender's name's
 *                  length (1, 0 if they didn't say who it's from) and the
 *                  name, then the text, in UTF-8: a message for the
 *                  Terminal from someone the wearer's allowed (others.h),
 *                  for the app's Terminal.
 *     0x09 direct group: 09, a group's id (4 bytes), how strong it's heard
 *                  (dBm, signed), how many boards are in it, its channel,
 *                  flags (bit 0 Long Range), then its name:
 *                  each group heard about over direct comms, from their
 *                  beacons, every couple of seconds.
 *
 *   Both ways: the phone remote's requests (see remote.h), so the app can
 *   show the remote's page without joining the board's hotspot
 *     0x03 request: 03, id, flags (bit 0 the first piece, bit 1 the last),
 *                  then a piece of "METHOD /api/...\n" and the body. Pieces
 *                  of one request share an id; a new one drops the last.
 *     0x03 answer: 03, the request's id, flags as above, then a piece of
 *                  "200\n" and the JSON, "304\n" for a GET /api/state that's
 *                  the same as the last one sent, or "404\n".
 *   GET /version?app=<the app's version>&os=<Android or iPhone> tells the
 *   board the app's version and what it runs on (see comm_app_version and
 *   comm_app_os), and answers {"firmware": rcat_hal_firmware_version,
 *   "built": rcat_hal_firmware_built, "comm": COMM_VERSION, "avatar": the
 *   avatars' size in pixels, 0 if it doesn't show them, "avatars":
 *   COMM_AVATAR_SLOTS}.
 *   GET /remote.html?h=<hash> answers with the page itself (remote_page.html),
 *   so the app shows the board's own version, or "304\n" if <hash>, eight
 *   hex digits of the page's 32-bit FNV-1a hash, says the app has it already.
 *
 * The link has to be paired, with the 6-digit code the board shows, before
 * any of it goes through (see rcat_hal_ble_peer_passkey in hal.h).
 *
 * The phone should ask for an MTU of 185 or more: the Opus packets are cut
 * down to fit, and with the smallest MTU there's only room for a poor 6 kb/s.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define COMM_SERVICE_UUID       "efe06e1b-a7ff-4823-bfbb-b3a82ea05849"
#define COMM_TO_PHONE_UUID      "efe06e1c-a7ff-4823-bfbb-b3a82ea05849"
#define COMM_FROM_PHONE_UUID    "efe06e1d-a7ff-4823-bfbb-b3a82ea05849"
/* The version of the messages here, in the status message, for the app to
 * tell what the board can do. Goes up by one with each change.
 *   1  sound, status, talk and mode
 *   2  the phone remote's requests (0x03), GET /version, and pairing with a
 *      code; the status's bit 2, the talk button
 *   3  server (0x04), hearing (0x05) and avatars (0x06), from the phone, in
 *      messages up to 244 bytes; direct comms (0x07 to 0x09); recording
 *      (0x0A)
 *   4  commands for the others (0x0B)
 *   5  direct peers' firmware and app versions (0x08's bit 1)
 *   6  messages for the Terminal passed on to the app (0x0C), and messages
 *      for the app only (others.h) */
#define COMM_VERSION            6

/* Who's heard at once, at most, and the longest name kept, in bytes. */
#define COMM_HEARING_MAX        4
#define COMM_NAME_MAX           24

/* Avatars: pictures of those on the channel, sent by the phone. */
#define COMM_AVATAR_SLOTS       16
#define COMM_AVATAR_NONE        0xFF

typedef enum
{
    COMM_SERVER_UNKNOWN,        // no phone, or an app from before COMM_VERSION 3
    COMM_SERVER_OFF,
    COMM_SERVER_CONNECTING,
    COMM_SERVER_CONNECTED,
} comm_server_t;

typedef enum
{
    COMM_PUSH_TO_TALK,
    COMM_VOICE,         // talks whenever it hears the wearer speak
    COMM_MODE_COUNT,
} comm_mode_t;

/* Set up the Bluetooth service, and start the channel if it was on when the
 * board was last switched off. Call it once at startup, after LVGL and before
 * anything else uses Bluetooth. */
void comm_init(void);

/* True on boards that can run it: Bluetooth that a phone can connect to, and
 * voice effects. */
bool comm_available(void);

/* Switch it on (the board advertises, for the phone to connect) or off (the
 * phone is dropped). Remembered for the next startup. comm_start() returns
 * false if Bluetooth didn't start. */
bool comm_start(void);
void comm_stop(void);
bool comm_running(void);

comm_mode_t comm_mode(void);
void comm_set_mode(comm_mode_t mode);

/* Where talking goes: to the server, through the phone, or board to board
 * over direct comms (direct.h); never both. It's the one chosen, unless
 * nobody's there to hear it and someone's on the other, decided as each
 * transmission starts. */
typedef enum
{
    COMM_TALK_SERVER,
    COMM_TALK_DIRECT,
    COMM_TALK_COUNT,
} comm_transport_t;
void comm_set_talk_on(comm_transport_t transport);
comm_transport_t comm_talk_on(void);            // as chosen
comm_transport_t comm_talk_now(void);           // where talking would go now, or is going
bool comm_talk_switched(void);                  // comm_talk_now() isn't the one chosen

/* True while the phone's recording (0x0A). */
bool comm_recording(void);

/* The voice effect for what's sent: -1 for the same as the speaker's, else a
 * voice effect preset. Remembered. */
void comm_set_voice_effect(int preset);
int comm_voice_effect(void);

/* Push to talk from the screen, in either mode. */
void comm_set_talk(bool talk);

bool comm_phone_connected(void);

/* Pass a message for the Terminal, from someone allowed, on to the app
 * (0x0C). from is "" if they didn't say who it's from. From the UI loop. */
void comm_message_to_phone(comm_transport_t via, const char *from, bool app_only, const uint8_t *text, size_t len);

/* True while it's sending the voice to the phone. */
bool comm_sending(void);

/* True while the phone has asked it to talk, which carries on, in either
 * mode, until the phone says stop. */
bool comm_phone_talking(void);

/* True while voice mode hears the wearer, whether or not a phone is there to
 * send to. */
bool comm_voice_heard(void);

/* What the phone says about the server (see 0x04 above). From the UI loop. */
comm_server_t comm_server(void);
bool comm_server_udp(void);
int comm_server_others(void);          // others in the channel
const char *comm_server_channel(void);  // its name, or ""

/* Who's talking on the channel, as the phone says (0x05), in the order they
 * started. The last may be "+2" and the like, for more that didn't fit.
 * From the UI loop. */
int comm_hearing_count(void);
const char *comm_hearing_name(int index);
int comm_hearing_avatar(int index);     // its slot, or COMM_AVATAR_NONE
int comm_hearing_transport(int index);  // comm_transport_t: how they're heard

/* Avatars. The UI says how big it shows them, in pixels, before the phone
 * connects; 0, as it starts, means it doesn't, and the phone sends none. */
void comm_set_avatar_size(int px);
int comm_avatar_size(void);
int comm_own_avatar(void);              // the wearer's slot, or COMM_AVATAR_NONE
/* A slot's picture (see 0x06), or NULL if it hasn't all come. */
const uint16_t *comm_avatar(int slot);
/* Goes up by one whenever a picture comes in, for the UI to redraw. */
uint32_t comm_avatar_changes(void);

/* The name it advertises. */
const char *comm_name(void);

/* Let a new phone pair, for COMM_PAIRING_MS, or shut it again. Phones
 * paired already can always connect. comm_pairing_left() is how long it's
 * open for still, 0 when it's shut. */
#define COMM_PAIRING_MS         120000
void comm_allow_pairing(bool allow, uint32_t now_ms);
uint32_t comm_pairing_left(uint32_t now_ms);

/* The connected app's version, as it said, or "" if it hasn't. */
const char *comm_app_version(void);
/* What the app runs on, as it said: "Android" or "iPhone", "" if it didn't
 * say. */
const char *comm_app_os(void);

/* Answer the phone. Call it every 50 ms or so, from the UI loop. */
void comm_poll(uint32_t now_ms);

#endif
