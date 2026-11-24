/*
 * HiveMind Control's rules, as the app gives them (see rules.h).
 *
 * The document's kept as it came, with a byte before it saying whether the
 * wearer's switched anything Off here since, and read into small tables
 * each time it changes. Everything here runs on the UI loop.
 */
#include "app/rules.h"

#include <stdio.h>
#include <string.h>

#include "app/toys.h"
#include "hal.h"
#include "lvgl.h"

#define STORE_NAME          "rules"
#define CLASS_ENTRY         4

typedef struct
{
    uint8_t edited;
    uint8_t doc[RULES_DOC_MAX];
} stored_t;

// Out of internal RAM, which WiFi and Bluetooth need: made by rules_init()
static stored_t *stored;
static size_t doc_len;              // 0 for none yet
static uint8_t *incoming;           // RULES_DOC_MAX, a document coming in pieces
static size_t incoming_len;
static bool incoming_bad;
static rules_person_t *people;      // RULES_PEOPLE_MAX of them
static int people_count;
static uint8_t policy[RULES_CLASS_MAX + 1];
static uint8_t ignoring[RULES_CLASS_MAX + 1];
static uint32_t hash;
static uint32_t changes;

static uint16_t le16(const uint8_t *p)
{
    return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t fnv1a(const uint8_t *p, size_t len)
{
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < len; i++)
    {
        h = (h ^ p[i]) * 16777619u;
    }
    return h;
}

/* Each section of a document in turn: false once there are no more, or if
 * it's not as it should be (*bad). */
typedef struct
{
    const uint8_t *doc;
    size_t len;
    size_t at;
    int left;
    bool bad;
} sections_t;

static void sections_start(sections_t *s, const uint8_t *doc, size_t len)
{
    s->doc = doc;
    s->len = len;
    s->at = 2;
    s->left = len >= 2 && doc[0] == RULES_VERSION ? doc[1] : 0;
    s->bad = len < 2 || doc[0] != RULES_VERSION;
}

static bool sections_next(sections_t *s, uint8_t *id, const uint8_t **body, size_t *body_len)
{
    if (s->bad || s->left == 0)
    {
        return false;
    }
    if (s->at + 3 > s->len || s->at + 3 + le16(s->doc + s->at + 1) > s->len)
    {
        s->bad = true;
        return false;
    }
    *id = s->doc[s->at];
    *body_len = le16(s->doc + s->at + 1);
    *body = s->doc + s->at + 3;
    s->at += 3 + *body_len;
    s->left--;
    return true;
}

/* Whether a document's good: every section in it fits, and those this
 * unit reads are as they should be. With [apply], it's what's gone by. */
