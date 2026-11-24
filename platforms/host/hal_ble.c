/*
 * The virtual unit's Bluetooth central (hal.h), which only finds virtual
 * Lovense toys (toys.h): the computer's own Bluetooth isn't used yet. Each
 * toy advertises as a real one does ("LVS-S01"), offers Lovense's service,
 * and answers its text commands, as toy_lovense.c expects:
 *
 *   DeviceType;        "S:11:C0FFEE000101;"
 *   Battery;           "85;"
 *   Vibrate:N;         every vibrator; Vibrate1:N; Vibrate2:N; one each
 *   Rotate:N;  Air:Level:N;  Mply:a:b:c;
 *
 * The talk button (a HID remote) isn't there.
 */

#include <ctype.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "hal.h"
#include "host.h"
#include "toys.h"

#define CONNECT_MS      400         // as long as connecting to a real one takes, roughly
#define FOUND_AFTER_MS  300         // and a scan to find it
#define RX_MAX          256         // replies waiting, per link, as the board keeps
#define FIRMWARE        "11"
#define DRAIN_MS        60000       // a percent of battery gone this often, while it's running

typedef struct
{
    const char *id;                 // what DeviceType says, and in its name
    const char *name;
    uint8_t motor_count;
    const char *motors[TOY_MAX_MOTORS];
} model_t;

// A few of each kind toy_lovense.c knows: its table has them all
static const model_t models[] = {
    { "S",  "Lush",    1, { "Vibrate" } },
    { "P",  "Edge",    2, { "Vibrate", "Vibrate" } },
    { "A",  "Nora",    2, { "Vibrate", "Rotate" } },
    { "B",  "Max",     2, { "Vibrate", "Air" } },
    { "EA", "Gravity", 2, { "Vibrate", "Thrust" } },
    { "U",  "Lapis",   3, { "Vibrate", "Vibrate", "Vibrate" } },
    { "H",  "Solace",  1, { "Thrust" } },
};
#define MODEL_COUNT (sizeof(models) / sizeof(models[0]))

typedef struct
{
    int id;                         // for links to know it by, as the list moves up
    const model_t *model;
    uint8_t addr[6];
    char name[16];
    uint8_t levels[TOY_MAX_MOTORS];
    uint8_t battery;
    uint32_t drained_ms;            // running time towards the next percent
    uint32_t last_tick;
    int link;                       // connecting or connected on, or -1
    bool found;                     // in this scan's results
    char last[24];
    uint32_t last_ms;
} toy_t;

typedef struct
{
    bool used;
    int toy;                        // the toy's id
    uint32_t started;
    bool connected;
    uint8_t rx[RX_MAX];
    size_t rx_len;
} link_t;

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static toy_t toys[TOY_MAX];
static size_t count;
static int next_id = 1;
static link_t links[RCAT_HAL_BLE_MAX_LINKS];
static bool scanning;
static uint32_t scan_started;
static uint32_t changes;

static toy_t *toy_by_id(int id)
{
    for (size_t i = 0; i < count; i++)
    {
        if (toys[i].id == id)
        {
            return &toys[i];
        }
    }
    return NULL;
}

static uint8_t motor_max(const toy_t *t, int m)
{
    return strcmp(t->model->motors[m], "Air") == 0 ? 3 : 20;
}

/* The battery runs down while it's running. Under the lock. */
static void drain(toy_t *t)
{
    uint32_t now = rcat_hal_millis();
    uint32_t dt = now - t->last_tick;
    t->last_tick = now;
    bool running = false;
    for (int m = 0; m < t->model->motor_count; m++)
    {
        running |= t->levels[m] > 0;
    }
    if (!running)
    {
        return;
    }
    t->drained_ms += dt;
    while (t->drained_ms >= DRAIN_MS)
    {
        t->drained_ms -= DRAIN_MS;
        if (t->battery > 1)
        {
            t->battery--;
            changes++;
        }
    }
}

/*
 * The toys
 */

size_t toy_model_count(void)
{
    return MODEL_COUNT;
}

const char *toy_model_name(size_t model)
{
    return model < MODEL_COUNT ? models[model].name : NULL;
}

