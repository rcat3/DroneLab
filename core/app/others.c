/*
 * Commands from others in the comm channel (see others.h).
 *
 * Commands are done on the UI loop, as the features' own controls are.
 * Those heard over direct comms come from its task, through a small queue
 * that only it writes to, to a task of their own that checks their
 * signatures (which takes tens of ms, too long to hold up the UI loop or
 * direct comms), and from there through another queue that only it writes
 * to, so nothing needs locking.
 */
#include "app/others.h"

#include <ctype.h>
#include <stdio.h>
#include <string.h>

#include "app/direct.h"
#include "app/lovense.h"
#include "app/message.h"
#include "app/patterns.h"
#include "app/reactive.h"
#include "app/settings.h"
#include "crypto/monocypher-ed25519.h"
#include "hal.h"
#include "lvgl.h"
#include "ui/ui.h"

#define STORE_NAME          "oth_people"
#define OWNER_STORE_NAME    "oth_owner"
#define STORE_VERSION       1
#define SAVE_DELAY_MS       1000
#define QUEUE_LEN           8           // from direct comms, waiting to be checked, and checked, waiting for the UI loop
#define KNOWN_GOOD          6           // commands checked lately, whose copies needn't be again
#define CHECKER_STACK       8192
#define CHECKER_IDLE_MS     10
#define SEEN_MAX            32          // commands remembered, so each is only done once
#define KEY_AT              1
#define COUNTER_AT          33
#define SCOPE_AT            39
#define OP                  OTHERS_HEADER_LEN   // where what to do is
#define LEVEL_TOP           20          // the levels commands give, as Lovense's patterns
#define TERMINAL_FEATURE    "Terminal"
#define MUTED_MAX           24

static const char signed_prefix[] = "dronelab-command\n";

// Someone in the list, as they're stored
typedef struct
{
    uint64_t counter;       // their last command's
    uint8_t key[OTHERS_KEY_LEN];
    char name[COMM_NAME_MAX];
    uint8_t sent;           // a bit for each kind they've sent
    uint8_t allowed;        // a bit for each kind they're allowed
    uint8_t clash;          // took the name of someone listed before them
    uint8_t spare[5];
} person_t;

typedef struct
{
    uint8_t version;
    uint8_t permission[OTHERS_KIND_COUNT];  // others_permission_t
    uint8_t options[OTHERS_KIND_COUNT];     // OTHERS_IGNORE_*
    uint8_t count;
    person_t people[OTHERS_PEOPLE_MAX];
} stored_t;

typedef struct
{
    char from[COMM_NAME_MAX];
    uint8_t len;
    uint8_t cmd[OTHERS_CMD_MAX];
} queued_t;

typedef struct
{
    uint8_t key[4];
    uint64_t counter;
    bool done;              // done, rather than refused: a copy by another way may be allowed
} seen_t;

// Out of internal RAM, which WiFi and Bluetooth need: made by others_init()
static stored_t *list;
static queued_t *queue;                 // QUEUE_LEN of them
static uint8_t (*muted)[OTHERS_ID_LEN]; // MUTED_MAX of them, made as the first come
static int muted_count;

static bool unsaved;
static uint32_t changed_ms;
static uint32_t changes;
static char last_from[OTHERS_KIND_COUNT][COMM_NAME_MAX];
static uint32_t last_ms[OTHERS_KIND_COUNT];

static uint8_t owner[OTHERS_KEY_LEN];
static bool have_owner;
static uint8_t binding[OTHERS_SIG_LEN];    // the owner's signature that this board's theirs
static bool have_binding;

static volatile uint32_t queue_write;   // only direct comms' task moves it
static volatile uint32_t queue_read;    // only the checker moves it
static queued_t *checked;               // QUEUE_LEN of them, checked and without their signatures
static volatile uint32_t checked_write; // only the checker moves it
static volatile uint32_t checked_read;  // only the UI loop moves it
static queued_t *known_good;            // KNOWN_GOOD of them, signatures and all: the checker's
static volatile bool checker_running;   // none are queued until it is
static int known_next;

static seen_t seen[SEEN_MAX];
static int seen_count;
static int seen_next;

