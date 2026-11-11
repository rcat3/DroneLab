/*
 * Firmware updates over WiFi (see updater.h).
 *
 * The server takes one connection at a time, each with one request. Both
 * requests need the code from the screen in an X-Update-Code header:
 *
 *   GET  /info      answers with "board=<name>", "battery=<percent, or -1>"
 *                   and "min_battery=<percent>", on lines of their own
 *   POST /update    the firmware (the .bin file) as the body, with its
 *                   Content-Length, and the board it's for in X-Update-Board
 *
 * The update is written as it arrives, from the UI loop, a little at a time
 * so the screen keeps going.
 */
#include "app/updater.h"

#include <stdio.h>
#include <string.h>

#include "app/battery.h"
#include "app/remote.h"
#include "hal.h"
#include "lvgl.h"

#define CONFIRM_MS          15000   // running this long shows the firmware works

#if RCAT_HAVE_NETWORK

#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <strings.h>
#include <sys/socket.h>
#include <unistd.h>

#define POLL_MS             10
#define ALLOW_MS            (10 * 60 * 1000)    // updates switch off after this
#define IDLE_TIMEOUT_MS     10000   // a connection that sends nothing for this long is dropped
#define READ_BUDGET_MS      20      // how long each poll can spend on an update
#define HEAD_MAX            1024
#define CHUNK               4096
#define MAX_WRONG_CODES     3
#define MAX_FIRMWARE        (7 * 1024 * 1024)   // the app partitions' size
#define MIN_BATTERY_PERCENT 20
#define RESTART_DELAY_MS    1500    // so the script gets its answer first

// The board's name, after a marker tools/update.py looks for in a .bin file,
// to check it's for this board.
static const char board_marker[] = "rcat-board:" RCAT_BOARD_NAME;
#define BOARD_NAME (board_marker + sizeof("rcat-board:") - 1)

typedef enum
{
    PHASE_HEAD,     // reading the request's headers
    PHASE_BODY,     // writing the firmware
} phase_t;

static bool allowed;
static bool started_hotspot;
static uint32_t allowed_at;
static char code[7];
static int wrong_codes;
static int listen_fd = -1;
static int client_fd = -1;
static uint32_t last_data_at;
static phase_t phase;
static char head[HEAD_MAX + 1];
static size_t head_len;
static size_t expected;
static size_t received;
static bool restarting;
static uint32_t restart_at;
static char status[64] = "";

static void set_status(const char *text)
{
    snprintf(status, sizeof(status), "%s", text);
    printf("update: %s\n", text);
}

static int open_listener(void)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
    {
        return -1;
    }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr = { 0 };
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(UPDATE_PORT);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 1) != 0)
    {
        close(fd);
        return -1;
    }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    return fd;
}

static void close_client(void)
{
    if (client_fd >= 0)
    {
        close(client_fd);
    }
    client_fd = -1;
    if (phase == PHASE_BODY)
    {
        rcat_hal_update_abort();
    }
    phase = PHASE_HEAD;
    head_len = 0;
}

/* A short answer, then the connection's closed. It fits in the socket's
 * buffer, so one send does it. */
static void respond(const char *status_line, const char *text)
{
    char out[256];
    int n = snprintf(out, sizeof(out),
                     "HTTP/1.1 %s\r\nContent-Type: text/plain\r\nContent-Length: %u\r\nConnection: close\r\n\r\n%s\n",
                     status_line, (unsigned)strlen(text) + 1, text);
    send(client_fd, out, (size_t)n, 0);
    phase = PHASE_HEAD;     // nothing to abort: the caller's dealt with it
    close_client();
}

