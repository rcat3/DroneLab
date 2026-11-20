/*
 * Direct comms (see direct.h).
 *
 * Everything to do with the radio happens on direct comms' own task:
 * sealing and sending, opening what's heard, the hellos, and keeping track of
 * who's about. The comm channel's encoder hands it the wearer's voice through
 * a small queue, and others read who's about through a copy that's taken
 * whole (a sequence lock), so none of it needs locking.
 */
#include "app/direct.h"

#include <string.h>

#if RCAT_HAVE_DIRECT

#include <stdio.h>
#include <stdlib.h>

#include "mbedtls/gcm.h"
#include "mbedtls/pkcs5.h"
#include "mbedtls/sha256.h"

#include "app/comm.h"
#include "app/others.h"
#include "app/settings.h"
#include "hal.h"
#include "lvgl.h"

// 1 for a board that only echoes back what it hears, as itself, for trying
// direct comms with one board that can send (set by -DRCAT_DIRECT_ECHO=1).
// It's in a group of its own, for trying joining one heard over the air.
#ifndef RCAT_DIRECT_ECHO
#define RCAT_DIRECT_ECHO    0
#endif
#define ECHO_GROUP          "Echo Test"
#define ECHO_PASSPHRASE     "dronelab"
#ifndef RCAT_DIRECT_ECHO_CHANNEL
#define RCAT_DIRECT_ECHO_CHANNEL    DIRECT_CHANNEL_DEFAULT
#endif
#ifndef RCAT_DIRECT_ECHO_LR
#define RCAT_DIRECT_ECHO_LR         0
#endif

// 1 to print what was sent, heard and dropped every couple of seconds.
#define DIRECT_DEBUG        0

#define MAGIC               'D'
#define HEADER_LEN          15
#define CHECKED_LEN         14          // the header but for the hops, which relays change
#define TAG_LEN             8
#define TYPE_VOICE          0x01
#define TYPE_HELLO          0x02
#define TYPE_AVATAR         0x03
#define TYPE_COMMAND        0x04
#define BEACON              'G'         // a group says it's here, not encrypted
#define BEACON_LR           0x01
#define HELLO_TALKING       0x01
#define HELLO_ASKS          0x02        // it asks for pieces of an avatar
#define HELLO_KEY           0x04        // the wearer's public key follows
#define ASK_LEN             (4 + 1 + 16)    // whose, its version, and the pieces, a bit each
#define MAX_OPUS            160

#define HELLO_EVERY_MS      2000
#define PEER_GONE_MS        10000       // not heard for this long: forgotten
#define TALKING_MS          300         // talking, until this long after its last voice
#define TASK_STACK          (6 * 1024)
#define TASK_IDLE_MS        50
#define TASK_BUSY_MS        2
#define VOICE_QUEUE         8           // the wearer's voice, waiting to go
#define REPEATS             2           // packets sent again in each after them
#define COMMAND_QUEUE       8           // commands for others, waiting to go: a long text's parts all fit
#define COMMAND_SENDS       3           // each is sent this many times, as nothing says it came
#define COMMAND_GAP_MS      100         // one every so often: those going take turns, a send each

// Relaying
#define HOPS                1           // how many times a broadcast may be passed on
#define RELAY_RSSI          (-78)       // heard weaker than this (dBm): pass it on
#define RELAY_WAIT_MIN_MS   3           // and wait between these first, for another
#define RELAY_WAIT_MAX_MS   15          // board to do it instead
#define RELAYS              8           // waiting at once
#define RADIO_COPY_WINDOW   64          // a command's broadcast heard again, as late as this many broadcasts behind

// Scanning the other channels for groups
#define SCAN_DWELL_MS       (HELLO_EVERY_MS + 300)
static const uint8_t scan_channels[] = { 1, 6, 11 };

// Avatars, sent over the air
#define AVATAR_PIXELS       (DIRECT_AVATAR_PX * DIRECT_AVATAR_PX)
#define AVATAR_PIECE        100         // pixels a piece
#define AVATAR_PIECES       ((AVATAR_PIXELS + AVATAR_PIECE - 1) / AVATAR_PIECE)
#define AVATAR_SKETCH       ((DIRECT_AVATAR_PX / 4) * (DIRECT_AVATAR_PX / 4))  // the two coarsest layers' pixels
#define AVATAR_SKETCH_PIECES ((AVATAR_SKETCH + AVATAR_PIECE - 1) / AVATAR_PIECE)
#define AVATAR_SKETCH_MS    30000       // the coarse layers this often
#define AVATAR_FULL_MS      300000      // and all of it this often
#define AVATAR_SOON_MS      3000        // or this soon after a new board's heard
#define AVATAR_PIECE_MS     150         // a piece at a time, this far apart

typedef struct
{
    uint32_t id;
    uint32_t counter;           // the last one heard, so nothing's played back
    uint32_t heard_ms;
    uint32_t voice_ms;
    uint16_t voice_seq;         // the last voice packet's
    bool voice_seen;
    char name[DIRECT_NAME_MAX];
    char firmware[DIRECT_VERSION_MAX];
    char app[DIRECT_VERSION_MAX];
    uint8_t key[OTHERS_KEY_LEN];    // its wearer's, as its hello says, once it's been checked
    bool has_key;
    uint8_t asked_key[OTHERS_KEY_LEN];  // being checked, or found wanting
    bool key_asked;
    int8_t rssi;
    bool used;
    uint8_t avatar_version;     // of the avatar coming in, 0 for none
    uint8_t avatar_changes;     // goes up with each piece of it
} peer_t;

typedef struct
{
    uint16_t seq;
    uint8_t flags;
    uint8_t len;
    uint8_t opus[MAX_OPUS];
    bool alone;                 // for one wearer alone: sealed with the pair's key
    uint8_t to[OTHERS_KEY_LEN]; // theirs
} voice_t;

typedef struct
{
    uint8_t their[OTHERS_KEY_LEN];  // the other wearer's public key
    uint8_t key[DIRECT_KEY_LEN];    // the two share
    uint8_t id[4];                  // the first of the key's SHA-256, where the group's goes
} pair_t;

typedef struct
{
    uint8_t targets;
    uint32_t target[DIRECT_COMMAND_TARGETS];
    uint8_t len;
    uint8_t cmd[OTHERS_CMD_MAX];
} command_t;

static bool started;
static volatile bool running;
static bool paused;         // by direct_pause(), to start again after
static uint32_t own_id;
static uint32_t counter;

// The group, as it's used, on the task; and a new one, waiting for it
static mbedtls_gcm_context gcm;
static uint8_t group_id[4];
static volatile bool group_changed = true;
static char group_name[DIRECT_NAME_MAX];
static char own_name[DIRECT_NAME_MAX];

// Who's about: only the task writes, others copy it whole (peers_seq is odd
// while it's being written)
static peer_t peers[DIRECT_PEERS_MAX];
static volatile uint32_t peers_seq;

// Groups heard about over the air, from their beacons; as peers, only the
// task writes, and others copy it whole
#define GROUP_SENDERS       8
typedef struct
{
    uint8_t id[4];
    char name[DIRECT_NAME_MAX];
    uint32_t heard_ms;
    int8_t rssi;
    uint32_t senders[GROUP_SENDERS];    // the boards heard in it
    uint32_t sender_ms[GROUP_SENDERS];
    uint8_t channel;
    bool long_range;
    bool used;
} group_t;
static group_t groups[DIRECT_GROUPS_MAX];
static volatile uint32_t groups_seq;
static bool keyed;                      // in a group with a key, so it says so
static uint8_t radio_channel = DIRECT_CHANNEL_DEFAULT;
static bool radio_long_range;

// Scanning: the channel it's on, as an index into scan_channels, or -1
static volatile bool scan_wanted;
static volatile int scan_at = -1;
static uint32_t scan_ms;

// Broadcasts waiting to be passed on
typedef struct
{
    uint8_t msg[RCAT_HAL_DIRECT_MAX];
    uint8_t len;
    uint32_t sender, counter;
    uint32_t due_ms;
    bool used;
} relay_t;
static relay_t relays[RELAYS];