static void load(void)
{
    memset(list, 0, sizeof(*list));
    size_t n = rcat_hal_store_read(STORE_NAME, list, sizeof(*list));
    if (n < offsetof(stored_t, people) || list->version != STORE_VERSION || list->count > OTHERS_PEOPLE_MAX
        || n < offsetof(stored_t, people) + list->count * sizeof(person_t))
    {
        memset(list, 0, sizeof(*list));
        list->version = STORE_VERSION;
        for (int k = 0; k < OTHERS_KIND_COUNT; k++)
        {
            list->permission[k] = OTHERS_ASK;
        }
    }
    for (int k = 0; k < OTHERS_KIND_COUNT; k++)
    {
        if (list->permission[k] > OTHERS_ACCEPT)
        {
            list->permission[k] = OTHERS_ASK;
        }
        list->options[k] &= OTHERS_IGNORE_EVERYONE | OTHERS_IGNORE_CHANNEL;
    }
    for (int i = 0; i < list->count; i++)
    {
        list->people[i].name[COMM_NAME_MAX - 1] = '\0';
    }
    have_owner = rcat_hal_store_read(OWNER_STORE_NAME, owner, sizeof(owner)) == sizeof(owner);
}

static void checker_task(void *arg);

void others_init(void)
{
    list = lv_malloc(sizeof(stored_t));
    queue = lv_malloc(QUEUE_LEN * sizeof(queued_t));
    checked = lv_malloc(QUEUE_LEN * sizeof(queued_t));
    known_good = lv_malloc(KNOWN_GOOD * sizeof(queued_t));
    if (list == NULL || queue == NULL || checked == NULL || known_good == NULL)
    {
        lv_free(list);
        lv_free(queue);
        lv_free(checked);
        lv_free(known_good);
        list = NULL;
        queue = NULL;
        return;
    }
    memset(known_good, 0, KNOWN_GOOD * sizeof(queued_t));
    load();
}

/* The checker, once direct comms is there to hear commands (it's set up
 * after this). */
static void start_checker(void)
{
    static bool tried;
    if (tried || queue == NULL || !direct_available())
    {
        return;
    }
    tried = true;
    if (!rcat_hal_task_start("others", checker_task, NULL, CHECKER_STACK))
    {
        printf("others: couldn't start checking commands heard directly\n");
    }
    else
    {
        checker_running = true;
    }
}

static void changed(void)
{
    unsaved = true;
    changed_ms = rcat_hal_millis();
    changes++;
}

static person_t *find(const uint8_t *key)
{
    for (int i = 0; i < list->count; i++)
    {
        if (memcmp(list->people[i].key, key, OTHERS_KEY_LEN) == 0)
        {
            return &list->people[i];
        }
    }
    return NULL;
}

static bool same_name(const char *a, const char *b)
{
    for (; *a && *b; a++, b++)
    {
        if (tolower((unsigned char)*a) != tolower((unsigned char)*b))
        {
            return false;
        }
    }
    return *a == *b;
}

/* Whether someone else listed goes by this name. */
static bool name_taken(const person_t *by, const char *name)
{
    for (int i = 0; i < list->count; i++)
    {
        if (&list->people[i] != by && same_name(list->people[i].name, name))
        {
            return true;
        }
    }
    return false;
}

/* Add someone new, allowed for nothing. When the list's full, the first
 * who isn't allowed for anything makes room; if they all are, the new one
 * isn't added. */
static person_t *add(const uint8_t *key, const char *name, uint64_t counter)
{
    if (list->count == OTHERS_PEOPLE_MAX)
    {
        int out = -1;
        for (int i = 0; i < list->count && out < 0; i++)
        {
            if (!list->people[i].allowed)
            {
                out = i;
            }
        }
        if (out < 0)
        {
            return NULL;
        }
        memmove(&list->people[out], &list->people[out + 1], (size_t)(list->count - out - 1) * sizeof(person_t));
        list->count--;
    }
    person_t *p = &list->people[list->count];
    memset(p, 0, sizeof(*p));
    memcpy(p->key, key, OTHERS_KEY_LEN);
    snprintf(p->name, sizeof(p->name), "%s", name);
    p->counter = counter;
    p->clash = name_taken(p, name);
    list->count++;
    changed();
    return p;
}

