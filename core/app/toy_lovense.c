/*
 * The driver for Lovense toys (see toy_driver.h).
 *
 * They advertise names starting "LVS-" (or "LOVE-" on some older ones), and
 * take plain text commands ending in ';' on a serial-style service, with
 * replies sent back as notifications:
 *
 *   DeviceType;    replies "<model>:<firmware>:<address>;", e.g. "P:37:..."
 *   Battery;       replies with the percentage, e.g. "85;" (some put an 's'
 *                  in front of it)
 *   Vibrate:N;     level 0 to 20 on single motor devices, replies "OK;"
 *   Vibrate1:N;    and Vibrate2:N; for each motor on two motor devices
 *   Rotate:N;      0 to 20 on devices that rotate
 *   Air:Level:N;   0 to 3 on the Max's air pump
 *   Mply:a:b:c;    all the motors at once, on the Lapis and newer Flexer
 *
 * The services, commands and model list are from the Buttplug project's
 * device configuration (https://github.com/buttplugio/buttplug).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "app/toy_driver.h"
#include "hal.h"

#define SEND_GAP_MS         100     // at most one command per device this often
#define IDENTIFY_EVERY_MS   500     // ask which model it is this often
#define IDENTIFY_TRIES      5       // before going by its advertised name instead
#define BATTERY_EVERY_MS    30000   // also keeps the connection busy, which some devices want
#define MODEL_OUTPUTS       3

/* How a model takes its commands */
typedef enum
{
    STYLE_SINGLE,       // Vibrate:N;
    STYLE_DUAL,         // Vibrate1:N; Vibrate2:N;
    STYLE_MAX,          // Vibrate:N; Air:Level:N;
    STYLE_ROTATE,       // Vibrate:N; Rotate:N;
    STYLE_MULTI,        // Mply:a:b:c;
    STYLE_STROKER,      // Mply:N:20;
} style_t;

typedef struct
{
    const char *id;     // what DeviceType replies with
    const char *model;
    style_t style;
    uint8_t output_count;
    toy_output_kind_t kinds[MODEL_OUTPUTS];
} model_t;

#define V   TOY_OUT_VIBRATE
#define R   TOY_OUT_ROTATE
#define A   TOY_OUT_AIR
#define O   TOY_OUT_OSCILLATE

static const model_t models[] = {
    { "S",    "Lush",              STYLE_SINGLE,  1, { V } },
    { "AN",   "Lush Anal",         STYLE_SINGLE,  1, { V } },
    { "Z",    "Hush",              STYLE_SINGLE,  1, { V } },
    { "L",    "Ambi",              STYLE_SINGLE,  1, { V } },
    { "ZA",   "Synth",             STYLE_SINGLE,  1, { V } },
    { "W",    "Domi",              STYLE_SINGLE,  1, { V } },
    { "O",    "Osci",              STYLE_SINGLE,  1, { V } },
    { "V",    "Mission",           STYLE_SINGLE,  1, { V } },
    { "CA",   "Mission 2",         STYLE_SINGLE,  1, { V } },
    { "X",    "Ferri",             STYLE_SINGLE,  1, { V } },
    { "R",    "Diamo",             STYLE_SINGLE,  1, { V } },
    { "ED",   "Gush",              STYLE_SINGLE,  1, { V } },
    { "EZ",   "Gush 2",            STYLE_SINGLE,  1, { V } },
    { "T",    "Calor",             STYLE_SINGLE,  1, { V } },
    { "Q",    "Tenera",            STYLE_SINGLE,  1, { V } },
    { "SD",   "Vulse",             STYLE_SINGLE,  1, { V } },
    { "EI",   "Flexer",            STYLE_SINGLE,  1, { V } },   // older firmware
    { "ToyS", "Dolp",              STYLE_SINGLE,  1, { V } },
    { "QB",   "Fizz",              STYLE_SINGLE,  1, { V } },
    { "F",    "Sex Machine",       STYLE_SINGLE,  1, { O } },
    { "FS",   "Mini Sex Machine",  STYLE_SINGLE,  1, { O } },
    { "P",    "Edge",              STYLE_DUAL,    2, { V, V } },
    { "J",    "Dolce",             STYLE_DUAL,    2, { V, V } },
    { "OC",   "Osci 3",            STYLE_DUAL,    2, { V, V } },
    { "EB",   "Hyphy",             STYLE_DUAL,    2, { V, V } },
    { "N",    "Gemini",            STYLE_DUAL,    2, { V, V } },
    { "EA",   "Gravity",           STYLE_DUAL,    2, { V, O } },
    { "WD",   "Spinel",            STYLE_DUAL,    2, { V, O } },
    { "B",    "Max",               STYLE_MAX,     2, { V, A } },
    { "A",    "Nora",              STYLE_ROTATE,  2, { V, R } },
    { "C",    "Nora",              STYLE_ROTATE,  2, { V, R } },
    { "CB",   "Velvo",             STYLE_ROTATE,  2, { V, R } },
    { "EL",   "Ridge",             STYLE_ROTATE,  2, { V, R } },
    { "U",    "Lapis",             STYLE_MULTI,   3, { V, V, V } },
    { "EI3",  "Flexer",            STYLE_MULTI,   3, { V, V, R } },   // firmware 3 and later
    { "H",    "Solace",            STYLE_STROKER, 1, { O } },
    { "BA",   "Solace Pro",        STYLE_STROKER, 1, { O } },
};