// Avatars: the wearer's, and each peer's (as peers[]), as much as has come:
// the pixels, which it has, and the pixels with those it hasn't filled in
// from the nearest coarser ones, to show
static uint16_t *own_avatar;
static volatile uint8_t own_avatar_version;
static uint16_t *avatar_order;          // the pixels, in the order they're sent
static uint16_t *peer_avatars;          // DIRECT_PEERS_MAX of them, filled in
static uint8_t *peer_known;             // DIRECT_PEERS_MAX bitmaps, a bit a pixel
static bool avatar_soon;                // a new board's about: send ours soon
static uint32_t avatar_full_ms, avatar_sketch_ms;   // when the last went
static int avatar_piece = -1;           // the next piece to go, -1 while none are
static int avatar_last;                 // the last piece of this round
static uint8_t resend[16];              // pieces of ours others asked for, a bit each
static int ask_next;                    // whose to ask for next, round the peers
static uint32_t avatar_piece_ms;

// The wearer's voice: one writer (the comm channel's encoder), one reader
static voice_t *voice_queue;
static volatile uint32_t voice_write, voice_read;

// Commands for others to send: one writer (the UI loop), one reader; the
// one going out, and how many more times it's to go
static command_t *command_queue;       // COMMAND_QUEUE of them, and the one going out after
static volatile uint32_t command_write, command_read;
static command_t *command_out;         // COMMAND_QUEUE of them, going out in turn
static uint8_t command_sends_left[COMMAND_QUEUE];
static uint32_t command_order[COMMAND_QUEUE];  // when each was queued, as command_read was
static uint32_t command_sent_ms;

#if DIRECT_DEBUG
static volatile uint32_t dbg_queued, dbg_queue_full;
static uint32_t dbg_sent, dbg_send_fail, dbg_heard, dbg_other, dbg_bad, dbg_replay, dbg_voice_in, dbg_recovered;
#define DBG(x) (x)
#else
#define DBG(x)
#endif

static direct_voice_cb_t voice_cb;
static void *voice_cb_data;
static volatile bool talking;   // the wearer, to anyone
static bool talking_alone;      // to one wearer alone, which the hellos don't say

// The pairs' keys: the UI loop writes, the others copy them whole (pairs_seq
// is odd while they're being written). The task keys pair_gcm with the one
// it used last.
static pair_t pairs[DIRECT_PAIRS_MAX];
static int pair_count;
static volatile uint32_t pairs_seq;
static mbedtls_gcm_context pair_gcm;
static uint8_t pair_gcm_id[4];
static bool pair_gcm_keyed;

/* The open group's key, which every board knows. */
static void open_key(uint8_t key[DIRECT_KEY_LEN])
{
    static const char seed[] = "DroneLab direct comms: the open group";
    uint8_t hash[32];
    mbedtls_sha256((const unsigned char *)seed, sizeof(seed) - 1, hash, 0);
    memcpy(key, hash, DIRECT_KEY_LEN);
}

static void use_group(void)
{
    const settings_t *s = settings_get();
    uint8_t key[DIRECT_KEY_LEN];
    if (s->direct_keyed)
    {
        memcpy(key, s->direct_key, sizeof(key));
    }
    else
    {
        open_key(key);
    }
    uint8_t hash[32];
    mbedtls_sha256(key, sizeof(key), hash, 0);
    memcpy(group_id, hash, sizeof(group_id));
    mbedtls_gcm_free(&gcm);
    mbedtls_gcm_init(&gcm);
    mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, 128);
    memset(key, 0, sizeof(key));
    snprintf(group_name, sizeof(group_name), "%s", s->direct_keyed ? s->direct_group : "Open");
    keyed = s->direct_keyed;
    radio_channel = keyed && s->direct_channel ? s->direct_channel : DIRECT_CHANNEL_DEFAULT;
    radio_long_range = keyed ? s->direct_long_range != 0 : true;     // the open group reaches as far as it can
    rcat_hal_direct_set_radio(radio_channel, radio_long_range);
    if (RCAT_DIRECT_ECHO)
    {
        snprintf(own_name, sizeof(own_name), "ECHO-%04lX", (unsigned long)(own_id & 0xFFFF));
    }
    else
    {
        snprintf(own_name, sizeof(own_name), "%s", s->direct_name[0] ? s->direct_name : comm_name());
    }

    // A different group: nobody from the old one's about
    __atomic_add_fetch(&peers_seq, 1, __ATOMIC_SEQ_CST);
    memset(peers, 0, sizeof(peers));
    __atomic_add_fetch(&peers_seq, 1, __ATOMIC_SEQ_CST);
}

static void nonce(uint8_t out[12], const uint8_t *header)
{
    memcpy(out, header + 6, 8);         // the sender, and the counter
    memcpy(out + 8, header + 2, 4);     // the group
}

static int copy_pairs(pair_t *out)
{
    uint32_t seq;
    int n;
    do
    {
        seq = __atomic_load_n(&pairs_seq, __ATOMIC_SEQ_CST);
        n = pair_count;
        memcpy(out, pairs, sizeof(pairs));
        __atomic_thread_fence(__ATOMIC_SEQ_CST);
    } while ((seq & 1) || seq != __atomic_load_n(&pairs_seq, __ATOMIC_SEQ_CST));
    return n < DIRECT_PAIRS_MAX ? n : DIRECT_PAIRS_MAX;
}

/* The pair with this id, or with the other wearer's key, if there's one. */
static bool find_pair(const uint8_t *id, const uint8_t *their, pair_t *out)
{
    pair_t copy[DIRECT_PAIRS_MAX];
    int n = copy_pairs(copy);
    for (int i = 0; i < n; i++)
    {
        if ((id != NULL && memcmp(copy[i].id, id, 4) == 0) ||
            (their != NULL && memcmp(copy[i].their, their, OTHERS_KEY_LEN) == 0))
        {
            *out = copy[i];
            memset(copy, 0, sizeof(copy));
            return true;
        }
    }
    memset(copy, 0, sizeof(copy));
    return false;
}

/* pair_gcm, keyed with this pair's key. On the task. */
static mbedtls_gcm_context *pair_cipher(const pair_t *pair)
{
    if (!pair_gcm_keyed || memcmp(pair_gcm_id, pair->id, 4) != 0)
    {
        mbedtls_gcm_free(&pair_gcm);
        mbedtls_gcm_init(&pair_gcm);
        mbedtls_gcm_setkey(&pair_gcm, MBEDTLS_CIPHER_ID_AES, pair->key, 128);
        memcpy(pair_gcm_id, pair->id, 4);
        pair_gcm_keyed = true;
    }
    return &pair_gcm;
}

/* Seal plain (len bytes) with this key, its id where the group's goes, and
 * broadcast it. */
static void send_sealed_with(mbedtls_gcm_context *key, const uint8_t *key_id, const uint8_t *plain, size_t len)
{
    uint8_t msg[RCAT_HAL_DIRECT_MAX];
    if (HEADER_LEN + len + TAG_LEN > sizeof(msg))
    {
        return;
    }
    uint32_t c = ++counter;
    msg[0] = MAGIC;
    msg[1] = DIRECT_VERSION;
    memcpy(msg + 2, key_id, 4);
    memcpy(msg + 6, &own_id, 4);
    msg[10] = (uint8_t)c;
    msg[11] = (uint8_t)(c >> 8);
    msg[12] = (uint8_t)(c >> 16);
    msg[13] = (uint8_t)(c >> 24);
    msg[14] = HOPS;
    uint8_t iv[12];
    nonce(iv, msg);
    if (mbedtls_gcm_crypt_and_tag(key, MBEDTLS_GCM_ENCRYPT, len, iv, sizeof(iv), msg, CHECKED_LEN, plain,
                                  msg + HEADER_LEN, TAG_LEN, msg + HEADER_LEN + len) == 0)
    {
        bool ok = rcat_hal_direct_send(msg, HEADER_LEN + len + TAG_LEN);
        DBG(ok ? dbg_sent++ : dbg_send_fail++);
        (void)ok;
    }
}

/* Seal plain with the group's key, and broadcast it. */
static void send_sealed(const uint8_t *plain, size_t len)
{
    send_sealed_with(&gcm, group_id, plain, len);
}

/* Say the group's here, for boards that aren't in it to see it and ask to
 * join: its id and name, and this board's id, not encrypted. */
