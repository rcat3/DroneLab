/*
 * The unit's toys, by channel (see toys.h), through their makers' drivers
 * (toy_driver.h).
 */
#include "app/toys.h"

#include <stdio.h>
#include <string.h>

#include "app/patterns.h"
#include "app/reactive.h"
#include "app/toy_driver.h"
#include "hal.h"

#define STOP_SETTLE_MS      200     // time for the stop to go out before disconnecting

static const toy_driver_t *const drivers[] = {
    &toy_lovense,
    &toy_wevibe,
    &toy_magicmotion,
    &toy_kiiroo,
};

typedef struct
{
    toy_t pub;                      // what toys_device() hands out
    bool used;
    const toy_driver_t *driver;
    rcat_hal_ble_device_t ble;
    int link;                       // HAL link while connecting or connected, else -1
    bool identified;
    uint32_t stop_ms;               // when it was told to stop before disconnecting, or 0
    union
    {
        uint8_t bytes[TOY_DRIVER_STATE];
        uint32_t align;
    } state;
} slot_t;

typedef struct
{
    toy_channel_t pub;
    uint32_t pattern_ms;            // how far into its pattern it is, at the pattern's own speed
    uint8_t row;                    // the pattern's row it plays: its place among the channels it was played on
    bool waiting;                   // for a pattern to come, held at 0 till then
    uint8_t wait_for[PATTERNS_HASH_LEN];
} channel_t;

static slot_t slots[TOYS_MAX_DEVICES];
static channel_t channels[TOYS_CHANNELS];
static toys_map_t maps[TOYS_MAPS_MAX];
static int map_count;
static toys_control_t controls[TOYS_SCREEN_CONTROLS];
static int control_count;           // 0 for one for each mapped channel
static uint32_t layout_changes;
static bool scanning;
static uint32_t now;                // the time of the last poll
static uint32_t last_poll;

const char *toys_output_name(toy_output_kind_t kind)
{
    switch (kind)
    {
    case TOY_OUT_ROTATE:    return "Rotate";
    case TOY_OUT_AIR:       return "Air";
    case TOY_OUT_OSCILLATE: return "Thrust";
    default:                return "Vibrate";
    }
}

/* ----- The mapping and the screen's controls ----- */

void toys_init(void)
{
    for (int c = 0; c < TOYS_CHANNELS; c++)
    {
        channels[c].pub.pattern = -1;
        channels[c].pub.speed = 100;
    }
}

static const toys_map_t *find_map(const uint8_t addr[6])
{
    for (int i = 0; i < map_count; i++)
    {
        if (memcmp(maps[i].addr, addr, 6) == 0)
        {
            return &maps[i];
        }
    }
    return NULL;
}

/* A toy's outputs take on its mapping, or the usual one: its first output
 * V1, its second V2, and so on. */
static void apply_map(slot_t *s)
{
    const toys_map_t *m = find_map(s->pub.addr);
    for (uint8_t i = 0; i < s->pub.output_count; i++)
    {
        uint8_t c = m != NULL ? m->channels[i] : (i < TOYS_CHANNELS ? i : TOYS_NO_CHANNEL);
        s->pub.outputs[i].channel = c < TOYS_CHANNELS ? c : TOYS_NO_CHANNEL;
    }
}

void toys_set_maps(const toys_map_t *new_maps, int count)
{
    map_count = count < 0 ? 0 : count > TOYS_MAPS_MAX ? TOYS_MAPS_MAX : count;
    if (map_count > 0)
    {
        memcpy(maps, new_maps, (size_t)map_count * sizeof(toys_map_t));
    }
    for (size_t i = 0; i < TOYS_MAX_DEVICES; i++)
    {
        if (slots[i].used && slots[i].pub.output_count > 0)
        {
            apply_map(&slots[i]);
        }
    }
    layout_changes++;
}

uint8_t toys_channels_mapped(void)
{
    uint8_t mask = 0;
    for (size_t i = 0; i < TOYS_MAX_DEVICES; i++)
    {
        const slot_t *s = &slots[i];
        for (uint8_t o = 0; s->used && s->pub.state == TOY_CONNECTED && o < s->pub.output_count; o++)
        {
            if (s->pub.outputs[o].channel < TOYS_CHANNELS)
            {
                mask |= 1u << s->pub.outputs[o].channel;
            }
        }
    }
    return mask;
}

