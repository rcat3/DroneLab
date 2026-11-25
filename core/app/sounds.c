/*
 * Sounds others play from the speaker (see sounds.h). Kept in PSRAM
 * (malloc, which puts anything this big there), never internal RAM; the
 * player frees them, on the speaker's task.
 */
#include "app/sounds.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "audio/audio_player.h"
#include "hal.h"
#include "mbedtls/sha256.h"
#include "ui/ui.h"

typedef struct
{
    uint8_t hash[SOUNDS_HASH_LEN];
    uint8_t kind;
    uint8_t *data;
    size_t len;
    uint32_t since;         // when it came, for one waiting
} sound_t;

static sound_t waiting[SOUNDS_WAITING];         // come, their commands not yet

static struct
{
    bool on;
    uint8_t hash[SOUNDS_HASH_LEN];
    char from[AUDIO_SENT_NAME_LEN - 5];     // room for "From "
    uint8_t visualizer;                     // 0 for none, else style + 1
    uint32_t since;
} wanted;                                       // a command, its sound not yet

static sound_t incoming;                        // coming from the phone
static uint32_t incoming_got;

static void drop(sound_t *s)
{
    free(s->data);
    memset(s, 0, sizeof(*s));
}

/* Play it and keep it, as the player does. Takes the sound's data. */
static void play(sound_t *s, const char *from, uint8_t visualizer)
{
    char name[AUDIO_SENT_NAME_LEN];
    snprintf(name, sizeof(name), "From %.*s", (int)sizeof(name) - 6, from);
    bool started = audio_player_add_sent(s->data, s->len, s->kind, s->hash, name);
    memset(s, 0, sizeof(*s));
    if (started && visualizer > 0)
    {
        // The screen changes now the sound does, not when its command came
        ui_visualizer_show_for_sound(visualizer - 1u);
    }
}

bool sounds_available(void)
{
    return audio_player_available();
}

bool sounds_begin(uint32_t length, uint8_t kind, const uint8_t hash[SOUNDS_HASH_LEN])
{
    drop(&incoming);
    incoming_got = 0;
    if (length == 0 || length > SOUNDS_MAX_BYTES || kind > AUDIO_SENT_FILE || !sounds_available())
    {
        return false;
    }
    incoming.data = malloc(length);
    if (incoming.data == NULL)
    {
        printf("sounds: no room for one of %lu bytes\n", (unsigned long)length);
        return false;
    }
    incoming.len = length;
    incoming.kind = kind;
    memcpy(incoming.hash, hash, SOUNDS_HASH_LEN);
    return true;
}

bool sounds_write(const uint8_t *data, size_t len)
{
    if (incoming.data == NULL || incoming_got + len > incoming.len)
    {
        return false;
    }
    memcpy(incoming.data + incoming_got, data, len);
    incoming_got += (uint32_t)len;
    return true;
}

uint32_t sounds_received(void)
{
    return incoming_got;
}

bool sounds_finish(void)
{
    uint8_t hash[SOUNDS_HASH_LEN];
    if (incoming.data == NULL || incoming_got != incoming.len)
    {
        drop(&incoming);
        return false;
    }
    mbedtls_sha256(incoming.data, incoming.len, hash, 0);
    if (memcmp(hash, incoming.hash, SOUNDS_HASH_LEN) != 0)
    {
        printf("sounds: one sent didn't come to its hash, dropped\n");
        drop(&incoming);
        return false;
    }
    if (wanted.on && memcmp(wanted.hash, hash, SOUNDS_HASH_LEN) == 0)
    {
        wanted.on = false;
        play(&incoming, wanted.from, wanted.visualizer);
        return true;
    }
    // To wait for its command, in place of the one that's waited longest
    sound_t *slot = &waiting[0];
    for (int i = 0; i < SOUNDS_WAITING; i++)
    {
        if (waiting[i].data == NULL || memcmp(waiting[i].hash, hash, SOUNDS_HASH_LEN) == 0)
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
    slot->since = rcat_hal_millis();
    memset(&incoming, 0, sizeof(incoming));
    return true;
}

void sounds_play_sent(const uint8_t hash[SOUNDS_HASH_LEN], const char *from, uint8_t visualizer)
{
    for (int w = 0; w < SOUNDS_WAITING; w++)
    {
        if (waiting[w].data != NULL && memcmp(waiting[w].hash, hash, SOUNDS_HASH_LEN) == 0)
        {
            play(&waiting[w], from, visualizer);
            return;
        }
    }
    // Not here yet: it waits for it. The phone gives it again even if it's
    // kept, as only the player knows what's kept, and it's played from there.
    wanted.on = true;
    wanted.visualizer = visualizer;
    memcpy(wanted.hash, hash, SOUNDS_HASH_LEN);
    snprintf(wanted.from, sizeof(wanted.from), "%s", from);
    wanted.since = rcat_hal_millis();
}

void sounds_poll(void)
{
    uint32_t now = rcat_hal_millis();
    if (wanted.on && now - wanted.since > SOUNDS_WAIT_MS)
    {
        wanted.on = false;
        printf("sounds: one to play didn't come\n");
    }
    for (int i = 0; i < SOUNDS_WAITING; i++)
    {
        if (waiting[i].data != NULL && now - waiting[i].since > SOUNDS_WAIT_MS)
        {
            drop(&waiting[i]);
        }
    }
}