static void send_beacon(void)
{
    uint8_t msg[12 + DIRECT_NAME_MAX];
    msg[0] = BEACON;
    msg[1] = DIRECT_VERSION;
    memcpy(msg + 2, group_id, 4);
    memcpy(msg + 6, &own_id, 4);
    msg[10] = radio_channel;
    msg[11] = radio_long_range ? BEACON_LR : 0;
    size_t n = strlen(group_name);
    memcpy(msg + 12, group_name, n);
    rcat_hal_direct_send(msg, 12 + n);
}

/* Broadcasts from boards with another version of direct comms, which can't
 * be heard: a few of them, not one stray, and it's said for a while after. */
#define OTHER_FIRMWARE_WINDOW_MS 10000
#define OTHER_FIRMWARE_COUNT     3
#define OTHER_FIRMWARE_MS        30000
static uint32_t other_firmware_window_ms, other_firmware_count;
static volatile uint32_t other_firmware_ms;

static void heard_other_firmware(const uint8_t *msg, size_t len, uint32_t now)
{
    if (len < 12 || (msg[0] != MAGIC && msg[0] != BEACON) || msg[1] == DIRECT_VERSION)
    {
        return;
    }
    if (now - other_firmware_window_ms > OTHER_FIRMWARE_WINDOW_MS)
    {
        other_firmware_window_ms = now;
        other_firmware_count = 0;
    }
    if (++other_firmware_count >= OTHER_FIRMWARE_COUNT)
    {
        other_firmware_ms = now | 1;    // never 0
    }
}

bool direct_other_firmware(void)
{
    uint32_t at = other_firmware_ms;
    return running && at != 0 && rcat_hal_millis() - at < OTHER_FIRMWARE_MS;
}

static void heard_beacon(const uint8_t *msg, size_t len, int8_t rssi, uint32_t now)
{
    if (len < 12 || msg[1] != DIRECT_VERSION)
    {
        heard_other_firmware(msg, len, now);
        return;
    }
    uint32_t sender;
    memcpy(&sender, msg + 6, 4);
    if (sender == own_id)
    {
        return;
    }
    __atomic_add_fetch(&groups_seq, 1, __ATOMIC_SEQ_CST);
    group_t *g = NULL, *spare = NULL;
    for (int i = 0; i < DIRECT_GROUPS_MAX; i++)
    {
        if (groups[i].used && memcmp(groups[i].id, msg + 2, 4) == 0)
        {
            g = &groups[i];
        }
        else if (spare == NULL && (!groups[i].used || now - groups[i].heard_ms > PEER_GONE_MS))
        {
            spare = &groups[i];
        }
    }
    if (g == NULL && spare != NULL)
    {
        g = spare;
        memset(g, 0, sizeof(*g));
        memcpy(g->id, msg + 2, 4);
        g->used = true;
    }
    if (g != NULL)
    {
        size_t n = len - 12 < DIRECT_NAME_MAX - 1 ? len - 12 : DIRECT_NAME_MAX - 1;
        memcpy(g->name, msg + 12, n);
        g->name[n] = '\0';
        g->channel = msg[10];
        g->long_range = (msg[11] & BEACON_LR) != 0;
        g->rssi = now - g->heard_ms > HELLO_EVERY_MS * 2 || rssi > g->rssi ? rssi : g->rssi;
        g->heard_ms = now;
        // Which boards are in it: this one, in its place or the oldest's
        int at = 0;
        for (int i = 0; i < GROUP_SENDERS; i++)
        {
            if (g->senders[i] == sender)
            {
                at = i;
                break;
            }
            if (g->sender_ms[i] < g->sender_ms[at])
            {
                at = i;
            }
        }
        g->senders[at] = sender;
        g->sender_ms[at] = now;
    }
    __atomic_add_fetch(&groups_seq, 1, __ATOMIC_SEQ_CST);
}

static bool avatar_ask(uint8_t out[ASK_LEN]);

/* Who we are, and, if we're missing pieces of a board's avatar, which. */
static void send_hello(void)
{
    uint8_t plain[2 + ASK_LEN + OTHERS_KEY_LEN + OTHERS_SIG_LEN + 2 * (1 + DIRECT_VERSION_MAX) + DIRECT_NAME_MAX];
    plain[0] = TYPE_HELLO;
    plain[1] = talking && !talking_alone ? HELLO_TALKING : 0;
    size_t at = 2;
    if (avatar_ask(plain + 2))
    {
        plain[1] |= HELLO_ASKS;
        at += ASK_LEN;
    }
    if (others_owner(plain + at, plain + at + OTHERS_KEY_LEN))
    {
        plain[1] |= HELLO_KEY;
        at += OTHERS_KEY_LEN + OTHERS_SIG_LEN;
    }
    char app[DIRECT_VERSION_MAX];
    snprintf(app, sizeof(app), comm_app_os()[0] ? "%s %s" : "%s%s", comm_app_os(), comm_app_version());
    const char *versions[2] = { rcat_hal_firmware_version(), app };
    for (int i = 0; i < 2; i++)
    {
        size_t v = strlen(versions[i]);
        v = v < DIRECT_VERSION_MAX - 1 ? v : DIRECT_VERSION_MAX - 1;
        plain[at++] = (uint8_t)v;
        memcpy(plain + at, versions[i], v);
        at += v;
    }
    size_t n = strlen(own_name);
    memcpy(plain + at, own_name, n);
    send_sealed(plain, at + n);
}

/* A packet of voice, with the REPEATS before it too, so that as many lost in
 * a row come back from the next: to the group, or sealed for one wearer
 * alone, if there's a pair's key for them (else it's dropped). */
static void send_voice(const voice_t *v)
{
    pair_t pair;
    if (v->alone && !find_pair(NULL, v->to, &pair))
    {
        return;
    }
    static voice_t before[REPEATS];     // newest first, from this task only
    uint8_t plain[RCAT_HAL_DIRECT_MAX];
    plain[0] = TYPE_VOICE;
    plain[1] = (uint8_t)v->seq;
    plain[2] = (uint8_t)(v->seq >> 8);
    plain[3] = v->flags;
    plain[4] = v->len;
    memcpy(plain + 5, v->opus, v->len);
    size_t len = 5 + v->len;
    // Each one before: its length, then it, as long as they follow on and fit
    for (int i = 0; i < REPEATS && !(v->flags & DIRECT_FIRST); i++)
    {
        const voice_t *b = &before[i];
        if (b->len == 0 || (uint16_t)(b->seq + 1 + i) != v->seq ||
            HEADER_LEN + len + 1 + b->len + TAG_LEN > RCAT_HAL_DIRECT_MAX)
        {
            break;
        }
        plain[len++] = b->len;
        memcpy(plain + len, b->opus, b->len);
        len += b->len;
    }
    if (v->alone)
    {
        send_sealed_with(pair_cipher(&pair), pair.id, plain, len);
        memset(&pair, 0, sizeof(pair));
    }
    else
    {
        send_sealed(plain, len);
    }
    memmove(&before[1], &before[0], (REPEATS - 1) * sizeof(before[0]));
    before[0] = *v;
    if (v->flags & DIRECT_LAST)
    {
        memset(before, 0, sizeof(before));
    }
}

/* The peer that sent this, made if it's new: the weakest or oldest goes. */
_Static_assert(HEADER_LEN + 2 + 4 * DIRECT_COMMAND_TARGETS + OTHERS_CMD_MAX + TAG_LEN <= RCAT_HAL_DIRECT_MAX,
               "a signed command for others doesn't fit in a broadcast");

/* A command for others, for the boards it's for (all of them, with none). */
static void send_command(const command_t *l)
{
    uint8_t plain[2 + 4 * DIRECT_COMMAND_TARGETS + OTHERS_CMD_MAX];
    plain[0] = TYPE_COMMAND;
    plain[1] = l->targets;
    memcpy(plain + 2, l->target, 4 * l->targets);
    size_t at = 2 + 4 * l->targets;
    memcpy(plain + at, l->cmd, l->len);
    send_sealed(plain, at + l->len);
}

/* A command heard: passed on, with who it's from and how it came over the
 * air, if it's for us. */
