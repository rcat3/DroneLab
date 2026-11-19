/*
 * Commands from others in the comm channel (see others.h).
 *
 * Commands are done on the UI loop, as the features' own controls are. Those
 * heard over direct comms come from its task, through a small queue that
 * only it writes to, so nothing needs locking.
 */
#include "app/others.h"

#include <stdio.h>
#include <string.h>

#include "app/lovense.h"
#include "app/message.h"
#include "app/patterns.h"
#include "app/reactive.h"
#include "app/settings.h"
#include "hal.h"
#include "lvgl.h"
#include "ui/ui.h"

#define STORE_VERSION       2
#define SAVE_DELAY_MS       1000
#define QUEUE_LEN           8           // from direct comms, waiting for the UI loop
#define SEEN_MAX            16          // commands remembered, so each is only done once
#define HEADER_LEN          9           // version, sender's id, seq, who it's for, what to do
#define OP                  8           // where what to do is
#define LEVEL_TOP           20          // the levels commands give, as Lovense's patterns
#define TERMINAL_FEATURE    "Terminal"

// Each kind's list, as it's stored
typedef struct
{
    uint8_t via;
    uint8_t allowed;
    char name[COMM_NAME_MAX];
} stored_sender_t;

typedef struct
{
    uint8_t version;
    uint8_t accepting;      // others_permission_t (0 and 1, as it was before Accept, mean the same)
    uint8_t options;        // OTHERS_IGNORE_* (bit 0, unnamed messages hidden, is no more)
    uint8_t count;
    stored_sender_t senders[OTHERS_SENDERS_MAX];
} stored_t;

typedef struct
{
    stored_t list;
    bool unsaved;
    uint32_t changed_ms;
    char last_from[COMM_NAME_MAX];
    uint32_t last_ms;
} kind_t;

typedef struct
{
    char from[COMM_NAME_MAX];
    uint8_t len;
    uint8_t cmd[OTHERS_CMD_MAX];
} queued_t;

typedef struct
{
    uint32_t source;
    uint16_t seq;
    bool done;              // done, rather than refused: a copy by another way may be allowed
} seen_t;

static const char *const store_names[OTHERS_KIND_COUNT] = { "oth_lovense", "oth_terminal" };

// Out of internal RAM, which WiFi and Bluetooth need: made by others_init()
static bool loaded;
static kind_t *kinds;                   // OTHERS_KIND_COUNT of them
static uint32_t changes;

static queued_t *queue;                 // QUEUE_LEN of them

static void load(void);
static volatile uint32_t queue_write;   // only direct comms' task moves it
static volatile uint32_t queue_read;    // only the UI loop moves it

#define MUTED_MAX           24
static char (*muted)[COMM_NAME_MAX];    // MUTED_MAX of them, made as the first come
static int muted_count;

static seen_t seen[SEEN_MAX];
static int seen_count;
static int seen_next;

void others_init(void)
{
    kinds = lv_malloc(OTHERS_KIND_COUNT * sizeof(kind_t));
    queue = lv_malloc(QUEUE_LEN * sizeof(queued_t));
    if (kinds == NULL || queue == NULL)
    {
        lv_free(kinds);
        lv_free(queue);
        kinds = NULL;
        queue = NULL;
        return;
    }
    memset(kinds, 0, OTHERS_KIND_COUNT * sizeof(kind_t));
    load();
}

static void load(void)
{
    if (loaded || kinds == NULL)
    {
        return;
    }
    loaded = true;
    for (int k = 0; k < OTHERS_KIND_COUNT; k++)
    {
        stored_t *list = &kinds[k].list;
        memset(list, 0, sizeof(*list));
        size_t n = rcat_hal_store_read(store_names[k], list, sizeof(*list));
        if (n < offsetof(stored_t, senders) || list->version != STORE_VERSION || list->count > OTHERS_SENDERS_MAX
            || n < offsetof(stored_t, senders) + list->count * sizeof(stored_sender_t))
        {
            memset(list, 0, sizeof(*list));
            list->version = STORE_VERSION;
            list->accepting = OTHERS_ASK;
            continue;
        }
        if (list->accepting > OTHERS_ACCEPT)
        {
            list->accepting = OTHERS_ASK;
        }
        list->options &= OTHERS_IGNORE_EVERYONE | OTHERS_IGNORE_CHANNEL;
        for (int i = 0; i < list->count; i++)
        {
            list->senders[i].name[COMM_NAME_MAX - 1] = '\0';
        }
    }
}

