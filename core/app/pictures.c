/*
 * Pictures others show on the screen (see pictures.h).
 *
 * A sent JPEG's decoded once, as it's kept, and only its decoded picture's
 * kept (about 434 KB on a 466 px screen); a GIF's kept as it came, and
 * decoded as it plays, as the SD card's are. All of it's in PSRAM
 * (lv_malloc), never internal RAM.
 */
#include "app/pictures.h"

#include <stdio.h>
#include <string.h>

#include "lvgl.h"
#include "mbedtls/sha256.h"
#include "media/media_library.h"
#include "ui/ui_internal.h"

typedef struct
{
    uint8_t hash[PICTURES_HASH_LEN];
    uint8_t kind;
    uint8_t *data;          // as it came: a GIF's, while it's kept; a JPEG's until it's decoded
    size_t len;
    uint32_t since;         // when it came, for one waiting
} picture_t;

typedef struct
{
    picture_t pic;
    const void *src;        // what's shown: a JPEG decoded, a GIF wrapped
    lv_obj_t *page;
} kept_t;

static picture_t waiting[PICTURES_WAITING];     // come, their commands not yet
static kept_t kept[PICTURES_KEPT];              // the oldest first
static int kept_count;

static struct
{
    bool on;
    uint8_t hash[PICTURES_HASH_LEN];
    uint16_t seconds;
    uint32_t since;
} wanted;                                       // a command, its picture not yet

static picture_t incoming;                      // coming from the phone
static uint32_t incoming_got;

static void drop(picture_t *p)
{
    lv_free(p->data);
    memset(p, 0, sizeof(*p));
}

static int find_kept(const uint8_t *hash)
{
    for (int i = 0; i < kept_count; i++)
    {
        if (memcmp(kept[i].pic.hash, hash, PICTURES_HASH_LEN) == 0)
        {
            return i;
        }
    }
    return -1;
}

static void forget_kept(int i)
{
    feature_images_remove_received(kept[i].page);   // before what it shows goes
    media_free_decoded(kept[i].src, kept[i].pic.kind == PICTURES_GIF);
    drop(&kept[i].pic);
    memmove(&kept[i], &kept[i + 1], (size_t)(kept_count - i - 1) * sizeof(kept[0]));
    kept_count--;
    memset(&kept[kept_count], 0, sizeof(kept[0]));
}

/* Keep it, with a page of its own, and show it. Takes the picture's data. */
static void keep_and_show(picture_t *p, uint16_t seconds)
{
    int i = find_kept(p->hash);
    if (i >= 0)
    {
        drop(p);    // had it already
        ui_show_page_for(kept[i].page, seconds);
        return;
    }
    lv_display_t *disp = lv_display_get_default();
    int32_t screen = LV_MIN(lv_display_get_horizontal_resolution(disp), lv_display_get_vertical_resolution(disp));
    bool gif = p->kind == PICTURES_GIF;
    uint16_t scale;
    if (kept_count == PICTURES_KEPT)
    {
        forget_kept(0);     // room for it first: a decoded picture's big
    }
    const void *src = media_decode_memory(p->data, p->len, gif, screen, &scale);
    if (src == NULL)
    {
        printf("pictures: one sent couldn't be shown\n");
        drop(p);
        return;
    }
    lv_obj_t *page = feature_images_add_received(src, gif, scale);
    if (page == NULL)
    {
        media_free_decoded(src, gif);
        drop(p);
        return;
    }
    kept_t *k = &kept[kept_count++];
    k->pic = *p;
    memset(p, 0, sizeof(*p));
    if (!gif)
    {
        lv_free(k->pic.data);   // decoded: what came isn't needed now
        k->pic.data = NULL;
    }
    k->src = src;
    k->page = page;
    ui_show_page_for(page, seconds);
}

