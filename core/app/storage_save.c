/*
 * Pictures and sounds saved to the card (see storage_save.h).
 */
#include "app/storage_save.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>

#include "audio/audio_player.h"
#include "hal.h"
#include "lvgl.h"
#include "mbedtls/sha256.h"
#include "media/media_library.h"
#include "ui/ui_internal.h"

#define PATH_MAX_LEN    200
#define SAVE_IDLE_MS    20000
#define ROOM_LEFT       (64u * 1024)    // kept free on the card

static char root[PATH_MAX_LEN - 40];                 // the card's mount point; empty if there's none

static struct
{
    bool on;
    uint8_t kind;
    FILE *file;
    char name[SAVE_NAME_MAX + 1];
    char part[PATH_MAX_LEN];
    uint32_t length;
    uint32_t got;
    uint32_t last_ms;               // when something last came
    uint8_t hash[SAVE_HASH_LEN];
    mbedtls_sha256_context sha;
    bool paused_player;
} cur;

static void end_transfer(bool remove_part);

static bool has_extension(const char *file_name, const char *ext)
{
    size_t len = strlen(file_name);
    size_t n = strlen(ext);
    return len > n && strcasecmp(file_name + len - n, ext) == 0;
}

static bool is_picture_name(const char *n)
{
    return has_extension(n, ".jpg") || has_extension(n, ".jpeg") || has_extension(n, ".png")
           || has_extension(n, ".bmp") || has_extension(n, ".gif");
}

static bool is_sound_name(const char *n)
{
    return has_extension(n, ".wav") || has_extension(n, ".mp3") || has_extension(n, ".flac");
}

static bool name_ok(uint8_t kind, const char *n)
{
    size_t len = strlen(n);
    if (len == 0 || len > SAVE_NAME_MAX || n[0] == '.' || n[0] == ' ' || n[len - 1] == ' ')
    {
        return false;
    }
    for (size_t i = 0; i < len; i++)
    {
        unsigned char c = (unsigned char)n[i];
        if (c < 0x20 || c > 0x7E || strchr("/\\:*?\"<>|", c) != NULL)
        {
            return false;
        }
    }
    return kind == SAVE_PICTURE ? is_picture_name(n) : is_sound_name(n);
}