static void heard_command(const peer_t *p, const uint8_t *plain, size_t len, const others_radio_t *radio)
{
    if (len < 2 || 2 + 4 * (size_t)plain[1] > len)
    {
        return;
    }
    bool ours = plain[1] == 0;
    for (int i = 0; i < plain[1] && !ours; i++)
    {
        uint32_t t;
        memcpy(&t, plain + 2 + 4 * i, 4);
        ours = t == own_id;
    }
    if (ours)
    {
        size_t at = 2 + 4 * (size_t)plain[1];
        others_queue(p->name, plain + at, len - at, radio);
    }
}

/* A board's wearer's key, from its hello: believed once they've signed that
 * the board's theirs, which is checked when it's new, on another task, as
 * it takes too long to hold up the voice (heard_keys). */
static void heard_key(peer_t *p, const uint8_t *key, const uint8_t *sig)
{
    if (p->has_key && memcmp(p->key, key, OTHERS_KEY_LEN) == 0)
    {
        return;
    }
    p->has_key = false;
    if (p->key_asked && memcmp(p->asked_key, key, OTHERS_KEY_LEN) == 0)
    {
        return;     // being checked, or found wanting already
    }
    if (others_check_board(p->id, key, sig))
    {
        memcpy(p->asked_key, key, OTHERS_KEY_LEN);
        p->key_asked = true;
    }
}

/* Boards' keys that have been checked. */
static void heard_keys(void)
{
    uint32_t id;
    uint8_t key[OTHERS_KEY_LEN];
    bool good;
    while (others_board_checked(&id, key, &good))
    {
        __atomic_add_fetch(&peers_seq, 1, __ATOMIC_SEQ_CST);
        for (int i = 0; i < DIRECT_PEERS_MAX; i++)
        {
            peer_t *p = &peers[i];
            if (p->used && p->id == id && p->key_asked && memcmp(p->asked_key, key, OTHERS_KEY_LEN) == 0)
            {
                p->has_key = good;
                if (good)
                {
                    memcpy(p->key, key, OTHERS_KEY_LEN);
                }
                else
                {
                    printf("direct: %s says it's someone it can't prove it is\n", p->name);
                }
            }
        }
        __atomic_add_fetch(&peers_seq, 1, __ATOMIC_SEQ_CST);
    }
}

static peer_t *find_peer(uint32_t id, uint32_t now)
{
    peer_t *spare = NULL;
    for (int i = 0; i < DIRECT_PEERS_MAX; i++)
    {
        if (peers[i].used && peers[i].id == id)
        {
            return &peers[i];
        }
        if (!peers[i].used || now - peers[i].heard_ms > PEER_GONE_MS)
        {
            spare = spare != NULL ? spare : &peers[i];
        }
    }
    if (spare == NULL)
    {
        spare = &peers[0];
        for (int i = 1; i < DIRECT_PEERS_MAX; i++)
        {
            if (peers[i].heard_ms < spare->heard_ms)
            {
                spare = &peers[i];
            }
        }
    }
    memset(spare, 0, sizeof(*spare));
    spare->id = id;
    spare->used = true;
    avatar_soon = true;     // a board that hasn't seen ours
    snprintf(spare->name, sizeof(spare->name), "%08lX", (unsigned long)id);    // until its hello
    return spare;
}

/* ----- Relaying ----- */

static void relay_later(const uint8_t *msg, size_t len, uint32_t sender, uint32_t c, uint32_t now)
{
    for (int i = 0; i < RELAYS; i++)
    {
        relay_t *r = &relays[i];
        if (!r->used)
        {
            memcpy(r->msg, msg, len);
            r->msg[14]--;       // one hop fewer
            r->len = (uint8_t)len;
            r->sender = sender;
            r->counter = c;
            r->due_ms = now + RELAY_WAIT_MIN_MS + rcat_hal_random() % (RELAY_WAIT_MAX_MS - RELAY_WAIT_MIN_MS + 1);
            r->used = true;
            return;
        }
    }
}

/* Another board passed it on first: no need. */
static void relay_cancel(uint32_t sender, uint32_t c)
{
    for (int i = 0; i < RELAYS; i++)
    {
        if (relays[i].used && relays[i].sender == sender && relays[i].counter == c)
        {
            relays[i].used = false;
        }
    }
}

static void relay_due(uint32_t now)
{
    for (int i = 0; i < RELAYS; i++)
    {
        if (relays[i].used && (int32_t)(now - relays[i].due_ms) >= 0)
        {
            rcat_hal_direct_send(relays[i].msg, relays[i].len);
            relays[i].used = false;
        }
    }
}

/* ----- Avatars ----- */

/* The order the pixels go in: every 8th pixel each way first, then every
 * 4th, then every 2nd, then the rest, so what's come shows the whole
 * picture, coarse at first and finer as more comes. */
static void make_avatar_order(void)
{
    int n = 0;
    for (int step = 8; step >= 1; step /= 2)
    {
        for (int y = 0; y < DIRECT_AVATAR_PX; y += step)
        {
            for (int x = 0; x < DIRECT_AVATAR_PX; x += step)
            {
                // Only those not in a coarser layer already
                if (step == 8 || x % (step * 2) != 0 || y % (step * 2) != 0)
                {
                    avatar_order[n++] = (uint16_t)(y * DIRECT_AVATAR_PX + x);
                }
            }
        }
    }
}

static void send_avatar_piece(int piece)
{
    uint8_t plain[4 + 2 * AVATAR_PIECE];
    int at = piece * AVATAR_PIECE;
    int n = AVATAR_PIXELS - at < AVATAR_PIECE ? AVATAR_PIXELS - at : AVATAR_PIECE;
    plain[0] = TYPE_AVATAR;
    plain[1] = own_avatar_version;
    plain[2] = (uint8_t)piece;
    plain[3] = AVATAR_PIECES;
    for (int i = 0; i < n; i++)
    {
        uint16_t v = own_avatar[avatar_order[at + i]];
        plain[4 + 2 * i] = (uint8_t)v;
        plain[5 + 2 * i] = (uint8_t)(v >> 8);
    }
    send_sealed(plain, 4 + 2 * (size_t)n);
}

static bool known(const uint8_t *bits, int i)
{
    return (bits[i >> 3] >> (i & 7)) & 1;
}

/* Fill in each pixel that hasn't come from the nearest coarser one that has:
 * blocks to start with, sharper as more comes. */
static void fill_avatar(uint16_t *pixels, const uint8_t *bits)
{
    for (int y = 0; y < DIRECT_AVATAR_PX; y++)
    {
        for (int x = 0; x < DIRECT_AVATAR_PX; x++)
        {
            int i = y * DIRECT_AVATAR_PX + x;
            if (known(bits, i))
            {
                continue;
            }
            for (int mask = ~1; mask >= ~7; mask = mask * 2)
            {
                int j = (y & mask) * DIRECT_AVATAR_PX + (x & mask);
                if (known(bits, j))
                {
                    pixels[i] = pixels[j];
                    break;
                }
            }
        }
    }
}

static void heard_avatar_piece(peer_t *p, const uint8_t *plain, size_t len)
{
    if (len < 4 || peer_avatars == NULL || plain[1] == 0 || plain[3] != AVATAR_PIECES || plain[2] >= AVATAR_PIECES)
    {
        return;
    }
    uint8_t version = plain[1];
    int at = plain[2] * AVATAR_PIECE;
    int n = AVATAR_PIXELS - at < AVATAR_PIECE ? AVATAR_PIXELS - at : AVATAR_PIECE;
    if (len - 4 != 2 * (size_t)n)
    {
        return;
    }
    size_t slot = (size_t)(p - peers);
    uint16_t *pixels = peer_avatars + slot * AVATAR_PIXELS;
    uint8_t *bits = peer_known + slot * (AVATAR_PIXELS / 8);
    if (version != p->avatar_version)
    {
        // A new picture: start afresh, from the board's head in a visor
        memset(bits, 0, AVATAR_PIXELS / 8);
        p->avatar_version = version;
    }
    bool news = false;
    for (int i = 0; i < n; i++)
    {
        int k = avatar_order[at + i];
        news |= !known(bits, k);
        pixels[k] = (uint16_t)(plain[4 + 2 * i] | (plain[5 + 2 * i] << 8));
        bits[k >> 3] |= (uint8_t)(1 << (k & 7));
    }
    if (news)
    {
        fill_avatar(pixels, bits);
        p->avatar_changes++;
    }
#if RCAT_DIRECT_ECHO
    // The echo board takes on the avatar it's sent, once it's all come, to
    // send back as its own
    bool all = true;
    for (int i = 0; i < AVATAR_PIXELS / 8 && all; i++)
    {
        all = bits[i] == 0xFF;
    }
    if (all && news)
    {
        direct_set_avatar(pixels, DIRECT_AVATAR_PX);
    }
#endif
}