/* Their name, kept up to date: a label, not who they are. */
static void rename_person(person_t *p, const char *name)
{
    if (strcmp(p->name, name) != 0)
    {
        if (name_taken(p, name))
        {
            p->clash = 1;
        }
        snprintf(p->name, sizeof(p->name), "%s", name);
        changed();
    }
}

// A command by its sender's key and counter: the one seen before, or a new one
static seen_t *seen_entry(const uint8_t *key, uint64_t counter, bool *again)
{
    for (int i = 0; i < seen_count; i++)
    {
        if (seen[i].counter == counter && memcmp(seen[i].key, key, sizeof(seen[i].key)) == 0)
        {
            *again = true;
            return &seen[i];
        }
    }
    seen_t *s = &seen[seen_next];
    memcpy(s->key, key, sizeof(s->key));
    s->counter = counter;
    s->done = false;
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
    char line[OTHERS_WHAT_MAX + 2];
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

/* Which kind a command is, from what to do on: OTHERS_KIND_COUNT for a
 * text, or -1 if it isn't one. */
static int kind_of(const uint8_t *what, size_t len)
{
    switch (what[0])
    {
    case OTHERS_STOP:
    case OTHERS_PATTERN:
        return OTHERS_LOVENSE;
    case OTHERS_LEVEL:
    case OTHERS_SPEED:
        return len >= 3 ? OTHERS_LOVENSE : -1;
    case OTHERS_REACT:
        return len >= 2 ? OTHERS_LOVENSE : -1;
    case OTHERS_MESSAGE:
        return len > 3 ? OTHERS_TERMINAL : -1;
    case OTHERS_CLEAR:
        return OTHERS_TERMINAL;
    case OTHERS_TEXT:
        return len > 1 ? OTHERS_KIND_COUNT : -1;
    default:
        return -1;
    }
}

/* Do it. */
static void run(const uint8_t *what, size_t len)
{
    const uint8_t *arg = what + 1;
    switch (what[0])
    {
    case OTHERS_STOP:
        lovense_stop_all();
        reactive_set_mode(REACTIVE_OFF);
        break;
    case OTHERS_LEVEL:
        set_levels(arg[0], arg[1]);
        break;
    case OTHERS_PATTERN:
        play(arg, len - 1);
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
        show_message(arg[0], arg[1], arg + 2, len - 3);
        break;
    case OTHERS_CLEAR:
        message_clear();
        break;
    }
}

/* ----- Checking them ----- */

/* Whether a command heard over direct comms was signed by the key in it,
 * for where it came: see others.h. */
static bool signature_good(const uint8_t *cmd, size_t len)
{
    uint8_t context[1 + OTHERS_KEY_LEN];
    size_t context_len = 1;
    switch (cmd[SCOPE_AT])
    {
    case OTHERS_SCOPE_EVERYONE:
        context[0] = 'E';
        break;
    case OTHERS_SCOPE_CHANNEL:
        context[0] = 'C';
        direct_group_id(context + 1);
        context_len = 5;
        break;
    case OTHERS_SCOPE_ONE:
        if (!have_owner)
        {
            return false;   // nobody's said who this board's wearer is
        }
        context[0] = 'O';
        memcpy(context + 1, owner, OTHERS_KEY_LEN);
        context_len = 1 + OTHERS_KEY_LEN;
        break;
    default:
        return false;
    }
    size_t body = len - OTHERS_SIG_LEN;
    uint8_t msg[sizeof(signed_prefix) - 1 + sizeof(context) + OTHERS_CMD_MAX];
    size_t at = 0;
    memcpy(msg, signed_prefix, sizeof(signed_prefix) - 1);
    at += sizeof(signed_prefix) - 1;
    memcpy(msg + at, context, context_len);
    at += context_len;
    memcpy(msg + at, cmd, body);
    at += body;
    return crypto_ed25519_check(cmd + body, cmd + KEY_AT, msg, at) == 0;
}

static bool is_muted(const uint8_t *key)
{
    for (int i = 0; i < muted_count; i++)
    {
        if (memcmp(muted[i], key, OTHERS_ID_LEN) == 0)
        {
            return true;
        }
    }
    return false;
}

void others_set_muted(bool first, const uint8_t *ids, size_t len)
{
    if (muted == NULL)
    {
        muted = lv_malloc(MUTED_MAX * OTHERS_ID_LEN);
        if (muted == NULL)
        {
            return;
        }
    }
    if (first)
    {
        muted_count = 0;
    }
    for (size_t at = 0; at + OTHERS_ID_LEN <= len && muted_count < MUTED_MAX; at += OTHERS_ID_LEN)
    {
        memcpy(muted[muted_count++], ids + at, OTHERS_ID_LEN);
    }
}

void others_set_owner(const uint8_t key[OTHERS_KEY_LEN])
{
    if (have_owner && memcmp(owner, key, OTHERS_KEY_LEN) == 0)
    {
        return;
    }
    memcpy(owner, key, OTHERS_KEY_LEN);
    have_owner = true;
    have_binding = false;   // someone else's now: theirs is to come
    if (!rcat_hal_store_write(OWNER_STORE_NAME, owner, sizeof(owner)))
    {
        printf("others: couldn't save the wearer's key\n");
    }
}

void others_set_binding(const uint8_t sig[OTHERS_SIG_LEN])
{
    memcpy(binding, sig, OTHERS_SIG_LEN);
    have_binding = true;
}

bool others_owner(uint8_t key[OTHERS_KEY_LEN], uint8_t sig[OTHERS_SIG_LEN])
{
    if (!have_owner || !have_binding)
    {
        return false;
    }
    memcpy(key, owner, OTHERS_KEY_LEN);
    memcpy(sig, binding, OTHERS_SIG_LEN);
    return true;
}

/* ----- Taking them ----- */

/* A command that's been checked, without its signature: from the server,
 * by the phone, or over direct comms, by the checker. */
static void receive(comm_transport_t via, const char *from, const uint8_t *cmd, size_t len)
{
    if (list == NULL || from == NULL || from[0] == '\0' || len > OTHERS_CMD_MAX - OTHERS_SIG_LEN
        || len < OTHERS_HEADER_LEN + 1 || cmd[0] != OTHERS_VERSION)
    {
        return;
    }
    const uint8_t *what = cmd + OP;
    size_t what_len = len - OP;
    int which = kind_of(what, what_len);
    if (which < 0)
    {
        return;
    }
    const uint8_t *key = cmd + KEY_AT;
    uint64_t counter = 0;
    for (int i = 5; i >= 0; i--)
    {
        counter = (counter << 8) | cmd[COUNTER_AT + i];
    }
    // Once, however many times it comes, and by whichever way. Senders send
    // to someone both ways they can reach them, so one refused may come
    // again by a way that's allowed: that's tried, but one done isn't again.
    bool again;
    seen_t *seen_as = seen_entry(key, counter, &again);
    if (again && (seen_as->done || which == OTHERS_KIND_COUNT))
    {
        return;
    }
    person_t *p = find(key);
    if (p != NULL && !again)
    {
        if (counter <= p->counter)
        {
            printf("others: an old command from %s again, dropped\n", from);
            return;
        }
        p->counter = counter;
        rename_person(p, from);
        changed();      // the counter's to be saved
    }
    uint8_t scope = cmd[SCOPE_AT];
    if (which == OTHERS_KIND_COUNT)
    {
        // A text: for the app, whoever it's from
        comm_heard_to_phone(via, from, key, COMM_HEARD_TEXT, scope, true, what + 1, what_len - 1);
        return;
    }
    comm_heard_t heard = which == OTHERS_LOVENSE ? COMM_HEARD_LOVENSE : COMM_HEARD_TERMINAL;
    uint8_t bit = (uint8_t)(1u << which);
    bool done = false;
    // To everyone nearby, if it's to the channel in the open direct group
    bool open = via == COMM_TALK_DIRECT && !settings_get()->direct_keyed;
    bool everyone = scope == OTHERS_SCOPE_EVERYONE || (scope == OTHERS_SCOPE_CHANNEL && open);
    uint8_t options = list->options[which];
    bool ignored = is_muted(key) || (everyone && (options & OTHERS_IGNORE_EVERYONE))
                   || (scope == OTHERS_SCOPE_CHANNEL && (options & OTHERS_IGNORE_CHANNEL));
    if (list->permission[which] != OTHERS_OFF && !ignored)
    {
        bool anyone = list->permission[which] == OTHERS_ACCEPT;
        if (p == NULL)
        {
            p = add(key, from, counter);    // listed either way, to say who's been sending
            printf("others: %s commands from %s (%s), %s\n", which == OTHERS_LOVENSE ? "Lovense" : "Terminal", from,
                   via == COMM_TALK_DIRECT ? "direct" : "server", anyone ? "accepted" : "not allowed yet");
        }
        if (p != NULL && !(p->sent & bit))
        {
            p->sent |= bit;
            changed();
        }
        done = anyone || (p != NULL && (p->allowed & bit));
    }
    if (!done && again)
    {
        return;     // refused again: the app's been told
    }
    if (done)
    {
        seen_as->done = true;
        run(what, what_len);
        snprintf(last_from[which], sizeof(last_from[which]), "%s", from);
        last_ms[which] = rcat_hal_millis();
        changes++;
    }
    // What it was, from what to do on, for the app to say
    comm_heard_to_phone(via, from, key, heard, scope, done, what, what_len);
}

void others_receive(comm_transport_t via, const char *from, const uint8_t *cmd, size_t len)
{
    receive(via, from, cmd, len);
}

/* Whether this very command, signature and all, has been checked lately:
 * a copy, sent again in case one was lost, is as good as the first. */
static bool known(const queued_t *q)
{
    for (int i = 0; i < KNOWN_GOOD; i++)
    {
        if (known_good[i].len == q->len && memcmp(known_good[i].cmd, q->cmd, q->len) == 0)
        {
            return true;
        }
    }
    return false;
}

/* Checks the signatures of commands heard over direct comms, and passes the
 * good ones on to the UI loop. */
static void checker_task(void *arg)
{
    (void)arg;
    bool timed = false;
    for (;;)
    {
        uint32_t r = queue_read;
        if (r == __atomic_load_n(&queue_write, __ATOMIC_ACQUIRE))
        {
            rcat_hal_delay_ms(CHECKER_IDLE_MS);
            continue;
        }
        queued_t *q = &queue[r % QUEUE_LEN];
        bool good = q->len >= OTHERS_HEADER_LEN + 1 + OTHERS_SIG_LEN && q->cmd[0] == OTHERS_VERSION;
        if (good && !known(q))
        {
            uint32_t start = rcat_hal_millis();
            good = signature_good(q->cmd, q->len);
            uint32_t took = rcat_hal_millis() - start;
            if (!good)
            {
                printf("others: a command from %s with a bad signature, dropped\n", q->from);
            }
            else
            {
                known_good[known_next] = *q;
                known_next = (known_next + 1) % KNOWN_GOOD;
                if (!timed)
                {
                    timed = true;
                    printf("others: checking a signature takes %lu ms\n", (unsigned long)took);
                }
            }
        }
        uint32_t w = checked_write;
        if (good && w - __atomic_load_n(&checked_read, __ATOMIC_ACQUIRE) < QUEUE_LEN)
        {
            queued_t *c = &checked[w % QUEUE_LEN];
            *c = *q;
            c->len = (uint8_t)(q->len - OTHERS_SIG_LEN);
            __atomic_store_n(&checked_write, w + 1, __ATOMIC_RELEASE);
        }
        __atomic_store_n(&queue_read, r + 1, __ATOMIC_RELEASE);
    }
}

void others_queue(const char *from, const uint8_t *cmd, size_t len)
{
    uint32_t w = queue_write;
    if (queue == NULL || !checker_running || w - __atomic_load_n(&queue_read, __ATOMIC_ACQUIRE) >= QUEUE_LEN
        || len > OTHERS_CMD_MAX)
    {
        return;     // full: the sender sends each more than once
    }
    queued_t *q = &queue[w % QUEUE_LEN];
    snprintf(q->from, sizeof(q->from), "%s", from);
    q->len = (uint8_t)len;
    memcpy(q->cmd, cmd, len);
    __atomic_store_n(&queue_write, w + 1, __ATOMIC_RELEASE);
}

/* ----- The list ----- */

others_permission_t others_permission(others_kind_t kind)
{
    return list != NULL && kind < OTHERS_KIND_COUNT ? (others_permission_t)list->permission[kind] : OTHERS_OFF;
}

void others_set_permission(others_kind_t kind, others_permission_t permission)
{
    if (list != NULL && kind < OTHERS_KIND_COUNT && permission <= OTHERS_ACCEPT && list->permission[kind] != permission)
    {
        list->permission[kind] = (uint8_t)permission;
        changed();
    }
}

uint8_t others_ignoring(others_kind_t kind)
{
    return list != NULL && kind < OTHERS_KIND_COUNT ? list->options[kind] : 0;
}

void others_set_ignoring(others_kind_t kind, uint8_t ignore)
{
    ignore &= OTHERS_IGNORE_EVERYONE | OTHERS_IGNORE_CHANNEL;
    if (list != NULL && kind < OTHERS_KIND_COUNT && list->options[kind] != ignore)
    {
        list->options[kind] = ignore;
        changed();
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
    if (list == NULL || kind >= OTHERS_KIND_COUNT)
    {
        return 0;
    }
    uint8_t bit = (uint8_t)(1u << kind);
    int n = 0;
    for (int i = 0; i < list->count; i++)
    {
        const person_t *p = &list->people[i];
        if (!((p->sent | p->allowed) & bit))
        {
            continue;
        }
        if (n < max)
        {
            memcpy(out[n].key, p->key, OTHERS_KEY_LEN);
            snprintf(out[n].name, sizeof(out[n].name), "%s", p->name);
            out[n].allowed = (p->allowed & bit) != 0;
            out[n].clash = p->clash != 0;
        }
        n++;
    }
    return n;
}

void others_allow(others_kind_t kind, const uint8_t key[OTHERS_KEY_LEN], bool allow)
{
    if (list == NULL || kind >= OTHERS_KIND_COUNT)
    {
        return;
    }
    person_t *p = find(key);
    uint8_t bit = (uint8_t)(1u << kind);
    if (p != NULL && ((p->allowed & bit) != 0) != allow)
    {
        p->allowed = allow ? (p->allowed | bit) : (p->allowed & ~bit);
        changed();
    }
}

void others_forget(others_kind_t kind, const uint8_t key[OTHERS_KEY_LEN])
{
    if (list == NULL || kind >= OTHERS_KIND_COUNT)
    {
        return;
    }
    person_t *p = find(key);
    if (p == NULL)
    {
        return;
    }
    uint8_t bit = (uint8_t)(1u << kind);
    p->sent &= ~bit;
    p->allowed &= ~bit;
    if (p->sent == 0 && p->allowed == 0)
    {
        // Nothing left for them: out of the list altogether
        int i = (int)(p - list->people);
        memmove(p, p + 1, (size_t)(list->count - i - 1) * sizeof(person_t));
        list->count--;
    }
    changed();
}

const char *others_last(others_kind_t kind, uint32_t now_ms, uint32_t *age_ms)
{
    if (list == NULL || kind >= OTHERS_KIND_COUNT || last_from[kind][0] == '\0')
    {
        return NULL;
    }
    *age_ms = now_ms - last_ms[kind];
    return last_from[kind];
}

uint32_t others_changes(void)
{
    return changes;
}

void others_poll(uint32_t now_ms)
{
    if (list == NULL)
    {
        return;
    }
    start_checker();
    while (checked_read != __atomic_load_n(&checked_write, __ATOMIC_ACQUIRE))
    {
        queued_t *q = &checked[checked_read % QUEUE_LEN];
        receive(COMM_TALK_DIRECT, q->from, q->cmd, q->len);
        __atomic_store_n(&checked_read, checked_read + 1, __ATOMIC_RELEASE);
    }
    if (unsaved && now_ms - changed_ms >= SAVE_DELAY_MS)
    {
        unsaved = false;
        size_t len = offsetof(stored_t, people) + list->count * sizeof(person_t);
        if (!rcat_hal_store_write(STORE_NAME, list, len))
        {
            printf("others: couldn't save who may send commands\n");
        }
    }
}
