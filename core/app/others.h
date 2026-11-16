#ifndef RCAT_OTHERS_H
#define RCAT_OTHERS_H

/*
 * Commands from others in the comm channel: someone in the group sends them
 * from the DroneLab app, to everyone or to the people they pick, and they
 * come in over the server (the phone passes them on, see comm.h) or over
 * direct comms (see direct.h). There are two kinds: for the Lovense devices,
 * which they set as the Lovense feature's own controls do, and stay set
 * until they're changed or Stop's touched; and messages, for the Terminal.
 *
 * Each kind has its own list of who may send it, and only those the wearer
 * has allowed are obeyed. Anyone new who sends one is added to that kind's
 * list, not allowed, for the wearer to tick if they want to. Accepting a
 * kind can be switched off altogether, and then nobody's added either.
 * Someone's known by their name and how they're heard (server or direct), so
 * the same person can be in a list twice. Names can be borrowed: in a
 * direct comms group with a passphrase, only its members can send at all,
 * but in the open group, or on a server anyone can join, anyone could use a
 * name that's allowed.
 *
 * A command, the same however it comes:
 *   version (OTHERS_VERSION), the sender's id (4 bytes, little endian, made
 *   up each time their app starts), seq (2, little endian, goes up with each
 *   command), then what to do. For the Lovense devices:
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
 *   For the Terminal:
 *     10 message:  10, flags (bit 0 named), then the text, in UTF-8: added
 *                  to the Terminal, on a line of its own, after the sender's
 *                  name if it's named, and the Terminal's brought on screen.
 *                  Unnamed ones are still only taken from those allowed, but
 *                  the wearer can choose not to have them shown at all
 * A command that comes more than once, by both ways, or sent again in case
 * one was lost, is only done once: by its sender's id and seq.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "app/comm.h"

#define OTHERS_VERSION          1
#define OTHERS_SENDERS_MAX      12      // in each kind's list
#define OTHERS_CMD_MAX          136     // the longest command, with a message

#define OTHERS_STOP             0x00
#define OTHERS_LEVEL            0x01
#define OTHERS_PATTERN          0x02
#define OTHERS_SPEED            0x03
#define OTHERS_REACT            0x04
#define OTHERS_MESSAGE          0x10
#define OTHERS_ALL_MOTORS       0xFF
#define OTHERS_NAMED            0x01    // a message's flags: shown with who it's from

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

/* Whether a kind of command is taken at all. Remembered. */
bool others_accepting(others_kind_t kind);
void others_set_accepting(others_kind_t kind, bool on);

/* Those who've sent a kind of command, oldest first. Returns how many there
 * are. */
int others_senders(others_kind_t kind, others_sender_t *out, int max);

/* Allow one of them, or not, or forget them. Remembered. */
void others_allow(others_kind_t kind, comm_transport_t via, const char *name, bool allow);
void others_forget(others_kind_t kind, comm_transport_t via, const char *name);

/* Whether messages for the Terminal that don't say who they're from are
 * shown (they are, to start with). Remembered. */
bool others_unnamed_shown(void);
void others_set_unnamed_shown(bool show);

/* Who sent the last command of a kind that was done, and how long ago, in
 * ms; NULL if none has been. */
const char *others_last(others_kind_t kind, uint32_t now_ms, uint32_t *age_ms);

/* Goes up whenever any of the above changes, for screens to redraw. */
uint32_t others_changes(void);

/* Do what's queued, and save the lists once they've settled. Call it every
 * 50 ms or so, from the UI loop. */
void others_poll(uint32_t now_ms);

#endif
