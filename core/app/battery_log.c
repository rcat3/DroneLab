#include "app/battery_log.h"

#include <string.h>

#include "app/battery.h"
#include "app/settings.h"
#include "hal.h"
#include "lvgl.h"

// The layout is read by tools/battery_log.py, so change both together.
#define LOG_MAGIC       0x474F4C42u     // "BLOG"
#define LOG_VERSION     2
#define SAMPLE_MS       1000            // readings, averaged into each entry
#define FIRST_INTERVAL  60              // seconds between entries
#define KEEP_LAST       10              // entries before the last run's log is overwritten

#define FLAG_CHARGING   0x01
#define FLAG_GAUGE      0x02            // gauge holds a fuel gauge's percent (no longer written)

// What makes a run complete, to learn from. Kept the same as the run that
// tools/battery_log.py finds.
#define FLAT_MV         5       // near empty, the reading sits within this of the lowest
#define MIN_FLAT        10      // for at least this many entries, as the supply drops out
#define FLAT_PERCENT    25      // and below the default curve's voltage here
#define RISE_MV         8       // a rise of more than this between entries is charging
#define MIN_DROP_MV     400     // from full to empty, at least
#define MIN_RUN_S       3600
#define FULL_PERCENT    90      // starting above the default curve's voltage here, less
#define FULL_MARGIN_MV  30      // this, counts as starting full
#define EMPTY_PERCENT   10      // without the flat end, it must get below this
#define BLEND_RUNS      3       // a new run counts as much as this share of the old: 1/(n+1)

typedef struct
{
    uint16_t millivolts;    // 0xFFFF where nothing's been written
    uint8_t gauge;          // 0: no board records a fuel gauge now
    uint8_t flags;
} entry_t;

typedef struct
{
    uint32_t magic;
    uint16_t version;
    uint16_t interval;      // seconds between entries
    uint16_t count;         // version 1 only; from version 2, counted from the entries
    uint16_t reserved;
    uint32_t session;       // a random number for each run
} header_t;

#define MAX_ENTRIES ((RCAT_HAL_LOG_SIZE - sizeof(header_t)) / sizeof(entry_t))

typedef struct
{
    header_t header;
    entry_t entries[MAX_ENTRIES];
} log_t;

static log_t log_data;
static uint16_t count;
static bool in_flash;           // this run's log has replaced the last one's
static bool available;
static lv_timer_t *timer;

static float volt_sum;
static uint32_t samples;
static bool charging;

static uint32_t last_seconds;
static battery_run_t last_run;

/* ----- Learning from the last run ----- */

static uint16_t default_mv(uint8_t percent)
{
    const rcat_battery_point_t *curve;
    size_t n = battery_default_curve(&curve);
    for (size_t i = 1; i < n; i++)
    {
        if (curve[i].percent <= percent)
        {
            float t = (float)(percent - curve[i].percent) / (curve[i - 1].percent - curve[i].percent);
            return (uint16_t)((curve[i].volts + t * (curve[i - 1].volts - curve[i].volts)) * 1000.0f + 0.5f);
        }
    }
    return (uint16_t)(curve[n - 1].volts * 1000.0f + 0.5f);
}