static void changed(kind_t *k)
{
    k->unsaved = true;
    k->changed_ms = rcat_hal_millis();
    changes++;
}

static int find(const stored_t *list, comm_transport_t via, const char *name)
{
    for (int i = 0; i < list->count; i++)
    {
        if (list->senders[i].via == (uint8_t)via && strcmp(list->senders[i].name, name) == 0)
        {
            return i;
        }
    }
    return -1;
}

/* Add someone new, not allowed. When the list's full, the first who isn't
 * allowed makes room; if they all are, the new one isn't added. */
static int add(kind_t *k, comm_transport_t via, const char *name)
{
    stored_t *list = &k->list;
    if (list->count == OTHERS_SENDERS_MAX)
    {
        int out = -1;
        for (int i = 0; i < list->count && out < 0; i++)
        {
            if (!list->senders[i].allowed)
            {
                out = i;
            }
        }
        if (out < 0)
        {
            return -1;
        }
        memmove(&list->senders[out], &list->senders[out + 1],
                (size_t)(list->count - out - 1) * sizeof(stored_sender_t));
        list->count--;
    }
    stored_sender_t *s = &list->senders[list->count];
    memset(s, 0, sizeof(*s));
    s->via = (uint8_t)via;
    snprintf(s->name, sizeof(s->name), "%s", name);
    changed(k);
    return list->count++;
}

/* True if this command's been done already. */
// A command by its sender's id and seq: the one seen before, or a new one
static seen_t *seen_entry(uint32_t source, uint16_t seq, bool *again)
{
    for (int i = 0; i < seen_count; i++)
    {
        if (seen[i].source == source && seen[i].seq == seq)
        {
            *again = true;
            return &seen[i];
        }
    }
    seen_t *s = &seen[seen_next];
    *s = (seen_t){ source, seq, false };
    seen_next = (seen_next + 1) % SEEN_MAX;
    if (seen_count < SEEN_MAX)
    {
        seen_count++;
    }
    *again = false;
    return s;
}

/* ----- What they do ----- */

static bool connected(size_t slot)
{
    const lovense_device_t *d = lovense_device(slot);
    return d != NULL && d->state == LOVENSE_CONNECTED;
}

static void set_levels(uint8_t kind, uint8_t level)
{
    if (level > LEVEL_TOP)
    {
        level = LEVEL_TOP;
    }
    for (size_t slot = 0; slot < LOVENSE_MAX_DEVICES; slot++)
    {
        if (!connected(slot))
        {
            continue;
        }
        const lovense_device_t *d = lovense_device(slot);
        for (uint8_t m = 0; m < d->motor_count; m++)
        {
            if (kind == OTHERS_ALL_MOTORS || d->motors[m].kind == (lovense_motor_kind_t)kind)
            {
                lovense_set_level(slot, m, (uint8_t)((level * d->motors[m].max + LEVEL_TOP / 2) / LEVEL_TOP));
            }
        }
    }
}

static void play(const uint8_t *name, size_t len)
{
    int pattern = -1;
    if (len > 0)
    {
        for (size_t i = 0; i < patterns_count() && pattern < 0; i++)
        {
            const char *p = patterns_name(i);
            if (strlen(p) == len && memcmp(p, name, len) == 0)
            {
                pattern = (int)i;
            }
        }
        if (pattern < 0)
        {
            return;     // not one this board has
        }
    }
    for (size_t slot = 0; slot < LOVENSE_MAX_DEVICES; slot++)
    {
        if (connected(slot))
        {
            lovense_play(slot, pattern);
        }
    }
}

/* As the Lovense feature's React page, or the remote's. */
static void react(uint8_t mode)
{
    if (mode >= REACTIVE_COUNT || !reactive_available((reactive_mode_t)mode))
    {
        mode = REACTIVE_OFF;
    }
    reactive_set_mode((reactive_mode_t)mode);
    lovense_set_reactive(mode != REACTIVE_OFF);
}