static void header_value(const char *name, char *out, size_t len)
{
    out[0] = '\0';
    size_t name_len = strlen(name);
    for (const char *line = strstr(head, "\r\n"); line != NULL; line = strstr(line + 2, "\r\n"))
    {
        const char *p = line + 2;
        if (strncasecmp(p, name, name_len) == 0 && p[name_len] == ':')
        {
            p += name_len + 1;
            while (*p == ' ')
            {
                p++;
            }
            size_t n = strcspn(p, "\r\n");
            n = n < len - 1 ? n : len - 1;
            memcpy(out, p, n);
            out[n] = '\0';
            return;
        }
    }
}

static bool write_firmware(const char *data, size_t len)
{
    if (len > expected - received)
    {
        len = expected - received;  // anything after the firmware is ignored
    }
    if (!rcat_hal_update_write(data, len))
    {
        set_status("Couldn't write the update");
        close_client();
        return false;
    }
    received += len;
    snprintf(status, sizeof(status), "Receiving  %u%%", (unsigned)(received * 100 / expected));
    if (received < expected)
    {
        return true;
    }

    phase = PHASE_HEAD;
    if (!rcat_hal_update_finish())
    {
        set_status("The update was damaged");
        respond("422 Unprocessable Entity", "The board didn't accept the firmware: it's damaged or not for this chip.");
        return false;
    }
    set_status("Installed, restarting");
    respond("200 OK", "Installed. The board is restarting into it.");
    restarting = true;
    restart_at = lv_tick_get() + RESTART_DELAY_MS;
    return false;
}

static void handle_request(char *body_start)
{
    char value[48];
    header_value("X-Update-Code", value, sizeof(value));
    if (strcmp(value, code) != 0)
    {
        wrong_codes++;
        respond("403 Forbidden", "Wrong code: use the one on the board's Firmware Update page.");
        if (wrong_codes >= MAX_WRONG_CODES)
        {
            updater_allow(false);
            set_status("Off after 3 wrong codes");
        }
        return;
    }

    if (strncmp(head, "GET /info ", 10) == 0)
    {
        char text[96];
        float volts;
        int percent = rcat_hal_battery_voltage(&volts) ? battery_percent_from_volts(volts) : -1;
        snprintf(text, sizeof(text), "board=%s\nbattery=%d\nmin_battery=%d", BOARD_NAME, percent,
                 MIN_BATTERY_PERCENT);
        respond("200 OK", text);
        return;
    }
    if (strncmp(head, "POST /update ", 13) != 0)
    {
        respond("404 Not Found", "Use GET /info or POST /update.");
        return;
    }

    header_value("X-Update-Board", value, sizeof(value));
    if (strcmp(value, BOARD_NAME) != 0)
    {
        respond("409 Conflict", "That firmware is for another board.");
        return;
    }
    header_value("Content-Length", value, sizeof(value));
    long length = strtol(value, NULL, 10);
    if (length <= 0 || length > MAX_FIRMWARE)
    {
        respond("411 Length Required", "Send the firmware's length, which has to fit the board.");
        return;
    }
    float volts;
    if (rcat_hal_battery_voltage(&volts) && battery_percent_from_volts(volts) < MIN_BATTERY_PERCENT)
    {
        set_status("Battery too low to update");
        respond("503 Service Unavailable", "The battery's too low to update. Charge it first.");
        return;
    }
    if (!rcat_hal_update_begin())
    {
        set_status("Couldn't start the update");
        respond("500 Internal Server Error", "The board couldn't start the update.");
        return;
    }

    expected = (size_t)length;
    received = 0;
    phase = PHASE_BODY;
    set_status("Receiving  0%");
    size_t already = head_len - (size_t)(body_start - head);
    if (already > 0)
    {
        write_firmware(body_start, already);
    }
}

static void read_head(void)
{
    ssize_t n = recv(client_fd, head + head_len, HEAD_MAX - head_len, 0);
    if (n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK))
    {
        close_client();
        return;
    }
    if (n < 0)
    {
        return;
    }
    last_data_at = lv_tick_get();
    head_len += (size_t)n;
    head[head_len] = '\0';
    char *end = strstr(head, "\r\n\r\n");
    if (end != NULL)
    {
        *end = '\0';    // the headers, as a string; the body starts after
        handle_request(end + 4);
    }
    else if (head_len >= HEAD_MAX)
    {
        respond("431 Request Header Fields Too Large", "The request's headers are too long.");
    }
}

