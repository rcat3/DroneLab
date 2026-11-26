#ifndef RCAT_MEDIA_LIBRARY_H
#define RCAT_MEDIA_LIBRARY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define MEDIA_NAME_LEN 24

typedef struct
{
    char name[MEDIA_NAME_LEN];  // file name without the extension
    const void *src;            // LVGL image source (lv_image_dsc_t or lv_draw_buf_t)
    bool is_gif;
    uint16_t scale;             // for GIFs: scale to show at, LV_SCALE_NONE (256) = as is
} media_item_t;

/* Start with the images built into the firmware. Call after lv_init(). */
void media_init(void);

/* Load the images in a folder on storage (its "images" subfolder if there is
 * one) and put them before the built-in images, sorted by name. Static
 * images are decoded and scaled for a screen_size x screen_size screen. GIFs
 * are loaded as they are, with a scale to show them at. Returns how many
 * were loaded. */
size_t media_load_folder(const char *path, int32_t screen_size);

size_t media_count(void);
const media_item_t *media_get(size_t index);

/* Pictures on storage (not the built-in ones), added and taken away while
 * it runs, for the app's saving to the card. There's room for
 * MEDIA_STORAGE_MAX of them. */
#define MEDIA_STORAGE_MAX 32
size_t media_storage_count(void);

/* Load the picture file at path (named file_name, which has its extension)
 * and put it among the storage ones, by name. Returns where it went (an
 * index for media_get), or -1 if it can't be shown or there's no room. Call
 * it from the UI loop. */
int media_add_file(const char *path, const char *file_name, int32_t screen_size);

/* Forget the storage picture called name (no extension) and free it.
 * Returns where it was, or -1. The file's the caller's. */
int media_remove_file(const char *name);

/* Index of the image with the given name, or -1 if there isn't one. */
int media_find(const char *name);

/* A picture in memory, a JPEG or a GIF, for showing on a screen_size x
 * screen_size screen, as one from storage is: a JPEG decoded and scaled, a
 * GIF wrapped as it is (data must stay valid while it's shown), with the
 * scale to show it at. NULL if it can't be. Free it with
 * media_free_decoded(). */
const void *media_decode_memory(const uint8_t *data, size_t len, bool is_gif, int32_t screen_size, uint16_t *scale);
void media_free_decoded(const void *src, bool is_gif);

/* How many of the images are built into the firmware: the last of them. */
size_t media_built_in_count(void);

#endif