/* On the Terminal, as its own controls would put it: as it is, added on a
 * line of its own or in place of what's there, at its letter size, and on
 * screen if they want it to be. */
static void show_message(uint8_t flags, uint8_t scale, const uint8_t *text, size_t len)
{
    char line[OTHERS_CMD_MAX + 2];
    bool append = (flags & OTHERS_MESSAGE_APPEND) != 0;
    bool first = !append || message_text()[0] == '\0';
    int n = snprintf(line, sizeof(line), "%s%.*s", first ? "" : "\n", (int)len, (const char *)text);
    if (n < 0)
    {
        return;
    }
    if (scale <= 6)
    {
        settings_set_terminal_size(scale);   // as the remote's letter size does
    }
    message_set(line, (size_t)n < sizeof(line) ? (size_t)n : sizeof(line) - 1, append);
    if (flags & OTHERS_MESSAGE_SHOW)
    {
        for (size_t f = 0; f < ui_feature_count(); f++)
        {
            if (strcmp(ui_feature_name(f), TERMINAL_FEATURE) == 0)
            {
                ui_show(f, 0);
            }
        }
    }
}

/* Which kind a command is: OTHERS_KIND_COUNT for a text, or -1 if it
 * isn't one. */
static int kind_of(const uint8_t *cmd, size_t len)
{
    switch (cmd[OP])
    {
    case OTHERS_STOP:
    case OTHERS_PATTERN:
        return OTHERS_LOVENSE;
    case OTHERS_LEVEL:
    case OTHERS_SPEED:
        return len >= HEADER_LEN + 2 ? OTHERS_LOVENSE : -1;
    case OTHERS_REACT:
        return len >= HEADER_LEN + 1 ? OTHERS_LOVENSE : -1;
    case OTHERS_MESSAGE:
        return len > HEADER_LEN + 2 ? OTHERS_TERMINAL : -1;
    case OTHERS_CLEAR:
        return OTHERS_TERMINAL;
    case OTHERS_TEXT:
        return len > HEADER_LEN ? OTHERS_KIND_COUNT : -1;
    default:
        return -1;
    }
}

/* Do it. */
static void run(const uint8_t *cmd, size_t len)
{
    const uint8_t *arg = cmd + HEADER_LEN;
    switch (cmd[OP])
    {
    case OTHERS_STOP:
        lovense_stop_all();
        reactive_set_mode(REACTIVE_OFF);
        break;
    case OTHERS_LEVEL:
        set_levels(arg[0], arg[1]);
        break;
    case OTHERS_PATTERN:
        play(arg, len - HEADER_LEN);
        break;
    case OTHERS_SPEED:
    {
        uint16_t speed = (uint16_t)(arg[0] | (arg[1] << 8));
        lovense_set_speed(speed < 25 ? 25 : speed > 300 ? 300 : speed);
        break;
    }
    case OTHERS_REACT:
        react(arg[0]);
        break;
    case OTHERS_MESSAGE:
        show_message(arg[0], arg[1], arg + 2, len - HEADER_LEN - 2);
        break;
    case OTHERS_CLEAR:
        message_clear();
        break;
    }
}

/* ----- Taking them ----- */

static bool is_muted(const char *from)
{
    for (int i = 0; i < muted_count; i++)
    {
        if (strcmp(muted[i], from) == 0)
        {
            return true;
        }
    }
    return false;
}

void others_set_muted(bool first, const char *names, size_t len)
{
    if (muted == NULL)
    {
        muted = lv_malloc(MUTED_MAX * COMM_NAME_MAX);
        if (muted == NULL)
        {
            return;
        }
    }
    if (first)
    {
        muted_count = 0;
    }
    size_t at = 0;
    while (at < len && muted_count < MUTED_MAX)
    {
        const char *name = names + at;
        size_t n = strnlen(name, len - at);
        if (n > 0 && n < COMM_NAME_MAX)
        {
            memcpy(muted[muted_count], name, n);
            muted[muted_count++][n] = '\0';
        }
        at += n + 1;
    }
}

