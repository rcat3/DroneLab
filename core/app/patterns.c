/*
 * The patterns (see patterns.h): the built-in ones, worked out from the time
 * as they play, and custom ones, from their definitions.
 *
 * The slots, and every custom pattern's levels, are out of internal RAM,
 * which WiFi and Bluetooth need.
 */
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "app/patterns.h"
#include "hal.h"
#include "lvgl.h"
#include "mbedtls/sha256.h"

#define MIN_STEP_MS         100     // Lovense's own patterns go no faster
#define MAX_STEP_MS         60000
#define TOP                 20      // a step's highest level
#define ASSEMBLING          2       // definitions coming in parts at once
#define ASSEMBLY_MS         90000   // how long one's parts may take to come

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

typedef float (*generator_t)(uint8_t row, float seconds);

typedef struct
{
    uint16_t step_ms;
    uint8_t rows;               // a bit for each, 0 for all of them
    uint16_t step_count;
    const uint8_t *steps;       // 0 to TOP, in the pattern's levels
} block_t;

typedef struct
{
    char name[PATTERNS_NAME_MAX + 1];
    generator_t generator;      // for a built-in one, otherwise NULL
    bool used;
    uint8_t hash[PATTERNS_HASH_LEN];
    uint32_t played;            // when it was last found, for which to keep
    uint8_t block_count;
    block_t blocks[PATTERNS_ROWS];
    uint8_t *levels;            // every block's steps
} pattern_t;

typedef struct
{
    bool used;
    uint8_t hash[PATTERNS_HASH_LEN];
    uint8_t count;
    uint8_t got;                // a bit for each part that's come
    uint8_t lens[PATTERNS_PARTS_MAX];
    uint32_t started;
    uint8_t data[PATTERNS_DEF_MAX];
} assembly_t;

static pattern_t *patterns;     // PATTERNS_SLOTS of them
static assembly_t *assembly;    // ASSEMBLING of them
static size_t favourite_count;
static uint32_t favourites_hash;
static uint8_t *incoming;       // a favourites' document coming in pieces, while it does
static size_t incoming_len;
static bool incoming_bad;
static uint32_t changes;
static uint32_t finds;          // counts finds, for which was played last

/* ----- Built-in patterns, each 0 to 1 over time ----- */

static float wrap(float x, float period)
{
    return x - period * floorf(x / period);
}

/* Half a cycle later on the second, fourth and sixth rows, so two channels
 * take turns. */
static float offset(uint8_t row, float period)
{
    return (row % 2) ? period / 2 : 0;
}

static float gen_pulse(uint8_t row, float s)
{
    return wrap(s + offset(row, 0.8f), 0.8f) < 0.4f ? 1.0f : 0.0f;
}

static float gen_wave(uint8_t row, float s)
{
    float p = wrap(s + offset(row, 4.0f), 4.0f) / 4.0f;
    return 0.5f - 0.5f * cosf(2 * (float)M_PI * p);
}

static float gen_heartbeat(uint8_t row, float s)
{
    // Two beats, the second softer, then a rest
    float p = wrap(s, 1.1f);
    float beat = expf(-p * 18.0f);
    if (p > 0.25f)
    {
        beat += 0.7f * expf(-(p - 0.25f) * 18.0f);
    }
    return beat > 1.0f ? 1.0f : beat;
}

static float gen_climb(uint8_t row, float s)
{
    // Up over eight seconds, then drop back
    return wrap(s, 8.0f) / 8.0f;
}

static float gen_surge(uint8_t row, float s)
{
    // Waves that grow for twenty seconds, then a short rest
    float p = wrap(s, 23.0f);
    if (p > 20.0f)
    {
        return 0.0f;
    }
    float swell = 0.25f + 0.75f * p / 20.0f;
    return swell * (0.55f + 0.45f * sinf(2 * (float)M_PI * (p + offset(row, 1.5f)) / 1.5f));
}

/* Smooth noise: random levels a third of a second apart, eased between. */
static float noise_at(uint32_t n, uint8_t row)
{
    uint32_t h = n * 2654435761u + row * 40503u;
    h ^= h >> 15;
    h *= 2246822519u;
    h ^= h >> 13;
    return (h & 0xFFFF) / 65535.0f;
}

static float gen_wander(uint8_t row, float s)
{
    float x = s * 3.0f;
    uint32_t n = (uint32_t)x;
    float f = x - n;
    f = f * f * (3 - 2 * f);
    return noise_at(n, row) + (noise_at(n + 1, row) - noise_at(n, row)) * f;
}

