/*
 * The driver for Magic Motion toys, and others made on them (see
 * toy_driver.h). Untested: no Magic Motion toy has been tried with it yet.
 *
 * They advertise just their model's name ("Flamingo", "Eidolon", "nyx"),
 * and take commands on characteristic 78667579-a914-... of service
 * 78667579-7b48-..., in one of four layouts, by model, with levels 0 to 100
 * (77 on the Krush):
 *
 *   V1:  0b ff 04 0a 32 32 00 04 08 L 64 00
 *   V2:  10 ff 04 0a 32 0a 00 04 08 L1 64 00 04 08 L2 64 01
 *   V3:  0b ff 04 0a 46 46 00 04 08 L 64 00
 *   V4:  10 ff 04 0a 32 32 00 04 08 L1 64 00 04 08 L2 64 01
 *
 * A one motor V4 toy gets its level in both places; a one motor V2 toy gets
 * 0 for the second.
 *
 * The names, layouts and levels are from the Buttplug project's device
 * configuration and protocols (https://github.com/buttplugio/buttplug).
 */
#include <string.h>

#include "app/toy_driver.h"
#include "hal.h"

#define SEND_GAP_MS         100     // at most one command this often
#define MODEL_OUTPUTS       2
#define COMMAND_MAX         17

typedef enum
{
    LAYOUT_V1,
    LAYOUT_V2,
    LAYOUT_V3,
    LAYOUT_V4,
} layout_t;

typedef struct
{
    const char *name;       // as it advertises; a '*' at the end matches anything after
    const char *model;
    layout_t layout;
    uint8_t outputs;
    toy_output_kind_t kind; // what its outputs do
    uint8_t max;
} model_t;

#define V   TOY_OUT_VIBRATE
#define O   TOY_OUT_OSCILLATE

// Most specific names first: "Smart Mini Vibe*" catches the rest.
static const model_t models[] = {
    { "Smart Mini Vibe3",   "Vini",                LAYOUT_V1, 1, V, 100 },
    { "Smart Mini Vibe*",   "Smart Mini Vibe",     LAYOUT_V1, 1, V, 100 },
    { "Smart Bean",         "Smart Bean",          LAYOUT_V1, 1, V, 100 },
    { "Smart Bean3",        "FitCute Kegel Rejuve", LAYOUT_V1, 1, V, 100 },
    { "Flamingo",           "Flamingo",            LAYOUT_V1, 1, V, 100 },
    { "Flamingo T",         "Flamingo",            LAYOUT_V1, 1, V, 100 },
    { "Magic Cell",         "Dante/Candy/Rise",    LAYOUT_V1, 1, V, 100 },
    { "Magic Wand",         "Wand",                LAYOUT_V1, 1, V, 100 },
    { "Fugu",               "Fugu",                LAYOUT_V1, 1, V, 100 },
    { "Fugu2",              "Fugu",                LAYOUT_V1, 1, V, 100 },
    { "Gballs2",            "G Vibe Gballs 2",     LAYOUT_V1, 1, V, 100 },
    { "GBalls3",            "G Vibe Gballs 3",     LAYOUT_V1, 1, V, 100 },
    { "FM-LILAC-101",       "Femometer Lilac",     LAYOUT_V1, 1, V, 100 },
    { "Xone",               "Xone",                LAYOUT_V1, 1, O, 100 },
    { "CBT002",             "FunTown Caleo",       LAYOUT_V1, 1, V, 100 },

    { "Lipstick",           "Awaken",              LAYOUT_V2, 1, V, 100 },
    { "Sword",              "Equinox",             LAYOUT_V2, 1, V, 100 },
    { "Curve",              "Solstice",            LAYOUT_V2, 1, V, 100 },
    { "Eidolon",            "Eidolon",             LAYOUT_V2, 2, V, 100 },
    { "Solstice X",         "Solstice X",          LAYOUT_V2, 2, V, 100 },
    { "funwand",            "Zenith",              LAYOUT_V2, 1, V, 100 },
    { "CBT001",             "FunTown Jive",        LAYOUT_V2, 1, V, 100 },    // its thrusting isn't in V2's commands

    { "Krush",              "LoveLife Krush",      LAYOUT_V3, 1, V, 77 },

    { "funone",             "Bunny",               LAYOUT_V4, 1, V, 100 },
    { "Magic Sundi",        "Sundae",              LAYOUT_V4, 1, V, 100 },
    { "Kegel Coach",        "Kegel Coach",         LAYOUT_V4, 1, V, 100 },
    { "Magic Lotos",        "Lotos",               LAYOUT_V4, 1, V, 100 },
    { "nyx",                "Nyx",                 LAYOUT_V4, 1, V, 100 },
    { "umi",                "Umi",                 LAYOUT_V4, 2, V, 100 },
    { "funkegel",           "Crystal",             LAYOUT_V4, 1, V, 100 },
    { "bobi2",              "Bobi",                LAYOUT_V4, 2, V, 100 },
};