bool toy_add(size_t model)
{
    if (model >= MODEL_COUNT)
    {
        return false;
    }
    pthread_mutex_lock(&lock);
    bool ok = count < TOY_MAX;
    if (ok)
    {
        toy_t *t = &toys[count++];
        memset(t, 0, sizeof(*t));
        t->id = next_id++;
        t->model = &models[model];
        // Made up, but the same from one run to the next
        const uint8_t addr[6] = { 0xC0, 0xFF, 0xEE, 0x00, (uint8_t)host_options.unit, (uint8_t)t->id };
        memcpy(t->addr, addr, 6);
        snprintf(t->name, sizeof(t->name), "LVS-%s%02d", t->model->id, t->id % 100);
        t->battery = 100 - (uint8_t)(rcat_hal_random() % 30);
        t->last_tick = rcat_hal_millis();
        t->link = -1;
        changes++;
        printf("Virtual toy %s (%s) switched on\n", t->name, t->model->name);
    }
    pthread_mutex_unlock(&lock);
    return ok;
}

bool toy_add_named(const char *model)
{
    for (size_t i = 0; i < MODEL_COUNT; i++)
    {
        if (strcasecmp(models[i].name, model) == 0)
        {
            return toy_add(i);
        }
    }
    return false;
}

void toy_remove(size_t index)
{
    pthread_mutex_lock(&lock);
    if (index < count)
    {
        toy_t *t = &toys[index];
        printf("Virtual toy %s switched off\n", t->name);
        if (t->link >= 0)
        {
            links[t->link].used = false;    // the connection drops: the link's idle
        }
        memmove(&toys[index], &toys[index + 1], (count - index - 1) * sizeof(toy_t));
        count--;
        changes++;
    }
    pthread_mutex_unlock(&lock);
}

size_t toy_count(void)
{
    pthread_mutex_lock(&lock);
    size_t n = count;
    pthread_mutex_unlock(&lock);
    return n;
}

bool toy_get(size_t index, toy_view_t *view)
{
    pthread_mutex_lock(&lock);
    bool ok = index < count;
    if (ok)
    {
        toy_t *t = &toys[index];
        drain(t);
        memset(view, 0, sizeof(*view));
        snprintf(view->name, sizeof(view->name), "%s", t->name);
        view->model = t->model->name;
        view->state = t->link < 0 ? TOY_WAITING : links[t->link].connected ? TOY_CONNECTED : TOY_CONNECTING;
        view->battery = t->battery;
        view->motor_count = t->model->motor_count;
        for (int m = 0; m < t->model->motor_count; m++)
        {
            view->motors[m].name = t->model->motors[m];
            view->motors[m].max = motor_max(t, m);
            view->motors[m].level = t->levels[m];
        }
        snprintf(view->last, sizeof(view->last), "%s", t->last);
        view->last_ms = t->last_ms;
    }
    pthread_mutex_unlock(&lock);
    return ok;
}

uint32_t toy_changes(void)
{
    pthread_mutex_lock(&lock);
    uint32_t n = changes;
    pthread_mutex_unlock(&lock);
    return n;
}

/*
 * Lovense's commands
 */

static void reply(link_t *l, const char *text)
{
    size_t n = strlen(text);
    if (l->rx_len + n <= RX_MAX)
    {
        memcpy(l->rx + l->rx_len, text, n);
        l->rx_len += n;
    }
}

static void set_level(toy_t *t, int m, long level)
{
    if (m < 0 || m >= t->model->motor_count)
    {
        return;
    }
    uint8_t max = motor_max(t, m);
    t->levels[m] = level < 0 ? 0 : level > max ? max : (uint8_t)level;
}

static int first_motor(const toy_t *t, const char *kind)
{
    for (int m = 0; m < t->model->motor_count; m++)
    {
        if (strcmp(t->model->motors[m], kind) == 0)
        {
            return m;
        }
    }
    return -1;
}