static const struct
{
    const char *name;
    generator_t generator;
} built_in[PATTERNS_BUILT_IN] = {
    { "Wave", gen_wave },
    { "Pulse", gen_pulse },
    { "Heartbeat", gen_heartbeat },
    { "Climb", gen_climb },
    { "Surge", gen_surge },
    { "Wander", gen_wander },
};

static void load_favourites(void);

void patterns_init(void)
{
    patterns = lv_malloc(PATTERNS_SLOTS * sizeof(pattern_t));
    assembly = lv_malloc(ASSEMBLING * sizeof(assembly_t));
    if (patterns == NULL || assembly == NULL)
    {
        lv_free(patterns);
        lv_free(assembly);
        patterns = NULL;
        assembly = NULL;
        printf("patterns: no memory for them\n");
        return;
    }
    memset(patterns, 0, PATTERNS_SLOTS * sizeof(pattern_t));
    memset(assembly, 0, ASSEMBLING * sizeof(assembly_t));
    for (size_t i = 0; i < PATTERNS_BUILT_IN; i++)
    {
        snprintf(patterns[i].name, sizeof(patterns[i].name), "%s", built_in[i].name);
        patterns[i].generator = built_in[i].generator;
        patterns[i].used = true;
    }
    load_favourites();
}

size_t patterns_count(void)
{
    return patterns != NULL ? PATTERNS_BUILT_IN + favourite_count : 0;
}

int patterns_listed(size_t position)
{
    if (position < favourite_count)
    {
        return (int)(PATTERNS_BUILT_IN + position);
    }
    return position < patterns_count() ? (int)(position - favourite_count) : -1;
}

const char *patterns_name(size_t index)
{
    return patterns != NULL && index < PATTERNS_SLOTS && patterns[index].used ? patterns[index].name : "";
}

int patterns_built_in(const uint8_t *name, size_t len)
{
    for (size_t i = 0; patterns != NULL && i < PATTERNS_BUILT_IN; i++)
    {
        if (strlen(patterns[i].name) == len && memcmp(patterns[i].name, name, len) == 0)
        {
            return (int)i;
        }
    }
    return -1;
}

int patterns_find(const uint8_t hash[PATTERNS_HASH_LEN])
{
    for (size_t i = PATTERNS_BUILT_IN; patterns != NULL && i < PATTERNS_SLOTS; i++)
    {
        if (patterns[i].used && memcmp(patterns[i].hash, hash, PATTERNS_HASH_LEN) == 0)
        {
            patterns[i].played = ++finds;
            return (int)i;
        }
    }
    return -1;
}

void patterns_hash(const uint8_t *def, size_t len, uint8_t out[PATTERNS_HASH_LEN])
{
    uint8_t full[32];
    mbedtls_sha256(def, len, full, 0);
    memcpy(out, full, PATTERNS_HASH_LEN);
}

uint32_t patterns_changes(void)
{
    return changes;
}

/* ----- Definitions ----- */

static uint16_t le16(const uint8_t *p)
{
    return (uint16_t)(p[0] | (p[1] << 8));
}

/* A definition, into a slot: false if it's no good. */
static bool decode(const uint8_t *d, size_t len, pattern_t *p)
{
    if (len < 3 || d[0] != PATTERNS_FORMAT || d[1] == 0 || d[1] > PATTERNS_NAME_MAX)
    {
        return false;
    }
    size_t at = 2 + d[1];
    if (at >= len || d[at] == 0 || d[at] > PATTERNS_ROWS)
    {
        return false;
    }
    uint8_t block_count = d[at++];

    // How many steps in all, checking it adds up to the end
    size_t total = 0;
    size_t scan = at;
    for (uint8_t b = 0; b < block_count; b++)
    {
        if (scan + 5 > len)
        {
            return false;
        }
        uint16_t count = le16(d + scan + 3);
        if (count == 0)
        {
            return false;
        }
        scan += 5 + (5u * count + 7) / 8;
        total += count;
    }
    if (scan != len)
    {
        return false;
    }

    uint8_t *levels = lv_malloc(total);
    if (levels == NULL)
    {
        return false;
    }
    memset(p, 0, sizeof(*p));
    memcpy(p->name, d + 2, d[1]);
    p->name[d[1]] = '\0';
    p->levels = levels;
    p->block_count = block_count;
    size_t out = 0;
    for (uint8_t b = 0; b < block_count; b++)
    {
        block_t *k = &p->blocks[b];
        k->step_ms = (uint16_t)LV_CLAMP(MIN_STEP_MS, le16(d + at), MAX_STEP_MS);
        k->rows = d[at + 2];
        k->step_count = le16(d + at + 3);
        k->steps = levels + out;
        at += 5;
        // 5 bits a level, the lowest first
        uint32_t bits = 0;
        int have = 0;
        for (uint16_t s = 0; s < k->step_count; s++)
        {
            while (have < 5)
            {
                bits |= (uint32_t)d[at++] << have;
                have += 8;
            }
            uint8_t v = bits & 0x1F;
            bits >>= 5;
            have -= 5;
            levels[out++] = v > TOP ? TOP : v;
        }
    }
    p->used = true;
    return true;
}

