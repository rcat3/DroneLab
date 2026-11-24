/*
 * The virtual unit's storage: the settings, the other stored blocks and the
 * battery log as files in its own folder, and a folder for the SD card
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "hal.h"
#include "host.h"

#define SETTINGS_FILE   "settings.bin"
#define LOG_FILE        "battery-log.bin"

/* Make dir and the folders it's in, as mkdir -p does */
static bool make_dirs(const char *dir)
{
    char path[512];
    snprintf(path, sizeof(path), "%s", dir);
    for (char *p = path + 1; *p != '\0'; p++)
    {
        if (*p == '/')
        {
            *p = '\0';
            if (mkdir(path, 0700) != 0 && errno != EEXIST)
            {
                return false;
            }
            *p = '/';
        }
    }
    return mkdir(path, 0700) == 0 || errno == EEXIST;
}

const char *host_data_dir(void)
{
    static char dir[400];
    if (dir[0] == '\0')
    {
        const char *data = getenv("XDG_DATA_HOME");
        const char *home = getenv("HOME");
        char base[300];
        if (data != NULL && data[0] == '/')
        {
            snprintf(base, sizeof(base), "%s", data);
        }
        else
        {
            snprintf(base, sizeof(base), "%s/.local/share", home != NULL ? home : "/tmp");
        }
        if (host_options.unit == 1)
        {
            snprintf(dir, sizeof(dir), "%s/io.github.rcat3.dronelab/unit", base);
        }
        else
        {
            snprintf(dir, sizeof(dir), "%s/io.github.rcat3.dronelab/unit-%d", base, host_options.unit);
        }
        if (!make_dirs(dir))
        {
            fprintf(stderr, "Couldn't make %s: %s\n", dir, strerror(errno));
        }
    }
    return dir;
}

void host_data_path(char *out, size_t len, const char *name)
{
    snprintf(out, len, "%s/%s", host_data_dir(), name);
}

/* Read up to len bytes of the file name, returning how many, or -1 if it isn't there. */
static long read_file(const char *name, void *data, size_t len)
{
    char path[512];
    host_data_path(path, sizeof(path), name);
    FILE *f = fopen(path, "rb");
    if (f == NULL)
    {
        return -1;
    }
    size_t n = fread(data, 1, len, f);
    fclose(f);
    return (long)n;
}

/* Write the file name whole, so it's never left half written. */
static bool write_file(const char *name, const void *data, size_t len)
{
    char path[512], tmp[520];
    host_data_path(path, sizeof(path), name);
    snprintf(tmp, sizeof(tmp), "%s.new", path);
    FILE *f = fopen(tmp, "wb");
    if (f == NULL)
    {
        return false;
    }
    bool ok = fwrite(data, 1, len, f) == len;
    ok = fflush(f) == 0 && ok;
    ok = fsync(fileno(f)) == 0 && ok;
    ok = fclose(f) == 0 && ok;
    return ok && rename(tmp, path) == 0;
}

bool rcat_hal_settings_read(void *data, size_t len)
{
    // Like erased flash, so a shorter saved block leaves the rest at 0xFF
    memset(data, 0xFF, len);
    return read_file(SETTINGS_FILE, data, len) > 0;
}

bool rcat_hal_settings_write(const void *data, size_t len)
{
    return write_file(SETTINGS_FILE, data, len);
}

/* The file a stored block is kept in, if its name will do for one */
static bool store_file(const char *name, char *file, size_t len)
{
    size_t n = strlen(name);
    if (n == 0 || n > 15)
    {
        return false;
    }
    for (size_t i = 0; i < n; i++)
    {
        char c = name[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-'))
        {
            return false;
        }
    }
    snprintf(file, len, "store-%s.bin", name);
    return true;
}

size_t rcat_hal_store_read(const char *name, void *data, size_t len)
{
    char file[40];
    if (!store_file(name, file, sizeof(file)))
    {
        return 0;
    }
    long n = read_file(file, data, len);
    return n > 0 ? (size_t)n : 0;
}

bool rcat_hal_store_write(const char *name, const void *data, size_t len)
{
    char file[40];
    return store_file(name, file, sizeof(file)) && write_file(file, data, len);
}

/* The battery log: a file the size of the board's partition, erased
 * (0xFF) where nothing's written. */
static uint8_t log_block[RCAT_HAL_LOG_SIZE];

static void log_load(void)
{
    memset(log_block, 0xFF, sizeof(log_block));
    read_file(LOG_FILE, log_block, sizeof(log_block));
}

bool rcat_hal_log_read(void *data, size_t len)
{
    if (len > RCAT_HAL_LOG_SIZE)
    {
        return false;
    }
    log_load();
    memcpy(data, log_block, len);
    return true;
}

bool rcat_hal_log_write(const void *data, size_t len)
{
    if (len > RCAT_HAL_LOG_SIZE)
    {
        return false;
    }
    memset(log_block, 0xFF, sizeof(log_block));
    memcpy(log_block, data, len);
    return write_file(LOG_FILE, log_block, sizeof(log_block));
}

bool rcat_hal_log_program(size_t offset, const void *data, size_t len)
{
    if (offset + len > RCAT_HAL_LOG_SIZE)
    {
        return false;
    }
    log_load();
    // Like flash, writing can only clear bits
    const uint8_t *bytes = data;
    for (size_t i = 0; i < len; i++)
    {
        log_block[offset + i] &= bytes[i];
    }
    return write_file(LOG_FILE, log_block, sizeof(log_block));
}

/* The favourite patterns: a file of their own, like the others. */
bool rcat_hal_patterns_available(void)
{
    return true;
}

size_t rcat_hal_patterns_read(void *data, size_t len)
{
    return rcat_hal_store_read("patterns", data, len > RCAT_HAL_PATTERNS_SIZE ? RCAT_HAL_PATTERNS_SIZE : len);
}

bool rcat_hal_patterns_write(const void *data, size_t len)
{
    return len <= RCAT_HAL_PATTERNS_SIZE && rcat_hal_store_write("patterns", data, len);
}

bool rcat_hal_storage_mount(const char **path)
{
    static char dir[512];
    if (host_options.sdcard != NULL)
    {
        snprintf(dir, sizeof(dir), "%s", host_options.sdcard);
        size_t n = strlen(dir);
        while (n > 1 && dir[n - 1] == '/')
        {
            dir[--n] = '\0';
        }
    }
    else
    {
        host_data_path(dir, sizeof(dir), "sdcard");
        if (!make_dirs(dir))
        {
            return false;
        }
    }
    struct stat st;
    if (stat(dir, &st) != 0 || !S_ISDIR(st.st_mode))
    {
        fprintf(stderr, "No SD card: %s isn't a folder\n", dir);
        return false;
    }
    printf("SD card: %s\n", dir);
    *path = dir;
    return true;
}