/* The pieces of a peer's avatar still missing, a bit each: true if any are. */
static bool missing_pieces(const peer_t *p, uint8_t out[16])
{
    const uint8_t *bits = peer_known + (size_t)(p - peers) * (AVATAR_PIXELS / 8);
    bool any = false;
    memset(out, 0, 16);
    for (int piece = 0; piece < AVATAR_PIECES; piece++)
    {
        int end = (piece + 1) * AVATAR_PIECE < AVATAR_PIXELS ? (piece + 1) * AVATAR_PIECE : AVATAR_PIXELS;
        for (int i = piece * AVATAR_PIECE; i < end; i++)
        {
            if (!known(bits, avatar_order[i]))
            {
                out[piece >> 3] |= (uint8_t)(1 << (piece & 7));
                any = true;
                break;
            }
        }
    }
    return any;
}

/* Ask for the pieces missing of one board's avatar, a different board each
 * time round. */
static bool avatar_ask(uint8_t out[ASK_LEN])
{
    if (peer_avatars == NULL)
    {
        return false;
    }
    for (int k = 0; k < DIRECT_PEERS_MAX; k++)
    {
        peer_t *p = &peers[(ask_next + k) % DIRECT_PEERS_MAX];
        if (p->used && p->avatar_version != 0 && missing_pieces(p, out + 5))
        {
            memcpy(out, &p->id, 4);
            out[4] = p->avatar_version;
            ask_next = (int)(p - peers) + 1;
            return true;
        }
    }
    return false;
}

/* Another board asks for pieces: if they're of ours, as it is, send them. */
static void heard_ask(const uint8_t *ask)
{
    uint32_t whose;
    memcpy(&whose, ask, 4);
    if (whose == own_id && ask[4] == own_avatar_version && own_avatar_version != 0)
    {
        for (int i = 0; i < 16; i++)
        {
            resend[i] |= ask[5 + i];
        }
    }
}

/* A packet of another board's voice: to the phone, or back out again. */
static void deliver(uint32_t id, uint16_t seq, uint8_t flags, const uint8_t *opus, size_t len)
{
#if RCAT_DIRECT_ECHO
    voice_t v = { .seq = seq, .flags = (uint8_t)(flags & (DIRECT_FIRST | DIRECT_LAST)), .len = (uint8_t)len };
    memcpy(v.opus, opus, len);
    talking = !(flags & DIRECT_LAST);
    send_voice(&v);
#endif
    if (voice_cb != NULL)
    {
        voice_cb(id, seq, flags, opus, len, voice_cb_data);
    }
}

/* Another group's broadcasts, to tell when someone's talking in it: voice
 * comes several to the half second, where the hellos are seconds apart. */
#define OTHER_WINDOW_MS     500
#define OTHER_VOICE_COUNT   4
#define OTHER_VOICE_MS      600         // talking for this long after
static uint32_t other_window_ms, other_count;
static volatile uint32_t other_voice_ms;

static void heard_other(uint32_t now)
{
    if (now - other_window_ms > OTHER_WINDOW_MS)
    {
        other_window_ms = now;
        other_count = 0;
    }
    if (++other_count >= OTHER_VOICE_COUNT)
    {
        other_voice_ms = now | 1;   // never 0
    }
}

bool direct_other_voice(void)
{
    uint32_t at = other_voice_ms;
    return running && at != 0 && rcat_hal_millis() - at < OTHER_VOICE_MS;
}

/* A board of the group's that's about, if this is one; NULL if not. */
static peer_t *known_peer(uint32_t id, uint32_t now)
{
    for (int i = 0; i < DIRECT_PEERS_MAX; i++)
    {
        if (peers[i].used && peers[i].id == id && now - peers[i].heard_ms <= PEER_GONE_MS)
        {
            return &peers[i];
        }
    }
    return NULL;
}

/* One of ours talking to another of ours alone, which can't be opened here:
 * only passed on, as the group's are, if it's heard from far off. Its
 * counter can't be trusted, as it can't be checked, so it isn't kept. */
static void passing_by(const peer_t *p, const uint8_t *msg, size_t len, uint32_t c, int8_t rssi, uint32_t now)
{
    if (msg[14] == 0)
    {
        relay_cancel(p->id, c);     // passed on by another: no need for us to
    }
    else if (rssi < RELAY_RSSI && (int32_t)(c - p->counter) > 0 && !RCAT_DIRECT_ECHO)
    {
        relay_later(msg, len, p->id, c, now);
    }
}

static void heard(const uint8_t *msg, size_t len, int8_t rssi, uint32_t now)
{
    DBG(dbg_heard++);
    if (len > 0 && msg[0] == BEACON)
    {
        heard_beacon(msg, len, rssi, now);
        return;
    }
    if (len < HEADER_LEN + 1 + TAG_LEN || msg[0] != MAGIC || msg[1] != DIRECT_VERSION)
    {
        DBG(dbg_other++);
        if (len >= HEADER_LEN && msg[0] == MAGIC && msg[1] == DIRECT_VERSION)
        {
            heard_other(now);
        }
        heard_other_firmware(msg, len, now);
        return;     // not ours: another version
    }
    uint32_t id, c;
    memcpy(&id, msg + 6, 4);
    if (id == own_id)
    {
        return;
    }
    c = msg[10] | (msg[11] << 8) | (msg[12] << 16) | ((uint32_t)msg[13] << 24);

    // The group's; or from one of ours, for this board alone, or for another
    // of ours alone; or another group's
    bool alone = memcmp(msg + 2, group_id, 4) != 0;
    pair_t pair;
    if (alone)
    {
        peer_t *from = known_peer(id, now);
        if (from == NULL)
        {
            DBG(dbg_other++);
            heard_other(now);
            return;     // another group's
        }
        if (!find_pair(msg + 2, NULL, &pair) || !from->has_key ||
            memcmp(from->key, pair.their, OTHERS_KEY_LEN) != 0)
        {
            passing_by(from, msg, len, c, rssi, now);
            return;
        }
    }
    size_t plain_len = len - HEADER_LEN - TAG_LEN;
    uint8_t plain[RCAT_HAL_DIRECT_MAX];
    uint8_t iv[12];
    nonce(iv, msg);
    int bad = mbedtls_gcm_auth_decrypt(alone ? pair_cipher(&pair) : &gcm, plain_len, iv, sizeof(iv), msg,
                                       CHECKED_LEN, msg + HEADER_LEN + plain_len, TAG_LEN, msg + HEADER_LEN, plain);
    if (alone)
    {
        memset(&pair, 0, sizeof(pair));
    }
    if (bad != 0 || (alone && plain[0] != TYPE_VOICE))
    {
        DBG(dbg_bad++);
        return;     // not the key, or tampered with; or more than voice for one alone
    }

    __atomic_add_fetch(&peers_seq, 1, __ATOMIC_SEQ_CST);
    peer_t *p = find_peer(id, now);
    others_radio_t radio = { .broadcast = c, .rssi = rssi, .hops = msg[14] < HOPS ? HOPS - msg[14] : 0,
                             .len = len < 255 ? (uint8_t)len : 255 };
    bool fresh = p->counter == 0 || (int32_t)(c - p->counter) > 0;
    if (!fresh)
    {
        relay_cancel(id, c);    // passed on by another: no need for us to
    }
    else if (!alone && msg[14] > 0 && rssi < RELAY_RSSI && !RCAT_DIRECT_ECHO)
    {
        relay_later(msg, len, id, c, now);  // heard from far off: pass it on
    }
    if (fresh)
    {
        p->counter = c;
        p->heard_ms = now;
        p->rssi = rssi;
        if (plain[0] == TYPE_HELLO && plain_len >= 2)
        {
            size_t at = 2;
            if ((plain[1] & HELLO_ASKS) && plain_len >= 2 + ASK_LEN)
            {
                heard_ask(plain + 2);
                at += ASK_LEN;
            }
            if ((plain[1] & HELLO_KEY) && at + OTHERS_KEY_LEN + OTHERS_SIG_LEN <= plain_len)
            {
                heard_key(p, plain + at, plain + at + OTHERS_KEY_LEN);
                at += OTHERS_KEY_LEN + OTHERS_SIG_LEN;
            }
            else
            {
                p->has_key = false;
            }
            char *versions[2] = { p->firmware, p->app };
            for (int i = 0; i < 2 && at < plain_len && at + 1 + plain[at] <= plain_len; i++)
            {
                size_t v = plain[at] < DIRECT_VERSION_MAX - 1 ? plain[at] : DIRECT_VERSION_MAX - 1;
                memcpy(versions[i], plain + at + 1, v);
                versions[i][v] = '\0';
                at += 1 + plain[at];
            }
            size_t n = plain_len - at < DIRECT_NAME_MAX - 1 ? plain_len - at : DIRECT_NAME_MAX - 1;
            memcpy(p->name, plain + at, n);
            p->name[n] = '\0';
        }
        else if (plain[0] == TYPE_VOICE && plain_len >= 5)
        {
            p->voice_ms = (plain[3] & DIRECT_LAST) ? 0 : now;
        }
        else if (plain[0] == TYPE_AVATAR)
        {
            heard_avatar_piece(p, plain, plain_len);
        }
        else if (plain[0] == TYPE_COMMAND)
        {
            heard_command(p, plain, plain_len, &radio);
        }
    }
    else if (plain[0] == TYPE_COMMAND && p->counter - c < RADIO_COPY_WINDOW)
    {
        // A broadcast heard already, passed on by another board: a copy of a
        // command, for the app's details of a text; others does it only once
        heard_command(p, plain, plain_len, &radio);
    }
    __atomic_add_fetch(&peers_seq, 1, __ATOMIC_SEQ_CST);

    DBG(fresh ? 0 : dbg_replay++);
    if (fresh && plain[0] == TYPE_VOICE && plain_len >= 5 && 5 + (size_t)plain[4] <= plain_len)
    {
        DBG(dbg_voice_in++);
        uint16_t seq = plain[1] | (plain[2] << 8);
        uint8_t flags = (uint8_t)((plain[3] & (DIRECT_FIRST | DIRECT_LAST)) | (alone ? DIRECT_PRIVATE : 0));
        size_t cur_len = plain[4];
        const uint8_t *cur = plain + 5;
        // Those before it that went missing are in it too, newest first
        int missed = p->voice_seen ? (int16_t)(seq - p->voice_seq) - 1 : 0;
        p->voice_seq = seq;
        p->voice_seen = !(flags & DIRECT_LAST);
        if (missed > 0 && missed <= REPEATS)
        {
            const uint8_t *at[REPEATS];
            size_t lens[REPEATS];
            int have = 0;
            size_t pos = 5 + cur_len;
            while (have < REPEATS && pos < plain_len && pos + 1 + plain[pos] <= plain_len)
            {
                lens[have] = plain[pos];
                at[have++] = plain + pos + 1;
                pos += 1 + plain[pos];
            }
            for (int i = (missed < have ? missed : have) - 1; i >= 0; i--)
            {
                DBG(dbg_recovered++);
                deliver(id, (uint16_t)(seq - 1 - i), alone ? DIRECT_PRIVATE : 0, at[i], lens[i]);
            }
        }
        deliver(id, seq, flags, cur, cur_len);
    }
}

