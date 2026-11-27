#ifndef RCAT_OTHERS_H
#define RCAT_OTHERS_H

/*
 * Commands from others in the comm channel: someone in the group sends them
 * from the DroneLab app, to everyone who can hear them, to a channel, or to
 * one person, and they come in over the server (the phone passes them on,
 * see comm.h) or over direct comms (see direct.h). They're HiveMind
 * Control's, by area: the Toys, Vibe toys for now (toys.h), which they set
 * by channel as the Toys feature's own controls do, and stay set until
 * they're changed or Stop's touched; the Display unit's screen, words on its
 * Terminal and pictures; its speaker, sounds (sounds.h);
 * and besides those, texts and the like, for the wearer's app only.
 *
 * Everyone is known by their identity key: an Ed25519 key pair their app
 * makes and keeps, which signs each command they send. A board checks the
 * signature of each command heard over direct comms against the key in it;
 * one from the server, the phone has checked already (it knows the server
 * and channel the signature covers), and passes on without its signature.
 * Names are only labels, so nobody can pass as someone else by taking
 * their name.
 *
 * Who may send what is the wearer's rules (rules.h), which their app owns
 * and gives this unit: each kind (others_kind_t) is a class there, with its
 * own policy: Off, nobody; Ask, only those the wearer has allowed for it
 * (their app asks them about anyone else who tries); or Anyone. Each kind
 * can also ignore commands sent to everyone who can hear the sender
 * (broadcasts, and those to the channel over the open direct comms group,
 * which anyone nearby can hear), and those sent to a whole channel, whoever
 * they're from; and commands from anyone the wearer has muted are ignored,
 * whatever the policy. Texts aren't anything to permit: anyone can text
 * anyone, though they're signed too.
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
 *   What to do, by its first byte: 0x10 to 0x1F for the Display unit, 0x20
 *   to 0x3F for the app, then 0x40 to 0x4F for Vibe toys, 0x50 to 0x5F
 *   E-stim and 0x60 to 0x6F Machines (those two to come). Channels are a
 *   byte with a bit for each, V1 the lowest (toys.h). For Vibe toys:
 *     40 stop:     stop every channel, as the Stop button, reactions too
 *     41 set:      41, the channels, a level for each of them, the
 *                  lowest first (0 to 20, scaled to each output's own
 *                  range), how fast their pattern plays, in
 *                  percent (2 bytes, little endian, 25 to 300), the
 *                  reaction (reactive_mode_t, 0 for none: to this board's
 *                  wearer, if it can sense it), the pattern's kind
 *                  (OTHERS_PATTERN_*), then the pattern: for a built-in one,
 *                  its name, in UTF-8; for a custom one, its hash
 *                  (patterns.h). The channels, as a whole, together: see
 *                  toys_set(). A channel already playing the pattern keeps
 *                  its place in it. One this board hasn't got, they hold
 *                  at 0 for, till it comes.
 *     45 pattern part: 45, a custom pattern's hash, which part it is
 *                  (from 0), how many parts (up to 6), then that part of
 *                  its definition (patterns.h), PATTERNS_PART_MAX bytes in
 *                  each but the last. Its sender sends them before the
 *                  set that plays it, and again now and then while it
 *                  plays, for anyone who missed them; once they're all
 *                  here, and come to the hash, it's kept, and the channels
 *                  waiting for it start it. They're taken from whoever's
 *                  allowed Vibe toys.
 *   For the Display unit, words on its Terminal (as its own controls, and
 *   the remote's, put them) and pictures, each brought on screen, and kept
 *   there for a while, or until the wearer moves on: see ui_show_for():
 *     10 message:  10, flags (bit 0 add it on a line of its own after
 *                  what's there, rather than replace it), the letter size
 *                  (0 for Auto, 1 to 6 for 8 to 48 px), how long it stays
 *                  on screen (2, little endian, in seconds, 0 until the
 *                  wearer moves on), then the text, in UTF-8, as it is: no
 *                  name's added
 *     11 clear:    11: empty the Terminal, and go back to what was on
 *                  screen before the last of these, if it's still showing
 *     12 picture:  12, how long it stays on screen (2, as a message's),
 *                  where it's from (OTHERS_PICTURE_*), then for one sent,
 *                  its SHA-256 (32): the picture itself comes to this board
 *                  from its phone (comm.h 0x1A), which has it from the
 *                  server, and the command waits up to
 *                  PICTURES_WAIT_MS for it (pictures.h); for one built into
 *                  the firmware, its name (image_list.c), in UTF-8, which
 *                  every board has, so it works over direct comms too
 *   For the Display unit's speaker:
 *     13 sound:    13, visualizer (1), its SHA-256 (32): played once, as it comes, and kept
 *                  (sounds.h). The visualizer is 0 for none, or 1 and up
 *                  for a Sound Visualizer style (its list order, from 1),
 *                  shown on the screen while the sound plays. The sound
 *                  itself comes to this board from
 *                  its phone (comm.h 0x1B), which has it from the server,
 *                  and the command waits up to SOUNDS_WAIT_MS for it. Over
 *                  the server only: one heard over direct comms is dropped
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
 * app, and patterns' parts, may come out of order, as the copies of many
 * parts are spread out: one is taken if it's no more than
 * OTHERS_TEXT_WINDOW_MS older than that, and hasn't been seen.
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
#define OTHERS_SENDERS_KEPT     32      // senders whose last counter is kept
#define OTHERS_TEXT_WINDOW_MS   10000   // how far a text may come behind (see above)

#define OTHERS_MESSAGE          0x10    // the Display unit
#define OTHERS_CLEAR            0x11
#define OTHERS_PICTURE          0x12
#define OTHERS_SOUND            0x13
#define OTHERS_TEXT             0x20
#define OTHERS_TEXT_PART        0x21
#define OTHERS_CALL             0x30    // a call's signal, for the app: op, call id (4)
#define OTHERS_INVITE           0x31    // an invitation to a direct channel, sealed for the app
#define OTHERS_REACTION         0x32    // a reaction to a message, for the app: its id (8), an emoji
#define OTHERS_VIBE_STOP        0x40    // Vibe toys
#define OTHERS_VIBE_SET         0x41
#define OTHERS_VIBE_PART        0x45
#define OTHERS_PATTERN_NONE     0       // a set's pattern's kind: none, a steady level
#define OTHERS_PATTERN_BUILT_IN 1       // by its name
#define OTHERS_PATTERN_CUSTOM   2       // by its hash
#define OTHERS_MESSAGE_APPEND   0x01    // a message's flags: on a line of its own after what's there
#define OTHERS_PICTURE_SENT     0       // a picture's from: sent, by its SHA-256
#define OTHERS_PICTURE_BUILT_IN 1       // built into the firmware, by its name

/* Who a command's for, as its sender put it */
#define OTHERS_SCOPE_EVERYONE   0       // everyone who can hear the sender, by any means
#define OTHERS_SCOPE_CHANNEL    1       // the channel it came on, server or direct
#define OTHERS_SCOPE_ONE        2       // this board alone

