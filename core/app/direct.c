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

#if RCAT_HAVE_DIRECT

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mbedtls/gcm.h"
#include "mbedtls/sha256.h"

#include "app/comm.h"
#include "app/settings.h"
#include "hal.h"

// 1 for a board that only echoes back what it hears, as itself, for trying
// direct comms with one board that can send (set by -DRCAT_DIRECT_ECHO=1).
#ifndef RCAT_DIRECT_ECHO
#define RCAT_DIRECT_ECHO    0
#endif

// 1 to print what was sent, heard and dropped every couple of seconds.
#define DIRECT_DEBUG        0

#define MAGIC               'D'
#define HEADER_LEN          15
#define TAG_LEN             8
#define TYPE_VOICE          0x01
#define TYPE_HELLO          0x02
#define HELLO_TALKING       0x01
#define MAX_OPUS            160

#define HELLO_EVERY_MS      2000
#define PEER_GONE_MS        10000       // not heard for this long: forgotten
#define TALKING_MS          300         // talking, until this long after its last voice
#define TASK_STACK          (6 * 1024)
#define TASK_IDLE_MS        50
#define TASK_BUSY_MS        2
#define VOICE_QUEUE         8           // the wearer's voice, waiting to go
#define REPEATS             2           // packets sent again in each after them

typedef struct
{
    uint32_t id;
    uint32_t counter;           // the last one heard, so nothing's played back
    uint32_t heard_ms;
    uint32_t voice_ms;
    uint16_t voice_seq;         // the last voice packet's
    bool voice_seen;
    char name[DIRECT_NAME_MAX];
    int8_t rssi;
    bool used;
} peer_t;

typedef struct
{
    uint16_t seq;
    uint8_t flags;
    uint8_t len;
    uint8_t opus[MAX_OPUS];
} voice_t;

static bool started;
static volatile bool running;
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

// The wearer's voice: one writer (the comm channel's encoder), one reader
static voice_t *voice_queue;
static volatile uint32_t voice_write, voice_read;

#if DIRECT_DEBUG
static volatile uint32_t dbg_queued, dbg_queue_full;
static uint32_t dbg_sent, dbg_send_fail, dbg_heard, dbg_other, dbg_bad, dbg_replay, dbg_voice_in, dbg_recovered;
#define DBG(x) (x)
#else
#define DBG(x)
#endif

static direct_voice_cb_t voice_cb;
static void *voice_cb_data;
static volatile bool talking;   // the wearer, for the hellos

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

/* Seal plain (len bytes) and broadcast it. */
static void send_sealed(const uint8_t *plain, size_t len)
{
    uint8_t msg[RCAT_HAL_DIRECT_MAX];
    if (HEADER_LEN + len + TAG_LEN > sizeof(msg))
    {
        return;
    }
    uint32_t c = ++counter;
    msg[0] = MAGIC;
    msg[1] = DIRECT_VERSION;
    memcpy(msg + 2, group_id, 4);
    memcpy(msg + 6, &own_id, 4);
    msg[10] = (uint8_t)c;
    msg[11] = (uint8_t)(c >> 8);
    msg[12] = (uint8_t)(c >> 16);
    msg[13] = (uint8_t)(c >> 24);
    msg[14] = 0;    // hops left: nothing's passed on yet
    uint8_t iv[12];
    nonce(iv, msg);
    if (mbedtls_gcm_crypt_and_tag(&gcm, MBEDTLS_GCM_ENCRYPT, len, iv, sizeof(iv), msg, HEADER_LEN, plain,
                                  msg + HEADER_LEN, TAG_LEN, msg + HEADER_LEN + len) == 0)
    {
        bool ok = rcat_hal_direct_send(msg, HEADER_LEN + len + TAG_LEN);
        DBG(ok ? dbg_sent++ : dbg_send_fail++);
        (void)ok;
    }
}

static void send_hello(void)
{
    uint8_t plain[2 + DIRECT_NAME_MAX];
    plain[0] = TYPE_HELLO;
    plain[1] = talking ? HELLO_TALKING : 0;
    size_t n = strlen(own_name);
    memcpy(plain + 2, own_name, n);
    send_sealed(plain, 2 + n);
}

/* A packet of voice, with the REPEATS before it too, so that as many lost in
 * a row come back from the next. */
static void send_voice(const voice_t *v)
{
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
    send_sealed(plain, len);
    memmove(&before[1], &before[0], (REPEATS - 1) * sizeof(before[0]));
    before[0] = *v;
    if (v->flags & DIRECT_LAST)
    {
        memset(before, 0, sizeof(before));
    }
}

/* The peer that sent this, made if it's new: the weakest or oldest goes. */
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
    snprintf(spare->name, sizeof(spare->name), "%08lX", (unsigned long)id);    // until its hello
    return spare;
}