/* One command, without its ';'. Under the lock. */
static void command(toy_t *t, link_t *l, const char *cmd)
{
    drain(t);
    snprintf(t->last, sizeof(t->last), "%.22s;", cmd);
    t->last_ms = rcat_hal_millis();
    changes++;

    char text[16];
    if (strcmp(cmd, "DeviceType") == 0)
    {
        char answer[48];
        snprintf(answer, sizeof(answer), "%s:%s:%02X%02X%02X%02X%02X%02X;", t->model->id, FIRMWARE, t->addr[0],
                 t->addr[1], t->addr[2], t->addr[3], t->addr[4], t->addr[5]);
        reply(l, answer);
        return;
    }
    if (strcmp(cmd, "Battery") == 0)
    {
        snprintf(text, sizeof(text), "%u;", t->battery);
        reply(l, text);
        return;
    }
    const char *colon = strrchr(cmd, ':');
    long level = colon != NULL ? strtol(colon + 1, NULL, 10) : 0;
    if (strncmp(cmd, "Vibrate:", 8) == 0)
    {
        for (int m = 0; m < t->model->motor_count; m++)
        {
            if (strcmp(t->model->motors[m], "Vibrate") == 0)
            {
                set_level(t, m, level);
            }
        }
    }
    else if (strncmp(cmd, "Vibrate", 7) == 0 && isdigit((unsigned char)cmd[7]) && cmd[8] == ':')
    {
        set_level(t, cmd[7] - '1', level);
    }
    else if (strncmp(cmd, "Rotate:", 7) == 0)
    {
        set_level(t, first_motor(t, "Rotate"), level);
    }
    else if (strncmp(cmd, "Air:Level:", 10) == 0)
    {
        set_level(t, first_motor(t, "Air"), level);
    }
    else if (strncmp(cmd, "Mply:", 5) == 0)
    {
        // One level for each motor, in order; a stroker's second is its range
        const char *p = cmd + 5;
        for (int m = 0; m < t->model->motor_count && *p != '\0'; m++)
        {
            set_level(t, m, strtol(p, NULL, 10));
            p = strchr(p, ':');
            p = p != NULL ? p + 1 : "";
        }
    }
    else
    {
        reply(l, "ERR;");
        return;
    }
    reply(l, "OK;");
}

/*
 * The HAL
 */

bool rcat_hal_ble_scan_start(void)
{
    pthread_mutex_lock(&lock);
    scanning = true;
    scan_started = rcat_hal_millis();
    for (size_t i = 0; i < count; i++)
    {
        toys[i].found = false;
    }
    pthread_mutex_unlock(&lock);
    return true;
}

void rcat_hal_ble_scan_stop(void)
{
    pthread_mutex_lock(&lock);
    scanning = false;
    pthread_mutex_unlock(&lock);
}

size_t rcat_hal_ble_scan_results(rcat_hal_ble_device_t *devices, size_t max)
{
    pthread_mutex_lock(&lock);
    // A toy's found once the scan's been going a moment, if it's advertising,
    // which it doesn't while it's connected
    if (scanning && rcat_hal_millis() - scan_started >= FOUND_AFTER_MS)
    {
        for (size_t i = 0; i < count; i++)
        {
            toys[i].found |= toys[i].link < 0;
        }
    }
    size_t n = 0;
    for (size_t i = 0; i < count && n < max; i++)
    {
        if (toys[i].found)
        {
            rcat_hal_ble_device_t *d = &devices[n++];
            memset(d, 0, sizeof(*d));
            memcpy(d->addr, toys[i].addr, 6);
            d->rssi = -50;
            snprintf(d->name, sizeof(d->name), "%s", toys[i].name);
        }
    }
    pthread_mutex_unlock(&lock);
    return n;
}

int rcat_hal_ble_connect(const rcat_hal_ble_device_t *device, rcat_hal_ble_service_match_t match)
{
    // Lovense's usual service, 5a300001-0023-4bd4-bbd5-a6920e4c5653
    static const uint8_t service[16] = { 0x5a, 0x30, 0x00, 0x01, 0x00, 0x23, 0x4b, 0xd4,
                                         0xbb, 0xd5, 0xa6, 0x92, 0x0e, 0x4c, 0x56, 0x53 };
    pthread_mutex_lock(&lock);
    int link = -1;
    toy_t *t = NULL;
    for (size_t i = 0; i < count; i++)
    {
        if (memcmp(toys[i].addr, device->addr, 6) == 0)
        {
            t = &toys[i];
        }
    }
    bool busy = false;
    for (int i = 0; i < RCAT_HAL_BLE_MAX_LINKS; i++)
    {
        busy |= links[i].used && !links[i].connected;
    }
    for (int i = 0; i < RCAT_HAL_BLE_MAX_LINKS && link < 0 && !busy; i++)
    {
        if (!links[i].used)
        {
            link = i;
        }
    }
    if (link >= 0)
    {
        // A toy that isn't there, or a service that won't do, fails like a
        // real connection: the link's idle again
        bool ok = t != NULL && t->link < 0 && match(service);
        links[link] = (link_t){ .used = ok, .toy = t != NULL ? t->id : 0, .started = rcat_hal_millis() };
        if (ok)
        {
            t->link = link;
            changes++;
        }
    }
    pthread_mutex_unlock(&lock);
    return link;
}