static void direct_task(void *arg)
{
    uint32_t hello_ms = 0;
    for (;;)
    {
        if (!running)
        {
            rcat_hal_delay_ms(TASK_IDLE_MS);
            continue;
        }
        uint32_t now = rcat_hal_millis();
        if (group_changed)
        {
            group_changed = false;
            use_group();
            hello_ms = now - HELLO_EVERY_MS;    // say hello to the new group now
        }

        // The wearer's voice first, as it's waiting on the radio
        while (voice_read != __atomic_load_n(&voice_write, __ATOMIC_ACQUIRE))
        {
            voice_t *v = &voice_queue[voice_read % VOICE_QUEUE];
            talking = !(v->flags & DIRECT_LAST);
            talking_alone = talking && v->alone;
            send_voice(v);
            __atomic_store_n(&voice_read, voice_read + 1, __ATOMIC_RELEASE);
        }

        uint8_t msg[RCAT_HAL_DIRECT_MAX];
        int8_t rssi;
        size_t len;
        while ((len = rcat_hal_direct_receive(msg, sizeof(msg), &rssi)) > 0)
        {
            heard(msg, len, rssi, now);
        }
        heard_keys();
        relay_due(now);

        // Commands for others, each a few times over. Those going take
        // turns, so the copies of each are spread out, and a moment's
        // interference doesn't take all of one (a long text's parts, most
        // of all): the one sent fewest times goes next, the oldest of
        // those first, so each one's first copy goes in the order they
        // came, as a board only does one newer than the last it did
        if (now - command_sent_ms >= COMMAND_GAP_MS)
        {
            for (int i = 0; i < COMMAND_QUEUE; i++)
            {
                if (command_sends_left[i] == 0 && command_read != __atomic_load_n(&command_write, __ATOMIC_ACQUIRE))
                {
                    command_out[i] = command_queue[command_read % COMMAND_QUEUE];
                    command_order[i] = command_read;
                    __atomic_store_n(&command_read, command_read + 1, __ATOMIC_RELEASE);
                    command_sends_left[i] = COMMAND_SENDS;
                }
            }
            int next = -1;
            for (int i = 0; i < COMMAND_QUEUE; i++)
            {
                if (command_sends_left[i] > 0
                    && (next < 0 || command_sends_left[i] > command_sends_left[next]
                        || (command_sends_left[i] == command_sends_left[next]
                            && (int32_t)(command_order[i] - command_order[next]) < 0)))
                {
                    next = i;
                }
            }
            if (next >= 0)
            {
                command_sent_ms = now;
                command_sends_left[next]--;
                send_command(&command_out[next]);
            }
        }

        // Scanning: a couple of seconds on each channel, then back
        if (scan_wanted && scan_at < 0)
        {
            scan_wanted = rcat_hal_direct_listen_on(scan_channels[0]);
            scan_at = scan_wanted ? 0 : -1;
            scan_ms = now;
        }
        if (scan_at >= 0)
        {
            if (now - scan_ms >= SCAN_DWELL_MS)
            {
                scan_ms = now;
                if (++scan_at < (int)sizeof(scan_channels))
                {
                    rcat_hal_direct_listen_on(scan_channels[scan_at]);
                }
                else
                {
                    rcat_hal_direct_listen_on(0);
                    scan_at = -1;
                    scan_wanted = false;
                }
            }
            rcat_hal_delay_ms(TASK_BUSY_MS);
            continue;   // nobody of ours to hear what's sent meanwhile
        }

        // Our avatar: all of it soon after a new board's heard, and now and
        // then; the coarse layers more often. Not while talking.
        if (avatar_piece < 0 && own_avatar_version != 0 && !talking)
        {
            if ((avatar_soon && now - avatar_full_ms >= AVATAR_SOON_MS) || now - avatar_full_ms >= AVATAR_FULL_MS)
            {
                avatar_piece = 0;
                avatar_last = AVATAR_PIECES - 1;
                avatar_soon = false;
                avatar_full_ms = avatar_sketch_ms = now;
            }
            else if (now - avatar_sketch_ms >= AVATAR_SKETCH_MS)
            {
                avatar_piece = 0;
                avatar_last = AVATAR_SKETCH_PIECES - 1;
                avatar_sketch_ms = now;
            }
        }
        if (avatar_piece >= 0 && !talking && now - avatar_piece_ms >= AVATAR_PIECE_MS)
        {
            avatar_piece_ms = now;
            send_avatar_piece(avatar_piece);
            avatar_piece = avatar_piece < avatar_last ? avatar_piece + 1 : -1;
        }
        else if (avatar_piece < 0 && !talking && own_avatar_version != 0 && now - avatar_piece_ms >= AVATAR_PIECE_MS)
        {
            // Pieces others asked for, between rounds
            for (int piece = 0; piece < AVATAR_PIECES; piece++)
            {
                if (resend[piece >> 3] & (1 << (piece & 7)))
                {
                    resend[piece >> 3] &= (uint8_t)~(1 << (piece & 7));
                    avatar_piece_ms = now;
                    send_avatar_piece(piece);
                    break;
                }
            }
        }

        if (now - hello_ms >= HELLO_EVERY_MS)
        {
            hello_ms = now;
            send_hello();
            if (keyed)
            {
                send_beacon();
            }
#if DIRECT_DEBUG
            printf("direct: sent %lu (%lu failed), voice queued %lu (%lu full); heard %lu: %lu not ours, %lu bad, "
                   "%lu replayed, %lu voice, %lu recovered\n",
                   (unsigned long)dbg_sent, (unsigned long)dbg_send_fail, (unsigned long)dbg_queued,
                   (unsigned long)dbg_queue_full, (unsigned long)dbg_heard, (unsigned long)dbg_other,
                   (unsigned long)dbg_bad, (unsigned long)dbg_replay, (unsigned long)dbg_voice_in,
                   (unsigned long)dbg_recovered);
            dbg_sent = dbg_send_fail = dbg_queued = dbg_queue_full = dbg_heard = dbg_other = dbg_bad = dbg_replay =
                dbg_voice_in = dbg_recovered = 0;
#endif
        }
        rcat_hal_delay_ms(TASK_BUSY_MS);
    }
}

