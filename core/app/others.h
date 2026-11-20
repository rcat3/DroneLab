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
 * Everyone is known by their identity key: an Ed25519 key pair their app
 * makes and keeps, which signs each command they send. A board checks the
 * signature of each command heard over direct comms against the key in it;
 * one from the server, the phone has checked already (it knows the server
 * and channel the signature covers), and passes on without its signature.
 * Names are only labels, so nobody can pass as someone else by taking
 * their name.
 *
 * Those who've sent commands are kept in one list of people, by key, each
 * with their name, whether they're allowed for each kind, and the counter
 * of the last command they sent (so a recorded one can't be played back).
 * The Lovense devices and the Terminal each have their permission: Off,
 * nobody (and nobody's added to the list either); Ask, only those the
 * wearer has allowed for that kind; or Accept, anyone. Anyone new who sends
 * one is added to the list, not allowed, for the wearer to tick if they want
 * to, in Ask and Accept both, so the list says who's been sending. Someone
 * new who uses the name of someone already listed is marked (clash): it's
 * someone else using that name. Texts aren't anything to permit: anyone can
 * text anyone, though they're signed too.
 *
 * Each kind can also ignore commands sent to everyone who can hear the
 * sender (broadcasts, and those to the channel over the open direct comms
 * group, which anyone nearby can hear), and those sent to a whole channel,
 * whoever they're from; and commands from anyone the wearer has muted in
 * their app (others_set_muted) are ignored, whatever the permission.
 *
 * Whatever comes is passed on to the wearer's app, with whether it was done,
 * for its conversations (comm_heard_to_phone).
 *
 * A command, the same however it comes:
 *   version (OTHERS_VERSION), the sender's public key (32 bytes), a counter
 *   (6, little endian: the sender's clock in ms, and always more than their
 *   last), who it's for (OTHERS_SCOPE_*: everyone who can hear the sender,
 *   the channel it came on, or this board alone), what to do and its
 *   arguments (at most OTHERS_WHAT_MAX bytes), then the Ed25519 signature
 *   (64) of
 *     "dronelab-command\n", what it's sent in (below), then the command
 *     before the signature.
 *   What it's sent in is part of what's signed, though it isn't sent, so a
 *   command can't be taken from where it was sent and played somewhere
 *   else: 'E' for everyone; to a channel, 'C' and the direct comms group's
 *   id (4 bytes, direct_group_id), or 'S', the server's certificate's
 *   SHA-256 (32) and the channel's id (4, little endian); to one person,
 *   'O' and their public key (32: the board's wearer's, others_set_owner).
 *   What to do: for the Lovense devices,
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
 *     21 text part: 21, the text's id (2, little endian, the same in each
 *                  of its parts), which part it is (from 0), how many
 *                  parts, then that part of the text, in UTF-8: a text too
 *                  long for one command, which the app puts back together
 * A command that comes more than once, by both ways, or sent again in case
 * one was lost, is only done once: by its sender's key and counter. A
 * command whose counter is no more than the last done from someone listed
 * is a replay, and dropped. Texts (and their parts), which only go to the
 * app, may come out of order, as the copies of a long text's parts are
 * spread out: one is taken if it's no more than OTHERS_TEXT_WINDOW_MS older
 * than that, and hasn't been seen.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "app/comm.h"

#define OTHERS_VERSION          3       // 3: signed, by the sender's identity key
#define OTHERS_KEY_LEN          32
#define OTHERS_SIG_LEN          64
#define OTHERS_ID_LEN           8       // a key's first bytes, as the muted list gives them
#define OTHERS_HEADER_LEN       40      // version, key, counter, who it's for
#define OTHERS_WHAT_MAX         117     // what to do and its arguments, at most
#define OTHERS_CMD_MAX          (OTHERS_HEADER_LEN + OTHERS_WHAT_MAX + OTHERS_SIG_LEN)
#define OTHERS_PEOPLE_MAX       16      // in the list
#define OTHERS_TEXT_WINDOW_MS   10000   // how far a text may come behind (see above)

#define OTHERS_STOP             0x00
#define OTHERS_LEVEL            0x01
#define OTHERS_PATTERN          0x02
#define OTHERS_SPEED            0x03
#define OTHERS_REACT            0x04
#define OTHERS_MESSAGE          0x10
#define OTHERS_ALL_MOTORS       0xFF
#define OTHERS_CLEAR            0x11
#define OTHERS_TEXT             0x20
#define OTHERS_TEXT_PART        0x21
#define OTHERS_CALL             0x30    // a call's signal, for the app: op, call id (4)
#define OTHERS_INVITE           0x31    // an invitation to a direct channel, sealed for the app
#define OTHERS_REACTION         0x32    // a reaction to a message, for the app: its id (8), an emoji
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
    uint8_t key[OTHERS_KEY_LEN];
    char name[COMM_NAME_MAX];
    bool allowed;
    bool clash;             // took the name of someone listed before them took it
} others_sender_t;