static bool is_dir(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static bool exists(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0;
}

/* Where the pictures are: "images", as the Images feature reads them, or the
 * card's top if that's where they are and there's no "images". */
static bool pictures_folder(char *out, size_t cap, bool make)
{
    if (snprintf(out, cap, "%s/images", root) >= (int)cap)
    {
        return false;
    }
    if (is_dir(out))
    {
        return true;
    }
    DIR *dir = opendir(root);
    bool top = false;
    for (struct dirent *e; dir != NULL && (e = readdir(dir)) != NULL && !top;)
    {
        top = e->d_type != DT_DIR && e->d_name[0] != '.' && is_picture_name(e->d_name);
    }
    if (dir != NULL)
    {
        closedir(dir);
    }
    if (top)
    {
        snprintf(out, cap, "%s", root);
        return true;
    }
    return make && mkdir(out, 0777) == 0;
}

static bool sounds_folder(char *out, size_t cap, bool make)
{
    if (snprintf(out, cap, "%s/sounds", root) >= (int)cap)
    {
        return false;
    }
    return is_dir(out) || (make && mkdir(out, 0777) == 0);
}

static bool folder_of(uint8_t kind, char *out, size_t cap, bool make)
{
    return root[0] != '\0' && (kind == SAVE_PICTURE ? pictures_folder(out, cap, make) : sounds_folder(out, cap, make));
}

static void remove_parts(const char *folder)
{
    DIR *dir = opendir(folder);
    for (struct dirent *e; dir != NULL && (e = readdir(dir)) != NULL;)
    {
        if (e->d_type != DT_DIR && has_extension(e->d_name, ".part"))
        {
            char path[PATH_MAX_LEN];
            if (snprintf(path, sizeof(path), "%s/%s", folder, e->d_name) < (int)sizeof(path))
            {
                remove(path);
            }
        }
    }
    if (dir != NULL)
    {
        closedir(dir);
    }
}

void storage_save_init(const char *storage_path)
{
    snprintf(root, sizeof(root), "%s", storage_path != NULL ? storage_path : "");
    char folder[PATH_MAX_LEN];
    for (uint8_t kind = SAVE_PICTURE; kind <= SAVE_SOUND && root[0] != '\0'; kind++)
    {
        if (folder_of(kind, folder, sizeof(folder), false))
        {
            remove_parts(folder);
        }
    }
}

bool storage_save_present(void)
{
    return root[0] != '\0';
}

bool storage_save_space(uint64_t *total, uint64_t *free_bytes)
{
    return root[0] != '\0' && rcat_hal_storage_space(total, free_bytes);
}

void storage_save_touch(void)
{
    cur.last_ms = rcat_hal_millis();
}

void storage_save_poll(uint32_t now_ms)
{
    // A phone that went quiet part way (its app closed, say) leaves the card's
    // busy and the player paused
    if (cur.on && now_ms - cur.last_ms > SAVE_IDLE_MS)
    {
        printf("save: %s went quiet, dropped\n", cur.name);
        end_transfer(true);
    }
}

bool storage_save_busy(void)
{
    return cur.on;
}

uint32_t storage_save_received(void)
{
    return cur.on ? cur.got : 0;
}

static void end_transfer(bool remove_part)
{
    if (cur.file != NULL)
    {
        fclose(cur.file);
        cur.file = NULL;
    }
    if (remove_part && cur.part[0] != '\0')
    {
        remove(cur.part);
    }
    if (cur.on)
    {
        mbedtls_sha256_free(&cur.sha);
    }
    if (cur.paused_player)
    {
        audio_player_resume();
    }
    cur.on = false;
    cur.paused_player = false;
    cur.part[0] = '\0';
}

void storage_save_abort(void)
{
    end_transfer(true);
}

/* The name without its extension, for the picture lists. */
static void stem_of(const char *name, char *out, size_t cap)
{
    snprintf(out, cap, "%s", name);
    char *dot = strrchr(out, '.');
    if (dot != NULL)
    {
        *dot = '\0';
    }
}

save_result_t storage_save_begin(uint8_t kind, uint32_t length, const uint8_t hash[SAVE_HASH_LEN],
                                 const char *name, size_t name_len)
{
    end_transfer(true);     // one that didn't finish gives way
    if (root[0] == '\0')
    {
        return SAVE_NO_CARD;
    }
    if (kind > SAVE_SOUND || name_len == 0 || name_len > SAVE_NAME_MAX)
    {
        return SAVE_BAD_NAME;
    }
    memcpy(cur.name, name, name_len);
    cur.name[name_len] = '\0';
    if (!name_ok(kind, cur.name))
    {
        return SAVE_BAD_NAME;
    }
    uint32_t most = kind == SAVE_PICTURE ? SAVE_PICTURE_MAX_BYTES : SAVE_SOUND_MAX_BYTES;
    if (length == 0 || length > most)
    {
        return SAVE_NO_ROOM;
    }
    // The lists have room, and nothing of that name's there
    char stem[SAVE_NAME_MAX + 1];
    stem_of(cur.name, stem, sizeof(stem));
    if (kind == SAVE_PICTURE && media_find(stem) >= 0)
    {
        return SAVE_EXISTS;
    }
    if (kind == SAVE_PICTURE ? media_storage_count() >= MEDIA_STORAGE_MAX
                             : audio_player_available() && audio_player_file_room() == 0)
    {
        return SAVE_NO_ROOM;
    }
    uint64_t total, free_bytes;
    if (rcat_hal_storage_space(&total, &free_bytes) && free_bytes < (uint64_t)length + ROOM_LEFT)
    {
        return SAVE_NO_ROOM;
    }
    char folder[PATH_MAX_LEN], path[PATH_MAX_LEN];
    if (!folder_of(kind, folder, sizeof(folder), true))
    {
        return SAVE_NO_CARD;
    }
    if (snprintf(path, sizeof(path), "%s/%s", folder, cur.name) >= (int)sizeof(path)
        || snprintf(cur.part, sizeof(cur.part), "%s/%s.part", folder, cur.name) >= (int)sizeof(cur.part))
    {
        cur.part[0] = '\0';
        return SAVE_BAD_NAME;
    }
    if (exists(path))
    {
        cur.part[0] = '\0';
        return SAVE_EXISTS;
    }
    cur.file = fopen(cur.part, "wb");
    if (cur.file == NULL)
    {
        printf("save: can't write %s (%d)\n", cur.part, errno);
        cur.part[0] = '\0';
        return SAVE_NO_CARD;
    }
    setvbuf(cur.file, NULL, _IOFBF, 4096);
    cur.on = true;
    cur.last_ms = rcat_hal_millis();
    cur.kind = kind;
    cur.length = length;
    cur.got = 0;
    memcpy(cur.hash, hash, SAVE_HASH_LEN);
    mbedtls_sha256_init(&cur.sha);
    mbedtls_sha256_starts(&cur.sha, 0);
    // The card's busy: what plays waits (it stutters otherwise)
    if (kind == SAVE_SOUND && audio_player_is_playing())
    {
        audio_player_pause();
        cur.paused_player = true;
    }
    printf("save: %s, %lu bytes\n", cur.name, (unsigned long)length);
    return SAVE_OK;
}

save_result_t storage_save_write(uint32_t offset, const uint8_t *data, size_t len)
{
    if (!cur.on)
    {
        return SAVE_BUSY;
    }
    if (offset != cur.got)
    {
        return SAVE_OK;     // not where it's got to: left out
    }
    if (len == 0 || cur.got + len > cur.length)
    {
        end_transfer(true);
        return SAVE_FAILED;
    }
    if (fwrite(data, 1, len, cur.file) != len)
    {
        printf("save: writing %s failed (%d)\n", cur.name, errno);
        end_transfer(true);
        return SAVE_FAILED;
    }
    mbedtls_sha256_update(&cur.sha, data, len);
    cur.got += (uint32_t)len;
    cur.last_ms = rcat_hal_millis();
    return SAVE_OK;
}

save_result_t storage_save_finish(void)
{
    if (!cur.on)
    {
        return SAVE_BUSY;
    }
    uint8_t hash[SAVE_HASH_LEN];
    mbedtls_sha256_finish(&cur.sha, hash);
    bool whole = cur.got == cur.length;
    bool flushed = fclose(cur.file) == 0;
    cur.file = NULL;
    if (!whole || !flushed)
    {
        end_transfer(true);
        return whole ? SAVE_FAILED : SAVE_BAD_HASH;
    }
    if (memcmp(hash, cur.hash, SAVE_HASH_LEN) != 0)
    {
        printf("save: %s didn't come to its hash\n", cur.name);
        end_transfer(true);
        return SAVE_BAD_HASH;
    }
    char folder[PATH_MAX_LEN], path[PATH_MAX_LEN];
    uint8_t kind = cur.kind;
    char name[SAVE_NAME_MAX + 1];
    snprintf(name, sizeof(name), "%s", cur.name);
    if (!folder_of(kind, folder, sizeof(folder), false)
        || snprintf(path, sizeof(path), "%s/%s", folder, name) >= (int)sizeof(path) || exists(path)
        || rename(cur.part, path) != 0)
    {
        end_transfer(true);
        return exists(path) ? SAVE_EXISTS : SAVE_FAILED;
    }
    cur.part[0] = '\0';     // it's the file now
    end_transfer(false);

    // Into the lists, with what shows or plays carrying on
    if (kind == SAVE_PICTURE)
    {
        lv_display_t *disp = lv_display_get_default();
        int32_t screen = LV_MIN(lv_display_get_horizontal_resolution(disp), lv_display_get_vertical_resolution(disp));
        int at = media_add_file(path, name, screen);
        if (at < 0)
        {
            printf("save: %s can't be shown, deleted\n", name);
            remove(path);
            return SAVE_BAD_FILE;
        }
        feature_images_add_stored((size_t)at);
    }
    else if (!audio_player_file_added(name) && audio_player_available())
    {
        remove(path);       // couldn't be put in the list, which would leave it unseen until the next start
        return SAVE_BUSY;
    }
    printf("save: %s saved\n", name);
    return SAVE_OK;
}

save_result_t storage_save_delete(uint8_t kind, const char *name)
{
    char folder[PATH_MAX_LEN], path[PATH_MAX_LEN];
    if (kind > SAVE_SOUND || !name_ok(kind, name))
    {
        return SAVE_BAD_NAME;
    }
    if (cur.on)
    {
        return SAVE_BUSY;
    }
    if (!folder_of(kind, folder, sizeof(folder), false)
        || snprintf(path, sizeof(path), "%s/%s", folder, name) >= (int)sizeof(path) || !exists(path))
    {
        return SAVE_BAD_NAME;
    }
    if (kind == SAVE_SOUND)
    {
        // The speaker's task stops it, takes it out of the list and deletes the file
        return audio_player_available() ? (audio_player_remove_file(name) ? SAVE_OK : SAVE_BUSY)
                                        : (remove(path) == 0 ? SAVE_OK : SAVE_FAILED);
    }
    char stem[SAVE_NAME_MAX + 1];
    stem_of(name, stem, sizeof(stem));
    int at = media_find(stem);
    if (at >= 0 && (size_t)at < media_storage_count())
    {
        feature_images_remove_stored((size_t)at);
        media_remove_file(stem);
    }
    return remove(path) == 0 ? SAVE_OK : SAVE_FAILED;
}

void storage_save_list(uint8_t kind, void (*each)(const char *name, void *user), void *user)
{
    char folder[PATH_MAX_LEN];
    if (!folder_of(kind, folder, sizeof(folder), false))
    {
        return;
    }
    DIR *dir = opendir(folder);
    for (struct dirent *e; dir != NULL && (e = readdir(dir)) != NULL;)
    {
        if (e->d_type != DT_DIR && e->d_name[0] != '.' && strlen(e->d_name) <= SAVE_NAME_MAX
            && (kind == SAVE_PICTURE ? is_picture_name(e->d_name) : is_sound_name(e->d_name)))
        {
            each(e->d_name, user);
        }
    }
    if (dir != NULL)
    {
        closedir(dir);
    }
}