void direct_key(const char *group, const char *passphrase, uint8_t key[DIRECT_KEY_LEN])
{
    char salt[32 + DIRECT_NAME_MAX];
    int n = snprintf(salt, sizeof(salt), "dronelab-direct\n%s", group);
    mbedtls_pkcs5_pbkdf2_hmac_ext(MBEDTLS_MD_SHA256, (const unsigned char *)passphrase, strlen(passphrase),
                                  (const unsigned char *)salt, (size_t)n, DIRECT_KEY_ROUNDS, DIRECT_KEY_LEN, key);
}

void direct_init(void)
{
    own_id = rcat_hal_random();
    voice_queue = calloc(VOICE_QUEUE, sizeof(voice_t));
    // Out of internal RAM, which WiFi and Bluetooth need (PSRAM first)
    command_queue = lv_malloc(2 * COMMAND_QUEUE * sizeof(command_t));
    command_out = command_queue != NULL ? &command_queue[COMMAND_QUEUE] : NULL;
    // Big enough to go in PSRAM
    own_avatar = calloc(AVATAR_PIXELS, sizeof(uint16_t));
    avatar_order = calloc(AVATAR_PIXELS, sizeof(uint16_t));
    peer_avatars = calloc((size_t)DIRECT_PEERS_MAX * AVATAR_PIXELS, sizeof(uint16_t));
    peer_known = calloc((size_t)DIRECT_PEERS_MAX * AVATAR_PIXELS / 8, 1);
    if (avatar_order != NULL)
    {
        make_avatar_order();
    }
    if (avatar_order == NULL || peer_known == NULL)
    {
        free(peer_avatars);
        peer_avatars = NULL;
    }
    mbedtls_gcm_init(&gcm);
    mbedtls_gcm_init(&pair_gcm);
    const settings_t *s = settings_get();
    if (voice_queue == NULL || !rcat_hal_task_start("direct", direct_task, NULL, TASK_STACK))
    {
        return;
    }
    started = true;
    if (RCAT_DIRECT_ECHO && !s->direct_keyed)
    {
        uint8_t key[DIRECT_KEY_LEN];
        direct_key(ECHO_GROUP, ECHO_PASSPHRASE, key);
        settings_set_direct_group(key, ECHO_GROUP, "");
        settings_set_direct_radio(RCAT_DIRECT_ECHO_CHANNEL, RCAT_DIRECT_ECHO_LR);
    }
    if (s->direct_on || RCAT_DIRECT_ECHO)
    {
        direct_start();
    }
}

bool direct_available(void)
{
    return started;
}

bool direct_start(void)
{
    paused = false;
    if (!started || (!running && !rcat_hal_direct_start()))
    {
        return false;
    }
    running = true;
    settings_set_direct(1);
    return true;
}

void direct_stop(void)
{
    paused = false;     // and it stays off
    if (running)
    {
        running = false;
        rcat_hal_direct_stop();
    }
    if (started)
    {
        settings_set_direct(0);
    }
}

void direct_pause(bool pause)
{
    if (pause && running)
    {
        running = false;
        rcat_hal_direct_stop();
        paused = true;
    }
    else if (!pause && paused)
    {
        paused = false;
        running = started && rcat_hal_direct_start();
    }
}

bool direct_running(void)
{
    return running;
}

void direct_set_group(const uint8_t *key, const char *group, const char *name, uint8_t channel, bool long_range)
{
    settings_set_direct_group(key, group, name);
    settings_set_direct_radio(channel, long_range);
    group_changed = true;   // the task takes it up
}

uint8_t direct_channel(void)
{
    return radio_channel;
}

bool direct_long_range(void)
{
    return radio_long_range;
}

void direct_scan(void)
{
    if (running)
    {
        scan_wanted = true;
    }
}

bool direct_scanning(void)
{
    return scan_wanted;
}

void direct_set_avatar(const uint16_t *pixels, int px)
{
    if (own_avatar == NULL)
    {
        return;
    }
    if (pixels == NULL || px <= 0)
    {
        own_avatar_version = 0;
        return;
    }
    // Shrink it, each pixel the average of those it covers
    uint32_t hash = 2166136261u;
    for (int y = 0; y < DIRECT_AVATAR_PX; y++)
    {
        for (int x = 0; x < DIRECT_AVATAR_PX; x++)
        {
            int y0 = y * px / DIRECT_AVATAR_PX, y1 = (y + 1) * px / DIRECT_AVATAR_PX;
            int x0 = x * px / DIRECT_AVATAR_PX, x1 = (x + 1) * px / DIRECT_AVATAR_PX;
            uint32_t r = 0, g = 0, b = 0, n = 0;
            for (int sy = y0; sy < (y1 > y0 ? y1 : y0 + 1); sy++)
            {
                for (int sx = x0; sx < (x1 > x0 ? x1 : x0 + 1); sx++)
                {
                    uint16_t v = pixels[sy * px + sx];
                    r += v >> 11;
                    g += (v >> 5) & 0x3F;
                    b += v & 0x1F;
                    n++;
                }
            }
            uint16_t v = (uint16_t)(((r / n) << 11) | ((g / n) << 5) | (b / n));
            own_avatar[y * DIRECT_AVATAR_PX + x] = v;
            hash = (hash ^ (v & 0xFF)) * 16777619u;
            hash = (hash ^ (v >> 8)) * 16777619u;
        }
    }
    uint8_t version = (uint8_t)(hash | 1);  // never 0
    if (version != own_avatar_version)
    {
        own_avatar_version = version;
        memset(resend, 0, sizeof(resend));
        avatar_soon = true;
    }
}

const uint16_t *direct_avatar(const char *name, uint8_t *version)
{
    peer_t copy[DIRECT_PEERS_MAX];
    uint32_t seq;
    do
    {
        seq = __atomic_load_n(&peers_seq, __ATOMIC_SEQ_CST);
        memcpy(copy, peers, sizeof(copy));
        __atomic_thread_fence(__ATOMIC_SEQ_CST);
    } while ((seq & 1) || seq != __atomic_load_n(&peers_seq, __ATOMIC_SEQ_CST));
    for (int i = 0; i < DIRECT_PEERS_MAX && peer_avatars != NULL; i++)
    {
        if (copy[i].used && copy[i].avatar_version != 0 && strcmp(copy[i].name, name) == 0)
        {
            *version = copy[i].avatar_changes;
            return peer_avatars + (size_t)i * AVATAR_PIXELS;
        }
    }
    return NULL;
}

const char *direct_group_name(void)
{
    return group_name;
}

const char *direct_own_name(void)
{
    return own_name;
}

void direct_send_voice(uint16_t seq, uint8_t flags, const uint8_t *opus, size_t len, const uint8_t *to)
{
    if (!running || voice_queue == NULL || len > MAX_OPUS)
    {
        return;
    }
    uint32_t w = voice_write;
    if (w - __atomic_load_n(&voice_read, __ATOMIC_ACQUIRE) >= VOICE_QUEUE)
    {
        DBG(dbg_queue_full++);
        return;     // the radio's fallen behind: drop it, as a lost packet
    }
    DBG(dbg_queued++);
    voice_t *v = &voice_queue[w % VOICE_QUEUE];
    v->seq = seq;
    v->flags = flags;
    v->len = (uint8_t)len;
    if (len > 0)
    {
        memcpy(v->opus, opus, len);
    }
    v->alone = to != NULL;
    if (to != NULL)
    {
        memcpy(v->to, to, OTHERS_KEY_LEN);
    }
    __atomic_store_n(&voice_write, w + 1, __ATOMIC_RELEASE);
}

