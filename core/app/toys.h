#ifndef RCAT_TOYS_H
#define RCAT_TOYS_H

/*
 * HiveMind Control's toys on this unit: those it connects to itself, over
 * Bluetooth LE, each through the driver for its maker (toy_driver.h).
 * Toys run by the phone, or a bridge, are the app's.
 *
 * Vibe toys are run by channel, V1 to V6 (TOYS_CHANNELS), each with a level
 * from 0 to TOYS_LEVEL_TOP. Each of a toy's outputs (a vibrator, a
 * rotation, the Max's air pump, a thrusting motor) follows one channel, or
 * none, as its wearer maps it in their app (toys_set_maps): by default a toy's first
 * output follows V1, its second V2, and so on. An output runs at its
 * channel's level, scaled to its own range. Commands from others, the
 * screen's controls and the remote all set channels, so everyone in a
 * channel can have different toys, and still all take the same commands.
 *
 * A channel can play a pattern (patterns.h), or react to its wearer
 * (reactive.h), or both, and each channel can have a pattern and a reaction
 * of its own. While it does, it's "driven": its level is how high the
 * pattern or reaction takes it, and what it runs at (its "out") is worked
 * out from them as they go. Starting one on a channel that's off sets its
 * level three quarters of the way up; once neither's left, it's off again.
 *
 * The screen shows a few controls (TOYS_SCREEN_CONTROLS), each driving one
 * or more channels together, as the wearer lays them out in their app
 * (toys_set_screen_controls). Until they do, there's one for each channel
 * a connected toy's output follows.
 *
 * Everything runs from toys_poll(), which the UI calls regularly, so nothing
 * here needs a task of its own.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define TOYS_MAX_DEVICES        8   // found or connected, listed together
#define TOYS_MAX_CONNECTED      3
#define TOYS_MAX_OUTPUTS        4   // on one toy
#define TOYS_CHANNELS           6   // V1 to V6
#define TOYS_ALL_CHANNELS       ((1u << TOYS_CHANNELS) - 1)
#define TOYS_LEVEL_TOP          20  // a channel's levels run from 0 to this
#define TOYS_NO_CHANNEL         0xFF
#define TOYS_SCREEN_CONTROLS    3   // as many rings as fit around the screen
#define TOYS_LABEL_LEN          12  // a screen control's label, with its '\0'
#define TOYS_SPEED_MIN          25  // patterns' speed, in percent
#define TOYS_SPEED_MAX          300

/* What an output does */
typedef enum
{
    TOY_OUT_VIBRATE,
    TOY_OUT_ROTATE,
    TOY_OUT_AIR,            // an air pump, like the Max's
    TOY_OUT_OSCILLATE,      // thrusting or stroking
} toy_output_kind_t;

typedef enum
{
    TOY_FOUND,              // seen in the scan, not connected
    TOY_CONNECTING,         // connecting, or asking which model it is
    TOY_CONNECTED,
    TOY_FAILED,             // couldn't connect
    TOY_LOST,               // the connection dropped
} toy_state_t;

typedef struct
{
    toy_output_kind_t kind;
    uint8_t max;            // its levels run from 0 to this
    uint8_t level;          // what it's running at now
    uint8_t channel;        // the channel it follows (0 for V1), or TOYS_NO_CHANNEL
} toy_output_t;

typedef struct
{
    char name[32];          // advertised name, e.g. "LVS-Edge"
    const char *maker;      // e.g. "Lovense"
    const char *model;      // e.g. "Edge", once known; otherwise the advertised name
    uint8_t addr[6];        // its Bluetooth address
    toy_state_t state;
    int battery;            // percent, or -1 if it hasn't said yet
    uint8_t output_count;   // 0 until it's connected
    toy_output_t outputs[TOYS_MAX_OUTPUTS];
} toy_t;

typedef struct
{
    uint8_t level;          // as it's set, 0 to TOYS_LEVEL_TOP; while driven, how high it goes
    uint8_t out;            // what it's running at now
    int pattern;            // the pattern it's playing (see patterns.h), or -1
    uint8_t react;          // the reaction it follows (reactive_mode_t, reactive.h), 0 for none
    uint16_t speed;         // how fast its pattern plays, in percent (100 is as written)
} toy_channel_t;

/* A control on the screen: the channels it drives, together. */
typedef struct
{
    char label[TOYS_LABEL_LEN];
    uint8_t channels;       // a bit for each, V1 the lowest
} toys_control_t;

/* Set it up. Call it once at startup, before rules_init(). */
void toys_init(void);

/* Start or stop looking for toys. Starting forgets those that aren't
 * connected. Returns false if the board has no Bluetooth. */
