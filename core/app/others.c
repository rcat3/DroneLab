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
#include "app/message.h"
#include "app/patterns.h"
#include "app/reactive.h"
#include "app/rules.h"
#include "app/settings.h"
#include "app/toys.h"
#include "crypto/monocypher-ed25519.h"
#include "hal.h"
#include "lvgl.h"
#include "ui/ui.h"

#define STORE_NAME          "oth_seen"
#define OWNER_STORE_NAME    "oth_owner"
#define STORE_VERSION       1
#define SAVE_DELAY_MS       1000
#define QUEUE_LEN           8           // from direct comms, waiting to be checked, and checked, waiting for the UI loop
#define KNOWN_GOOD          6           // commands checked lately, whose copies needn't be again
#define CHECKER_STACK       8192
#define CHECKER_IDLE_MS     10
#define SEEN_MAX            64          // commands remembered, so each is only done once
#define KEY_AT              1
#define COUNTER_AT          33
#define SCOPE_AT            39
#define OP                  OTHERS_HEADER_LEN   // where what to do is
#define TERMINAL_FEATURE    "Terminal"

static const char signed_prefix[] = "dronelab-command\n";

// A sender's last command, as it's stored: so a recorded one can't be
// played back
typedef struct
{
    uint8_t id[OTHERS_ID_LEN];
    uint64_t counter;
    uint32_t order;         // when they last sent: the oldest goes first
} sender_t;

typedef struct
{
    uint8_t version;
    uint8_t count;
    sender_t senders[OTHERS_SENDERS_KEPT];
} stored_t;