#undef V
#undef O

/* What's kept for each toy, in its toy_link_t's state */
typedef struct
{
    const model_t *model;
    uint8_t sent[MODEL_OUTPUTS];
    bool sent_once;
    uint32_t last_send_ms;
} magicmotion_t;

_Static_assert(sizeof(magicmotion_t) <= TOY_DRIVER_STATE, "magicmotion_t must fit in a toy's driver state");

static const uint8_t service_uuid[16] = { 0x78, 0x66, 0x75, 0x79, 0x7b, 0x48, 0x43, 0xdb,
                                          0xb8, 0xc5, 0x79, 0x28, 0xa6, 0xb0, 0xa3, 0x35 };
static const uint8_t tx_uuid[16] = { 0x78, 0x66, 0x75, 0x79, 0xa9, 0x14, 0x49, 0xa4,
                                     0x83, 0x33, 0xaa, 0x3c, 0x0c, 0xd8, 0xfe, 0xdc };

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

static bool magicmotion_claims(const char *name)
{
    return find_model(name) != NULL;
}

static bool magicmotion_service(const uint8_t u[16])
{
    return memcmp(u, service_uuid, 16) == 0;
}

static rcat_hal_ble_chr_use_t magicmotion_characteristic(const uint8_t u[16])
{
    return memcmp(u, tx_uuid, 16) == 0 ? RCAT_HAL_BLE_CHR_TX : RCAT_HAL_BLE_CHR_SKIP;
}

/* The command for these levels, and how long it is. */
static size_t encode(const model_t *m, const uint8_t *levels, uint8_t out[COMMAND_MAX])
{
    static const uint8_t one[12] = { 0x0b, 0xff, 0x04, 0x0a, 0x32, 0x32, 0x00, 0x04, 0x08, 0x00, 0x64, 0x00 };
    static const uint8_t two[17] = { 0x10, 0xff, 0x04, 0x0a, 0x32, 0x32, 0x00, 0x04, 0x08, 0x00, 0x64, 0x00,
                                     0x04, 0x08, 0x00, 0x64, 0x01 };
    switch (m->layout)
    {
    case LAYOUT_V2:
    case LAYOUT_V4:
        memcpy(out, two, sizeof(two));
        if (m->layout == LAYOUT_V2)
        {
            out[5] = 0x0a;
        }
        out[9] = levels[0];
        out[14] = m->layout == LAYOUT_V4 && m->outputs == 1 ? levels[0] : levels[1];
        return sizeof(two);
    default:
        memcpy(out, one, sizeof(one));
        if (m->layout == LAYOUT_V3)
        {
            out[4] = out[5] = 0x46;
        }
        out[9] = levels[0];
        return sizeof(one);
    }
}

static bool send_levels(toy_link_t *t, const uint8_t *levels)
{
    magicmotion_t *mm = t->state;
    uint8_t command[COMMAND_MAX];
    size_t len = encode(mm->model, levels, command);
    if (!rcat_hal_ble_send(t->link, command, len))
    {
        return false;
    }
    mm->last_send_ms = t->now;
    memcpy(mm->sent, levels, sizeof(mm->sent));
    mm->sent_once = true;
    return true;
}

static bool magicmotion_identify(toy_link_t *t)
{
    magicmotion_t *mm = t->state;
    const model_t *m = find_model(t->toy->name);
    if (m == NULL)
    {
        return false;       // can't be: claims() found it
    }
    mm->model = m;
    t->toy->model = m->model;
    t->toy->output_count = m->outputs;
    for (uint8_t i = 0; i < m->outputs; i++)
    {
        t->toy->outputs[i].kind = m->kind;
        t->toy->outputs[i].max = m->max;
    }
    return true;
}

static void magicmotion_poll(toy_link_t *t)
{
    magicmotion_t *mm = t->state;
    if (t->now - mm->last_send_ms < SEND_GAP_MS)
    {
        return;
    }
    uint8_t levels[MODEL_OUTPUTS] = { 0 };
    bool changed = !mm->sent_once;
    for (uint8_t i = 0; i < mm->model->outputs; i++)
    {
        levels[i] = t->toy->outputs[i].level;
        changed |= levels[i] != mm->sent[i];
    }
    if (changed)
    {
        send_levels(t, levels);
    }
}

static void magicmotion_stop(toy_link_t *t)
{
    magicmotion_t *mm = t->state;
    if (mm->model == NULL)
    {
        return;
    }
    static const uint8_t zero[MODEL_OUTPUTS] = { 0 };
    send_levels(t, zero);
}

const toy_driver_t toy_magicmotion = {
    .maker = "Magic Motion",
    .claims = magicmotion_claims,
    .service = magicmotion_service,
    .characteristic = magicmotion_characteristic,
    .identify = magicmotion_identify,
    .poll = magicmotion_poll,
    .stop = magicmotion_stop,
};