static battery_run_t learn(const entry_t *e, uint16_t n, uint16_t interval, uint32_t session)
{
    if (n < 2)
    {
        return n == 0 ? BATTERY_RUN_NONE : BATTERY_RUN_SHORT;
    }
    const settings_t *s = settings_get();
    if (s->battery_curve_runs > 0 && s->battery_curve_last_run == session)
    {
        return BATTERY_RUN_LEARNED;     // learned from it already, the last time it started
    }

    // The run ends at its lowest; anything after is charging again.
    uint16_t low = 0;
    for (uint16_t i = 1; i < n; i++)
    {
        if (e[i].millivolts < e[low].millivolts)
        {
            low = i;
        }
    }
    // Near empty, the board's supply drops out and the reading sits flat
    // until it stops. The curve ends where that starts.
    uint16_t flat = 0;
    while (flat < low && e[low - flat - 1].millivolts <= e[low].millivolts + FLAT_MV)
    {
        flat++;
    }
    bool ended_flat = flat + 1 >= MIN_FLAT && e[low].millivolts <= default_mv(FLAT_PERCENT);
    uint16_t end = ended_flat ? low - flat : low + 1;   // one past the run's last entry

    // It starts after the last time it was charging.
    uint16_t start = end - 1;
    while (start > 0 && !(e[start].flags & FLAG_CHARGING) && !(e[start - 1].flags & FLAG_CHARGING)
           && e[start].millivolts <= e[start - 1].millivolts + RISE_MV)
    {
        start--;
    }
    // ...and once it's on its way down, not while it's still sitting full on USB.
    while (start + 1 < end && e[start].millivolts <= e[start + 1].millivolts)
    {
        start++;
    }

    uint16_t len = end - start;
    if (len < 2 || (uint32_t)len * interval < MIN_RUN_S)
    {
        return BATTERY_RUN_SHORT;
    }
    if (e[start].millivolts + FULL_MARGIN_MV < default_mv(FULL_PERCENT))
    {
        return BATTERY_RUN_NOT_FULL;
    }
    if ((!ended_flat && e[low].millivolts > default_mv(EMPTY_PERCENT))
        || e[start].millivolts < e[end - 1].millivolts + MIN_DROP_MV)
    {
        return BATTERY_RUN_NOT_EMPTY;
    }

    // The board draws about the same all the time, so the share of the run
    // left is the share of the charge left. Entry i is the average over the
    // i-th interval, so its middle is (i + 0.5) / len of the way through.
    uint16_t mv[SETTINGS_CURVE_POINTS];
    for (int k = 0; k < SETTINGS_CURVE_POINTS; k++)
    {
        float t = (float)k / (SETTINGS_CURVE_POINTS - 1) * len - 0.5f;
        int i = t < 0 ? 0 : (int)t;
        if (i > len - 1)
        {
            i = len - 1;
        }
        int j = i + 1 < len ? i + 1 : len - 1;
        float f = t - i;
        f = f < 0 ? 0 : (f > 1 ? 1 : f);
        float v = e[start + i].millivolts + f * (e[start + j].millivolts - e[start + i].millivolts);
        mv[k] = (uint16_t)(v + 0.5f);
    }

    uint8_t runs = s->battery_curve_runs;
    if (runs > 0)
    {
        uint32_t w = runs < BLEND_RUNS ? runs : BLEND_RUNS;
        for (int k = 0; k < SETTINGS_CURVE_POINTS; k++)
        {
            mv[k] = (uint16_t)((s->battery_curve_mv[k] * w + mv[k] + w / 2) / (w + 1));
        }
    }
    // Highest first, each lower than the one before.
    for (int k = 1; k < SETTINGS_CURVE_POINTS; k++)
    {
        if (mv[k] >= mv[k - 1])
        {
            mv[k] = mv[k - 1] - 1;
        }
    }
    settings_set_battery_curve(mv, runs < 255 ? runs + 1 : 255, session);
    return BATTERY_RUN_LEARNED;
}

static void read_last(void)
{
    if (!rcat_hal_log_read(&log_data, sizeof(log_data)) || log_data.header.magic != LOG_MAGIC
        || log_data.header.interval == 0 || log_data.header.interval == 0xFFFF)
    {
        last_run = BATTERY_RUN_NONE;
        return;
    }
    uint16_t n = 0;
    if (log_data.header.version == 1 && log_data.header.count <= MAX_ENTRIES)
    {
        n = log_data.header.count;
    }
    else if (log_data.header.version == LOG_VERSION)
    {
        while (n < MAX_ENTRIES && log_data.entries[n].millivolts != 0xFFFF)
        {
            n++;
        }
    }
    else
    {
        last_run = BATTERY_RUN_NONE;
        return;
    }
    last_seconds = (uint32_t)n * log_data.header.interval;

    // Logs from the version 1 battery log, which was started by hand, have
    // no session to tell whether they've been learned from already.
    if (log_data.header.version == 1)
    {
        last_run = BATTERY_RUN_NONE;
        return;
    }
    last_run = learn(log_data.entries, n, log_data.header.interval, log_data.header.session);
}

