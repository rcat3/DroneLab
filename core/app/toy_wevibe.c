/*
 * The driver for We-Vibe toys (see toy_driver.h). Untested: no We-Vibe toy
 * has been tried with it yet.
 *
 * They advertise just their model's name ("Sync", "Moxie", "Chorus"), and
 * take 8-byte commands on characteristic f000c000 of service f000bb03. All
 * of a toy's motors go in each command, in one of three layouts, by model:
 *
 *   4-bit:   0f 03 00 (ext | int << 4) 00 03 00 00     levels 0 to 15
 *   8-bit:   0f 03 00 ext+3 int+3 on 00 00             levels 0 to 12, 22 or 27
 *   Chorus:  0f 03 00 int ext on 00 00                 levels 0 to 30
 *
 * where int is the first motor, ext the second (the first again on a one
 * motor toy), and on has bit 0 set while int runs and bit 1 while ext does.
 * All of them stop with 0f 00 00 00 00 00 00 00. A 4-bit toy is sent
 * 0f 03 00 99 00 03 00 00 and then the stop as it connects.
 *
 * The names, layouts and levels are from the Buttplug project's device
 * configuration and protocols (https://github.com/buttplugio/buttplug).
 */
#include <string.h>

#include "app/toy_driver.h"
#include "hal.h"

#define SEND_GAP_MS         100     // at most one command this often
#define MODEL_OUTPUTS       2
#define COMMAND_LEN         8

typedef enum
{
    LAYOUT_4BIT,
    LAYOUT_8BIT,
    LAYOUT_CHORUS,
} layout_t;

typedef struct
{
    const char *name;       // as it advertises
    const char *model;
    layout_t layout;
    uint8_t motors;
    uint8_t max;
} model_t;

static const model_t models[] = {
    { "Bloom",      "Bloom",       LAYOUT_4BIT,   1, 15 },
    { "Ditto",      "Ditto",       LAYOUT_4BIT,   1, 15 },
    { "Jive",       "Jive",        LAYOUT_4BIT,   1, 15 },
    { "Pivot",      "Pivot",       LAYOUT_4BIT,   1, 15 },
    { "Rave",       "Rave",        LAYOUT_4BIT,   1, 15 },
    { "Verge",      "Verge",       LAYOUT_4BIT,   1, 15 },
    { "Wish",       "Wish",        LAYOUT_4BIT,   1, 15 },
    { "Cougar",     "4 Plus",      LAYOUT_4BIT,   2, 15 },
    { "4 Plus",     "4 Plus",      LAYOUT_4BIT,   2, 15 },
    { "4_Plus",     "4 Plus",      LAYOUT_4BIT,   2, 15 },
    { "4plus",      "4 Plus",      LAYOUT_4BIT,   2, 15 },
    { "classic",    "4 Plus",      LAYOUT_4BIT,   2, 15 },
    { "Classic",    "4 Plus",      LAYOUT_4BIT,   2, 15 },
    { "Gala",       "Gala",        LAYOUT_4BIT,   2, 15 },
    { "Nova",       "Nova",        LAYOUT_4BIT,   2, 15 },
    { "Sync",       "Sync",        LAYOUT_4BIT,   2, 15 },

    { "Melt",       "Melt",        LAYOUT_8BIT,   1, 22 },
    { "Melt 2",     "Melt",        LAYOUT_8BIT,   1, 22 },
    { "Moxie",      "Moxie",       LAYOUT_8BIT,   1, 12 },
    { "Vector",     "Vector",      LAYOUT_8BIT,   2, 12 },
    { "Wand",       "Wand",        LAYOUT_8BIT,   1, 22 },
    { "Wand 2",     "Wand 2",      LAYOUT_8BIT,   1, 22 },
    { "Bond",       "Bond",        LAYOUT_8BIT,   1, 27 },
    { "Nelson",     "Bond",        LAYOUT_8BIT,   1, 27 },
    { "Nova2",      "Nova 2",      LAYOUT_8BIT,   2, 27 },
    { "Nova_2",     "Nova 2",      LAYOUT_8BIT,   2, 27 },
    { "Nova 2",     "Nova 2",      LAYOUT_8BIT,   2, 27 },
    { "Jive 2",     "Jive 2",      LAYOUT_8BIT,   1, 12 },
    { "Jive Lite",  "Jive Lite",   LAYOUT_8BIT,   1, 12 },

    { "Chorus",     "Chorus",      LAYOUT_CHORUS, 2, 30 },
    { "skeena",     "Chorus",      LAYOUT_CHORUS, 2, 30 },
    { "Sync 2",     "Sync 2",      LAYOUT_CHORUS, 2, 30 },
    { "Sync Lite",  "Sync Lite",   LAYOUT_CHORUS, 1, 30 },
    { "Sync O",     "Sync O",      LAYOUT_CHORUS, 1, 30 },
};

/* What's kept for each toy, in its toy_link_t's state */
typedef struct
{
    const model_t *model;
    uint8_t sent[MODEL_OUTPUTS];
    uint8_t init_step;              // 4-bit: how much of the start-up it's sent
    bool sent_once;
    uint32_t last_send_ms;
} wevibe_t;