static void free_slot(pattern_t *p)
{
    lv_free(p->levels);
    memset(p, 0, sizeof(*p));
}

/* A slot for one received: an empty one, or the one played longest ago that
 * isn't playing now. */
static int received_slot(void)
{
    int best = -1;
    for (int i = PATTERNS_RECEIVED_AT; i < PATTERNS_SLOTS; i++)
    {
        if (!patterns[i].used)
        {
            return i;
        }
        if (!toys_pattern_in_use(i) && (best < 0 || patterns[i].played < patterns[best].played))
        {
            best = i;
        }
    }
    return best;
}

static int keep(const uint8_t hash[PATTERNS_HASH_LEN], const uint8_t *def, size_t len)
{
    int slot = received_slot();
    if (slot < 0)
    {
        printf("patterns: no room for another\n");
        return -1;
    }
    pattern_t decoded;
    if (!decode(def, len, &decoded))
    {
        printf("patterns: one sent was no good\n");
        return -1;
    }
    free_slot(&patterns[slot]);
    patterns[slot] = decoded;
    memcpy(patterns[slot].hash, hash, PATTERNS_HASH_LEN);
    patterns[slot].played = ++finds;
    printf("patterns: got \"%s\"\n", patterns[slot].name);
    return slot;
}

int patterns_part(const uint8_t hash[PATTERNS_HASH_LEN], uint8_t part, uint8_t count, const uint8_t *data, size_t len,
                  uint32_t now_ms)
{
    if (patterns == NULL || count == 0 || count > PATTERNS_PARTS_MAX || part >= count || len > PATTERNS_PART_MAX)
    {
        return -1;
    }
    int found = patterns_find(hash);
    if (found >= 0)
    {
        return found;
    }

    // Its own, or an empty one, or one that's taken too long, or the oldest
    assembly_t *a = NULL;
    for (int i = 0; i < ASSEMBLING && a == NULL; i++)
    {
        if (assembly[i].used && memcmp(assembly[i].hash, hash, PATTERNS_HASH_LEN) == 0)
        {
            a = &assembly[i];
        }
    }
    if (a == NULL)
    {
        a = &assembly[0];
        for (int i = 0; i < ASSEMBLING; i++)
        {
            assembly_t *b = &assembly[i];
            if (!b->used || now_ms - b->started > ASSEMBLY_MS)
            {
                a = b;
                break;
            }
            if ((int32_t)(b->started - a->started) < 0)
            {
                a = b;
            }
        }
        memset(a, 0, offsetof(assembly_t, data));
        a->used = true;
        memcpy(a->hash, hash, PATTERNS_HASH_LEN);
        a->count = count;
        a->started = now_ms;
    }
    if (a->count != count)
    {
        return -1;
    }
    memcpy(a->data + (size_t)part * PATTERNS_PART_MAX, data, len);
    a->lens[part] = (uint8_t)len;
    a->got |= 1u << part;
    if (a->got != (1u << count) - 1)
    {
        return -1;
    }

    // All here: put it together, every part but the last full
    a->used = false;
    size_t total = 0;
    for (uint8_t i = 0; i < count; i++)
    {
        if (i + 1 < count && a->lens[i] != PATTERNS_PART_MAX)
        {
            return -1;
        }
        total += a->lens[i];
    }
    uint8_t check[PATTERNS_HASH_LEN];
    patterns_hash(a->data, total, check);
    if (memcmp(check, hash, PATTERNS_HASH_LEN) != 0)
    {
        printf("patterns: one sent didn't come to its hash\n");
        return -1;
    }
    return keep(hash, a->data, total);
}

/* ----- Favourites ----- */

static uint32_t fnv1a(const uint8_t *p, size_t len)
{
    uint32_t h = 0x811c9dc5u;
    for (size_t i = 0; i < len; i++)
    {
        h = (h ^ p[i]) * 0x01000193u;
    }
    return h;
}

/* A favourites' document, in place of those there were: false, and nothing
 * changed, if it's no good. */