int toys_maps(const toys_map_t **out)
{
    *out = maps;
    return map_count;
}

int toys_custom_controls(toys_control_t out[TOYS_SCREEN_CONTROLS])
{
    memcpy(out, controls, (size_t)control_count * sizeof(toys_control_t));
    return control_count;
}

int toys_screen_controls(toys_control_t out[TOYS_SCREEN_CONTROLS])
{
    if (control_count > 0)
    {
        memcpy(out, controls, (size_t)control_count * sizeof(toys_control_t));
        return control_count;
    }
    uint8_t mapped = toys_channels_mapped();
    int n = 0;
    for (uint8_t c = 0; c < TOYS_CHANNELS && n < TOYS_SCREEN_CONTROLS; c++)
    {
        if (mapped & (1u << c))
        {
            snprintf(out[n].label, TOYS_LABEL_LEN, "V%u", c + 1);
            out[n].channels = 1u << c;
            n++;
        }
    }
    return n;
}

void toys_set_screen_controls(const toys_control_t *new_controls, int count)
{
    if (count < 0)
    {
        count = 0;
    }
    if (count > TOYS_SCREEN_CONTROLS)
    {
        count = TOYS_SCREEN_CONTROLS;
    }
    memset(controls, 0, sizeof(controls));
    int n = 0;
    for (int i = 0; i < count; i++)
    {
        if ((new_controls[i].channels & TOYS_ALL_CHANNELS) == 0)
        {
            continue;   // drives nothing
        }
        controls[n] = new_controls[i];
        controls[n].channels &= TOYS_ALL_CHANNELS;
        controls[n].label[TOYS_LABEL_LEN - 1] = '\0';
        if (controls[n].label[0] == '\0')
        {
            // By its channels, as many as fit: "V1+V2"
            size_t at = 0;
            for (uint8_t c = 0; c < TOYS_CHANNELS && at + 4 < TOYS_LABEL_LEN; c++)
            {
                if (controls[n].channels & (1u << c))
                {
                    at += (size_t)snprintf(controls[n].label + at, TOYS_LABEL_LEN - at, "%sV%u", at ? "+" : "", c + 1);
                }
            }
        }
        n++;
    }
    control_count = n;
    layout_changes++;
}

uint32_t toys_layout_changes(void)
{
    return layout_changes;
}

/* ----- Channels ----- */

const toy_channel_t *toys_channel(uint8_t channel)
{
    return channel < TOYS_CHANNELS ? &channels[channel].pub : NULL;
}

bool toys_driven(uint8_t channel)
{
    return channel < TOYS_CHANNELS
           && (channels[channel].pub.pattern >= 0 || channels[channel].pub.react != 0 || channels[channel].waiting);
}

/* A channel's place among [mask]'s: 0 for the lowest. */
static uint8_t row_in(uint8_t mask, uint8_t channel)
{
    uint8_t row = 0;
    for (uint8_t c = 0; c < channel; c++)
    {
        row += (mask >> c) & 1;
    }
    return row;
}

uint32_t toys_reactions(void)
{
    uint32_t modes = 0;
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        if (channels[c].pub.react != 0)
        {
            modes |= 1u << channels[c].pub.react;
        }
    }
    return modes;
}

uint8_t toys_reaction(void)
{
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        if (channels[c].pub.react != 0)
        {
            return channels[c].pub.react;
        }
    }
    return 0;
}

/* Starting a pattern or reaction on a channel that's off: three quarters
 * of the way up, for it to drive up to. */
static void start_driving(channel_t *c)
{
    if (c->pub.level == 0)
    {
        c->pub.level = (TOYS_LEVEL_TOP * 3 + 3) / 4;
    }
}

void toys_set_level(uint8_t mask, uint8_t level)
{
    if (level > TOYS_LEVEL_TOP)
    {
        level = TOYS_LEVEL_TOP;
    }
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        if (mask & (1u << c))
        {
            channels[c].pub.level = level;
        }
    }
}