void others_receive(comm_transport_t via, const char *from, const uint8_t *cmd, size_t len)
{
    if (kinds == NULL || from == NULL || from[0] == '\0' || len < HEADER_LEN || len > OTHERS_CMD_MAX || cmd[0] != OTHERS_VERSION)
    {
        return;
    }
    int which = kind_of(cmd, len);
    if (which < 0)
    {
        return;
    }
    // Once, however many times it comes, and by whichever way. Senders send
    // to someone both ways they can reach them, so one refused may come
    // again by a way that's allowed: that's tried, but one done isn't again.
    uint32_t source = cmd[1] | (cmd[2] << 8) | (cmd[3] << 16) | ((uint32_t)cmd[4] << 24);
    uint16_t seq = (uint16_t)(cmd[5] | (cmd[6] << 8));
    bool again;
    seen_t *seen_as = seen_entry(source, seq, &again);
    if (again && (seen_as->done || which == OTHERS_KIND_COUNT))
    {
        return;
    }
    uint8_t scope = cmd[7];
    if (which == OTHERS_KIND_COUNT)
    {
        // A text: for the app, whoever it's from
        comm_heard_to_phone(via, from, COMM_HEARD_TEXT, scope, true, cmd + HEADER_LEN, len - HEADER_LEN);
        return;
    }
    kind_t *k = &kinds[which];
    comm_heard_t heard = which == OTHERS_LOVENSE ? COMM_HEARD_LOVENSE : COMM_HEARD_TERMINAL;
    bool done = false;
    // To everyone nearby, if it's to the channel in the open direct group
    bool open = via == COMM_TALK_DIRECT && !settings_get()->direct_keyed;
    bool everyone = scope == OTHERS_SCOPE_EVERYONE || (scope == OTHERS_SCOPE_CHANNEL && open);
    bool ignored = is_muted(from) || (everyone && (k->list.options & OTHERS_IGNORE_EVERYONE))
                   || (scope == OTHERS_SCOPE_CHANNEL && (k->list.options & OTHERS_IGNORE_CHANNEL));
    if (k->list.accepting != OTHERS_OFF && !ignored)
    {
        bool anyone = k->list.accepting == OTHERS_ACCEPT;
        int i = find(&k->list, via, from);
        if (i < 0)
        {
            i = add(k, via, from);  // listed either way, to say who's been sending
            printf("others: %s commands from %s (%s), %s\n", which == OTHERS_LOVENSE ? "Lovense" : "Terminal", from,
                   via == COMM_TALK_DIRECT ? "direct" : "server", anyone ? "accepted" : "not allowed yet");
        }
        done = anyone || (i >= 0 && k->list.senders[i].allowed);
    }
    if (!done && again)
    {
        return;     // refused again: the app's been told
    }
    if (done)
    {
        seen_as->done = true;
        run(cmd, len);
        snprintf(k->last_from, sizeof(k->last_from), "%s", from);
        k->last_ms = rcat_hal_millis();
        changes++;
    }
    // What it was, from what to do on, for the app to say
    comm_heard_to_phone(via, from, heard, scope, done, cmd + OP, len - OP);
}

void others_queue(const char *from, const uint8_t *cmd, size_t len)
{
    uint32_t w = queue_write;
    if (queue == NULL || w - __atomic_load_n(&queue_read, __ATOMIC_ACQUIRE) >= QUEUE_LEN || len > OTHERS_CMD_MAX)
    {
        return;     // full: the sender sends each more than once
    }
    queued_t *q = &queue[w % QUEUE_LEN];
    snprintf(q->from, sizeof(q->from), "%s", from);
    q->len = (uint8_t)len;
    memcpy(q->cmd, cmd, len);
    __atomic_store_n(&queue_write, w + 1, __ATOMIC_RELEASE);
}

/* ----- The lists ----- */

others_permission_t others_permission(others_kind_t kind)
{
    return kinds != NULL && kind < OTHERS_KIND_COUNT ? (others_permission_t)kinds[kind].list.accepting : OTHERS_OFF;
}