static bool read_doc(const uint8_t *doc, size_t len, bool apply)
{
    uint8_t new_policy[RULES_CLASS_MAX + 1] = { 0 };
    uint8_t new_ignoring[RULES_CLASS_MAX + 1] = { 0 };
    toys_map_t maps[RULES_TOYS_MAX];
    int map_count = 0;
    toys_control_t controls[TOYS_SCREEN_CONTROLS];
    int control_count = 0;
    int count = 0;

    sections_t s;
    sections_start(&s, doc, len);
    uint8_t id;
    const uint8_t *b;
    size_t n;
    while (sections_next(&s, &id, &b, &n))
    {
        switch (id)
        {
        case RULES_SECTION_CLASSES:
            if (n % CLASS_ENTRY != 0)
            {
                return false;
            }
            for (size_t i = 0; i < n; i += CLASS_ENTRY)
            {
                if (b[i] <= RULES_CLASS_MAX && b[i + 1] <= RULES_ANYONE)
                {
                    new_policy[b[i]] = b[i + 1];
                    new_ignoring[b[i]] = b[i + 2];
                }
            }
            break;

        case RULES_SECTION_PEOPLE:
            for (size_t i = 0; i < n;)
            {
                if (i + RULES_KEY_LEN + 4 > n || i + RULES_KEY_LEN + 4 + b[i + RULES_KEY_LEN + 3] > n)
                {
                    return false;
                }
                size_t name_len = b[i + RULES_KEY_LEN + 3];
                if (apply && count < RULES_PEOPLE_MAX)
                {
                    rules_person_t *p = &people[count];
                    memcpy(p->key, b + i, RULES_KEY_LEN);
                    p->flags = b[i + RULES_KEY_LEN];
                    p->allowed = le16(b + i + RULES_KEY_LEN + 1);
                    size_t keep = name_len < RULES_NAME_MAX - 1 ? name_len : RULES_NAME_MAX - 1;
                    memcpy(p->name, b + i + RULES_KEY_LEN + 4, keep);
                    p->name[keep] = '\0';
                }
                count++;
                i += RULES_KEY_LEN + 4 + name_len;
            }
            break;

        case RULES_SECTION_TOYS:
            if (n % (6 + TOYS_MAX_OUTPUTS) != 0)
            {
                return false;
            }
            for (size_t i = 0; i < n && map_count < RULES_TOYS_MAX; i += 6 + TOYS_MAX_OUTPUTS)
            {
                memcpy(maps[map_count].addr, b + i, 6);
                memcpy(maps[map_count].channels, b + i + 6, TOYS_MAX_OUTPUTS);
                map_count++;
            }
            break;

        case RULES_SECTION_CONTROLS:
        {
            if (n < 1)
            {
                return false;
            }
            size_t i = 1;
            for (int c = 0; c < b[0]; c++)
            {
                if (i + 1 > n || i + 2 + b[i] > n)
                {
                    return false;
                }
                size_t label_len = b[i];
                if (control_count < TOYS_SCREEN_CONTROLS)
                {
                    toys_control_t *t = &controls[control_count++];
                    size_t keep = label_len < TOYS_LABEL_LEN - 1 ? label_len : TOYS_LABEL_LEN - 1;
                    memcpy(t->label, b + i + 1, keep);
                    t->label[keep] = '\0';
                    t->channels = b[i + 1 + label_len] & TOYS_ALL_CHANNELS;
                }
                i += 2 + label_len;
            }
            break;
        }

        default:
            break;      // for another host, or from a newer app
        }
    }
    if (s.bad || count > RULES_PEOPLE_MAX)
    {
        return false;
    }
    if (apply)
    {
        memcpy(policy, new_policy, sizeof(policy));
        memcpy(ignoring, new_ignoring, sizeof(ignoring));
        people_count = count;
        toys_set_maps(maps, map_count);
        toys_set_screen_controls(controls, control_count);
        hash = fnv1a(doc, len);
        changes++;
    }
    return true;
}

/* Until the app's given any: every class on Ask, nobody allowed. */
static void defaults(void)
{
    memset(policy, 0, sizeof(policy));
    memset(ignoring, 0, sizeof(ignoring));
    for (int c = RULES_CLASS_TERMINAL; c <= RULES_CLASS_SOUNDS; c++)
    {
        policy[c] = c == RULES_CLASS_ESTIM ? RULES_OFF : RULES_ASK;
    }
    people_count = 0;
    hash = 0;
    toys_set_maps(NULL, 0);
    toys_set_screen_controls(NULL, 0);
    changes++;
}

static void save(void)
{
    if (!rcat_hal_store_write(STORE_NAME, stored, 1 + doc_len))
    {
        printf("rules: couldn't save them\n");
    }
}

