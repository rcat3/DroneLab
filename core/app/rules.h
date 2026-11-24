#ifndef RCAT_RULES_H
#define RCAT_RULES_H

/*
 * HiveMind Control's rules: who may control what of the wearer's, and how
 * their toys are laid out. The wearer's app owns them, and pushes them to
 * each host that runs something others control (this unit; the phone and a
 * Bluetooth bridge are hosts too), which keeps the last it was given and
 * goes by them, so commands still work while the phone's away.
 *
 * The rules are one document, the same for every host, which takes the
 * sections it knows and leaves the rest:
 *
 *   version (RULES_VERSION), how many sections, then each section: its id,
 *   its length (2 bytes, little endian), and its body.
 *
 *   0x01 classes:  for each class (a permission for a class of toy or a
 *                  function of the Display unit), 4 bytes: its id
 *                  (RULES_CLASS_*, the capabilities' ids, others.h), its
 *                  policy (RULES_OFF nobody, RULES_ASK those allowed, the
 *                  others asking in the app, RULES_ANYONE), what it ignores
 *                  whoever it's from (OTHERS_IGNORE_*), and a spare byte. A
 *                  class that isn't listed is Off.
 *   0x02 people:   for each person: their public key (32), flags (bit 0
 *                  muted: their commands are ignored), the classes they're
 *                  allowed (2, little endian, a bit for each class id), and
 *                  their name, a label (its length, at most
 *                  RULES_NAME_MAX - 1, then the name, in UTF-8).
 *   0x03 toys:     for each toy whose outputs are mapped: its Bluetooth
 *                  address (6), then the channel each of its outputs follows
 *                  (TOYS_MAX_OUTPUTS, 0 for V1, 0xFF for none). A toy that
 *                  isn't listed has the usual mapping (toys.h).
 *   0x04 controls: the screen's controls (toys.h): how many (0 for one for
 *                  each mapped channel), then for each, its label (its
 *                  length, then the label, in UTF-8), and the channels it
 *                  drives (a bit for each).
 *
 * It comes from the app over Bluetooth, in pieces (comm.h's 0x10 rules),
 * and is kept as it came. Until one has, every class is on Ask, with
 * nobody allowed. The app knows whether this unit has its latest by the
 * document's hash (rules_hash), and whether the wearer's changed anything on
 * the unit since (rules_edited): the only change made here is switching a
 * class Off, which the app takes on when it next connects.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define RULES_VERSION           1
#define RULES_DOC_MAX           2048
#define RULES_PEOPLE_MAX        32
#define RULES_TOYS_MAX          16
#define RULES_NAME_MAX          16      // with its '\0'
#define RULES_KEY_LEN           32

#define RULES_SECTION_CLASSES   0x01
#define RULES_SECTION_PEOPLE    0x02
#define RULES_SECTION_TOYS      0x03
#define RULES_SECTION_CONTROLS  0x04

/* Classes, by the capabilities' ids */
#define RULES_CLASS_TERMINAL    1
#define RULES_CLASS_VIBE        2
#define RULES_CLASS_ESTIM       3
#define RULES_CLASS_MACHINE     4
#define RULES_CLASS_PICTURES    5
#define RULES_CLASS_SOUNDS      6
#define RULES_CLASS_MAX         15      // the allowed bits have room for ids up to this

#define RULES_OFF               0
#define RULES_ASK               1
#define RULES_ANYONE            2

#define RULES_MUTED             0x01    // a person's flags

typedef struct
{
    uint8_t key[RULES_KEY_LEN];
    char name[RULES_NAME_MAX];
    uint8_t flags;
    uint16_t allowed;       // a bit for each class id
} rules_person_t;

/* Read the last rules given, and lay out the toys by them. Call it once at
 * startup, after toys_init(). */
void rules_init(void);

/* A piece of a new document, from the app: [first] starts it afresh, and
 * once [last] has come, it's checked and, if it's good, kept and gone by.
 * Returns false if a document that's ended isn't good (the last rules
 * stay). */
bool rules_receive(bool first, bool last, const uint8_t *piece, size_t len);

/* A class's policy (RULES_OFF, ASK or ANYONE), and what it ignores. */
uint8_t rules_policy(uint8_t class_id);
uint8_t rules_ignoring(uint8_t class_id);

/* Someone in the rules, by their key; NULL if they aren't. */
const rules_person_t *rules_person(const uint8_t key[RULES_KEY_LEN]);

/* Everyone in the rules, in order. */
int rules_people_count(void);
const rules_person_t *rules_person_at(int i);

/* Switch a class Off, here on the unit: kept, and marked for the app to
 * take on. Switching it on again is the app's. */
void rules_set_off(uint8_t class_id);

/* The document's FNV-1a hash, 0 for none yet, and whether the wearer's
 * switched anything Off here since it came. */
uint32_t rules_hash(void);
bool rules_edited(void);

/* Goes up whenever the rules change, for screens to redraw. */
uint32_t rules_changes(void);

#endif
