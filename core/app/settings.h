#ifndef RCAT_SETTINGS_H
#define RCAT_SETTINGS_H

#include <stdbool.h>
#include <stdint.h>

#define SETTINGS_DEFAULT_BRIGHTNESS 50
#define SETTINGS_DEFAULT_VOLUME     50
#define SETTINGS_DEFAULT_VOICE_VOLUME 50

/* The display's rotation on a new board, in clockwise quarter turns. The
 * board's .cmake file sets it to suit the way its housing holds the board. */
#ifdef RCAT_DEFAULT_ROTATION
#define SETTINGS_DEFAULT_ROTATION   RCAT_DEFAULT_ROTATION
#else
#define SETTINGS_DEFAULT_ROTATION   0
#endif
#define SETTINGS_NAME_LEN           24
#define SETTINGS_REMOTE_LEN         16
#define SETTINGS_CURVE_POINTS       21      // 100%, 95% ... 0%
#define SETTINGS_BUTTON_NAME_LEN    20
#define SETTINGS_DIRECT_KEY_LEN     16
#define SETTINGS_DIRECT_NAME_LEN    16

/* Startup image names that select the blank (black) tile and the Visualizer.
 * Firmware from before the Visualizer saved it as "kitt". */
#define SETTINGS_STARTUP_BLANK      "blank"
#define SETTINGS_STARTUP_VISUALIZER "visualizer"
#define SETTINGS_STARTUP_OLD_KITT   "kitt"

/* Only ever add new fields to the end. Settings saved by older firmware are
 * still loaded, and any fields they don't have get their defaults. */
typedef struct
{
    uint8_t brightness;                     // backlight, percent
    uint8_t rotation;                       // display rotation, clockwise quarter turns
    char startup_image[SETTINGS_NAME_LEN];  // image name; empty means the first image
    uint8_t voice_ring;                     // 1 to show the voice ring around the edge
    uint8_t voice_ring_color;               // index into the voice ring color list
    uint8_t sound_volume;                   // percent
    uint8_t sound_repeat;                   // audio_repeat_t
    uint8_t sound_autoplay;                 // 1 to start playing at startup
    char sound_track[SETTINGS_NAME_LEN];    // file name of the last track played
    uint8_t voice_effect;                   // voice effect preset, 0 for your natural voice
    uint8_t toy_release_to_zero;        // 1 to set a toy control back to 0 when its ring is let go
    char remote_ssid[SETTINGS_REMOTE_LEN];      // the phone remote's hotspot; empty until it's first used
    char remote_password[SETTINGS_REMOTE_LEN];
    uint8_t terminal_size;                  // Terminal letter size: 0 to fit the message, or 1 to 6 for 8 to 48 px
    uint16_t battery_curve_mv[SETTINGS_CURVE_POINTS];  // the learned discharge curve, highest first
    uint8_t battery_curve_runs;             // how many runs it's learned from, 0 for none
    uint32_t battery_curve_last_run;        // the battery log session it last learned from
    uint8_t voice_volume;                   // the voice effect on the speaker, percent
    uint8_t remote_autostart;               // 1 to switch the phone remote on at power-up
    uint8_t visualizer;                     // which visualizer style, 0 for KITT
    uint8_t comm_on;                        // 1 to start the comm channel at startup
    uint8_t comm_mode;                      // comm_mode_t: push to talk, or voice
    uint8_t button_paired;                  // 1 if the comm channel's talk button is below
    uint8_t button_addr_type;               // its Bluetooth address
    uint8_t button_addr[6];
    char button_name[SETTINGS_BUTTON_NAME_LEN];
    uint8_t comm_mute_speaker;              // 1 to silence the speaker while the comm channel sends
    uint8_t comm_auto_show;                 // SETTINGS_SHOW_*: when to switch to the comm status screen
    uint8_t direct_on;                      // 1 for direct comms (see app/direct.h)
    uint8_t direct_keyed;                   // 1 if direct_key is a group's, 0 for the open group
    uint8_t direct_key[SETTINGS_DIRECT_KEY_LEN];
    char direct_group[SETTINGS_DIRECT_NAME_LEN];    // the group's name, to show
    char direct_name[SETTINGS_DIRECT_NAME_LEN];     // what the others see this board as; empty for its own name
    uint8_t comm_voice_effect;              // the comm channel's own voice effect: 0 the speaker's, else its preset + 1
    uint8_t comm_talk_on;                   // comm_transport_t: the channel talked to, the server's or direct comms' group
    uint8_t direct_channel;                 // direct comms' group's channel: 1, 6 or 11; 0 for 6
    uint8_t direct_long_range;              // 1 if the group sends in Long Range mode
    uint8_t speaker;                        // SETTINGS_SPEAKER_*: whether the housing has a speaker
    uint8_t voice_loud_room;                // the voice effect's Loud room level, 0 off (voice_fx_set_loud_room)
} settings_t;