void rules_init(void)
{
    stored = lv_malloc(sizeof(stored_t));
    people = lv_malloc(RULES_PEOPLE_MAX * sizeof(rules_person_t));
    incoming = lv_malloc(RULES_DOC_MAX);
    if (stored == NULL || people == NULL || incoming == NULL)
    {
        lv_free(stored);
        lv_free(people);
        lv_free(incoming);
        stored = NULL;
        people = NULL;
        incoming = NULL;
        defaults();
        return;
    }
    size_t n = rcat_hal_store_read(STORE_NAME, stored, sizeof(stored_t));
    doc_len = n > 1 ? n - 1 : 0;
    if (doc_len == 0 || !read_doc(stored->doc, doc_len, true))
    {
        doc_len = 0;
        stored->edited = 0;
        defaults();
    }
}

bool rules_receive(bool first, bool last, const uint8_t *piece, size_t len)
{
    if (incoming == NULL)
    {
        return false;
    }
    if (first)
    {
        incoming_len = 0;
        incoming_bad = false;
    }
    if (incoming_len + len > RULES_DOC_MAX)
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
    if (incoming_bad || !read_doc(incoming, incoming_len, false))
    {
        printf("rules: the app's rules aren't right, kept the last\n");
        return false;
    }
    memcpy(stored->doc, incoming, incoming_len);
    doc_len = incoming_len;
    stored->edited = 0;
    read_doc(stored->doc, doc_len, true);
    save();
    printf("rules: new rules from the app, %d people\n", people_count);
    return true;
}

uint8_t rules_policy(uint8_t class_id)
{
    return class_id <= RULES_CLASS_MAX ? policy[class_id] : RULES_OFF;
}

uint8_t rules_ignoring(uint8_t class_id)
{
    return class_id <= RULES_CLASS_MAX ? ignoring[class_id] : 0;
}

const rules_person_t *rules_person(const uint8_t key[RULES_KEY_LEN])
{
    for (int i = 0; i < people_count; i++)
    {
        if (memcmp(people[i].key, key, RULES_KEY_LEN) == 0)
        {
            return &people[i];
        }
    }
    return NULL;
}

int rules_people_count(void)
{
    return people_count;
}

const rules_person_t *rules_person_at(int i)
{
    return i >= 0 && i < people_count ? &people[i] : NULL;
}

/* The class's entry in the document's classes, or NULL if it hasn't one. */
static uint8_t *class_entry(uint8_t class_id)
{
    sections_t s;
    sections_start(&s, stored->doc, doc_len);
    uint8_t id;
    const uint8_t *b;
    size_t n;
    while (sections_next(&s, &id, &b, &n))
    {
        for (size_t i = 0; id == RULES_SECTION_CLASSES && i + CLASS_ENTRY <= n; i += CLASS_ENTRY)
        {
            if (b[i] == class_id)
            {
                return (uint8_t *)&b[i];
            }
        }
    }
    return NULL;
}

void rules_set_off(uint8_t class_id)
{
    if (stored == NULL || rules_policy(class_id) == RULES_OFF)
    {
        return;
    }
    if (doc_len == 0)
    {
        // None from the app yet: the defaults, written out, to change
        uint8_t *d = stored->doc;
        size_t at = 0;
        d[at++] = RULES_VERSION;
        d[at++] = 1;
        d[at++] = RULES_SECTION_CLASSES;
        size_t len_at = at;
        at += 2;
        for (int c = RULES_CLASS_TERMINAL; c <= RULES_CLASS_SOUNDS; c++)
        {
            d[at++] = (uint8_t)c;
            d[at++] = policy[c];
            d[at++] = ignoring[c];
            d[at++] = 0;
        }
        d[len_at] = (uint8_t)(at - len_at - 2);
        d[len_at + 1] = 0;
        doc_len = at;
    }
    uint8_t *e = class_entry(class_id);
    if (e == NULL)
    {
        return;     // not listed, so it's Off already
    }
    e[1] = RULES_OFF;
    stored->edited = 1;
    read_doc(stored->doc, doc_len, true);
    save();
}

uint32_t rules_hash(void)
{
    return hash;
}

bool rules_edited(void)
{
    return stored != NULL && stored->edited != 0;
}

uint32_t rules_changes(void)
{
    return changes;
}
