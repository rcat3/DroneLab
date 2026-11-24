/*
 * The unit's toys, by channel (see toys.h), through their makers' drivers
 * (toy_driver.h).
 */
#include "app/toys.h"

#include <stdio.h>
#include <string.h>

#include "app/patterns.h"
#include "app/toy_driver.h"
#include "hal.h"

#define STOP_SETTLE_MS      200     // time for the stop to go out before disconnecting
#define STORE_NAME          "toys"
#define STORE_VERSION       1
#define SAVE_DELAY_MS       1000
#define MAPS_KEPT           8       // toys whose mapping is remembered

static const toy_driver_t *const drivers[] = {
    &toy_lovense,
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
} channel_t;

// A toy's mapping, as it's remembered
typedef struct
{
    uint8_t addr[6];
    uint8_t channels[TOYS_MAX_OUTPUTS];
    uint32_t order;                 // when it was last used: the oldest goes first
} map_t;

typedef struct
{
    uint8_t version;
    uint8_t map_count;
    uint8_t control_count;          // 0 for one for each mapped channel
    uint8_t spare;
    map_t maps[MAPS_KEPT];
    toys_control_t controls[TOYS_SCREEN_CONTROLS];
} stored_t;

static slot_t slots[TOYS_MAX_DEVICES];
static channel_t channels[TOYS_CHANNELS];
static stored_t stored;
static uint32_t map_order;
static bool unsaved;
static uint32_t changed_ms;
static uint32_t layout_changes;
static bool scanning;
static uint32_t now;                // the time of the last poll
static uint32_t last_poll;
static uint16_t speed = 100;        // percent
static float reactive_factor = 1;

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

/* ----- What's remembered ----- */

void toys_init(void)
{
    memset(&stored, 0, sizeof(stored));
    size_t n = rcat_hal_store_read(STORE_NAME, &stored, sizeof(stored));
    if (n != sizeof(stored) || stored.version != STORE_VERSION || stored.map_count > MAPS_KEPT
        || stored.control_count > TOYS_SCREEN_CONTROLS)
    {
        memset(&stored, 0, sizeof(stored));
        stored.version = STORE_VERSION;
    }
    for (int i = 0; i < stored.map_count; i++)
    {
        if (stored.maps[i].order >= map_order)
        {
            map_order = stored.maps[i].order + 1;
        }
    }
    for (int i = 0; i < TOYS_SCREEN_CONTROLS; i++)
    {
        stored.controls[i].label[TOYS_LABEL_LEN - 1] = '\0';
        stored.controls[i].channels &= TOYS_ALL_CHANNELS;
    }
    for (int c = 0; c < TOYS_CHANNELS; c++)
    {
        channels[c].pub.pattern = -1;
    }
}

static void changed(void)
{
    unsaved = true;
    changed_ms = now;
    layout_changes++;
}

static map_t *find_map(const uint8_t addr[6])
{
    for (int i = 0; i < stored.map_count; i++)
    {
        if (memcmp(stored.maps[i].addr, addr, 6) == 0)
        {
            return &stored.maps[i];
        }
    }
    return NULL;
}

/* A toy's outputs take on its remembered mapping, or the usual one: its
 * first output V1, its second V2, and so on. */
static void apply_map(slot_t *s)
{
    const map_t *m = find_map(s->pub.addr);
    for (uint8_t i = 0; i < s->pub.output_count; i++)
    {
        uint8_t c = m != NULL ? m->channels[i] : (i < TOYS_CHANNELS ? i : TOYS_NO_CHANNEL);
        s->pub.outputs[i].channel = c < TOYS_CHANNELS ? c : TOYS_NO_CHANNEL;
        s->pub.outputs[i].level = 0;
    }
}