/* What can be controlled here, each a class in the rules (others_class).
 * E-stim and Machines are to come. */
typedef enum
{
    OTHERS_VIBE,            // Vibe toys
    OTHERS_DISPLAY,         // the Display unit's screen: words on its Terminal, and pictures
    OTHERS_SOUNDS,          // the Display unit's speaker: sounds
    OTHERS_KIND_COUNT,
} others_kind_t;

/* Set it up. Call it once at startup, after LVGL and the rules, and
 * before direct comms. */
void others_init(void);

/* A command from the server, through the phone (via COMM_TALK_SERVER),
 * checked by the phone and without its signature, from the one named. From
 * the UI loop. */
void others_receive(comm_transport_t via, const char *from, const uint8_t *cmd, size_t len);

/* What the wearer sends others' Vibe toys, for their own to follow along,
 * from their app: what to do on, as a command's, with nothing before it. As
 * it's theirs, the rules don't come into it, and nobody's told. Vibe
 * commands only. From the UI loop. */
void others_run_own(const uint8_t *what, size_t len);

/* A lease on the toys, from the wearer's app, for as long as it's kept up:
 * every Vibe toy stops if [seconds] go by without it being given again, as
 * they do if the phone or the link to it is lost. 0 ends it, with the toys
 * as they are. From the UI loop. */
void others_lease(uint32_t seconds);

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

/* A kind's class in the rules (RULES_CLASS_*). */
uint8_t others_class(others_kind_t kind);

/* Who a kind of command is taken from, by the rules. */
typedef enum
{
    OTHERS_OFF,         // nobody
    OTHERS_ASK,         // those allowed for it
    OTHERS_ACCEPT,      // anyone
} others_permission_t;
others_permission_t others_permission(others_kind_t kind);

/* What a kind ignores, whoever it's from: OTHERS_IGNORE_* together. */
#define OTHERS_IGNORE_EVERYONE  0x02    // broadcasts, and the open direct group's channel
#define OTHERS_IGNORE_CHANNEL   0x04    // those to a whole channel
uint8_t others_ignoring(others_kind_t kind);

/* Who sent the last command of a kind that was done, and how long ago, in
 * ms; NULL if none has been. */
const char *others_last(others_kind_t kind, uint32_t now_ms, uint32_t *age_ms);

/* What the wearer lets others control: their capabilities, for direct
 * comms' hello and the app to say to the others. A list, so more can be
 * added: how many (1), then for each (OTHERS_CAP_ENTRY bytes), its id
 * (OTHERS_CAP_*), how (OTHERS_CAP_ASK: those the wearer allows;
 * OTHERS_CAP_OPEN: anyone), and a byte more: for Vibe toys, the channels a
 * connected toy follows; otherwise 0. One the wearer hasn't got (Vibe toys,
 * with none connected), or lets nobody control (Off), is left out. Worked
 * out on the UI loop, by others_poll(); from any task. Returns its length,
 * 1 for none. Sounds only with a speaker. Ids 3 and 4 are kept for E-stim
 * and Machines (5 was to be Pictures, which Display covers). */
#define OTHERS_CAP_DISPLAY      1       // words and pictures
#define OTHERS_CAP_VIBE         2
#define OTHERS_CAP_SOUNDS       6
#define OTHERS_CAP_ASK          1
#define OTHERS_CAP_OPEN         2
#define OTHERS_CAP_ENTRY        3
#define OTHERS_CAPS_MAX         (1 + OTHERS_CAP_ENTRY * OTHERS_KIND_COUNT)
size_t others_capabilities(uint8_t out[OTHERS_CAPS_MAX]);

/* How a kind's offered in the capabilities: OTHERS_CAP_ASK or
 * OTHERS_CAP_OPEN, or 0 for not at all. From any task. */
uint8_t others_offered(others_kind_t kind);

/* Goes up whenever any of the above changes, or the rules do, for screens
 * to redraw. */
uint32_t others_changes(void);

/* Check and do what's queued, and save the senders' counters once they've
 * settled. Call it every 50 ms or so, from the UI loop. */
void others_poll(uint32_t now_ms);

#endif