/* speaker: on boards whose speaker plugs in, whether the housing has one
 * (RCAT_SPEAKER_OPTIONAL, in the board's .cmake file). A new board asks at
 * its first start. Settings saved before there was a choice have a 0 here
 * (it was padding at the end of the struct), and are the speaker model's, the
 * only model there was. */
#define SETTINGS_SPEAKER_OLD        0
#define SETTINGS_SPEAKER_FITTED     1
#define SETTINGS_SPEAKER_NONE       2
#define SETTINGS_SPEAKER_ASK        3

/* comm_auto_show: switch to the comm channel's status screen while it's
 * sending, while it hears someone, or both, and back afterwards. */
#define SETTINGS_SHOW_SENDING       0x01
#define SETTINGS_SHOW_HEARING       0x02

/* Load the saved settings, or the defaults if nothing valid has been saved. */
void settings_init(void);

const settings_t *settings_get(void);

/* Change a setting. It's written to storage a couple of seconds after the
 * last change, so dragging a slider doesn't wear out the flash. Requires LVGL
 * to be initialised. */
void settings_set_brightness(uint8_t percent);
void settings_set_rotation(uint8_t quarter_turns);
void settings_set_speaker(uint8_t speaker);

/* Whether there's a speaker to play to: always, on boards where it isn't a
 * choice. */
bool settings_speaker_fitted(void);

/* Whether a new board has yet to be asked if it has a speaker */
bool settings_speaker_unasked(void);

/* Save now, rather than a couple of seconds after the last change, as before
 * restarting. */
void settings_save_now(void);
void settings_set_startup_image(const char *name);
void settings_set_voice_ring(uint8_t enabled, uint8_t color);
void settings_set_sound_volume(uint8_t percent);
void settings_set_sound_repeat(uint8_t repeat);
void settings_set_sound_autoplay(uint8_t enabled);
void settings_set_sound_track(const char *name);
void settings_set_voice_effect(uint8_t preset);
void settings_set_voice_volume(uint8_t percent);
void settings_set_voice_loud_room(uint8_t level);
void settings_set_toy_release_to_zero(uint8_t enabled);
void settings_set_remote(const char *ssid, const char *password);
void settings_set_remote_autostart(uint8_t enabled);
void settings_set_terminal_size(uint8_t size);
void settings_set_visualizer(uint8_t index);
void settings_set_comm(uint8_t on, uint8_t mode);
void settings_set_comm_options(uint8_t mute_speaker, uint8_t auto_show);
void settings_set_direct(uint8_t on);
/* The comm channel's voice effect: -1 for the speaker's, else a preset. */
void settings_set_comm_voice_effect(int preset);
void settings_set_comm_talk_on(uint8_t transport);
/* Direct comms' group: its key (NULL for the open group) and name, and this
 * board's name in it. */
void settings_set_direct_group(const uint8_t *key, const char *group, const char *name);
void settings_set_direct_radio(uint8_t channel, uint8_t long_range);
/* The talk button, or none with addr NULL. */
void settings_set_button(const uint8_t *addr, uint8_t addr_type, const char *name);
/* Keep a learned battery curve (see app/battery_log.h), or forget it with runs = 0. */
void settings_set_battery_curve(const uint16_t *mv, uint8_t runs, uint32_t last_run);

#endif