typedef struct
{
    char from[COMM_NAME_MAX];
    uint8_t len;
    uint8_t cmd[OTHERS_CMD_MAX];
    others_radio_t radio;
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

// Boards' signatures that they're their wearers', from direct comms' task to
// the checker, and back
#define BOARDS_LEN          4
typedef struct
{
    uint32_t id;
    uint8_t key[OTHERS_KEY_LEN];
    uint8_t sig[OTHERS_SIG_LEN];
    bool good;
} board_check_t;
static board_check_t boards[BOARDS_LEN];
static volatile uint32_t boards_write;  // only direct comms' task moves it
static volatile uint32_t boards_read;   // only the checker moves it
static board_check_t board_results[BOARDS_LEN];
static volatile uint32_t results_write; // only the checker moves it
static volatile uint32_t results_read;  // only direct comms' task moves it
static int known_next;

static uint32_t order_next;             // one more than any sender's order

static seen_t seen[SEEN_MAX];
static int seen_count;
static int seen_next;

static void load(void)
{
    memset(list, 0, sizeof(*list));
    size_t n = rcat_hal_store_read(STORE_NAME, list, sizeof(*list));
    if (n < offsetof(stored_t, senders) || list->version != STORE_VERSION || list->count > OTHERS_SENDERS_KEPT
        || n < offsetof(stored_t, senders) + list->count * sizeof(sender_t))
    {
        memset(list, 0, sizeof(*list));
        list->version = STORE_VERSION;
    }
    for (int i = 0; i < list->count; i++)
    {
        if (list->senders[i].order >= order_next)
        {
            order_next = list->senders[i].order + 1;
        }
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

static sender_t *find(const uint8_t *key)
{
    for (int i = 0; i < list->count; i++)
    {
        if (memcmp(list->senders[i].id, key, OTHERS_ID_LEN) == 0)
        {
            return &list->senders[i];
        }
    }
    return NULL;
}

/* Someone new, in place of the one who sent longest ago if there's no room. */
static sender_t *add(const uint8_t *key)
{
    sender_t *p;
    if (list->count < OTHERS_SENDERS_KEPT)
    {
        p = &list->senders[list->count++];
    }
    else
    {
        p = &list->senders[0];
        for (int i = 1; i < list->count; i++)
        {
            if (list->senders[i].order < p->order)
            {
                p = &list->senders[i];
            }
        }
    }
    memset(p, 0, sizeof(*p));
    memcpy(p->id, key, OTHERS_ID_LEN);
    return p;
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

/* The channels, as a whole: see others.h. A pattern that isn't here yet,
 * they wait for: a custom one's definition comes in its parts. */
static void set_vibe(const uint8_t *arg, size_t len)
{
    uint8_t channels = arg[0] & TOYS_ALL_CHANNELS;
    uint8_t levels[TOYS_CHANNELS];
    size_t n = 0;
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        levels[c] = (channels & (1u << c)) ? arg[1 + n++] : 0;
    }
    const uint8_t *rest = arg + 1 + n;
    uint16_t speed = (uint16_t)(rest[0] | (rest[1] << 8));
    speed = speed < TOYS_SPEED_MIN ? TOYS_SPEED_MIN : speed > TOYS_SPEED_MAX ? TOYS_SPEED_MAX : speed;
    uint8_t mode = rest[2];
    if (mode >= REACTIVE_COUNT || !reactive_available((reactive_mode_t)mode))
    {
        mode = REACTIVE_OFF;
    }
    static const uint8_t none[PATTERNS_HASH_LEN];
    int pattern = -1;
    const uint8_t *waiting = NULL;
    size_t name_len = len - (size_t)(rest + 4 - arg);
    if (rest[3] == OTHERS_PATTERN_BUILT_IN)
    {
        pattern = patterns_built_in(rest + 4, name_len);
        waiting = pattern < 0 ? none : NULL;    // one this board hasn't got: held
    }
    else if (rest[3] == OTHERS_PATTERN_CUSTOM)
    {
        pattern = patterns_find(rest + 4);
        waiting = pattern < 0 ? rest + 4 : NULL;
    }
    toys_set(channels, levels, speed, mode, pattern, waiting);
}

/* A part of a custom pattern's definition: once they're all here, the
 * channels waiting for it start it. */
static void pattern_part(const uint8_t *arg, size_t len)
{
    const uint8_t *hash = arg;
    int pattern = patterns_part(hash, arg[PATTERNS_HASH_LEN], arg[PATTERNS_HASH_LEN + 1], arg + PATTERNS_HASH_LEN + 2,
                                len - PATTERNS_HASH_LEN - 2, rcat_hal_millis());
    if (pattern >= 0)
    {
        toys_pattern_came(hash, pattern);
    }
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

/* Whether a set's the right length (see others.h): what to do (1), the
 * channels, a level for each, the speed (2), the reaction, the pattern's
 * kind, then the pattern. */
static bool set_length_good(const uint8_t *what, size_t len)
{
    size_t at = 2;
    for (uint8_t c = 0; c < TOYS_CHANNELS; c++)
    {
        at += (what[1] >> c) & 1;
    }
    at += 4;
    if (len < at)
    {
        return false;
    }
    switch (what[at - 1])
    {
    case OTHERS_PATTERN_NONE:
        return len == at;
    case OTHERS_PATTERN_BUILT_IN:
        return len > at && len <= at + PATTERNS_NAME_MAX;
    case OTHERS_PATTERN_CUSTOM:
        return len == at + PATTERNS_HASH_LEN;
    default:
        return false;
    }
}

/* Which kind a command is, from what to do on: OTHERS_KIND_COUNT for a
 * text, or -1 if it isn't one. */
static int kind_of(const uint8_t *what, size_t len)
{
    switch (what[0])
    {
    case OTHERS_VIBE_STOP:
        return OTHERS_VIBE;
    case OTHERS_VIBE_SET:
        return set_length_good(what, len) ? OTHERS_VIBE : -1;
    case OTHERS_VIBE_PART:
        // what to do (1), the hash, which part, how many, then that part
        return len > 3 + PATTERNS_HASH_LEN && what[1 + PATTERNS_HASH_LEN] < what[2 + PATTERNS_HASH_LEN]
                       && what[2 + PATTERNS_HASH_LEN] <= PATTERNS_PARTS_MAX
                       && len - 3 - PATTERNS_HASH_LEN <= PATTERNS_PART_MAX
                   ? OTHERS_VIBE
                   : -1;
    case OTHERS_MESSAGE:
        return len > 3 ? OTHERS_TERMINAL : -1;
    case OTHERS_CLEAR:
        return OTHERS_TERMINAL;
    case OTHERS_TEXT:
        return len > 1 ? OTHERS_KIND_COUNT : -1;
    case OTHERS_TEXT_PART:
        return len > 5 && what[3] < what[4] ? OTHERS_KIND_COUNT : -1;
    case OTHERS_CALL:
        return len >= 6 ? OTHERS_KIND_COUNT : -1;
    case OTHERS_INVITE:
        return len > 29 ? OTHERS_KIND_COUNT : -1;     // a nonce (12), something, and a tag (16)
    case OTHERS_REACTION:
        return len >= 9 ? OTHERS_KIND_COUNT : -1;     // the message's id (8), and the emoji, or none
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
    case OTHERS_VIBE_STOP:
        toys_stop_all();
        break;
    case OTHERS_VIBE_SET:
        set_vibe(arg, len - 1);
        break;
    case OTHERS_VIBE_PART:
        pattern_part(arg, len - 1);
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
    const rules_person_t *p = rules_person(key);
    return p != NULL && (p->flags & RULES_MUTED);
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
    sender_t *sender = find(key);
    if (!again)
    {
        // A text, or a pattern's part, may come a little behind (a part's
        // checked by its hash, so one again does no harm); anything else
        // must be newer
        bool text = which == OTHERS_KIND_COUNT || what[0] == OTHERS_VIBE_PART;
        uint64_t last = sender != NULL ? sender->counter : 0;
        uint64_t oldest = text ? (last > OTHERS_TEXT_WINDOW_MS ? last - OTHERS_TEXT_WINDOW_MS : 0) : last;
        if (sender != NULL && counter <= oldest)
        {
            printf("others: an old command from %s again, dropped\n", from);
            return;
        }
        if (!text)
        {
            if (sender == NULL)
            {
                sender = add(key);
            }
            sender->counter = counter;
            sender->order = order_next++;
            changed();  // the counter's to be saved
        }
    }
    uint8_t scope = cmd[SCOPE_AT];
    if (which == OTHERS_KIND_COUNT)
    {
        // A text, part of one, a call's signal or an invitation: for the app, whoever it's from
        comm_heard_t kind = what[0] == OTHERS_TEXT_PART ? COMM_HEARD_TEXT_PART
                            : what[0] == OTHERS_CALL    ? COMM_HEARD_CALL
                            : what[0] == OTHERS_INVITE  ? COMM_HEARD_INVITE
                            : what[0] == OTHERS_REACTION ? COMM_HEARD_REACTION
                                                        : COMM_HEARD_TEXT;
        comm_heard_to_phone(via, from, key, counter, kind, scope, true, what + 1, what_len - 1);
        return;
    }
    comm_heard_t heard = which == OTHERS_VIBE ? COMM_HEARD_VIBE : COMM_HEARD_TERMINAL;
    bool done = false;
    // To everyone nearby, if it's to the channel in the open direct group
    bool open = via == COMM_TALK_DIRECT && !settings_get()->direct_keyed;
    bool everyone = scope == OTHERS_SCOPE_EVERYONE || (scope == OTHERS_SCOPE_CHANNEL && open);
    uint8_t cls = others_class((others_kind_t)which);
    uint8_t options = rules_ignoring(cls);
    bool ignored = is_muted(key) || (everyone && (options & OTHERS_IGNORE_EVERYONE))
                   || (scope == OTHERS_SCOPE_CHANNEL && (options & OTHERS_IGNORE_CHANNEL));
    uint8_t policy = rules_policy(cls);
    if (policy != RULES_OFF && !ignored)
    {
        const rules_person_t *p = rules_person(key);
        done = policy == RULES_ANYONE || (p != NULL && (p->allowed & (1u << cls)));
        if (!done)
        {
            printf("others: %s commands from %s (%s), not allowed\n", which == OTHERS_VIBE ? "Vibe" : "Terminal",
                   from, via == COMM_TALK_DIRECT ? "direct" : "server");
        }
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
    comm_heard_to_phone(via, from, key, counter, heard, scope, done, what, what_len);
}

void others_receive(comm_transport_t via, const char *from, const uint8_t *cmd, size_t len)
{
    receive(via, from, cmd, len);
}

void others_run_own(const uint8_t *what, size_t len)
{
    if (list == NULL || len == 0 || len > OTHERS_WHAT_MAX || kind_of(what, len) != OTHERS_VIBE)
    {
        return;
    }
    run(what, len);
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

bool others_check_board(uint32_t id, const uint8_t key[OTHERS_KEY_LEN], const uint8_t sig[OTHERS_SIG_LEN])
{
    uint32_t w = boards_write;
    if (!checker_running || w - __atomic_load_n(&boards_read, __ATOMIC_ACQUIRE) >= BOARDS_LEN)
    {
        return false;
    }
    board_check_t *b = &boards[w % BOARDS_LEN];
    b->id = id;
    memcpy(b->key, key, OTHERS_KEY_LEN);
    memcpy(b->sig, sig, OTHERS_SIG_LEN);
    __atomic_store_n(&boards_write, w + 1, __ATOMIC_RELEASE);
    return true;
}

bool others_board_checked(uint32_t *id, uint8_t key[OTHERS_KEY_LEN], bool *good)
{
    uint32_t r = results_read;
    if (r == __atomic_load_n(&results_write, __ATOMIC_ACQUIRE))
    {
        return false;
    }
    const board_check_t *b = &board_results[r % BOARDS_LEN];
    *id = b->id;
    memcpy(key, b->key, OTHERS_KEY_LEN);
    *good = b->good;
    __atomic_store_n(&results_read, r + 1, __ATOMIC_RELEASE);
    return true;
}

/* A board's signature that it's its wearer's: see direct.h's hello. */
static void check_board(void)
{
    uint32_t r = boards_read;
    uint32_t w = results_write;
    if (r == __atomic_load_n(&boards_write, __ATOMIC_ACQUIRE)
        || w - __atomic_load_n(&results_read, __ATOMIC_ACQUIRE) >= BOARDS_LEN)
    {
        return;     // none, or no room for the answer till direct comms takes the last
    }
    board_check_t *b = &boards[r % BOARDS_LEN];
    static const char prefix[] = "dronelab-board\n";
    uint8_t msg[sizeof(prefix) - 1 + 4];
    memcpy(msg, prefix, sizeof(prefix) - 1);
    memcpy(msg + sizeof(prefix) - 1, &b->id, 4);
    board_check_t *out = &board_results[w % BOARDS_LEN];
    *out = *b;
    out->good = crypto_ed25519_check(b->sig, b->key, msg, sizeof(msg)) == 0;
    __atomic_store_n(&results_write, w + 1, __ATOMIC_RELEASE);
    __atomic_store_n(&boards_read, r + 1, __ATOMIC_RELEASE);
}

/* Checks the signatures of commands heard over direct comms, and passes the
 * good ones on to the UI loop; and boards' that they're their wearers'. */
static void checker_task(void *arg)
{
    (void)arg;
    bool timed = false;
    for (;;)
    {
        check_board();
        uint32_t r = queue_read;
        if (r == __atomic_load_n(&queue_write, __ATOMIC_ACQUIRE))
        {
            if (boards_read == __atomic_load_n(&boards_write, __ATOMIC_ACQUIRE))
            {
                rcat_hal_delay_ms(CHECKER_IDLE_MS);
            }
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

void others_queue(const char *from, const uint8_t *cmd, size_t len, const others_radio_t *radio)
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
    q->radio = *radio;
    __atomic_store_n(&queue_write, w + 1, __ATOMIC_RELEASE);
}

/* ----- The rules ----- */

uint8_t others_class(others_kind_t kind)
{
    return kind == OTHERS_VIBE ? RULES_CLASS_VIBE : kind == OTHERS_TERMINAL ? RULES_CLASS_TERMINAL : 0;
}

others_permission_t others_permission(others_kind_t kind)
{
    uint8_t p = rules_policy(others_class(kind));
    return p == RULES_ANYONE ? OTHERS_ACCEPT : p == RULES_ASK ? OTHERS_ASK : OTHERS_OFF;
}

uint8_t others_ignoring(others_kind_t kind)
{
    return rules_ignoring(others_class(kind));
}

const char *others_last(others_kind_t kind, uint32_t now_ms, uint32_t *age_ms)
{
    if (kind >= OTHERS_KIND_COUNT || last_from[kind][0] == '\0')
    {
        return NULL;
    }
    *age_ms = now_ms - last_ms[kind];
    return last_from[kind];
}

uint32_t others_changes(void)
{
    return changes + rules_changes();
}

/* The capabilities, for each kind: how it's open (OTHERS_CAP_*), 0 for not
 * at all, and its byte more. Set on the UI loop, read from any task. */
static uint8_t caps_how[OTHERS_KIND_COUNT];
static uint8_t caps_data[OTHERS_KIND_COUNT];

/* Whether a toy is connected, or on its way to it. */
static bool toys_any(void)
{
    for (size_t i = 0; i < TOYS_MAX_DEVICES; i++)
    {
        const toy_t *t = toys_device(i);
        if (t != NULL && (t->state == TOY_CONNECTED || t->state == TOY_CONNECTING || t->state == TOY_LOST))
        {
            return true;
        }
    }
    return false;
}

static void update_capabilities(void)
{
    for (int k = 0; k < OTHERS_KIND_COUNT; k++)
    {
        others_permission_t p = others_permission((others_kind_t)k);
        uint8_t how = p == OTHERS_ACCEPT ? OTHERS_CAP_OPEN : p == OTHERS_ASK ? OTHERS_CAP_ASK : 0;
        uint8_t data = 0;
        if (k == OTHERS_VIBE)
        {
            how = toys_any() ? how : 0;
            data = toys_channels_mapped();
        }
        __atomic_store_n(&caps_how[k], how, __ATOMIC_RELAXED);
        __atomic_store_n(&caps_data[k], data, __ATOMIC_RELAXED);
    }
}

size_t others_capabilities(uint8_t out[OTHERS_CAPS_MAX])
{
    static const uint8_t ids[OTHERS_KIND_COUNT] = { [OTHERS_VIBE] = OTHERS_CAP_VIBE,
                                                    [OTHERS_TERMINAL] = OTHERS_CAP_TERMINAL };
    size_t at = 1;
    out[0] = 0;
    for (int k = 0; k < OTHERS_KIND_COUNT; k++)
    {
        uint8_t how = __atomic_load_n(&caps_how[k], __ATOMIC_RELAXED);
        if (how != 0)
        {
            out[at++] = ids[k];
            out[at++] = how;
            out[at++] = __atomic_load_n(&caps_data[k], __ATOMIC_RELAXED);
            out[0]++;
        }
    }
    return at;
}

void others_poll(uint32_t now_ms)
{
    update_capabilities();
    if (list == NULL)
    {
        return;
    }
    start_checker();
    while (checked_read != __atomic_load_n(&checked_write, __ATOMIC_ACQUIRE))
    {
        queued_t *q = &checked[checked_read % QUEUE_LEN];
        if (q->len >= OTHERS_HEADER_LEN)
        {
            // Each copy, for the app's details of a text, before it's done
            uint64_t counter = 0;
            for (int i = 5; i >= 0; i--)
            {
                counter = (counter << 8) | q->cmd[COUNTER_AT + i];
            }
            comm_copy_to_phone(q->cmd + KEY_AT, counter, q->radio.broadcast, q->radio.rssi, q->radio.hops,
                               q->radio.len);
        }
        receive(COMM_TALK_DIRECT, q->from, q->cmd, q->len);
        __atomic_store_n(&checked_read, checked_read + 1, __ATOMIC_RELEASE);
    }
    if (unsaved && now_ms - changed_ms >= SAVE_DELAY_MS)
    {
        unsaved = false;
        size_t len = offsetof(stored_t, senders) + list->count * sizeof(sender_t);
        if (!rcat_hal_store_write(STORE_NAME, list, len))
        {
            printf("others: couldn't save the senders' counters\n");
        }
    }
}