static bool take_favourites(const uint8_t *doc, size_t len)
{
    if (len < 1 || doc[0] > PATTERNS_FAVOURITES)
    {
        return false;
    }
    uint8_t count = doc[0];
    size_t at = 1;
    for (uint8_t i = 0; i < count; i++)
    {
        if (at + 2 > len || at + 2 + le16(doc + at) > len)
        {
            return false;
        }
        at += 2 + le16(doc + at);
    }
    if (at != len)
    {
        return false;
    }
    pattern_t *fresh = count > 0 ? lv_malloc(count * sizeof(pattern_t)) : NULL;
    if (count > 0 && fresh == NULL)
    {
        return false;
    }
    at = 1;
    for (uint8_t i = 0; i < count; i++)
    {
        uint16_t n = le16(doc + at);
        if (!decode(doc + at + 2, n, &fresh[i]))
        {
            for (uint8_t j = 0; j < i; j++)
            {
                lv_free(fresh[j].levels);
            }
            lv_free(fresh);
            return false;
        }
        patterns_hash(doc + at + 2, n, fresh[i].hash);
        at += 2 + n;
    }

    // Where each old one is now, for the channels playing them
    int moved[PATTERNS_FAVOURITES];
    for (size_t j = 0; j < PATTERNS_FAVOURITES; j++)
    {
        moved[j] = -1;
        pattern_t *old = &patterns[PATTERNS_BUILT_IN + j];
        for (uint8_t i = 0; old->used && i < count && moved[j] < 0; i++)
        {
            if (memcmp(old->hash, fresh[i].hash, PATTERNS_HASH_LEN) == 0)
            {
                moved[j] = (int)(PATTERNS_BUILT_IN + i);
            }
        }
        free_slot(old);
    }
    for (uint8_t i = 0; i < count; i++)
    {
        patterns[PATTERNS_BUILT_IN + i] = fresh[i];
    }
    lv_free(fresh);
    favourite_count = count;
    favourites_hash = fnv1a(doc, len);
    toys_patterns_moved(PATTERNS_BUILT_IN, PATTERNS_FAVOURITES, moved);
    changes++;
    return true;
}

bool patterns_receive_favourites(bool first, bool last, const uint8_t *piece, size_t len)
{
    if (patterns == NULL)
    {
        return false;
    }
    if (first)
    {
        lv_free(incoming);
        incoming = lv_malloc(RCAT_HAL_PATTERNS_SIZE);
        incoming_len = 0;
        incoming_bad = incoming == NULL;
    }
    if (incoming == NULL)
    {
        return false;
    }
    if (incoming_len + len > RCAT_HAL_PATTERNS_SIZE)
    {
        incoming_bad = true;
    }
    else
    {
        memcpy(incoming + incoming_len, piece, len);
        incoming_len += len;
    }
    if (!last)
    {
        return true;
    }
    bool good = !incoming_bad && take_favourites(incoming, incoming_len);
    if (good)
    {
        if (!rcat_hal_patterns_write(incoming, incoming_len) && rcat_hal_patterns_available())
        {
            printf("patterns: couldn't keep the favourites\n");
        }
        printf("patterns: %u favourites\n", (unsigned)favourite_count);
    }
    else
    {
        printf("patterns: the favourites sent were no good\n");
    }
    lv_free(incoming);
    incoming = NULL;
    return good;
}

uint32_t patterns_favourites_hash(void)
{
    return favourites_hash;
}

static void load_favourites(void)
{
    static const uint8_t none = 0;
    favourites_hash = fnv1a(&none, 1);
    uint8_t *doc = lv_malloc(RCAT_HAL_PATTERNS_SIZE);
    if (doc == NULL)
    {
        return;
    }
    size_t len = rcat_hal_patterns_read(doc, RCAT_HAL_PATTERNS_SIZE);
    if (len > 0 && !take_favourites(doc, len))
    {
        printf("patterns: the favourites kept were no good\n");
    }
    lv_free(doc);
}

/* ----- Playing ----- */

float patterns_level(size_t index, uint8_t row, uint32_t t_ms)
{
    if (patterns == NULL || index >= PATTERNS_SLOTS || !patterns[index].used)
    {
        return -1;
    }
    const pattern_t *p = &patterns[index];
    if (p->generator != NULL)
    {
        return p->generator(row, t_ms / 1000.0f);
    }
    float level = -1;
    for (uint8_t i = 0; i < p->block_count; i++)
    {
        const block_t *b = &p->blocks[i];
        if (b->rows == 0 || (b->rows & (1u << row)))
        {
            uint32_t step = (t_ms / b->step_ms) % b->step_count;
            level = b->steps[step] / (float)TOP;
        }
    }
    return level;
}
