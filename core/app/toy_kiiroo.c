/*
 * The driver for Kiiroo's vibrators, and OhMiBod's and others made on them
 * (see toy_driver.h). Untested: no Kiiroo toy has been tried with it yet.
 * Their strokers (Keon, Onyx, Launch) aren't here: they take positions, not
 * levels.
 *
 * They advertise just their model's name ("Pearl2", "OhMiBod LUMEN"), and
 * take commands in one of two layouts, by model, with levels 0 to 100 (6 on
 * the Pulse Solo):
 *
 *   V2:    L1 L2 L3    every motor, 0 for those it hasn't, on
 *                      characteristic 88f82581 of service 88f82580
 *   V2.1:  01 L        on characteristic 1902 of service 1900, or
 *                      a0d70002 of service a0d70001
 *
 * The names, layouts and levels are from the Buttplug project's device
 * configuration and protocols (https://github.com/buttplugio/buttplug).
 */
#include <string.h>

#include "app/toy_driver.h"
#include "hal.h"

#define SEND_GAP_MS         100     // at most one command this often
#define MODEL_OUTPUTS       3

typedef enum
{
    LAYOUT_V2,
    LAYOUT_V21,
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
    { "Pearl2",                   "Pearl 2",                LAYOUT_V2,  1, 100 },
    { "Fuse",                     "OhMiBod Fuse",           LAYOUT_V2,  2, 100 },
    { "Virtual Rabbit",           "Virtual Rabbit",         LAYOUT_V2,  2, 100 },
    { "Virtual Blowbot",          "Virtual Blowbot",        LAYOUT_V2,  3, 100 },
    { "Titan",                    "Titan",                  LAYOUT_V2,  3, 100 },

    { "Pearl2.1",                 "Pearl 2.1",              LAYOUT_V21, 1, 100 },
    { "Pearl2+",                  "Pearl 2+",               LAYOUT_V21, 1, 100 },
    { "Pearl 2+",                 "Pearl 2+",               LAYOUT_V21, 1, 100 },
    { "Pearl3",                   "Pearl 3",                LAYOUT_V21, 1, 100 },
    { "Pearl 3",                  "Pearl 3",                LAYOUT_V21, 1, 100 },
    { "Cliona",                   "Cliona",                 LAYOUT_V21, 1, 100 },
    { "Titan1.1",                 "Titan 1.1",              LAYOUT_V21, 1, 100 },    // its stroker isn't here
    { "Fuse1.1",                  "OhMiBod Fuse 1.1",       LAYOUT_V21, 1, 100 },
    { "OhMiBod 4.0",              "OhMiBod Esca 2",         LAYOUT_V21, 1, 100 },
    { "OhMiBod ESCA",             "OhMiBod Esca 2",         LAYOUT_V21, 1, 100 },
    { "OhMiBod LUMEN",            "OhMiBod Lumen",          LAYOUT_V21, 1, 100 },
    { "OhMiBod NEX2",             "OhMiBod NEX|2",          LAYOUT_V21, 1, 100 },
    { "OhMiBod NEX3",             "OhMiBod NEX|3",          LAYOUT_V21, 1, 100 },
    { "OhMiBod Foxy",             "OhMiBod Foxy",           LAYOUT_V21, 1, 100 },
    { "OhMiBod Chill Panty Vibe", "OhMiBod Chill",          LAYOUT_V21, 1, 100 },
    { "OhMiBod Sphinx",           "OhMiBod Sphinx",         LAYOUT_V21, 1, 100 },
    { "Pulse Interactive",        "Hot Octopuss Pulse Solo", LAYOUT_V21, 1, 6 },
};

/* What's kept for each toy, in its toy_link_t's state */
typedef struct
{
    const model_t *model;
    uint8_t sent[MODEL_OUTPUTS];
    bool sent_once;
    uint32_t last_send_ms;
} kiiroo_t;

_Static_assert(sizeof(kiiroo_t) <= TOY_DRIVER_STATE, "kiiroo_t must fit in a toy's driver state");

// V2
static const uint8_t v2_service[16] = { 0x88, 0xf8, 0x25, 0x80, 0x00, 0x00, 0x01, 0xe6,
                                        0xaa, 0xce, 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b };