bool pictures_begin(uint32_t length, uint8_t kind, const uint8_t hash[PICTURES_HASH_LEN])
{
    drop(&incoming);
    incoming_got = 0;
    if (length == 0 || length > PICTURES_MAX_BYTES || kind > PICTURES_GIF)
    {
        return false;
    }
    incoming.data = lv_malloc(length);
    if (incoming.data == NULL)
    {
        printf("pictures: no room for one of %lu bytes\n", (unsigned long)length);
        return false;
    }
    incoming.len = length;
    incoming.kind = kind;
    memcpy(incoming.hash, hash, PICTURES_HASH_LEN);
    return true;
}

bool pictures_write(const uint8_t *data, size_t len)
{
    if (incoming.data == NULL || incoming_got + len > incoming.len)
    {
        return false;
    }
    memcpy(incoming.data + incoming_got, data, len);
    incoming_got += (uint32_t)len;
    return true;
}

uint32_t pictures_received(void)
{
    return incoming_got;
}

bool pictures_finish(void)
{
    uint8_t hash[PICTURES_HASH_LEN];
    if (incoming.data == NULL || incoming_got != incoming.len)
    {
        drop(&incoming);
        return false;
    }
    mbedtls_sha256(incoming.data, incoming.len, hash, 0);
    if (memcmp(hash, incoming.hash, PICTURES_HASH_LEN) != 0)
    {
        printf("pictures: one sent didn't come to its hash, dropped\n");
        drop(&incoming);
        return false;
    }
    if (wanted.on && memcmp(wanted.hash, hash, PICTURES_HASH_LEN) == 0)
    {
        wanted.on = false;
        keep_and_show(&incoming, wanted.seconds);
        return true;
    }
    if (find_kept(hash) >= 0)
    {
        drop(&incoming);    // had it already
        return true;
    }
    // To wait for its command, in place of the one that's waited longest
    picture_t *slot = &waiting[0];
    for (int i = 0; i < PICTURES_WAITING; i++)
    {
        if (waiting[i].data == NULL || memcmp(waiting[i].hash, hash, PICTURES_HASH_LEN) == 0)
        {
            slot = &waiting[i];
            break;
        }
        if ((int32_t)(waiting[i].since - slot->since) < 0)
        {
            slot = &waiting[i];
        }
    }
    drop(slot);
    *slot = incoming;
    slot->since = lv_tick_get();
    memset(&incoming, 0, sizeof(incoming));
    return true;
}

void pictures_show_sent(const uint8_t hash[PICTURES_HASH_LEN], uint16_t seconds)
{
    int i = find_kept(hash);
    if (i >= 0)
    {
        ui_show_page_for(kept[i].page, seconds);
        return;
    }
    for (int w = 0; w < PICTURES_WAITING; w++)
    {
        if (waiting[w].data != NULL && memcmp(waiting[w].hash, hash, PICTURES_HASH_LEN) == 0)
        {
            keep_and_show(&waiting[w], seconds);
            return;
        }
    }
    // Not here yet: it waits for it
    wanted.on = true;
    memcpy(wanted.hash, hash, PICTURES_HASH_LEN);
    wanted.seconds = seconds;
    wanted.since = lv_tick_get();
}

void pictures_show_built_in(const char *name, size_t len, uint16_t seconds)
{
    char n[MEDIA_NAME_LEN];
    if (len == 0 || len >= sizeof(n))
    {
        return;
    }
    memcpy(n, name, len);
    n[len] = '\0';
    lv_obj_t *page = feature_images_built_in_page(n);
    if (page == NULL)
    {
        printf("pictures: no built-in picture called %s\n", n);
        return;
    }
    ui_show_page_for(page, seconds);
}

void pictures_delete_page(const void *page)
{
    for (int i = 0; i < kept_count; i++)
    {
        if (kept[i].page == page)
        {
            forget_kept(i);
            return;
        }
    }
}

void pictures_poll(uint32_t now_ms)
{
    (void)now_ms;
    uint32_t now = lv_tick_get();
    if (wanted.on && now - wanted.since > PICTURES_WAIT_MS)
    {
        wanted.on = false;
        printf("pictures: one to show didn't come\n");
    }
    for (int i = 0; i < PICTURES_WAITING; i++)
    {
        if (waiting[i].data != NULL && now - waiting[i].since > PICTURES_WAIT_MS)
        {
            drop(&waiting[i]);
        }
    }
}