#undef V
#undef R
#undef A
#undef O

// For a model that isn't in the list
static const model_t unknown_model = { "", NULL, STYLE_SINGLE, 1, { TOY_OUT_VIBRATE } };

/* What's kept for each toy, in its toy_link_t's state */
typedef struct
{
    const model_t *model;           // NULL until it's known
    uint8_t sent[MODEL_OUTPUTS];
    uint8_t identify_tries;
    bool battery_asked;
    uint32_t last_send_ms;
    uint32_t last_identify_ms;
    uint32_t last_battery_ms;
    char reply[32];
    uint8_t reply_len;
} lovense_t;

_Static_assert(sizeof(lovense_t) <= TOY_DRIVER_STATE, "lovense_t must fit in a toy's driver state");

/* XXXX00?1-002?-4bd4-bbd5-a6920e4c5653 (the usual one), the Nordic UART
 * service, or 0000fff0 on some older devices. */
static bool lovense_service(const uint8_t u[16])
{
    static const uint8_t lovense_tail[10] = { 0x4b, 0xd4, 0xbb, 0xd5, 0xa6, 0x92, 0x0e, 0x4c, 0x56, 0x53 };
    static const uint8_t nordic_uart[16] = { 0x6e, 0x40, 0x00, 0x01, 0xb5, 0xa3, 0xf3, 0x93,
                                             0xe0, 0xa9, 0xe5, 0x0e, 0x24, 0xdc, 0xca, 0x9e };
    static const uint8_t fff0[16] = { 0x00, 0x00, 0xff, 0xf0, 0x00, 0x00, 0x10, 0x00,
                                      0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb };

    if (memcmp(u + 6, lovense_tail, sizeof(lovense_tail)) == 0
        && u[2] == 0x00 && (u[3] & 0x0F) == 0x01
        && u[4] == 0x00 && (u[5] == 0x23 || u[5] == 0x24))
    {
        return true;
    }
    return memcmp(u, nordic_uart, 16) == 0 || memcmp(u, fff0, 16) == 0;
}

static bool lovense_claims(const char *name)
{
    return strncmp(name, "LVS-", 4) == 0 || strncmp(name, "LOVE-", 5) == 0;
}

static const model_t *find_model(const char *id)
{
    for (size_t i = 0; i < sizeof(models) / sizeof(models[0]); i++)
    {
        if (strcmp(models[i].id, id) == 0)
        {
            return &models[i];
        }
    }
    return NULL;
}

/* Take on a model's outputs. */
static void set_model(toy_link_t *t, const model_t *m)
{
    lovense_t *l = t->state;
    l->model = m;
    t->toy->model = m->model != NULL ? m->model : t->toy->name;
    t->toy->output_count = m->output_count;
    for (uint8_t i = 0; i < m->output_count; i++)
    {
        t->toy->outputs[i].kind = m->kinds[i];
        t->toy->outputs[i].max = m->kinds[i] == TOY_OUT_AIR ? 3 : 20;
        l->sent[i] = 0;
    }
}

/* When DeviceType gets no answer: names like "LVS-Z36" carry the model's
 * letters before the digits. */
static const model_t *model_from_name(const char *name)
{
    const char *p = strchr(name, '-');
    if (p == NULL)
    {
        return NULL;
    }
    p++;
    char id[8];
    size_t n = 0;
    while (p[n] >= 'A' && p[n] <= 'Z' && n < sizeof(id) - 1)
    {
        id[n] = p[n];
        n++;
    }
    if (n == 0 || p[n] < '0' || p[n] > '9')
    {
        return NULL;
    }
    id[n] = '\0';
    return find_model(id);
}

/* ----- Sending ----- */

static bool send(toy_link_t *t, const char *command)
{
    if (!rcat_hal_ble_send(t->link, command, strlen(command)))
    {
        return false;
    }
    ((lovense_t *)t->state)->last_send_ms = t->now;
    return true;
}

/* The command that sets output i to level, for this model. */
static void output_command(const toy_link_t *t, const uint8_t *levels, uint8_t i, char *out, size_t len)
{
    const model_t *m = ((const lovense_t *)t->state)->model;
    uint8_t level = levels[i];
    switch (m->style)
    {
    case STYLE_DUAL:
        snprintf(out, len, "Vibrate%u:%u;", i + 1, level);
        break;
    case STYLE_MAX:
        snprintf(out, len, i == 0 ? "Vibrate:%u;" : "Air:Level:%u;", level);
        break;
    case STYLE_ROTATE:
        snprintf(out, len, i == 0 ? "Vibrate:%u;" : "Rotate:%u;", level);
        break;
    case STYLE_MULTI:
        snprintf(out, len, "Mply:%u:%u:%u;", levels[0], levels[1], levels[2]);
        break;
    case STYLE_STROKER:
        // The Solace has to be told the stroke range is 0 to stop it.
        snprintf(out, len, "Mply:%u:%u;", level, (level == 0 && strcmp(m->id, "H") == 0) ? 0 : 20);
        break;
    default:
        snprintf(out, len, "Vibrate:%u;", level);
        break;
    }
}