static const uint8_t v2_tx[16] = { 0x88, 0xf8, 0x25, 0x81, 0x00, 0x00, 0x01, 0xe6,
                                   0xaa, 0xce, 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b };
// V2.1, either of two
static const uint8_t v21_service[16] = { 0x00, 0x00, 0x19, 0x00, 0x00, 0x00, 0x10, 0x00,
                                         0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb };
static const uint8_t v21_tx[16] = { 0x00, 0x00, 0x19, 0x02, 0x00, 0x00, 0x10, 0x00,
                                    0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb };
static const uint8_t v21b_service[16] = { 0xa0, 0xd7, 0x00, 0x01, 0x4c, 0x16, 0x4b, 0xa7,
                                          0x97, 0x7a, 0xd3, 0x94, 0x92, 0x0e, 0x13, 0xa3 };
static const uint8_t v21b_tx[16] = { 0xa0, 0xd7, 0x00, 0x02, 0x4c, 0x16, 0x4b, 0xa7,
                                     0x97, 0x7a, 0xd3, 0x94, 0x92, 0x0e, 0x13, 0xa3 };

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

static bool kiiroo_claims(const char *name)
{
    return find_model(name) != NULL;
}

static bool kiiroo_service(const uint8_t u[16])
{
    return memcmp(u, v2_service, 16) == 0 || memcmp(u, v21_service, 16) == 0
        || memcmp(u, v21b_service, 16) == 0;
}

/* V2.1's service 1900 has a characteristic that can be written to ahead of
 * the one commands go to, so only the ones they go to will do. */
static rcat_hal_ble_chr_use_t kiiroo_characteristic(const uint8_t u[16])
{
    if (memcmp(u, v2_tx, 16) == 0 || memcmp(u, v21_tx, 16) == 0 || memcmp(u, v21b_tx, 16) == 0)
    {
        return RCAT_HAL_BLE_CHR_TX;
    }
    return RCAT_HAL_BLE_CHR_SKIP;
}

static bool send_levels(toy_link_t *t, const uint8_t *levels)
{
    kiiroo_t *k = t->state;
    uint8_t command[MODEL_OUTPUTS];
    size_t len;
    if (k->model->layout == LAYOUT_V2)
    {
        memcpy(command, levels, MODEL_OUTPUTS);
        len = MODEL_OUTPUTS;
    }
    else
    {
        command[0] = 0x01;
        command[1] = levels[0];
        len = 2;
    }
    if (!rcat_hal_ble_send(t->link, command, len))
    {
        return false;
    }
    k->last_send_ms = t->now;
    memcpy(k->sent, levels, sizeof(k->sent));
    k->sent_once = true;
    return true;
}

static bool kiiroo_identify(toy_link_t *t)
{
    kiiroo_t *k = t->state;
    const model_t *m = find_model(t->toy->name);
    if (m == NULL)
    {
        return false;       // can't be: claims() found it
    }
    k->model = m;
    t->toy->model = m->model;
    t->toy->output_count = m->motors;
    for (uint8_t i = 0; i < m->motors; i++)
    {
        t->toy->outputs[i].kind = TOY_OUT_VIBRATE;
        t->toy->outputs[i].max = m->max;
    }
    return true;
}

static void kiiroo_poll(toy_link_t *t)
{
    kiiroo_t *k = t->state;
    if (t->now - k->last_send_ms < SEND_GAP_MS)
    {
        return;
    }
    uint8_t levels[MODEL_OUTPUTS] = { 0 };
    bool changed = !k->sent_once;
    for (uint8_t i = 0; i < k->model->motors; i++)
    {
        levels[i] = t->toy->outputs[i].level;
        changed |= levels[i] != k->sent[i];
    }
    if (changed)
    {
        send_levels(t, levels);
    }
}

static void kiiroo_stop(toy_link_t *t)
{
    kiiroo_t *k = t->state;
    if (k->model == NULL)
    {
        return;
    }
    static const uint8_t zero[MODEL_OUTPUTS] = { 0 };
    send_levels(t, zero);
}

const toy_driver_t toy_kiiroo = {
    .maker = "Kiiroo",
    .claims = kiiroo_claims,
    .service = kiiroo_service,
    .characteristic = kiiroo_characteristic,
    .identify = kiiroo_identify,
    .poll = kiiroo_poll,
    .stop = kiiroo_stop,
};
