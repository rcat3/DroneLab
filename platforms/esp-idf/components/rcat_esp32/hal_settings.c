/*
 * The settings block and the other stored blocks (see hal.h), kept as blobs
 * in NVS, and the battery log, in a partition of its own, for the ESP32
 * boards
 */

#include <stdio.h>
#include <string.h>

#include "esp_err.h"
#include "esp_partition.h"
#include "esp_rom_crc.h"
#include "nvs.h"
#include "nvs_flash.h"

#include "hal.h"
#include "rcat_esp32.h"

#define NVS_NAMESPACE       "rcat"
#define NVS_SETTINGS_KEY    "settings"

// The battery log's partition (see partitions.csv). tools/battery_log.py reads
// it from there.
#define LOG_PARTITION_TYPE  0x40
#define LOG_PARTITION_NAME  "batlog"

void rcat_esp32_settings_init(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND)
    {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);
}

bool rcat_hal_settings_read(void *data, size_t len)
{
    nvs_handle_t nvs;
    if (nvs_open(NVS_NAMESPACE, NVS_READONLY, &nvs) != ESP_OK)
    {
        return false;   // nothing saved yet
    }

    // Like erased flash, so a shorter saved blob leaves the rest at 0xFF.
    memset(data, 0xFF, len);
    size_t stored_len = len;
    esp_err_t err = nvs_get_blob(nvs, NVS_SETTINGS_KEY, data, &stored_len);
    nvs_close(nvs);
    return err == ESP_OK;
}

bool rcat_hal_settings_write(const void *data, size_t len)
{
    nvs_handle_t nvs;
    if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &nvs) != ESP_OK)
    {
        return false;
    }

    esp_err_t err = nvs_set_blob(nvs, NVS_SETTINGS_KEY, data, len);
    if (err == ESP_OK)
    {
        err = nvs_commit(nvs);
    }
    nvs_close(nvs);
    return err == ESP_OK;
}

size_t rcat_hal_store_read(const char *name, void *data, size_t len)
{
    nvs_handle_t nvs;
    if (nvs_open(NVS_NAMESPACE, NVS_READONLY, &nvs) != ESP_OK)
    {
        return 0;
    }
    size_t stored_len = len;
    esp_err_t err = nvs_get_blob(nvs, name, data, &stored_len);
    nvs_close(nvs);
    return err == ESP_OK ? stored_len : 0;
}

bool rcat_hal_store_write(const char *name, const void *data, size_t len)
{
    nvs_handle_t nvs;
    if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &nvs) != ESP_OK)
    {
        return false;
    }
    esp_err_t err = nvs_set_blob(nvs, name, data, len);
    if (err == ESP_OK)
    {
        err = nvs_commit(nvs);
    }
    nvs_close(nvs);
    return err == ESP_OK;
}

static const esp_partition_t *log_partition(void)
{
    static const esp_partition_t *part;
    if (part == NULL)
    {
        part = esp_partition_find_first(ESP_PARTITION_TYPE_DATA, LOG_PARTITION_TYPE, LOG_PARTITION_NAME);
    }
    return part;
}

bool rcat_hal_log_read(void *data, size_t len)
{
    const esp_partition_t *part = log_partition();
    return part != NULL && len <= part->size && esp_partition_read(part, 0, data, len) == ESP_OK;
}

bool rcat_hal_log_write(const void *data, size_t len)
{
    const esp_partition_t *part = log_partition();
    return part != NULL && len <= part->size
           && esp_partition_erase_range(part, 0, part->size) == ESP_OK
           && esp_partition_write(part, 0, data, len) == ESP_OK;
}

bool rcat_hal_log_program(size_t offset, const void *data, size_t len)
{
    const esp_partition_t *part = log_partition();
    return part != NULL && offset + len <= part->size && esp_partition_write(part, offset, data, len) == ESP_OK;
}