/* ----- Recording this run ----- */

static size_t used_bytes(void)
{
    return sizeof(header_t) + (size_t)count * sizeof(entry_t);
}

// When the log's full, halve how often it records, so it keeps going: each
// pair of entries becomes one.
static void halve(void)
{
    uint16_t n = count / 2;
    for (uint16_t i = 0; i < n; i++)
    {
        const entry_t *a = &log_data.entries[2 * i];
        const entry_t *b = &log_data.entries[2 * i + 1];
        entry_t e = {
            .millivolts = (uint16_t)((a->millivolts + b->millivolts + 1) / 2),
            .gauge = 0,
            .flags = a->flags | b->flags,
        };
        log_data.entries[i] = e;
    }
    memset(&log_data.entries[n], 0xFF, (MAX_ENTRIES - n) * sizeof(entry_t));
    count = n;
    log_data.header.interval *= 2;
}

static void add_entry(void)
{
    bool rewrite = false;
    if (count >= MAX_ENTRIES)
    {
        halve();
        rewrite = true;
    }
    entry_t e = {
        .millivolts = (uint16_t)(volt_sum / samples * 1000.0f + 0.5f),
        .gauge = 0,
        .flags = charging ? FLAG_CHARGING : 0,
    };
    log_data.entries[count++] = e;

    if (!in_flash)
    {
        // Keep the last run's log a while, in case it's wanted.
        if (count >= KEEP_LAST)
        {
            in_flash = rcat_hal_log_write(&log_data, used_bytes());
        }
    }
    else if (rewrite)
    {
        rcat_hal_log_write(&log_data, used_bytes());
    }
    else
    {
        // Only write the new entry, so the block's erased once a run, not
        // once a minute.
        size_t offset = sizeof(header_t) + (size_t)(count - 1) * sizeof(entry_t);
        rcat_hal_log_program(offset, &log_data.entries[count - 1], sizeof(entry_t));
    }
}

static void timer_cb(lv_timer_t *t)
{
    float volts;
    if (rcat_hal_battery_voltage(&volts))
    {
        volt_sum += volts;
        samples++;
    }
    charging |= rcat_hal_battery_charger() == RCAT_CHARGER_CHARGING;

    if (samples > 0 && samples * SAMPLE_MS >= (uint32_t)log_data.header.interval * 1000)
    {
        add_entry();
        volt_sum = 0;
        samples = 0;
        charging = false;
    }
}

void battery_log_init(void)
{
    float volts;
    if (timer != NULL || !rcat_hal_battery_voltage(&volts))
    {
        return;
    }
    read_last();

    uint32_t session;
    do
    {
        session = rcat_hal_random();
    } while (session == 0 || session == 0xFFFFFFFFu);

    memset(&log_data, 0xFF, sizeof(log_data));
    log_data.header = (header_t){
        .magic = LOG_MAGIC,
        .version = LOG_VERSION,
        .interval = FIRST_INTERVAL,
        .count = 0xFFFF,
        .reserved = 0xFFFF,
        .session = session,
    };
    count = 0;
    in_flash = false;
    available = true;
    timer = lv_timer_create(timer_cb, SAMPLE_MS, NULL);
}

bool battery_log_available(void)
{
    return available;
}

uint32_t battery_log_seconds(void)
{
    return (uint32_t)count * log_data.header.interval;
}

uint32_t battery_log_last_seconds(void)
{
    return last_seconds;
}

battery_run_t battery_log_last_run(void)
{
    return last_run;
}
