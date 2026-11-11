#include "app/battery_log.h"

#include <string.h>

#include "hal.h"
#include "lvgl.h"

// The layout is read by tools/battery_log.py, so change both together.
#define LOG_MAGIC       0x474F4C42u     // "BLOG"
#define LOG_VERSION     1
#define SAMPLE_MS       1000            // readings, averaged into each entry
#define FIRST_INTERVAL  60              // seconds between entries

#define FLAG_CHARGING   0x01
#define FLAG_GAUGE      0x02            // gauge holds the fuel gauge's percent

typedef struct
{
    uint16_t millivolts;
    uint8_t gauge;
    uint8_t flags;
} entry_t;

typedef struct
{
    uint32_t magic;
    uint16_t version;
    uint16_t interval;      // seconds between entries
    uint16_t count;
    uint16_t reserved;
    uint32_t sequence;      // counts the writes
} header_t;

#define MAX_ENTRIES ((RCAT_HAL_LOG_SIZE - sizeof(header_t)) / sizeof(entry_t))

typedef struct
{
    header_t header;
    entry_t entries[MAX_ENTRIES];
} log_t;

static log_t log_data;
static lv_timer_t *timer;
static float volt_sum;
static uint32_t gauge_sum;
static uint32_t samples;
static uint32_t gauge_samples;
static bool charging;

bool battery_log_available(void)
{
    float volts;
    if (!rcat_hal_battery_voltage(&volts))
    {
        return false;
    }
    if (timer == NULL)
    {
        // Pick up the last log, to show how long it ran for
        bool ok = rcat_hal_log_read(&log_data, sizeof(log_data));
        if (!ok || log_data.header.magic != LOG_MAGIC || log_data.header.version != LOG_VERSION
            || log_data.header.count > MAX_ENTRIES)
        {
            memset(&log_data, 0, sizeof(log_data));
        }
        return ok;
    }
    return true;
}

bool battery_log_running(void)
{
    return timer != NULL;
}

uint32_t battery_log_seconds(void)
{
    return (uint32_t)log_data.header.count * log_data.header.interval;
}

// When the log's full, halve how often it records, so it keeps going: each
// pair of entries becomes one.
static void halve(void)
{
    uint16_t n = log_data.header.count / 2;
    for (uint16_t i = 0; i < n; i++)
    {
        const entry_t *a = &log_data.entries[2 * i];
        const entry_t *b = &log_data.entries[2 * i + 1];
        entry_t e = {
            .millivolts = (uint16_t)((a->millivolts + b->millivolts + 1) / 2),
            .gauge = (uint8_t)((a->gauge + b->gauge + 1) / 2),
            .flags = a->flags | b->flags,
        };
        log_data.entries[i] = e;
    }
    log_data.header.count = n;
    log_data.header.interval *= 2;
}

static void add_entry(void)
{
    if (log_data.header.count >= MAX_ENTRIES)
    {
        halve();
    }
    entry_t e = {
        .millivolts = (uint16_t)(volt_sum / samples * 1000.0f + 0.5f),
        .gauge = 0,
        .flags = charging ? FLAG_CHARGING : 0,
    };
    if (gauge_samples > 0)
    {
        e.gauge = (uint8_t)((gauge_sum + gauge_samples / 2) / gauge_samples);
        e.flags |= FLAG_GAUGE;
    }
    log_data.entries[log_data.header.count++] = e;
    log_data.header.sequence++;
    rcat_hal_log_write(&log_data, sizeof(log_data));
}

static void timer_cb(lv_timer_t *t)
{
    float volts;
    if (rcat_hal_battery_voltage(&volts))
    {
        volt_sum += volts;
        samples++;
    }
    uint8_t percent;
    bool now_charging;
    if (rcat_hal_battery_gauge(&percent, &now_charging))
    {
        gauge_sum += percent;
        gauge_samples++;
        charging |= now_charging;
    }

    if (samples > 0 && samples * SAMPLE_MS >= (uint32_t)log_data.header.interval * 1000)
    {
        add_entry();
        volt_sum = 0;
        gauge_sum = 0;
        samples = 0;
        gauge_samples = 0;
        charging = false;
    }
}

void battery_log_start(void)
{
    memset(&log_data, 0xFF, sizeof(log_data));
    log_data.header = (header_t){
        .magic = LOG_MAGIC,
        .version = LOG_VERSION,
        .interval = FIRST_INTERVAL,
        .count = 0,
        .reserved = 0,
        .sequence = 0,
    };
    volt_sum = 0;
    gauge_sum = 0;
    samples = 0;
    gauge_samples = 0;
    charging = false;
    rcat_hal_log_write(&log_data, sizeof(log_data));

    if (timer == NULL)
    {
        timer = lv_timer_create(timer_cb, SAMPLE_MS, NULL);
    }
}