void toys_play(uint8_t mask, int pattern)
{
    if (pattern >= PATTERNS_SLOTS || patterns_name((size_t)pattern)[0] == '\0')
    {
        pattern = -1;
    }
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        channel_t *ch = &channels[c];
        if (!(mask & (1u << c)))
        {
            continue;
        }
        ch->waiting = false;
        if (pattern < 0)
        {
            // Stopped. Following a reaction, it carries on at its level.
            if (ch->pub.pattern >= 0 && !ch->pub.react)
            {
                ch->pub.level = 0;
            }
            ch->pub.pattern = -1;
            continue;
        }
        if (!toys_driven(c))
        {
            start_driving(ch);
        }
        ch->pub.pattern = pattern;
        ch->pattern_ms = 0;     // those played on together, in step
        ch->row = row_in(mask, c);
    }
}

void toys_set(uint8_t mask, const uint8_t levels[TOYS_CHANNELS], uint16_t speed, uint8_t react, int pattern, const uint8_t *waiting)
{
    if (pattern >= PATTERNS_SLOTS || waiting != NULL)
    {
        pattern = -1;
    }
    mask &= TOYS_ALL_CHANNELS;
    // Where the channels already playing it are, for those starting it
    bool in_step = false;
    uint32_t place = 0;
    for (uint8_t c = 0; c < TOYS_CHANNELS && pattern >= 0 && !in_step; c++)
    {
        if ((mask & (1u << c)) && channels[c].pub.pattern == pattern)
        {
            in_step = true;
            place = channels[c].pattern_ms;
        }
    }
    toys_set_speed(mask, speed);
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        channel_t *ch = &channels[c];
        if (!(mask & (1u << c)))
        {
            continue;
        }
        ch->pub.level = levels[c] > TOYS_LEVEL_TOP ? TOYS_LEVEL_TOP : levels[c];
        ch->pub.react = react < REACTIVE_COUNT ? react : REACTIVE_OFF;
        ch->row = row_in(mask, c);
        ch->waiting = waiting != NULL;
        if (waiting != NULL)
        {
            memcpy(ch->wait_for, waiting, PATTERNS_HASH_LEN);
        }
        if (pattern >= 0 && ch->pub.pattern != pattern)
        {
            ch->pattern_ms = in_step ? place : 0;
        }
        ch->pub.pattern = pattern;
    }
}

void toys_pattern_came(const uint8_t *hash, int pattern)
{
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        channel_t *ch = &channels[c];
        if (ch->waiting && memcmp(ch->wait_for, hash, PATTERNS_HASH_LEN) == 0)
        {
            ch->waiting = false;
            ch->pub.pattern = pattern;
            ch->pattern_ms = 0;     // all that waited for it, in step
        }
    }
}

void toys_patterns_moved(int first, int count, const int *moved)
{
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        channel_t *ch = &channels[c];
        int p = ch->pub.pattern;
        if (p < first || p >= first + count)
        {
            continue;
        }
        if (moved[p - first] >= 0)
        {
            ch->pub.pattern = moved[p - first];
        }
        else
        {
            toys_play(1u << c, -1);
        }
    }
}

bool toys_pattern_in_use(int pattern)
{
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        if (channels[c].pub.pattern == pattern)
        {
            return true;
        }
    }
    return false;
}

void toys_react(uint8_t mask, uint8_t mode)
{
    if (mode >= REACTIVE_COUNT)
    {
        mode = REACTIVE_OFF;
    }
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        channel_t *ch = &channels[c];
        if (!(mask & (1u << c)) || ch->pub.react == mode)
        {
            continue;
        }
        if (mode != REACTIVE_OFF && !toys_driven(c))
        {
            start_driving(ch);
        }
        else if (mode == REACTIVE_OFF && ch->pub.pattern < 0)
        {
            ch->pub.level = 0;  // stopped, as a pattern that's stopped is
        }
        ch->pub.react = mode;
    }
}

void toys_set_speed(uint8_t mask, uint16_t percent)
{
    percent = percent < TOYS_SPEED_MIN ? TOYS_SPEED_MIN : percent > TOYS_SPEED_MAX ? TOYS_SPEED_MAX : percent;
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        if (mask & (1u << c))
        {
            channels[c].pub.speed = percent;
        }
    }
}