/* Set it up, and read the list. Call it once at startup, after LVGL and
 * before direct comms. */
void others_init(void);

/* A command from the server, through the phone (via COMM_TALK_SERVER),
 * checked by the phone and without its signature, from the one named. From
 * the UI loop. */
void others_receive(comm_transport_t via, const char *from, const uint8_t *cmd, size_t len);

/* How a command came over direct comms: the broadcast it came in (the
 * sending board's counter for it, the same in a copy another board passed
 * on), how strong (dBm, from the last board it came from), how many times
 * it was passed on, and its length on the air. Every copy heard is told to
 * the app (comm_copy_to_phone), for a text's details, though it's only done
 * once. */
typedef struct
{
    uint32_t broadcast;
    int8_t rssi;
    uint8_t hops;
    uint8_t len;
} others_radio_t;

/* One heard over direct comms, signed, from its own task: it's queued, to
 * be checked on a task of its own, and done on the UI loop's next
 * others_poll() if it's good. Nothing else may call it. */
void others_queue(const char *from, const uint8_t *cmd, size_t len, const others_radio_t *radio);

/* The wearer's own public key, from their app: commands to this board
 * alone are signed for it. Remembered. */
void others_set_owner(const uint8_t key[OTHERS_KEY_LEN]);

/* The wearer's app's signature, with their key, of "dronelab-board\n" and
 * this board's direct comms id (4 bytes, little endian): that this board's
 * theirs, for the others to check (direct.h's hello). Not kept, as the id's
 * new each time the board starts. */
void others_set_binding(const uint8_t sig[OTHERS_SIG_LEN]);

/* From direct comms' task: check another board's wearer's signature that
 * it's theirs (from its hello), on the task that checks commands, as it
 * takes tens of ms. Returns false if it can't be queued just now: ask
 * again with its next hello. */
bool others_check_board(uint32_t id, const uint8_t key[OTHERS_KEY_LEN], const uint8_t sig[OTHERS_SIG_LEN]);

/* From direct comms' task: a board that's been checked, and whether its
 * signature was good; false if none has since last asked. */
bool others_board_checked(uint32_t *id, uint8_t key[OTHERS_KEY_LEN], bool *good);

/* The wearer's public key, and their signature that this board's theirs:
 * false until their app's given both. From any task: direct comms says them
 * in its hello. */
bool others_owner(uint8_t key[OTHERS_KEY_LEN], uint8_t sig[OTHERS_SIG_LEN]);

/* Who a kind of command is taken from. Remembered. */
typedef enum
{
    OTHERS_OFF,         // nobody
    OTHERS_ASK,         // those allowed for it in the list
    OTHERS_ACCEPT,      // anyone
} others_permission_t;
others_permission_t others_permission(others_kind_t kind);
void others_set_permission(others_kind_t kind, others_permission_t permission);

/* Whether a kind of command is taken at all: its permission isn't Off.
 * Switching it on goes back to Ask. Remembered. */
bool others_accepting(others_kind_t kind);
void others_set_accepting(others_kind_t kind, bool on);

/* What a kind ignores, whoever it's from: OTHERS_IGNORE_* together. */
#define OTHERS_IGNORE_EVERYONE  0x02    // broadcasts, and the open direct group's channel
#define OTHERS_IGNORE_CHANNEL   0x04    // those to a whole channel
uint8_t others_ignoring(others_kind_t kind);
void others_set_ignoring(others_kind_t kind, uint8_t ignore);

/* Those the wearer's muted in their app, whose commands are ignored: the
 * first OTHERS_ID_LEN bytes of each one's key, one after another, [len]
 * bytes in all; [first] starts the list afresh, otherwise they're added to
 * it. Kept until the board restarts, as the app sends them each time it
 * connects. */
void others_set_muted(bool first, const uint8_t *ids, size_t len);

/* Those who've sent a kind of command, or are allowed for it, oldest
 * first. Returns how many there are. */
int others_senders(others_kind_t kind, others_sender_t *out, int max);

/* Allow someone for a kind, or not, or forget them for it, by their key.
 * Remembered. */
void others_allow(others_kind_t kind, const uint8_t key[OTHERS_KEY_LEN], bool allow);
void others_forget(others_kind_t kind, const uint8_t key[OTHERS_KEY_LEN]);

/* Who sent the last command of a kind that was done, and how long ago, in
 * ms; NULL if none has been. */
const char *others_last(others_kind_t kind, uint32_t now_ms, uint32_t *age_ms);

/* Goes up whenever any of the above changes, for screens to redraw. */
uint32_t others_changes(void);

/* Check and do what's queued, and save the list once it's settled. Call it
 * every 50 ms or so, from the UI loop. */
void others_poll(uint32_t now_ms);

#endif