void rcat_hal_ble_disconnect(int link)
{
    if (link < 0 || link >= RCAT_HAL_BLE_MAX_LINKS)
    {
        return;
    }
    pthread_mutex_lock(&lock);
    if (links[link].used)
    {
        toy_t *t = toy_by_id(links[link].toy);
        if (t != NULL)
        {
            // A real one stops when it's let go
            drain(t);
            memset(t->levels, 0, sizeof(t->levels));
            t->link = -1;
        }
        links[link].used = false;
        changes++;
    }
    pthread_mutex_unlock(&lock);
}

rcat_hal_ble_state_t rcat_hal_ble_link_state(int link)
{
    if (link < 0 || link >= RCAT_HAL_BLE_MAX_LINKS)
    {
        return RCAT_HAL_BLE_IDLE;
    }
    pthread_mutex_lock(&lock);
    link_t *l = &links[link];
    if (l->used && !l->connected && rcat_hal_millis() - l->started >= CONNECT_MS)
    {
        l->connected = true;
        changes++;
    }
    rcat_hal_ble_state_t state = !l->used ? RCAT_HAL_BLE_IDLE
                                 : l->connected ? RCAT_HAL_BLE_CONNECTED : RCAT_HAL_BLE_CONNECTING;
    pthread_mutex_unlock(&lock);
    return state;
}

bool rcat_hal_ble_send(int link, const void *data, size_t len)
{
    if (link < 0 || link >= RCAT_HAL_BLE_MAX_LINKS)
    {
        return false;
    }
    pthread_mutex_lock(&lock);
    link_t *l = &links[link];
    toy_t *t = l->used && l->connected ? toy_by_id(l->toy) : NULL;
    if (t != NULL)
    {
        // Each command ends with ';', and a write may hold several
        char cmd[64];
        size_t n = 0;
        const char *p = data;
        for (size_t i = 0; i < len; i++)
        {
            if (p[i] == ';')
            {
                cmd[n] = '\0';
                command(t, l, cmd);
                n = 0;
            }
            else if (n < sizeof(cmd) - 1)
            {
                cmd[n++] = p[i];
            }
        }
    }
    pthread_mutex_unlock(&lock);
    return t != NULL;
}

size_t rcat_hal_ble_receive(int link, void *data, size_t max)
{
    if (link < 0 || link >= RCAT_HAL_BLE_MAX_LINKS)
    {
        return 0;
    }
    pthread_mutex_lock(&lock);
    link_t *l = &links[link];
    size_t n = l->rx_len < max ? l->rx_len : max;
    memcpy(data, l->rx, n);
    memmove(l->rx, l->rx + n, l->rx_len - n);
    l->rx_len -= n;
    pthread_mutex_unlock(&lock);
    return n;
}

/* The talk button: not on a computer */

bool rcat_hal_ble_button_find(void)
{
    return false;
}

void rcat_hal_ble_button_find_stop(void)
{
}

size_t rcat_hal_ble_button_found(rcat_hal_ble_device_t *devices, size_t max)
{
    return 0;
}

bool rcat_hal_ble_button_use(const rcat_hal_ble_device_t *device, bool connect_now)
{
    return false;
}

void rcat_hal_ble_button_stop(void)
{
}

void rcat_hal_ble_button_forget(const rcat_hal_ble_device_t *device)
{
}

rcat_hal_ble_button_state_t rcat_hal_ble_button_state(void)
{
    return RCAT_HAL_BLE_BUTTON_OFF;
}

uint32_t rcat_hal_ble_button_held(void)
{
    return 0;
}
