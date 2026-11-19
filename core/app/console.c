#include "console.h"

#if RCAT_SERIAL_CONSOLE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lvgl.h"

#include "hal.h"
#include "remote.h"
#include "screenshot.h"

#define POLL_MS         20
#define CONSOLE_LINE_MAX        700
#define ANSWER_MAX      8192
#define SHOT_LINE_BYTES 384     // pixels' bytes per line of base64 (a multiple of 3)

static char *line;     // CONSOLE_LINE_MAX, from PSRAM
static size_t line_len;

static void base64(const uint8_t *in, size_t len, char *out)
{
    static const char digits[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t o = 0;
    for (size_t i = 0; i < len; i += 3)
    {
        uint32_t v = (uint32_t)in[i] << 16;
        if (i + 1 < len)
        {
            v |= (uint32_t)in[i + 1] << 8;
        }
        if (i + 2 < len)
        {
            v |= in[i + 2];
        }
        out[o++] = digits[(v >> 18) & 63];
        out[o++] = digits[(v >> 12) & 63];
        out[o++] = i + 1 < len ? digits[(v >> 6) & 63] : '=';
        out[o++] = i + 2 < len ? digits[v & 63] : '=';
    }
    out[o] = '\0';
}

/* The last picture taken, kept so a line that didn't arrive whole can be
 * sent again */
static uint16_t *shot_px;
static size_t shot_bytes;

static uint32_t crc32(const uint8_t *p, size_t len)
{
    uint32_t crc = 0xffffffffu;
    for (size_t i = 0; i < len; i++)
    {
        crc ^= p[i];
        for (int b = 0; b < 8; b++)
        {
            crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
        }
    }
    return ~crc;
}

/* One line of the picture: "SHOT: <line> <crc32> <base64>" */
static void send_shot_line(size_t i)
{
    size_t at = i * SHOT_LINE_BYTES;
    if (shot_px == NULL || at >= shot_bytes)
    {
        printf("SHOT: FAILED\n");
        return;
    }
    const uint8_t *bytes = (const uint8_t *)shot_px + at;   // little-endian, as the ESP32 is
    size_t n = shot_bytes - at < SHOT_LINE_BYTES ? shot_bytes - at : SHOT_LINE_BYTES;
    char text[SHOT_LINE_BYTES / 3 * 4 + 1];
    base64(bytes, n, text);
    printf("SHOT: %u %08lx %s\n", (unsigned)i, (unsigned long)crc32(bytes, n), text);
}

static void send_shot(void)
{
    lv_free(shot_px);
    int32_t w, h;
    shot_px = screenshot_take(&w, &h);
    if (shot_px == NULL)
    {
        printf("SHOT: FAILED\n");
        return;
    }
    shot_bytes = (size_t)w * h * 2;
    size_t lines = (shot_bytes + SHOT_LINE_BYTES - 1) / SHOT_LINE_BYTES;
    printf("SHOT: BEGIN %d %d %u\n", (int)w, (int)h, (unsigned)lines);
    for (size_t i = 0; i < lines; i++)
    {
        send_shot_line(i);
        // Writing to USB waits without blocking, so let the core's other
        // tasks in now and then, or the watchdog restarts the board
        rcat_hal_delay_ms(1);
    }
    printf("SHOT: END\n");
    fflush(stdout);
}

static void run(char *cmd)
{
    if (strcmp(cmd, "shot") == 0)
    {
        send_shot();
        return;
    }
    if (strncmp(cmd, "line ", 5) == 0)
    {
        send_shot_line((size_t)atoi(cmd + 5));
        return;
    }
    if (strcmp(cmd, "save") == 0)
    {
        char name[24];
        printf("CONSOLE: %s\n", screenshot_save(name, sizeof(name)) ? name : "-1");
        return;
    }
    if (strncmp(cmd, "api ", 4) == 0)
    {
        char method[8], target[200];
        int used = 0;
        if (sscanf(cmd + 4, "%7s %199s %n", method, target, &used) < 2)
        {
            printf("CONSOLE: -1\n");
            return;
        }
        const char *body = used > 0 ? cmd + 4 + used : "";
        // From PSRAM: internal RAM is short on these boards, and the SD
        // card and the radio need it
        char *answer = lv_malloc(ANSWER_MAX);
        int n = answer == NULL ? -1 : remote_api(method, target, body, strlen(body), answer, ANSWER_MAX - 1);
        if (n < 0)
        {
            printf("CONSOLE: -1\n");
        }
        else
        {
            answer[n] = '\0';
            printf("CONSOLE: %s\n", answer);
        }
        lv_free(answer);
        return;
    }
    printf("CONSOLE: -1\n");
}

static void poll_cb(lv_timer_t *t)
{
    (void)t;
    char buf[128];
    size_t n;
    while ((n = rcat_hal_console_read(buf, sizeof(buf))) > 0)
    {
        for (size_t i = 0; i < n; i++)
        {
            char c = buf[i];
            if (c == '\r' || c == '\n')
            {
                if (line_len > 0)
                {
                    line[line_len] = '\0';
                    line_len = 0;
                    run(line);
                }
            }
            else if (line_len < CONSOLE_LINE_MAX - 1)
            {
                line[line_len++] = c;
            }
        }
    }
}

void console_init(void)
{
    line = lv_malloc(CONSOLE_LINE_MAX);
    if (line == NULL)
    {
        return;
    }
    printf("console: ready\n");
    lv_timer_create(poll_cb, POLL_MS, NULL);
}

#else

void console_init(void)
{
}

#endif