uint16_t toys_speed(uint8_t mask)
{
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        if (mask & (1u << c))
        {
            return channels[c].pub.speed;
        }
    }
    return channels[0].pub.speed;
}

void toys_stop_all(void)
{
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        channels[c].pub.level = 0;
        channels[c].pub.out = 0;
        channels[c].pub.pattern = -1;
        channels[c].pub.react = REACTIVE_OFF;
        channels[c].waiting = false;
    }
}

/* What each channel runs at now, from its pattern and the reaction, dt_ms
 * after the last time. */
static void run_channels(uint32_t dt_ms)
{
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        channel_t *ch = &channels[c];
        if (!toys_driven(c))
        {
            ch->pub.out = ch->pub.level;
            continue;
        }
        if (ch->waiting)
        {
            ch->pub.out = 0;    // held till its pattern comes
            continue;
        }
        float v = 1;
        if (ch->pub.pattern >= 0)
        {
            ch->pattern_ms += dt_ms * ch->pub.speed / 100;
            v = patterns_level((size_t)ch->pub.pattern, ch->row, ch->pattern_ms);
        }
        if (ch->pub.react != 0)
        {
            v *= reactive_factor((reactive_mode_t)ch->pub.react);
        }
        ch->pub.out = v <= 0 ? 0 : (uint8_t)(v * ch->pub.level + 0.5f);
    }
}

/* Each output at its channel's level, scaled to its own range. */
static void set_outputs(slot_t *s)
{
    for (uint8_t i = 0; i < s->pub.output_count; i++)
    {
        toy_output_t *o = &s->pub.outputs[i];
        uint8_t out = o->channel < TOYS_CHANNELS ? channels[o->channel].pub.out : 0;
        o->level = (uint8_t)((out * o->max + TOYS_LEVEL_TOP / 2) / TOYS_LEVEL_TOP);
    }
}

/* ----- Toys ----- */

size_t toys_connected_count(void)
{
    size_t n = 0;
    for (size_t i = 0; i < TOYS_MAX_DEVICES; i++)
    {
        n += slots[i].used && slots[i].pub.state == TOY_CONNECTED;
    }
    return n;
}

static size_t linked_count(void)
{
    size_t n = 0;
    for (size_t i = 0; i < TOYS_MAX_DEVICES; i++)
    {
        n += slots[i].used && (slots[i].pub.state == TOY_CONNECTING || slots[i].pub.state == TOY_CONNECTED);
    }
    return n;
}

static const toy_driver_t *driver_for(const char *name)
{
    for (size_t i = 0; i < sizeof(drivers) / sizeof(drivers[0]); i++)
    {
        if (drivers[i]->claims(name))
        {
            return drivers[i];
        }
    }
    return NULL;
}

static void add_found(void)
{
    rcat_hal_ble_device_t found[16];
    size_t count = rcat_hal_ble_scan_results(found, sizeof(found) / sizeof(found[0]));
    for (size_t i = 0; i < count; i++)
    {
        const toy_driver_t *driver = driver_for(found[i].name);
        if (driver == NULL)
        {
            continue;
        }
        slot_t *free_slot = NULL;
        bool known = false;
        for (size_t j = 0; j < TOYS_MAX_DEVICES; j++)
        {
            if (slots[j].used && memcmp(slots[j].ble.addr, found[i].addr, 6) == 0)
            {
                known = true;
                break;
            }
            if (!slots[j].used && free_slot == NULL)
            {
                free_slot = &slots[j];
            }
        }
        if (known || free_slot == NULL)
        {
            continue;
        }
        memset(free_slot, 0, sizeof(*free_slot));
        free_slot->used = true;
        free_slot->driver = driver;
        free_slot->ble = found[i];
        free_slot->link = -1;
        strncpy(free_slot->pub.name, found[i].name, sizeof(free_slot->pub.name) - 1);
        memcpy(free_slot->pub.addr, found[i].addr, 6);
        free_slot->pub.maker = driver->maker;
        free_slot->pub.model = free_slot->pub.name;
        free_slot->pub.state = TOY_FOUND;
        free_slot->pub.battery = -1;
    }
}

