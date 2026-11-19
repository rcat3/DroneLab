#ifndef RCAT_OTHERS_H
#define RCAT_OTHERS_H

/*
 * Commands from others in the comm channel: someone in the group sends them
 * from the DroneLab app, to everyone who can hear them, to a channel, or to
 * one person, and they come in over the server (the phone passes them on,
 * see comm.h) or over direct comms (see direct.h). There are three kinds:
 * for the Lovense devices, which they set as the Lovense feature's own
 * controls do, and stay set until they're changed or Stop's touched; for the
 * Terminal, on the display; and texts, for the wearer's app only.
 *
 * The Lovense devices and the Terminal each have their own list of who may
 * send them commands, and their permission: Off, nobody (and nobody's added
 * to the list either); Ask, only those the wearer has allowed in the list;
 * or Accept, anyone. Anyone new who sends one is added to that kind's list,
 * not allowed, for the wearer to tick if they want to, in Ask and Accept
 * both, so the list says who's been sending. Someone's known by their name
 * and how they're heard (server or direct), so the same person can be in a
 * list twice. Names can be borrowed: in a direct comms group with a
 * passphrase, only its members can send at all, but in the open group, or on
 * a server anyone can join, anyone could use a name that's allowed. Texts
 * aren't anything to permit: anyone can text anyone.
 *
 * Whatever comes is passed on to the wearer's app, with whether it was done,
 * for its conversations (comm_heard_to_phone).
 *
 * A command, the same however it comes:
 *   version (OTHERS_VERSION), the sender's id (4 bytes, little endian, made
 *   up each time their app starts), seq (2, little endian, goes up with each
 *   command), who it's for (OTHERS_SCOPE_*: everyone who can hear the sender,
 *   the channel it came on, or this board alone), then what to do. For the
 *   Lovense devices:
 *     00 stop:     stop everything, as the Stop button, reactions too
 *     01 level:    01, the kind of motor (lovense_motor_kind_t, or 0xFF for
 *                  all of them), the level (0 to 20, scaled to each motor's
 *                  own range)
 *     02 pattern:  02, then the pattern's name, in UTF-8: played on every
 *                  device, if this board has one by that name; no name stops
 *                  the patterns
 *     03 speed:    03, how fast patterns play, in percent (2 bytes, little
 *                  endian, 25 to 300)
 *     04 react:    04, the reaction (reactive_mode_t, 0 for none): to this
 *                  board's wearer, if it can sense it
 *   For the Terminal, as its own controls (and the remote's) do:
 *     10 message:  10, flags (bit 0 add it on a line of its own after
 *                  what's there, rather than replace it; bit 1 bring the
 *                  Terminal on screen), the letter size (0 for Auto, 1 to 6
 *                  for 8 to 48 px), then the text, in UTF-8, as it is: no
 *                  name's added
 *     11 clear:    11: empty the Terminal
 *   For the wearer's app:
 *     20 text:     20, then the text, in UTF-8: a text, only passed on to
 *                  the app, whoever it's from
 * A command that comes more than once, by both ways, or sent again in case
 * one was lost, is only done once: by its sender's id and seq.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "app/comm.h"

#define OTHERS_VERSION          2       // 2: who it's for, the Terminal's own controls, and texts
#define OTHERS_SENDERS_MAX      12      // in each kind's list
#define OTHERS_CMD_MAX          136     // the longest command, with a message

#define OTHERS_STOP             0x00
#define OTHERS_LEVEL            0x01
#define OTHERS_PATTERN          0x02
#define OTHERS_SPEED            0x03
#define OTHERS_REACT            0x04
#define OTHERS_MESSAGE          0x10
#define OTHERS_ALL_MOTORS       0xFF
#define OTHERS_CLEAR            0x11
#define OTHERS_TEXT             0x20
#define OTHERS_MESSAGE_APPEND   0x01    // a message's flags: on a line of its own after what's there
#define OTHERS_MESSAGE_SHOW     0x02    // and bring the Terminal on screen

/* Who a command's for, as its sender put it */
#define OTHERS_SCOPE_EVERYONE   0       // everyone who can hear the sender, by any means
#define OTHERS_SCOPE_CHANNEL    1       // the channel it came on, server or direct
#define OTHERS_SCOPE_ONE        2       // this board alone

typedef enum
{
    OTHERS_LOVENSE,
    OTHERS_TERMINAL,
    OTHERS_KIND_COUNT,
} others_kind_t;

typedef struct
{
    char name[COMM_NAME_MAX];
    comm_transport_t via;
    bool allowed;
} others_sender_t;

/* Set it up, and read the lists. Call it once at startup, after LVGL and
 * before direct comms. */
void others_init(void);

/* A command, from the server through the phone (via COMM_TALK_SERVER) or
 * over direct comms (COMM_TALK_DIRECT), from the one named. From the UI
 * loop. */
void others_receive(comm_transport_t via, const char *from, const uint8_t *cmd, size_t len);

/* The same, from direct comms' own task: it's queued, for the UI loop to do
 * on its next others_poll(). Nothing else may call it. */
void others_queue(const char *from, const uint8_t *cmd, size_t len);

/* Who a kind of command is taken from. Remembered. */
typedef enum
{
    OTHERS_OFF,         // nobody
    OTHERS_ASK,         // those allowed in its list
    OTHERS_ACCEPT,      // anyone
} others_permission_t;
others_permission_t others_permission(others_kind_t kind);
void others_set_permission(others_kind_t kind, others_permission_t permission);

/* Whether a kind of command is taken at all: its permission isn't Off.
 * Switching it on goes back to Ask. Remembered. */
bool others_accepting(others_kind_t kind);
void others_set_accepting(others_kind_t kind, bool on);

/* Those who've sent a kind of command, oldest first. Returns how many there
 * are. */
int others_senders(others_kind_t kind, others_sender_t *out, int max);

/* Allow one of them, or not, or forget them. Remembered. */
void others_allow(others_kind_t kind, comm_transport_t via, const char *name, bool allow);
void others_forget(others_kind_t kind, comm_transport_t via, const char *name);

/* Who sent the last command of a kind that was done, and how long ago, in
 * ms; NULL if none has been. */
const char *others_last(others_kind_t kind, uint32_t now_ms, uint32_t *age_ms);

/* Goes up whenever any of the above changes, for screens to redraw. */
uint32_t others_changes(void);

/* Do what's queued, and save the lists once they've settled. Call it every
 * 50 ms or so, from the UI loop. */
void others_poll(uint32_t now_ms);

#endif