void toys_set_channel(size_t slot, uint8_t output, uint8_t channel)
{
    if (slot >= TOYS_MAX_DEVICES || !slots[slot].used || output >= slots[slot].pub.output_count)
    {
        return;
    }
    slot_t *s = &slots[slot];
    if (channel >= TOYS_CHANNELS)
    {
        channel = TOYS_NO_CHANNEL;
    }
    if (s->pub.outputs[output].channel == channel)
    {
        return;
    }
    map_t *m = find_map(s->pub.addr);
    if (m == NULL)
    {
        // A new one, in place of the one used longest ago if they're all taken
        if (stored.map_count < MAPS_KEPT)
        {
            m = &stored.maps[stored.map_count++];
        }
        else
        {
            m = &stored.maps[0];
            for (int i = 1; i < MAPS_KEPT; i++)
            {
                if (stored.maps[i].order < m->order)
                {
                    m = &stored.maps[i];
                }
            }
        }
        memcpy(m->addr, s->pub.addr, 6);
        for (uint8_t i = 0; i < TOYS_MAX_OUTPUTS; i++)
        {
            m->channels[i] = i < s->pub.output_count ? s->pub.outputs[i].channel : TOYS_NO_CHANNEL;
        }
    }
    m->order = map_order++;
    m->channels[output] = channel;
    s->pub.outputs[output].channel = channel;
    changed();
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

int toys_screen_controls(toys_control_t out[TOYS_SCREEN_CONTROLS])
{
    if (stored.control_count > 0)
    {
        memcpy(out, stored.controls, stored.control_count * sizeof(toys_control_t));
        return stored.control_count;
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

void toys_set_screen_controls(const toys_control_t *controls, int count)
{
    if (count < 0)
    {
        count = 0;
    }
    if (count > TOYS_SCREEN_CONTROLS)
    {
        count = TOYS_SCREEN_CONTROLS;
    }
    memset(stored.controls, 0, sizeof(stored.controls));
    int n = 0;
    for (int i = 0; i < count; i++)
    {
        if ((controls[i].channels & TOYS_ALL_CHANNELS) == 0)
        {
            continue;   // drives nothing
        }
        stored.controls[n] = controls[i];
        stored.controls[n].channels &= TOYS_ALL_CHANNELS;
        stored.controls[n].label[TOYS_LABEL_LEN - 1] = '\0';
        n++;
    }
    stored.control_count = (uint8_t)n;
    changed();
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
    return channel < TOYS_CHANNELS && (channels[channel].pub.pattern >= 0 || channels[channel].pub.react);
}

bool toys_reacting(void)
{
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        if (channels[c].pub.react)
        {
            return true;
        }
    }
    return false;
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
    if (pattern >= (int)patterns_count())
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
    }
}

void toys_react(uint8_t mask, bool on)
{
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        channel_t *ch = &channels[c];
        if (!(mask & (1u << c)) || ch->pub.react == on)
        {
            continue;
        }
        if (on && !toys_driven(c))
        {
            start_driving(ch);
        }
        ch->pub.react = on;
    }
}

void toys_set_reactive_factor(float factor)
{
    reactive_factor = factor < 0 ? 0 : factor > 1 ? 1 : factor;
}

void toys_set_speed(uint16_t percent)
{
    speed = percent < TOYS_SPEED_MIN ? TOYS_SPEED_MIN : percent > TOYS_SPEED_MAX ? TOYS_SPEED_MAX : percent;
}

uint16_t toys_speed(void)
{
    return speed;
}

void toys_stop_all(void)
{
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        channels[c].pub.level = 0;
        channels[c].pub.out = 0;
        channels[c].pub.pattern = -1;
        channels[c].pub.react = false;
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
        float v = 1;
        if (ch->pub.pattern >= 0)
        {
            ch->pattern_ms += dt_ms * speed / 100;
            v = patterns_level((size_t)ch->pub.pattern, c, ch->pattern_ms);
        }
        if (ch->pub.react)
        {
            v *= reactive_factor;
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
        s->link = rcat_hal_ble_connect(&s->ble, s->driver->service);
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
    if (unsaved && now - changed_ms >= SAVE_DELAY_MS)
    {
        unsaved = false;
        if (!rcat_hal_store_write(STORE_NAME, &stored, sizeof(stored)))
        {
            printf("toys: couldn't save the mapping\n");
        }
    }
}