bool toys_scan_start(void)
{
    if (!rcat_hal_ble_scan_start())
    {
        return false;
    }
    for (size_t i = 0; i < TOYS_MAX_DEVICES; i++)
    {
        if (slots[i].link < 0)
        {
            slots[i].used = false;
        }
    }
    scanning = true;
    return true;
}

void toys_scan_stop(void)
{
    if (scanning)
    {
        rcat_hal_ble_scan_stop();
        scanning = false;
    }
}

bool toys_scanning(void)
{
    return scanning;
}

const toy_t *toys_device(size_t slot)
{
    return slot < TOYS_MAX_DEVICES && slots[slot].used ? &slots[slot].pub : NULL;
}

static toy_link_t link_of(slot_t *s)
{
    return (toy_link_t){ .toy = &s->pub, .link = s->link, .now = now, .state = s->state.bytes };
}

bool toys_toggle(size_t slot)
{
    if (slot >= TOYS_MAX_DEVICES || !slots[slot].used)
    {
        return false;
    }
    slot_t *s = &slots[slot];
    switch (s->pub.state)
    {
    case TOY_CONNECTING:
        rcat_hal_ble_disconnect(s->link);
        s->link = -1;
        s->pub.state = TOY_FOUND;
        return true;

    case TOY_CONNECTED:
        if (s->stop_ms == 0)
        {
            toy_link_t t = link_of(s);
            s->driver->stop(&t);
            for (uint8_t i = 0; i < s->pub.output_count; i++)
            {
                s->pub.outputs[i].level = 0;
            }
            s->stop_ms = now | 1;   // toys_poll() disconnects once the stop has gone out
        }
        return true;

    default:
        if (linked_count() >= TOYS_MAX_CONNECTED)
        {
            return false;
        }
        s->link = rcat_hal_ble_connect(&s->ble, s->driver->service, s->driver->characteristic);
        if (s->link < 0)
        {
            return false;
        }
        s->pub.state = TOY_CONNECTING;
        s->pub.battery = -1;
        s->pub.output_count = 0;
        s->pub.model = s->pub.name;
        s->identified = false;
        s->stop_ms = 0;
        memset(&s->state, 0, sizeof(s->state));
        return true;
    }
}

static void poll_toy(slot_t *s)
{
    rcat_hal_ble_state_t ble = rcat_hal_ble_link_state(s->link);
    toy_link_t t = link_of(s);

    switch (s->pub.state)
    {
    case TOY_CONNECTING:
        if (ble == RCAT_HAL_BLE_IDLE)
        {
            s->link = -1;
            s->pub.state = TOY_FAILED;
            break;
        }
        if (ble != RCAT_HAL_BLE_CONNECTED)
        {
            break;
        }
        // Connected: find out which model it is, then it's ready.
        if (s->driver->identify(&t))
        {
            if (s->pub.output_count > TOYS_MAX_OUTPUTS)
            {
                s->pub.output_count = TOYS_MAX_OUTPUTS;
            }
            apply_map(s);
            s->identified = true;
            s->pub.state = TOY_CONNECTED;
            layout_changes++;
        }
        break;

    case TOY_CONNECTED:
        if (ble != RCAT_HAL_BLE_CONNECTED)
        {
            s->link = -1;
            s->stop_ms = 0;
            s->pub.state = TOY_LOST;
            for (uint8_t i = 0; i < s->pub.output_count; i++)
            {
                s->pub.outputs[i].level = 0;
            }
            layout_changes++;
            break;
        }
        if (s->stop_ms != 0)
        {
            if (now - s->stop_ms >= STOP_SETTLE_MS)
            {
                rcat_hal_ble_disconnect(s->link);
                s->link = -1;
                s->stop_ms = 0;
                s->pub.state = TOY_FOUND;
                layout_changes++;
            }
            break;
        }
        set_outputs(s);
        s->driver->poll(&t);
        break;

    default:
        break;
    }
}

void toys_poll(uint32_t now_ms)
{
    last_poll = now != 0 ? now : now_ms;
    now = now_ms;
    if (scanning)
    {
        add_found();
    }
    run_channels(now - last_poll);
    for (size_t i = 0; i < TOYS_MAX_DEVICES; i++)
    {
        if (slots[i].used)
        {
            poll_toy(&slots[i]);
        }
    }
}
