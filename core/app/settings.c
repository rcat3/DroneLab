#include <stddef.h>
#include <string.h>

#include "app/settings.h"
#include "app/utf8.h"
#include "hal.h"
#include "lvgl.h"

#define SETTINGS_MAGIC      0x54414352u     // "RCAT"
#define SETTINGS_VERSION    2               // layout of settings_record_t
#define SAVE_DELAY_MS       2000

// What actually goes into storage. `size` records how much of settings_t was
// saved, so firmware with more fields can still read older settings, and
// older firmware can read newer ones, keeping the fields it knows.
typedef struct
{
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint32_t checksum;      // over the first `size` bytes of values
    settings_t values;
} settings_record_t;

#define STORAGE_MAX         256     // what the board can store (see hal.h)
#define HEADER_SIZE         offsetof(settings_record_t, values)

_Static_assert(sizeof(settings_record_t) <= STORAGE_MAX, "settings_t has outgrown the board's storage");

static settings_t current;
static settings_t saved;
static lv_timer_t *save_timer;

static void set_defaults(settings_t *s)
{
    memset(s, 0, sizeof(*s));
    s->brightness = SETTINGS_DEFAULT_BRIGHTNESS;
    s->rotation = SETTINGS_DEFAULT_ROTATION;
    s->startup_image[0] = '\0';
    s->voice_ring = 0;
    s->voice_ring_color = 0;
    s->sound_volume = SETTINGS_DEFAULT_VOLUME;
    s->sound_repeat = 0;
    s->sound_autoplay = 0;
    s->sound_track[0] = '\0';
    s->voice_effect = 0;
    s->toy_release_to_zero = 0;
    s->voice_volume = SETTINGS_DEFAULT_VOICE_VOLUME;
    s->speaker = SETTINGS_SPEAKER_ASK;
#if RCAT_DEFAULT_COMM_ON
    s->comm_on = 1;     // the comm channel's what this unit's for (the virtual unit)
#endif
}

static uint32_t checksum(const void *data, size_t len)
{
    // FNV-1a
    const uint8_t *p = data;
    uint32_t hash = 2166136261u;
    for (size_t i = 0; i < len; i++)
    {
        hash = (hash ^ p[i]) * 16777619u;
    }
    return hash;
}

static bool load(settings_t *out)
{
    // Read all there could be, as newer firmware may have saved more than
    // this firmware's settings_t, to check its checksum.
    static union
    {
        settings_record_t rec;
        uint8_t bytes[STORAGE_MAX];
    } stored;
    const settings_record_t *rec = &stored.rec;

    if (!rcat_hal_settings_read(stored.bytes, sizeof(stored.bytes))
        || rec->magic != SETTINGS_MAGIC
        || rec->version != SETTINGS_VERSION
        || rec->size == 0
        || rec->size > STORAGE_MAX - HEADER_SIZE
        || rec->checksum != checksum(stored.bytes + HEADER_SIZE, rec->size))
    {
        return false;
    }

    // Start from the defaults so fields newer than the saved data keep them,
    // and leave out any fields this firmware doesn't have.
    set_defaults(out);
    memcpy(out, stored.bytes + HEADER_SIZE, rec->size < sizeof(settings_t) ? rec->size : sizeof(settings_t));

    // Sanity check each field on its own, so one bad value doesn't lose the rest.
    if (out->brightness < 1 || out->brightness > 100)
    {
        out->brightness = SETTINGS_DEFAULT_BRIGHTNESS;
    }
    out->rotation &= 3;
    if (rec->size <= offsetof(settings_t, speaker) || out->speaker == SETTINGS_SPEAKER_OLD)
    {
        out->speaker = SETTINGS_SPEAKER_FITTED;     // saved before there was a choice
    }
    else if (out->speaker > SETTINGS_SPEAKER_ASK)
    {
        out->speaker = SETTINGS_SPEAKER_ASK;
    }
    out->startup_image[SETTINGS_NAME_LEN - 1] = '\0';
    if (strcmp(out->startup_image, SETTINGS_STARTUP_OLD_KITT) == 0)
    {
        // KITT is one of the Sound Visualizer's styles now, and the default one.
        strcpy(out->startup_image, SETTINGS_STARTUP_VISUALIZER);
    }
    out->voice_ring = out->voice_ring ? 1 : 0;
    // voice_ring_color is checked against the color list by the UI
    if (out->sound_volume > 100)
    {
        out->sound_volume = SETTINGS_DEFAULT_VOLUME;
    }
    // sound_repeat is checked by the audio player
    out->sound_autoplay = out->sound_autoplay ? 1 : 0;
    out->sound_track[SETTINGS_NAME_LEN - 1] = '\0';
    // voice_effect is checked against the preset list by the UI
    if (out->voice_volume > 100)
    {
        out->voice_volume = SETTINGS_DEFAULT_VOICE_VOLUME;
    }
    if (out->voice_loud_room > 4)     // VOICE_FX_LOUD_LEVELS
    {
        out->voice_loud_room = 0;
    }
    out->toy_release_to_zero = out->toy_release_to_zero ? 1 : 0;
    out->remote_autostart = out->remote_autostart ? 1 : 0;
    // visualizer is checked against the list of styles by the UI
    out->comm_on = out->comm_on ? 1 : 0;
    out->button_paired = out->button_paired ? 1 : 0;
    out->button_name[SETTINGS_BUTTON_NAME_LEN - 1] = '\0';
    // comm_mode is checked by the comm channel
    out->comm_mute_speaker = out->comm_mute_speaker ? 1 : 0;
    out->comm_auto_show &= SETTINGS_SHOW_SENDING | SETTINGS_SHOW_HEARING;
    out->direct_on = out->direct_on ? 1 : 0;
    out->direct_keyed = out->direct_keyed ? 1 : 0;
    out->direct_group[SETTINGS_DIRECT_NAME_LEN - 1] = '\0';
    out->direct_name[SETTINGS_DIRECT_NAME_LEN - 1] = '\0';
    for (int k = 0; k < SETTINGS_CURVE_POINTS && out->battery_curve_runs > 0; k++)
    {
        uint16_t mv = out->battery_curve_mv[k];
        if (mv < 2500 || mv > 4500 || (k > 0 && mv >= out->battery_curve_mv[k - 1]))
        {
            out->battery_curve_runs = 0;
        }
    }
    return true;
}