/* Send every level that has changed, one after another. */
static void send_levels(toy_link_t *t)
{
    lovense_t *l = t->state;
    uint8_t levels[MODEL_OUTPUTS] = { 0 };
    for (uint8_t i = 0; i < l->model->output_count; i++)
    {
        levels[i] = t->toy->outputs[i].level;
    }
    for (uint8_t i = 0; i < l->model->output_count; i++)
    {
        if (levels[i] == l->sent[i])
        {
            continue;
        }
        char command[24];
        output_command(t, levels, i, command, sizeof(command));
        if (!send(t, command))
        {
            continue;
        }
        if (l->model->style == STYLE_MULTI)
        {
            memcpy(l->sent, levels, sizeof(l->sent));     // one command sets them all
            break;
        }
        l->sent[i] = levels[i];
    }
}

static void lovense_stop(toy_link_t *t)
{
    lovense_t *l = t->state;
    if (l->model == NULL)
    {
        return;
    }
    static const uint8_t zero[MODEL_OUTPUTS] = { 0 };
    for (uint8_t i = 0; i < l->model->output_count; i++)
    {
        char command[24];
        output_command(t, zero, i, command, sizeof(command));
        send(t, command);
        l->sent[i] = 0;
        if (l->model->style == STYLE_MULTI)
        {
            break;      // one command does them all
        }
    }
}

/* ----- Replies ----- */

static void handle_reply(toy_link_t *t, const char *text)
{
    lovense_t *l = t->state;

    // DeviceType: "<model>:<firmware>:<address>"
    const char *colon = strchr(text, ':');
    if (colon != NULL && l->model == NULL && text[0] >= 'A' && text[0] <= 'Z')
    {
        char id[8];
        size_t n = (size_t)(colon - text);
        if (n < sizeof(id) - 1)
        {
            memcpy(id, text, n);
            id[n] = '\0';
            if (strcmp(id, "EI") == 0 && atoi(colon + 1) >= 3)
            {
                strcpy(id, "EI3");
            }
            const model_t *m = find_model(id);
            set_model(t, m != NULL ? m : &unknown_model);
        }
        return;
    }

    // Battery: a number, perhaps after an 's'
    const char *p = text[0] == 's' ? text + 1 : text;
    if (*p == '\0')
    {
        return;
    }
    int value = 0;
    for (; *p != '\0'; p++)
    {
        if (*p < '0' || *p > '9')
        {
            return;     // "OK", "ERR" and the like
        }
        value = value * 10 + (*p - '0');
    }
    if (l->battery_asked && value <= 100)
    {
        t->toy->battery = value;
        l->battery_asked = false;
    }
}

static void read_replies(toy_link_t *t)
{
    lovense_t *l = t->state;
    char data[64];
    size_t n;
    while ((n = rcat_hal_ble_receive(t->link, data, sizeof(data))) > 0)
    {
        for (size_t i = 0; i < n; i++)
        {
            if (data[i] == ';')
            {
                l->reply[l->reply_len] = '\0';
                handle_reply(t, l->reply);
                l->reply_len = 0;
            }
            else if (l->reply_len < sizeof(l->reply) - 1)
            {
                l->reply[l->reply_len++] = data[i];
            }
        }
    }
}

/* ----- Running it ----- */

static bool lovense_identify(toy_link_t *t)
{
    lovense_t *l = t->state;
    read_replies(t);
    if (l->model == NULL && t->now - l->last_identify_ms >= IDENTIFY_EVERY_MS)
    {
        if (l->identify_tries >= IDENTIFY_TRIES)
        {
            const model_t *m = model_from_name(t->toy->name);
            set_model(t, m != NULL ? m : &unknown_model);
        }
        else if (send(t, "DeviceType;"))
        {
            l->identify_tries++;
            l->last_identify_ms = t->now;
        }
    }
    if (l->model == NULL)
    {
        return false;
    }
    l->last_battery_ms = t->now - BATTERY_EVERY_MS;     // ask straight away
    return true;
}

static void lovense_poll(toy_link_t *t)
{
    lovense_t *l = t->state;
    read_replies(t);
    if (t->now - l->last_send_ms < SEND_GAP_MS)
    {
        return;
    }
    // The battery first when it's due, as a pattern keeps the levels
    // changing.
    if (t->now - l->last_battery_ms >= BATTERY_EVERY_MS)
    {
        if (send(t, "Battery;"))
        {
            l->battery_asked = true;
            l->last_battery_ms = t->now;
        }
        return;
    }
    send_levels(t);
}

const toy_driver_t toy_lovense = {
    .maker = "Lovense",
    .claims = lovense_claims,
    .service = lovense_service,
    .identify = lovense_identify,
    .poll = lovense_poll,
    .stop = lovense_stop,
};