/* A packet of another board's voice: to the phone, or back out again. */
static void deliver(uint32_t id, uint16_t seq, uint8_t flags, const uint8_t *opus, size_t len)
{
#if RCAT_DIRECT_ECHO
    voice_t v = { .seq = seq, .flags = flags, .len = (uint8_t)len };
    memcpy(v.opus, opus, len);
    talking = !(flags & DIRECT_LAST);
    send_voice(&v);
#endif
    if (voice_cb != NULL)
    {
        voice_cb(id, seq, flags, opus, len, voice_cb_data);
    }
}

static void heard(const uint8_t *msg, size_t len, int8_t rssi, uint32_t now)
{
    DBG(dbg_heard++);
    if (len < HEADER_LEN + 1 + TAG_LEN || msg[0] != MAGIC || msg[1] != DIRECT_VERSION ||
        memcmp(msg + 2, group_id, 4) != 0)
    {
        DBG(dbg_other++);
        return;     // not ours: another version, or another group
    }
    uint32_t id, c;
    memcpy(&id, msg + 6, 4);
    if (id == own_id)
    {
        return;
    }
    c = msg[10] | (msg[11] << 8) | (msg[12] << 16) | ((uint32_t)msg[13] << 24);
    size_t plain_len = len - HEADER_LEN - TAG_LEN;
    uint8_t plain[RCAT_HAL_DIRECT_MAX];
    uint8_t iv[12];
    nonce(iv, msg);
    if (mbedtls_gcm_auth_decrypt(&gcm, plain_len, iv, sizeof(iv), msg, HEADER_LEN, msg + HEADER_LEN + plain_len,
                                 TAG_LEN, msg + HEADER_LEN, plain) != 0)
    {
        DBG(dbg_bad++);
        return;     // not the group's key, or tampered with
    }

    __atomic_add_fetch(&peers_seq, 1, __ATOMIC_SEQ_CST);
    peer_t *p = find_peer(id, now);
    bool fresh = p->counter == 0 || (int32_t)(c - p->counter) > 0;
    if (fresh)
    {
        p->counter = c;
        p->heard_ms = now;
        p->rssi = rssi;
        if (plain[0] == TYPE_HELLO && plain_len >= 2)
        {
            size_t n = plain_len - 2 < DIRECT_NAME_MAX - 1 ? plain_len - 2 : DIRECT_NAME_MAX - 1;
            memcpy(p->name, plain + 2, n);
            p->name[n] = '\0';
        }
        else if (plain[0] == TYPE_VOICE && plain_len >= 5)
        {
            p->voice_ms = (plain[3] & DIRECT_LAST) ? 0 : now;
        }
    }
    __atomic_add_fetch(&peers_seq, 1, __ATOMIC_SEQ_CST);

    DBG(fresh ? 0 : dbg_replay++);
    if (fresh && plain[0] == TYPE_VOICE && plain_len >= 5 && 5 + (size_t)plain[4] <= plain_len)
    {
        DBG(dbg_voice_in++);
        uint16_t seq = plain[1] | (plain[2] << 8);
        uint8_t flags = plain[3];
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
                deliver(id, (uint16_t)(seq - 1 - i), 0, at[i], lens[i]);
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

        if (now - hello_ms >= HELLO_EVERY_MS)
        {
            hello_ms = now;
            send_hello();
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

void direct_init(void)
{
    own_id = rcat_hal_random();
    voice_queue = calloc(VOICE_QUEUE, sizeof(voice_t));
    mbedtls_gcm_init(&gcm);
    const settings_t *s = settings_get();
    if (voice_queue == NULL || !rcat_hal_task_start("direct", direct_task, NULL, TASK_STACK))
    {
        return;
    }
    started = true;
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

bool direct_running(void)
{
    return running;
}

void direct_set_group(const uint8_t *key, const char *group, const char *name)
{
    settings_set_direct_group(key, group, name);
    group_changed = true;   // the task takes it up
}

const char *direct_group_name(void)
{
    return group_name;
}

const char *direct_own_name(void)
{
    return own_name;
}

void direct_send_voice(uint16_t seq, uint8_t flags, const uint8_t *opus, size_t len)
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
    __atomic_store_n(&voice_write, w + 1, __ATOMIC_RELEASE);
}

void direct_set_voice_cb(direct_voice_cb_t cb, void *user_data)
{
    voice_cb_data = user_data;
    voice_cb = cb;
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

void direct_set_group(const uint8_t *key, const char *group, const char *name)
{
}

const char *direct_group_name(void)
{
    return "";
}

const char *direct_own_name(void)
{
    return "";
}

void direct_send_voice(uint16_t seq, uint8_t flags, const uint8_t *opus, size_t len)
{
}

void direct_set_voice_cb(direct_voice_cb_t cb, void *user_data)
{
}

int direct_peers(direct_peer_t *out, int max)
{
    return 0;
}

#endif