void direct_clear_pairs(void)
{
    __atomic_add_fetch(&pairs_seq, 1, __ATOMIC_SEQ_CST);
    memset(pairs, 0, sizeof(pairs));
    pair_count = 0;
    __atomic_add_fetch(&pairs_seq, 1, __ATOMIC_SEQ_CST);
}

void direct_add_pair(const uint8_t *their_key, const uint8_t *key)
{
    uint8_t hash[32];
    mbedtls_sha256(key, DIRECT_KEY_LEN, hash, 0);
    __atomic_add_fetch(&pairs_seq, 1, __ATOMIC_SEQ_CST);
    // In place of theirs, if there's one already
    int at = 0;
    while (at < pair_count && memcmp(pairs[at].their, their_key, OTHERS_KEY_LEN) != 0)
    {
        at++;
    }
    if (at < DIRECT_PAIRS_MAX)
    {
        memcpy(pairs[at].their, their_key, OTHERS_KEY_LEN);
        memcpy(pairs[at].key, key, DIRECT_KEY_LEN);
        memcpy(pairs[at].id, hash, 4);
        pair_count = at < pair_count ? pair_count : at + 1;
    }
    __atomic_add_fetch(&pairs_seq, 1, __ATOMIC_SEQ_CST);
}

bool direct_can_reach(const uint8_t *their_key)
{
    pair_t pair;
    if (!running || !find_pair(NULL, their_key, &pair))
    {
        return false;
    }
    memset(&pair, 0, sizeof(pair));
    direct_peer_t about[DIRECT_PEERS_MAX];
    int n = direct_peers(about, DIRECT_PEERS_MAX);
    for (int i = 0; i < n; i++)
    {
        if (about[i].has_key && memcmp(about[i].key, their_key, OTHERS_KEY_LEN) == 0)
        {
            return true;
        }
    }
    return false;
}

void direct_set_voice_cb(direct_voice_cb_t cb, void *user_data)
{
    voice_cb_data = user_data;
    voice_cb = cb;
}

bool direct_send_command(const uint32_t *targets, int count, const uint8_t *cmd, size_t len)
{
    if (!running || command_queue == NULL || count < 0 || count > DIRECT_COMMAND_TARGETS || len > OTHERS_CMD_MAX)
    {
        return false;
    }
    uint32_t w = command_write;
    if (w - __atomic_load_n(&command_read, __ATOMIC_ACQUIRE) >= COMMAND_QUEUE)
    {
        return false;
    }
    command_t *l = &command_queue[w % COMMAND_QUEUE];
    l->targets = (uint8_t)count;
    memcpy(l->target, targets, 4 * (size_t)count);
    l->len = (uint8_t)len;
    memcpy(l->cmd, cmd, len);
    __atomic_store_n(&command_write, w + 1, __ATOMIC_RELEASE);
    return true;
}

uint32_t direct_own_id(void)
{
    return own_id;
}

void direct_group_id(uint8_t out[4])
{
    memcpy(out, group_id, 4);
}

int direct_groups(direct_group_t *out, int max)
{
    group_t copy[DIRECT_GROUPS_MAX];
    uint32_t seq;
    do
    {
        seq = __atomic_load_n(&groups_seq, __ATOMIC_SEQ_CST);
        memcpy(copy, groups, sizeof(copy));
        __atomic_thread_fence(__ATOMIC_SEQ_CST);
    } while ((seq & 1) || seq != __atomic_load_n(&groups_seq, __ATOMIC_SEQ_CST));

    uint32_t now = rcat_hal_millis();
    int n = 0;
    for (int i = 0; i < DIRECT_GROUPS_MAX && n < max; i++)
    {
        if (!copy[i].used || now - copy[i].heard_ms > PEER_GONE_MS)
        {
            continue;
        }
        direct_group_t g = { .rssi = copy[i].rssi, .channel = copy[i].channel, .long_range = copy[i].long_range };
        memcpy(g.id, copy[i].id, 4);
        memcpy(g.name, copy[i].name, sizeof(g.name));
        for (int k = 0; k < GROUP_SENDERS; k++)
        {
            g.boards += copy[i].senders[k] != 0 && now - copy[i].sender_ms[k] <= PEER_GONE_MS;
        }
        out[n++] = g;
    }
    return n;
}

int direct_peers(direct_peer_t *out, int max)
{
    peer_t copy[DIRECT_PEERS_MAX];
    uint32_t seq;
    do
    {
        seq = __atomic_load_n(&peers_seq, __ATOMIC_SEQ_CST);
        memcpy(copy, peers, sizeof(copy));
        __atomic_thread_fence(__ATOMIC_SEQ_CST);
    } while ((seq & 1) || seq != __atomic_load_n(&peers_seq, __ATOMIC_SEQ_CST));

    uint32_t now = rcat_hal_millis();
    int n = 0;
    for (int i = 0; i < DIRECT_PEERS_MAX && n < max; i++)
    {
        if (!copy[i].used || now - copy[i].heard_ms > PEER_GONE_MS)
        {
            continue;
        }
        direct_peer_t p = { .id = copy[i].id, .rssi = copy[i].rssi,
                            .talking = copy[i].voice_ms != 0 && now - copy[i].voice_ms < TALKING_MS };
        memcpy(p.name, copy[i].name, sizeof(p.name));
        memcpy(p.firmware, copy[i].firmware, sizeof(p.firmware));
        memcpy(p.app, copy[i].app, sizeof(p.app));
        memcpy(p.key, copy[i].key, sizeof(p.key));
        p.has_key = copy[i].has_key;
        // Strongest first
        int at = n++;
        while (at > 0 && out[at - 1].rssi < p.rssi)
        {
            out[at] = out[at - 1];
            at--;
        }
        out[at] = p;
    }
    return n;
}

#else   // no direct comms on this platform

void direct_init(void)
{
}

bool direct_available(void)
{
    return false;
}

bool direct_start(void)
{
    return false;
}

void direct_stop(void)
{
}

bool direct_running(void)
{
    return false;
}

void direct_set_group(const uint8_t *key, const char *group, const char *name, uint8_t channel, bool long_range)
{
}

uint8_t direct_channel(void)
{
    return DIRECT_CHANNEL_DEFAULT;
}

bool direct_long_range(void)
{
    return false;
}

void direct_scan(void)
{
}

bool direct_scanning(void)
{
    return false;
}

void direct_set_avatar(const uint16_t *pixels, int px)
{
}

const uint16_t *direct_avatar(const char *name, uint8_t *version)
{
    return NULL;
}

const char *direct_group_name(void)
{
    return "";
}

const char *direct_own_name(void)
{
    return "";
}

void direct_send_voice(uint16_t seq, uint8_t flags, const uint8_t *opus, size_t len, const uint8_t *to)
{
}

void direct_clear_pairs(void)
{
}

void direct_add_pair(const uint8_t *their_key, const uint8_t *key)
{
}

bool direct_can_reach(const uint8_t *their_key)
{
    return false;
}

void direct_set_voice_cb(direct_voice_cb_t cb, void *user_data)
{
}

bool direct_send_command(const uint32_t *targets, int count, const uint8_t *cmd, size_t len)
{
    return false;
}

uint32_t direct_own_id(void)
{
    return 0;
}

void direct_group_id(uint8_t out[4])
{
    memset(out, 0, 4);
}

int direct_groups(direct_group_t *out, int max)
{
    return 0;
}

bool direct_other_voice(void)
{
    return false;
}

bool direct_other_firmware(void)
{
    return false;
}

void direct_pause(bool pause)
{
    (void)pause;
}

int direct_peers(direct_peer_t *out, int max)
{
    return 0;
}

void direct_key(const char *group, const char *passphrase, uint8_t key[DIRECT_KEY_LEN])
{
    memset(key, 0, DIRECT_KEY_LEN);
}

#endif
