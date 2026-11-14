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
 *                  (bit 0 sending, bit 1 voice heard), when the phone turns
 *                  notifications on, when any of it changes, and every few
 *                  seconds.
 *
 *   COMM_FROM_PHONE_UUID (write): messages from the phone
 *     0x01 talk:   01, then 1 to talk or 0 to stop (push to talk from the
 *                  phone, or a button paired with it)
 *     0x02 mode:   02, then a comm_mode_t
 *
 * The phone should ask for an MTU of 185 or more: the Opus packets are cut
 * down to fit, and with the smallest MTU there's only room for a poor 6 kb/s.
 */

#include <stdbool.h>
#include <stdint.h>

#define COMM_SERVICE_UUID       "efe06e1b-a7ff-4823-bfbb-b3a82ea05849"
#define COMM_TO_PHONE_UUID      "efe06e1c-a7ff-4823-bfbb-b3a82ea05849"
#define COMM_FROM_PHONE_UUID    "efe06e1d-a7ff-4823-bfbb-b3a82ea05849"
#define COMM_VERSION            1

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

/* Push to talk from the screen, in either mode. */
void comm_set_talk(bool talk);

bool comm_phone_connected(void);

/* True while it's sending the voice to the phone. */
bool comm_sending(void);

/* True while voice mode hears the wearer, whether or not a phone is there to
 * send to. */
bool comm_voice_heard(void);

/* The name it advertises. */
const char *comm_name(void);

/* Answer the phone. Call it every 50 ms or so, from the UI loop. */
void comm_poll(uint32_t now_ms);

#endif