void settings_init(void)
{
    if (!load(&current))
    {
        set_defaults(&current);
    }
    saved = current;
}

const settings_t *settings_get(void)
{
    return &current;
}

static void save_timer_cb(lv_timer_t *t)
{
    if (t != NULL)
    {
        lv_timer_pause(t);
    }

    if (memcmp(&current, &saved, sizeof(current)) == 0)
    {
        return;
    }

    settings_record_t rec;
    memset(&rec, 0, sizeof(rec));
    rec.magic = SETTINGS_MAGIC;
    rec.version = SETTINGS_VERSION;
    rec.size = sizeof(settings_t);
    rec.values = current;
    rec.checksum = checksum(&rec.values, rec.size);

    if (rcat_hal_settings_write(&rec, sizeof(rec)))
    {
        saved = current;
    }
}

static void schedule_save(void)
{
    if (save_timer == NULL)
    {
        save_timer = lv_timer_create(save_timer_cb, SAVE_DELAY_MS, NULL);
    }
    lv_timer_reset(save_timer);
    lv_timer_resume(save_timer);
}

void settings_set_brightness(uint8_t percent)
{
    current.brightness = percent;
    schedule_save();
}

void settings_set_rotation(uint8_t quarter_turns)
{
    current.rotation = quarter_turns & 3;
    schedule_save();
}

void settings_set_speaker(uint8_t speaker)
{
    current.speaker = speaker >= SETTINGS_SPEAKER_FITTED && speaker <= SETTINGS_SPEAKER_NONE ? speaker
                                                                                          : SETTINGS_SPEAKER_ASK;
    schedule_save();
}

bool settings_speaker_fitted(void)
{
#if RCAT_SPEAKER_OPTIONAL
    return current.speaker != SETTINGS_SPEAKER_NONE;
#else
    return true;
#endif
}

bool settings_speaker_unasked(void)
{
#if RCAT_SPEAKER_OPTIONAL
    return current.speaker == SETTINGS_SPEAKER_ASK;
#else
    return false;
#endif
}

void settings_save_now(void)
{
    if (save_timer != NULL)
    {
        lv_timer_pause(save_timer);
    }
    save_timer_cb(NULL);
}

void settings_set_startup_image(const char *name)
{
    // strncpy zero-fills the rest, which keeps the memcmp in save_timer_cb honest.
    strncpy(current.startup_image, name, SETTINGS_NAME_LEN - 1);
    current.startup_image[SETTINGS_NAME_LEN - 1] = '\0';
    schedule_save();
}

void settings_set_voice_ring(uint8_t enabled, uint8_t color)
{
    current.voice_ring = enabled ? 1 : 0;
    current.voice_ring_color = color;
    schedule_save();
}

void settings_set_sound_volume(uint8_t percent)
{
    current.sound_volume = percent;
    schedule_save();
}

void settings_set_sound_repeat(uint8_t repeat)
{
    current.sound_repeat = repeat;
    schedule_save();
}