bool toys_scan_start(void);
void toys_scan_stop(void);
bool toys_scanning(void);

/* The toys, found or connected, by slot. A slot keeps its toy until the next
 * scan starts, unless it's connected. Returns NULL for an empty slot. */
const toy_t *toys_device(size_t slot);
size_t toys_connected_count(void);

/* Connect to a found toy, or stop and disconnect a connected one. Returns
 * false if it can't connect now: too many connected, or one is still
 * connecting. */
bool toys_toggle(size_t slot);

/* A channel, 0 for V1. */
const toy_channel_t *toys_channel(uint8_t channel);
bool toys_driven(uint8_t channel);

/* The channels a connected toy's output follows: a bit for each. */
uint8_t toys_channels_mapped(void);

/* Set the channels in [channels] (a bit for each) to a level, 0 to
 * TOYS_LEVEL_TOP. While one's driven, it's how high it goes. Levels stay
 * when a toy disconnects, but its outputs go to 0. */
void toys_set_level(uint8_t channels, uint8_t level);

/* Play a pattern on the channels, over and over, or stop it with -1 (which
 * also stops those channels, unless they're reacting). */
void toys_play(uint8_t channels, int pattern);

/* Have the channels follow a reaction (reactive_mode_t), or none
 * (REACTIVE_OFF, 0). Each channel follows its own. */
void toys_react(uint8_t channels, uint8_t mode);

/* The reactions followed, a bit for each (1 << mode), for reactive_poll();
 * 0 for none. */
uint32_t toys_reactions(void);

/* The reaction the lowest channel that reacts follows, or 0 for none. */
uint8_t toys_reaction(void);

/* How fast patterns play on the channels, in percent (100 is as written,
 * TOYS_SPEED_MIN to TOYS_SPEED_MAX): each channel has its own. */
void toys_set_speed(uint8_t channels, uint16_t percent);

/* How fast patterns play on the lowest of [channels]. */
uint16_t toys_speed(uint8_t channels);

/* Stop every pattern and reaction, and set every channel to 0. */
void toys_stop_all(void);

/* Set the channels as a whole, as a command from others does (others.h):
 * each one's level (levels[0] V1's), the speed, the reaction, and the pattern, or -1 for none.
 * A channel already playing that pattern keeps its place in it, and one
 * that starts it takes the place of one of the others that's playing it,
 * so they're in step. A pattern played on several channels drives them by
 * rows: its first row the lowest channel, and so on. With [waiting] (a
 * pattern's hash, see patterns.h) in place of a pattern, they hold at 0 till
 * it comes (toys_pattern_came). */
void toys_set(uint8_t channels, const uint8_t levels[TOYS_CHANNELS], uint16_t speed, uint8_t react, int pattern, const uint8_t *waiting);

/* A pattern that's come, by its hash: the channels waiting for it start it,
 * together. */
void toys_pattern_came(const uint8_t *hash, int pattern);

/* Whether any channel's playing a pattern, by its index. */
bool toys_pattern_in_use(int pattern);

/* A toy's mapping: the channel each of its outputs follows (0 for V1), or
 * TOYS_NO_CHANNEL, by its address. */
typedef struct
{
    uint8_t addr[6];
    uint8_t channels[TOYS_MAX_OUTPUTS];
} toys_map_t;

/* The toys' mappings, from the wearer's rules (rules.h): connected toys take
 * theirs at once, and any not given has the usual mapping. */
#define TOYS_MAPS_MAX           16
void toys_set_maps(const toys_map_t *maps, int count);

/* The mappings given, and how many. */
int toys_maps(const toys_map_t **maps);

/* The screen's controls as laid out, and how many: 0 for one for each
 * mapped channel. */
int toys_custom_controls(toys_control_t out[TOYS_SCREEN_CONTROLS]);

/* The screen's controls: as laid out, or one for each mapped channel until
 * they are. Returns how many. */
int toys_screen_controls(toys_control_t out[TOYS_SCREEN_CONTROLS]);

/* Lay out the screen's controls, from the wearer's rules; none (count 0)
 * goes back to one for each mapped channel. One without a label is called
 * by its channels, e.g. "V1+V2". */
void toys_set_screen_controls(const toys_control_t *controls, int count);

/* Goes up whenever the mapping or screen controls change, for screens to
 * redraw. */
uint32_t toys_layout_changes(void);

/* Run the connections. Call every 50 ms or so with a millisecond clock. */
void toys_poll(uint32_t now_ms);

/* Short name for a kind of output, e.g. "Vibrate". */
const char *toys_output_name(toy_output_kind_t kind);

#endif