_Static_assert(sizeof(wevibe_t) <= TOY_DRIVER_STATE, "wevibe_t must fit in a toy's driver state");

static const uint8_t service_uuid[16] = { 0xf0, 0x00, 0xbb, 0x03, 0x04, 0x51, 0x40, 0x00,
                                          0xb0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
static const uint8_t tx_uuid[16] = { 0xf0, 0x00, 0xc0, 0x00, 0x04, 0x51, 0x40, 0x00,
                                     0xb0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

static const model_t *find_model(const char *name)
{
    for (size_t i = 0; i < sizeof(models) / sizeof(models[0]); i++)
    {
        if (toy_name_matches(name, models[i].name))
        {
            return &models[i];
        }
    }
    return NULL;
}

static bool wevibe_claims(const char *name)
{
    return find_model(name) != NULL;
}

static bool wevibe_service(const uint8_t u[16])
{
    return memcmp(u, service_uuid, 16) == 0;
}

static rcat_hal_ble_chr_use_t wevibe_characteristic(const uint8_t u[16])
{
    return memcmp(u, tx_uuid, 16) == 0 ? RCAT_HAL_BLE_CHR_TX : RCAT_HAL_BLE_CHR_SKIP;
}

/* The command for these levels. */
static void encode(const model_t *m, const uint8_t *levels, uint8_t out[COMMAND_LEN])
{
    uint8_t in = levels[0];
    uint8_t ext = levels[m->motors > 1 ? 1 : 0];
    memset(out, 0, COMMAND_LEN);
    out[0] = 0x0f;
    if (in == 0 && ext == 0)
    {
        return;
    }
    uint8_t on = (ext != 0 ? 2 : 0) | (in != 0 ? 1 : 0);
    out[1] = 0x03;
    switch (m->layout)
    {
    case LAYOUT_4BIT:
        out[3] = (uint8_t)(ext | (in << 4));
        out[5] = 0x03;
        break;
    case LAYOUT_8BIT:
        out[3] = ext + 3;
        out[4] = in + 3;
        out[5] = on;
        break;
    case LAYOUT_CHORUS:
        out[3] = in;
        out[4] = ext;
        out[5] = on;
        break;
    }
}

static bool send(toy_link_t *t, const uint8_t *command)
{
    if (!rcat_hal_ble_send(t->link, command, COMMAND_LEN))
    {
        return false;
    }
    ((wevibe_t *)t->state)->last_send_ms = t->now;
    return true;
}

static bool wevibe_identify(toy_link_t *t)
{
    wevibe_t *w = t->state;
    if (w->model == NULL)
    {
        const model_t *m = find_model(t->toy->name);
        if (m == NULL)
        {
            return false;       // can't be: claims() found it
        }
        w->model = m;
        t->toy->model = m->model;
        t->toy->output_count = m->motors;
        for (uint8_t i = 0; i < m->motors; i++)
        {
            t->toy->outputs[i].kind = TOY_OUT_VIBRATE;
            t->toy->outputs[i].max = m->max;
        }
    }

    // A 4-bit toy's start-up, one command each poll.
    if (w->model->layout == LAYOUT_4BIT && w->init_step < 2)
    {
        if (t->now - w->last_send_ms < SEND_GAP_MS)
        {
            return false;
        }
        static const uint8_t init[2][COMMAND_LEN] = {
            { 0x0f, 0x03, 0x00, 0x99, 0x00, 0x03, 0x00, 0x00 },
            { 0x0f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
        };
        if (send(t, init[w->init_step]))
        {
            w->init_step++;
        }
        return false;
    }
    return true;
}

static void wevibe_poll(toy_link_t *t)
{
    wevibe_t *w = t->state;
    if (t->now - w->last_send_ms < SEND_GAP_MS)
    {
        return;
    }
    uint8_t levels[MODEL_OUTPUTS] = { 0 };
    bool changed = !w->sent_once;
    for (uint8_t i = 0; i < w->model->motors; i++)
    {
        levels[i] = t->toy->outputs[i].level;
        changed |= levels[i] != w->sent[i];
    }
    if (!changed)
    {
        return;
    }
    uint8_t command[COMMAND_LEN];
    encode(w->model, levels, command);
    if (send(t, command))
    {
        memcpy(w->sent, levels, sizeof(w->sent));
        w->sent_once = true;
    }
}

static void wevibe_stop(toy_link_t *t)
{
    wevibe_t *w = t->state;
    if (w->model == NULL)
    {
        return;
    }
    static const uint8_t stop[COMMAND_LEN] = { 0x0f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    send(t, stop);
    memset(w->sent, 0, sizeof(w->sent));
}

const toy_driver_t toy_wevibe = {
    .maker = "We-Vibe",
    .claims = wevibe_claims,
    .service = wevibe_service,
    .characteristic = wevibe_characteristic,
    .identify = wevibe_identify,
    .poll = wevibe_poll,
    .stop = wevibe_stop,
};
