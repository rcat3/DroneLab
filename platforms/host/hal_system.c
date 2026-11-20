/*
 * The rest of the virtual unit's HAL: time, tasks, its identity, the network,
 * and what a computer doesn't have (battery, accelerometer, firmware updates)
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <time.h>
#include <unistd.h>

#include "hal.h"
#include "host.h"

/*
 * Time and tasks
 */

uint32_t rcat_hal_millis(void)
{
    static struct timespec start;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (start.tv_sec == 0 && start.tv_nsec == 0)
    {
        start = now;
    }
    int64_t ms = (int64_t)(now.tv_sec - start.tv_sec) * 1000 + (now.tv_nsec - start.tv_nsec) / 1000000;
    return (uint32_t)ms;
}

void rcat_hal_delay_ms(uint32_t ms)
{
    struct timespec t = { .tv_sec = ms / 1000, .tv_nsec = (long)(ms % 1000) * 1000000L };
    while (nanosleep(&t, &t) != 0 && errno == EINTR)
    {
    }
}

typedef struct
{
    void (*fn)(void *arg);
    void *arg;
} task_t;

static void *task_main(void *p)
{
    task_t task = *(task_t *)p;
    free(p);
    task.fn(task.arg);
    return NULL;
}

bool rcat_hal_task_start(const char *name, void (*fn)(void *arg), void *arg, size_t stack_size)
{
    task_t *task = malloc(sizeof(task_t));
    if (task == NULL)
    {
        return false;
    }
    task->fn = fn;
    task->arg = arg;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    // A computer's stacks are cheap: give it plenty more than the board's
    size_t stack = stack_size * 4 < 256 * 1024 ? 256 * 1024 : stack_size * 4;
    pthread_attr_setstacksize(&attr, stack);
    pthread_t thread;
    int err = pthread_create(&thread, &attr, task_main, task);
    pthread_attr_destroy(&attr);
    if (err != 0)
    {
        fprintf(stderr, "Couldn't start task %s\n", name);
        free(task);
        return false;
    }
    char short_name[16];
    snprintf(short_name, sizeof(short_name), "%s", name);
    pthread_setname_np(thread, short_name);
    return true;
}

uint32_t rcat_hal_random(void)
{
    uint32_t r;
    if (getrandom(&r, sizeof(r), 0) != sizeof(r))
    {
        r = (uint32_t)rand() ^ ((uint32_t)rand() << 16);
    }
    return r;
}

/*
 * What it is
 */

const char *rcat_hal_firmware_version(void)
{
    return RCAT_GIT_VERSION;
}

const char *rcat_hal_firmware_built(void)
{
    return __DATE__ " " __TIME__;
}

/* A MAC address of its own, made up the first time and kept in its folder,
 * marked as locally administered, as no factory set it. */
bool rcat_hal_mac_address(uint8_t mac[6])
{
    static uint8_t own[6];
    static bool known;
    if (!known)
    {
        char path[512];
        host_data_path(path, sizeof(path), "mac");
        FILE *f = fopen(path, "rb");
        bool ok = f != NULL && fread(own, 1, 6, f) == 6;
        if (f != NULL)
        {
            fclose(f);
        }
        if (!ok)
        {
            for (int i = 0; i < 6; i++)
            {
                own[i] = (uint8_t)rcat_hal_random();
            }
            own[0] = (own[0] & 0xFC) | 0x02;    // unicast, locally administered
            f = fopen(path, "wb");
            if (f != NULL)
            {
                fwrite(own, 1, 6, f);
                fclose(f);
            }
        }
        known = true;
    }
    memcpy(mac, own, 6);
    return true;
}

bool rcat_hal_bt_mac_address(uint8_t mac[6])
{
    // As on the ESP32, the Bluetooth address is the WiFi one plus 2
    rcat_hal_mac_address(mac);
    mac[5] += 2;
    return true;
}

/*
 * Restarting, and firmware updates, which it can't do: it's updated with the app.
 */

void rcat_hal_restart(void)
{
    printf("Restarting\n");
    host_peer_close();
    execv("/proc/self/exe", host_options.argv);
    fprintf(stderr, "Couldn't restart: %s\n", strerror(errno));
    exit(1);
}

bool rcat_hal_update_supported(void)
{
    return false;
}

bool rcat_hal_update_begin(void)
{
    return false;
}

bool rcat_hal_update_write(const void *data, size_t len)
{
    return false;
}

bool rcat_hal_update_finish(void)
{
    return false;
}

void rcat_hal_update_abort(void)
{
}

void rcat_hal_update_confirm(void)
{
}

/*
 * Buttons: keys in the window (hal_display.c)
 */

static atomic_bool button_press;
static atomic_bool screenshot_press;

void host_button_press(void)
{
    button_press = true;
}

void host_screenshot_press(void)
{
    screenshot_press = true;
}

bool rcat_hal_button_pressed(void)
{
    return atomic_exchange(&button_press, false);
}

bool rcat_hal_screenshot_pressed(void)
{
    return atomic_exchange(&screenshot_press, false);
}

/* The development console, typed in on the terminal */
size_t rcat_hal_console_read(char *buf, size_t cap)
{
    static bool ready;
    if (!ready)
    {
        int flags = fcntl(STDIN_FILENO, F_GETFL);
        fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK);
        ready = true;
    }
    ssize_t n = read(STDIN_FILENO, buf, cap);
    return n > 0 ? (size_t)n : 0;
}

/*
 * The network: the computer's own, already joined
 */

bool rcat_hal_wifi_connect(const char *ssid, const char *password)
{
    return true;
}

void rcat_hal_wifi_disconnect(void)
{
}

bool rcat_hal_wifi_address(char *ip, size_t len)
{
    struct ifaddrs *list;
    if (getifaddrs(&list) != 0)
    {
        return false;
    }
    bool found = false;
    for (struct ifaddrs *a = list; a != NULL && !found; a = a->ifa_next)
    {
        if (a->ifa_addr != NULL && a->ifa_addr->sa_family == AF_INET && (a->ifa_flags & IFF_UP) &&
            !(a->ifa_flags & IFF_LOOPBACK))
        {
            const struct sockaddr_in *in = (const struct sockaddr_in *)a->ifa_addr;
            found = inet_ntop(AF_INET, &in->sin_addr, ip, (socklen_t)len) != NULL;
        }
    }
    freeifaddrs(list);
    return found;
}

bool rcat_hal_hotspot_start(const char *ssid, const char *password)
{
    return false;
}

void rcat_hal_hotspot_stop(void)
{
}

int rcat_hal_hotspot_clients(void)
{
    return 0;
}

/*
 * What a computer doesn't have
 */

bool rcat_hal_battery_voltage(float *volts)
{
    return false;
}

rcat_charger_t rcat_hal_battery_charger(void)
{
    return RCAT_CHARGER_UNKNOWN;
}

size_t rcat_hal_battery_curve(const rcat_battery_point_t **points)
{
    return 0;
}

bool rcat_hal_accel_read(float *x, float *y, float *z)
{
    return false;
}

bool rcat_hal_audio_levels(rcat_hal_audio_levels_t *levels)
{
    return false;
}