void others_set_permission(others_kind_t kind, others_permission_t permission)
{
    if (kinds != NULL && kind < OTHERS_KIND_COUNT && permission <= OTHERS_ACCEPT &&
        kinds[kind].list.accepting != permission)
    {
        kinds[kind].list.accepting = (uint8_t)permission;
        changed(&kinds[kind]);
    }
}

uint8_t others_ignoring(others_kind_t kind)
{
    return kinds != NULL && kind < OTHERS_KIND_COUNT ? kinds[kind].list.options : 0;
}

void others_set_ignoring(others_kind_t kind, uint8_t ignore)
{
    ignore &= OTHERS_IGNORE_EVERYONE | OTHERS_IGNORE_CHANNEL;
    if (kinds != NULL && kind < OTHERS_KIND_COUNT && kinds[kind].list.options != ignore)
    {
        kinds[kind].list.options = ignore;
        changed(&kinds[kind]);
    }
}

bool others_accepting(others_kind_t kind)
{
    return others_permission(kind) != OTHERS_OFF;
}

void others_set_accepting(others_kind_t kind, bool on)
{
    if (on != others_accepting(kind))
    {
        others_set_permission(kind, on ? OTHERS_ASK : OTHERS_OFF);
    }
}

int others_senders(others_kind_t kind, others_sender_t *out, int max)
{
    if (kinds == NULL || kind >= OTHERS_KIND_COUNT)
    {
        return 0;
    }
    const stored_t *list = &kinds[kind].list;
    for (int n = 0; n < list->count && n < max; n++)
    {
        snprintf(out[n].name, sizeof(out[n].name), "%s", list->senders[n].name);
        out[n].via = (comm_transport_t)list->senders[n].via;
        out[n].allowed = list->senders[n].allowed != 0;
    }
    return list->count;
}

void others_allow(others_kind_t kind, comm_transport_t via, const char *name, bool allow)
{
    if (kinds == NULL || kind >= OTHERS_KIND_COUNT)
    {
        return;
    }
    kind_t *k = &kinds[kind];
    int i = find(&k->list, via, name);
    if (i >= 0 && k->list.senders[i].allowed != allow)
    {
        k->list.senders[i].allowed = allow;
        changed(k);
    }
}

void others_forget(others_kind_t kind, comm_transport_t via, const char *name)
{
    if (kinds == NULL || kind >= OTHERS_KIND_COUNT)
    {
        return;
    }
    kind_t *k = &kinds[kind];
    int i = find(&k->list, via, name);
    if (i >= 0)
    {
        memmove(&k->list.senders[i], &k->list.senders[i + 1],
                (size_t)(k->list.count - i - 1) * sizeof(stored_sender_t));
        k->list.count--;
        changed(k);
    }
}

const char *others_last(others_kind_t kind, uint32_t now_ms, uint32_t *age_ms)
{
    if (kinds == NULL || kind >= OTHERS_KIND_COUNT || kinds[kind].last_from[0] == '\0')
    {
        return NULL;
    }
    *age_ms = now_ms - kinds[kind].last_ms;
    return kinds[kind].last_from;
}

uint32_t others_changes(void)
{
    return changes;
}

void others_poll(uint32_t now_ms)
{
    if (kinds == NULL)
    {
        return;
    }
    while (queue_read != __atomic_load_n(&queue_write, __ATOMIC_ACQUIRE))
    {
        queued_t *q = &queue[queue_read % QUEUE_LEN];
        others_receive(COMM_TALK_DIRECT, q->from, q->cmd, q->len);
        __atomic_store_n(&queue_read, queue_read + 1, __ATOMIC_RELEASE);
    }
    for (int i = 0; i < OTHERS_KIND_COUNT; i++)
    {
        kind_t *k = &kinds[i];
        if (k->unsaved && now_ms - k->changed_ms >= SAVE_DELAY_MS)
        {
            k->unsaved = false;
            size_t len = offsetof(stored_t, senders) + k->list.count * sizeof(stored_sender_t);
            if (!rcat_hal_store_write(store_names[i], &k->list, len))
            {
                printf("others: couldn't save who may send commands\n");
            }
        }
    }
}