static void read_body(void)
{
    static char buf[CHUNK];
    uint32_t start = lv_tick_get();
    while (client_fd >= 0 && phase == PHASE_BODY && lv_tick_elaps(start) < READ_BUDGET_MS)
    {
        ssize_t n = recv(client_fd, buf, sizeof(buf), 0);
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
        {
            return;
        }
        if (n <= 0)
        {
            set_status("The update stopped part way");
            close_client();
            return;
        }
        last_data_at = lv_tick_get();
        if (!write_firmware(buf, (size_t)n))
        {
            return;
        }
    }
}

static void poll_cb(lv_timer_t *t)
{
    if (restarting)
    {
        if ((int32_t)(lv_tick_get() - restart_at) >= 0)
        {
            rcat_hal_restart();
        }
        return;
    }
    if (!allowed)
    {
        return;
    }
    if (client_fd < 0 && lv_tick_elaps(allowed_at) > ALLOW_MS)
    {
        updater_allow(false);
        set_status("Off after 10 minutes");
        return;
    }
    if (!remote_running())
    {
        return;     // the hotspot's been switched off
    }
    if (listen_fd < 0)
    {
        listen_fd = open_listener();    // once the network's up
        if (listen_fd < 0)
        {
            return;
        }
    }
    if (client_fd < 0)
    {
        int fd = accept(listen_fd, NULL, NULL);
        if (fd < 0)
        {
            return;
        }
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
        client_fd = fd;
        phase = PHASE_HEAD;
        head_len = 0;
        last_data_at = lv_tick_get();
    }
    if (lv_tick_elaps(last_data_at) > IDLE_TIMEOUT_MS)
    {
        if (phase == PHASE_BODY)
        {
            set_status("The update stopped part way");
        }
        close_client();
        return;
    }
    if (phase == PHASE_HEAD)
    {
        read_head();
    }
    else
    {
        read_body();
    }
}

bool updater_available(void)
{
    return remote_available() && rcat_hal_update_supported();
}

void updater_allow(bool allow)
{
    if (allow == allowed)
    {
        return;
    }
    if (allow)
    {
        if (!remote_running())
        {
            if (!remote_start())
            {
                set_status("WiFi didn't start");
                return;
            }
            started_hotspot = true;
        }
        snprintf(code, sizeof(code), "%06lu", (unsigned long)(rcat_hal_random() % 1000000));
        wrong_codes = 0;
        allowed_at = lv_tick_get();
        allowed = true;
        set_status("Waiting for the update");
        return;
    }

    allowed = false;
    close_client();
    if (listen_fd >= 0)
    {
        close(listen_fd);
        listen_fd = -1;
    }
    code[0] = '\0';
    if (started_hotspot)
    {
        remote_stop();
        started_hotspot = false;
    }
    set_status("");
}

bool updater_allowed(void)
{
    return allowed;
}

const char *updater_code(void)
{
    return code;
}

const char *updater_status(void)
{
    return status;
}

#else   // no network

bool updater_available(void) { return false; }
void updater_allow(bool allow) { (void)allow; }
bool updater_allowed(void) { return false; }
const char *updater_code(void) { return ""; }
const char *updater_status(void) { return ""; }

#endif

static void confirm_cb(lv_timer_t *t)
{
    rcat_hal_update_confirm();
}

void updater_init(void)
{
    lv_timer_t *confirm = lv_timer_create(confirm_cb, CONFIRM_MS, NULL);
    lv_timer_set_repeat_count(confirm, 1);
#if RCAT_HAVE_NETWORK
    lv_timer_create(poll_cb, POLL_MS, NULL);
#endif
}