/* ----- The favourite patterns -----
 *
 * Two copies, each in half the partition: a header (a marker, a count that
 * goes up with each save, the length and a CRC-32 of the bytes), then the
 * bytes. A save goes in the half that isn't the newest, its header last,
 * so one cut short leaves the newest as it was. */

#define PATTERNS_PARTITION_NAME "patterns"
#define PATTERNS_MAGIC          0x53544150u     // "PATS"

typedef struct
{
    uint32_t magic;
    uint32_t seq;
    uint32_t len;
    uint32_t crc;
} patterns_header_t;

static const esp_partition_t *patterns_partition(void)
{
    static const esp_partition_t *part;
    static bool looked;
    if (!looked)
    {
        looked = true;
        part = esp_partition_find_first(ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_ANY, PATTERNS_PARTITION_NAME);
        if (part != NULL && part->size < 2 * (sizeof(patterns_header_t) + RCAT_HAL_PATTERNS_SIZE))
        {
            part = NULL;
        }
        if (part == NULL)
        {
            printf("patterns: no partition for favourites; flash over USB to add it\n");
        }
    }
    return part;
}

/* A half's header, if what's there is good. */
static bool patterns_half(const esp_partition_t *part, int half, patterns_header_t *h)
{
    size_t at = (size_t)half * (part->size / 2);
    if (esp_partition_read(part, at, h, sizeof(*h)) != ESP_OK || h->magic != PATTERNS_MAGIC
        || h->len > RCAT_HAL_PATTERNS_SIZE)
    {
        return false;
    }
    uint32_t crc = 0;
    uint8_t buf[256];
    for (size_t done = 0; done < h->len;)
    {
        size_t n = h->len - done < sizeof(buf) ? h->len - done : sizeof(buf);
        if (esp_partition_read(part, at + sizeof(*h) + done, buf, n) != ESP_OK)
        {
            return false;
        }
        crc = esp_rom_crc32_le(crc, buf, n);
        done += n;
    }
    return crc == h->crc;
}

/* The newest good half, or -1. */
static int patterns_newest(const esp_partition_t *part, patterns_header_t *h)
{
    patterns_header_t a, b;
    bool good_a = patterns_half(part, 0, &a), good_b = patterns_half(part, 1, &b);
    if (good_a && (!good_b || (int32_t)(a.seq - b.seq) > 0))
    {
        *h = a;
        return 0;
    }
    if (good_b)
    {
        *h = b;
        return 1;
    }
    return -1;
}

bool rcat_hal_patterns_available(void)
{
    return patterns_partition() != NULL;
}

size_t rcat_hal_patterns_read(void *data, size_t len)
{
    const esp_partition_t *part = patterns_partition();
    patterns_header_t h;
    int half = part != NULL ? patterns_newest(part, &h) : -1;
    if (half < 0 || h.len > len)
    {
        return 0;
    }
    size_t at = (size_t)half * (part->size / 2) + sizeof(h);
    return esp_partition_read(part, at, data, h.len) == ESP_OK ? h.len : 0;
}

bool rcat_hal_patterns_write(const void *data, size_t len)
{
    const esp_partition_t *part = patterns_partition();
    if (part == NULL || len > RCAT_HAL_PATTERNS_SIZE)
    {
        return false;
    }
    patterns_header_t newest;
    int was = patterns_newest(part, &newest);
    int half = was == 0 ? 1 : 0;
    size_t at = (size_t)half * (part->size / 2);
    size_t erase = (sizeof(patterns_header_t) + len + 4095) & ~(size_t)4095;
    patterns_header_t h = {
        .magic = PATTERNS_MAGIC,
        .seq = was >= 0 ? newest.seq + 1 : 1,
        .len = (uint32_t)len,
        .crc = esp_rom_crc32_le(0, data, len),
    };
    return esp_partition_erase_range(part, at, erase) == ESP_OK
           && (len == 0 || esp_partition_write(part, at + sizeof(h), data, len) == ESP_OK)
           && esp_partition_write(part, at, &h, sizeof(h)) == ESP_OK;
}