void settings_set_sound_autoplay(uint8_t enabled)
{
    current.sound_autoplay = enabled ? 1 : 0;
    schedule_save();
}

void settings_set_voice_effect(uint8_t preset)
{
    current.voice_effect = preset;
    schedule_save();
}

void settings_set_voice_volume(uint8_t percent)
{
    current.voice_volume = percent;
    schedule_save();
}

void settings_set_voice_loud_room(uint8_t level)
{
    current.voice_loud_room = level;
    schedule_save();
}

void settings_set_visualizer(uint8_t index)
{
    current.visualizer = index;
    schedule_save();
}

void settings_set_sound_track(const char *name)
{
    strncpy(current.sound_track, name, SETTINGS_NAME_LEN - 1);
    current.sound_track[SETTINGS_NAME_LEN - 1] = '\0';
    schedule_save();
}

void settings_set_toy_release_to_zero(uint8_t enabled)
{
    current.toy_release_to_zero = enabled ? 1 : 0;
    schedule_save();
}

void settings_set_remote(const char *ssid, const char *password)
{
    strncpy(current.remote_ssid, ssid, SETTINGS_REMOTE_LEN - 1);
    current.remote_ssid[SETTINGS_REMOTE_LEN - 1] = '\0';
    strncpy(current.remote_password, password, SETTINGS_REMOTE_LEN - 1);
    current.remote_password[SETTINGS_REMOTE_LEN - 1] = '\0';
    schedule_save();
}

void settings_set_remote_autostart(uint8_t enabled)
{
    current.remote_autostart = enabled ? 1 : 0;
    schedule_save();
}

void settings_set_terminal_size(uint8_t size)
{
    current.terminal_size = size <= 6 ? size : 0;
    schedule_save();
}

void settings_set_battery_curve(const uint16_t *mv, uint8_t runs, uint32_t last_run)
{
    if (runs > 0)
    {
        memcpy(current.battery_curve_mv, mv, sizeof(current.battery_curve_mv));
    }
    else
    {
        memset(current.battery_curve_mv, 0, sizeof(current.battery_curve_mv));
    }
    current.battery_curve_runs = runs;
    current.battery_curve_last_run = last_run;
    schedule_save();
}

void settings_set_button(const uint8_t *addr, uint8_t addr_type, const char *name)
{
    current.button_paired = addr != NULL;
    current.button_addr_type = addr != NULL ? addr_type : 0;
    memset(current.button_addr, 0, sizeof(current.button_addr));
    memset(current.button_name, 0, sizeof(current.button_name));
    if (addr != NULL)
    {
        memcpy(current.button_addr, addr, sizeof(current.button_addr));
        strncpy(current.button_name, name, sizeof(current.button_name) - 1);
    }
    schedule_save();
}

void settings_set_comm(uint8_t on, uint8_t mode)
{
    current.comm_on = on ? 1 : 0;
    current.comm_mode = mode;
    schedule_save();
}

void settings_set_comm_talk_on(uint8_t transport)
{
    current.comm_talk_on = transport;
    schedule_save();
}

void settings_set_comm_voice_effect(int preset)
{
    current.comm_voice_effect = preset < 0 ? 0 : (uint8_t)(preset + 1);
    schedule_save();
}

void settings_set_direct_radio(uint8_t channel, uint8_t long_range)
{
    current.direct_channel = channel;
    current.direct_long_range = long_range ? 1 : 0;
    schedule_save();
}

void settings_set_direct(uint8_t on)
{
    current.direct_on = on ? 1 : 0;
    schedule_save();
}

void settings_set_direct_group(const uint8_t *key, const char *group, const char *name)
{
    current.direct_keyed = key != NULL;
    memset(current.direct_key, 0, sizeof(current.direct_key));
    if (key != NULL)
    {
        memcpy(current.direct_key, key, sizeof(current.direct_key));
    }
    memset(current.direct_group, 0, sizeof(current.direct_group));
    strncpy(current.direct_group, group != NULL ? group : "", sizeof(current.direct_group) - 1);
    utf8_trim(current.direct_group);
    memset(current.direct_name, 0, sizeof(current.direct_name));
    strncpy(current.direct_name, name != NULL ? name : "", sizeof(current.direct_name) - 1);
    utf8_trim(current.direct_name);
    schedule_save();
}

void settings_set_comm_options(uint8_t mute_speaker, uint8_t auto_show)
{
    current.comm_mute_speaker = mute_speaker ? 1 : 0;
    current.comm_auto_show = auto_show & (SETTINGS_SHOW_SENDING | SETTINGS_SHOW_HEARING);
    schedule_save();
}
