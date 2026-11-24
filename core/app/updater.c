/*
 * Firmware updates from the app (see updater.h).
 *
 * The Bluetooth controller runs from flash on the 1.75" board, to leave
 * internal RAM for WiFi and Bluetooth together (see its sdkconfig.defaults),
 * so it stops while flash is written. A settings save is over before a
 * connection notices; writing a whole update as it streams in isn't, and
 * drops the link, or upsets the controller. So the update's kept in PSRAM as
 * it comes, and only written to flash once it's all here and the app's been
 * told, a slice at a time from the UI loop. (Not from a task of its own:
 * writing flash needs the stack in internal RAM, and the board's tasks have
 * theirs in PSRAM.) If there isn't room for it, it's written as it comes
 * after all, and the link has to ride it out.
 */
#include "app/updater.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "app/battery.h"
#include "app/direct.h"
#include "app/toys.h"
#include "app/remote.h"
#include "audio/audio_player.h"
#include "audio/voice_fx.h"
#include "hal.h"
#include "lvgl.h"

#define CONFIRM_MS          15000   // running this long shows the firmware works
#define MAX_FIRMWARE        (7 * 1024 * 1024)   // the app partitions' size
#define RESTART_DELAY_MS    1500    // so the app gets its answer first
#define INSTALL_SLICE       (32 * 1024)     // written each poll: a moment's pause for the screen
#define POLL_MS             20
#define RATE_WINDOW_MS      2000    // the rate shown is over about this long


static void confirm_cb(lv_timer_t *t)
{
    rcat_hal_update_confirm();
}

#if RCAT_HAVE_COMM

// The board's name, after a marker the board looks for in the firmware it's
// sent, and tools/release/bundle_firmware.sh in a build, to check it's for
// this board.
static const char board_marker[] = "rcat-board:" RCAT_BOARD_NAME;
#define BOARD_NAME (board_marker + sizeof("rcat-board:") - 1)


static bool updating;               // taking it in from the app
static uint8_t *buffer;             // what's come, in PSRAM; NULL if it's written as it comes
static size_t expected, received;
static size_t marker_at;            // how much of board_marker's been seen in a row
static bool marker_seen;
static bool installing;             // writing the buffer to flash
static size_t installed;            // how much of it so far
static bool result_ready;           // the install's outcome, for the app
static update_result_t result;
static bool restarting;
static char new_version[32];
static uint32_t rate_ms;            // the rate's window: when it started,
static size_t rate_from;            // how much had come then,
static uint32_t rate;               // and the rate over the last one

static void set_status(const char *text)
{
    printf("update: %s\n", text);
}

static void restart_cb(lv_timer_t *t)
{
    rcat_hal_restart();
}

static void restart_soon(void)
{
    restarting = true;
    set_status("Installed, restarting");
    lv_timer_t *restart = lv_timer_create(restart_cb, RESTART_DELAY_MS, NULL);
    lv_timer_set_repeat_count(restart, 1);
}

static void release_buffer(void)
{
    if (buffer != NULL)
    {
        lv_free(buffer);
        buffer = NULL;
    }
}

/* The unit's out of service while an update comes in and installs: the
 * radio to Bluetooth alone (direct comms paused, and the WiFi remote, if
 * it's on, and the search for toys stopped), and the voice effects and
 * sounds stopped, so nothing slows it. The screen's paused too
 * (update_screen.c). If the update stops, what was going goes again; if it
 * works, the unit restarts. */
static bool quieted, remote_was_on, player_was_on;

static void quiet(bool on)
{
    if (on == quieted)
    {
        return;
    }
    quieted = on;
    // Bluetooth shares the radio with direct comms' ESP-NOW, and an
    // update's steady stream alongside broadcasts can drop the link
    direct_pause(on);
    voice_fx_pause(on);
    if (on)
    {
        remote_was_on = remote_running();
        if (remote_was_on)
        {
            remote_stop();
        }
        player_was_on = audio_player_is_playing();
        if (player_was_on)
        {
            audio_player_pause();
        }
        audio_player_chime_stop();
        toys_stop_all();
        toys_scan_stop();
    }
    else
    {
        if (remote_was_on)
        {
            remote_start();
        }
        if (player_was_on)
        {
            audio_player_resume();
        }
    }
}

static void install_failed(void)
{
    installing = false;
    rcat_hal_update_abort();
    release_buffer();
    quiet(false);
    set_status("The update was damaged");
    result = UPDATE_DAMAGED;
    result_ready = true;
}

/* Write the next slice of the buffer to flash, then check it and restart
 * into it. From the UI loop. */
static void poll_cb(lv_timer_t *t)
{
    if (!installing)
    {
        return;
    }
    if (installed == 0 && !rcat_hal_update_begin())
    {
        install_failed();
        return;
    }
    size_t n = expected - installed < INSTALL_SLICE ? expected - installed : INSTALL_SLICE;
    if (!rcat_hal_update_write(buffer + installed, n))
    {
        install_failed();
        return;
    }
    installed += n;
    if (installed < expected)
    {
        return;
    }
    installing = false;
    if (!rcat_hal_update_finish())
    {
        install_failed();
        return;
    }
    release_buffer();
    restart_soon();
}

static lv_timer_t *confirm_timer, *poll_timer;

void updater_init(void)
{
    confirm_timer = lv_timer_create(confirm_cb, CONFIRM_MS, NULL);
    lv_timer_set_repeat_count(confirm_timer, 1);
    poll_timer = lv_timer_create(poll_cb, POLL_MS, NULL);
}

bool updater_owns_timer(const lv_timer_t *t)
{
    return t != NULL && (t == confirm_timer || t == poll_timer);
}

bool updater_app_available(void)
{
    return rcat_hal_update_supported();
}

update_result_t updater_app_begin(size_t length, const char *board, const char *version)
{
    if (installing)
    {
        return UPDATE_CANT_START;   // one's being installed
    }
    updater_app_cancel();
    if (strcmp(board, BOARD_NAME) != 0)
    {
        set_status("That firmware's for another board");
        return UPDATE_WRONG_BOARD;
    }
    if (length == 0 || length > MAX_FIRMWARE)
    {
        return UPDATE_TOO_BIG;
    }
    float volts;
    if (rcat_hal_battery_voltage(&volts) && battery_percent_from_volts(volts) < UPDATER_MIN_BATTERY_PERCENT)
    {
        set_status("Battery too low to update");
        return UPDATE_LOW_BATTERY;
    }
    if (!rcat_hal_update_supported())
    {
        set_status("Couldn't start the update");
        return UPDATE_CANT_START;
    }
    // In PSRAM if there's room, to write once it's all here; else as it comes
    buffer = lv_malloc(length);
    if (buffer == NULL && !rcat_hal_update_begin())
    {
        set_status("Couldn't start the update");
        return UPDATE_CANT_START;
    }
    printf("update: from the app, %u bytes, %s\n", (unsigned)length,
           buffer != NULL ? "kept until it's all here" : "written as it comes");
    // The radio to itself: Bluetooth shares it with direct comms' ESP-NOW,
    // and an update's steady stream alongside broadcasts can drop the link
    quiet(true);
    rcat_hal_ble_peer_fast(true);
    updating = true;
    expected = length;
    received = 0;
    snprintf(new_version, sizeof(new_version), "%s", version);
    rate_ms = rcat_hal_millis();
    rate_from = 0;
    rate = 0;
    marker_at = 0;
    marker_seen = false;
    result_ready = false;
    set_status("Updating from the app");
    return UPDATE_OK;
}

/* Look for this board's marker in what's come, across pieces. */
static void find_marker(const uint8_t *data, size_t len)
{
    const size_t marker_len = sizeof(board_marker) - 1;
    for (size_t i = 0; i < len && !marker_seen; i++)
    {
        if (data[i] == (uint8_t)board_marker[marker_at])
        {
            marker_seen = ++marker_at == marker_len;
        }
        else
        {
            marker_at = data[i] == (uint8_t)board_marker[0] ? 1 : 0;
        }
    }
}

update_result_t updater_app_write(size_t offset, const void *data, size_t len)
{
    if (!updating)
    {
        return UPDATE_NOT_STARTED;
    }
    if (offset != received)
    {
        return UPDATE_OK;   // one went missing: the app starts again from received
    }
    if (len > expected - received)
    {
        len = expected - received;
    }
    if (buffer != NULL)
    {
        memcpy(buffer + received, data, len);
    }
    else if (!rcat_hal_update_write(data, len))
    {
        updater_app_cancel();
        set_status("Couldn't write the update");
        return UPDATE_WRITE_FAILED;
    }
    find_marker(data, len);
    received += len;
    uint32_t now = rcat_hal_millis();
    if (now - rate_ms >= RATE_WINDOW_MS)
    {
        rate = (uint32_t)((uint64_t)(received - rate_from) * 1000 / (now - rate_ms));
        rate_ms = now;
        rate_from = received;
    }
    return UPDATE_OK;
}

size_t updater_app_received(void)
{
    return received;
}

update_result_t updater_app_finish(void)
{
    if (!updating)
    {
        return UPDATE_NOT_STARTED;
    }
    if (received != expected)
    {
        updater_app_cancel();
        return UPDATE_INCOMPLETE;
    }
    if (!marker_seen)
    {
        updater_app_cancel();
        set_status("That firmware's for another board");
        return UPDATE_WRONG_BOARD;
    }
    updating = false;
    rcat_hal_ble_peer_fast(false);
    if (buffer != NULL)
    {
        set_status("Installing the update");
        installed = 0;
        installing = true;      // poll_cb takes it from here, after the app's answered
        return UPDATE_OK;
    }
    if (!rcat_hal_update_finish())
    {
        quiet(false);
        set_status("The update was damaged");
        return UPDATE_DAMAGED;
    }
    restart_soon();
    return UPDATE_OK;
}

bool updater_app_installing(void)
{
    return installing;
}

void updater_progress(update_progress_t *out)
{
    out->show = restarting   ? UPDATE_SHOW_RESTARTING
                : installing ? UPDATE_SHOW_INSTALLING
                : updating   ? UPDATE_SHOW_RECEIVING
                             : UPDATE_SHOW_NONE;
    out->done = installing ? installed : restarting ? expected : received;
    out->total = expected;
    // Nothing coming for a while counts as nothing coming
    out->bytes_per_s = updating && rcat_hal_millis() - rate_ms < 2 * RATE_WINDOW_MS ? rate : 0;
    out->from = rcat_hal_firmware_version();
    out->to = new_version;
}

bool updater_app_outcome(update_result_t *out)
{
    if (!result_ready)
    {
        return false;
    }
    result_ready = false;
    *out = result;
    return true;
}

void updater_app_cancel(void)
{
    if (updating)
    {
        updating = false;
        rcat_hal_ble_peer_fast(false);
        if (buffer != NULL)
        {
            release_buffer();
        }
        else
        {
            rcat_hal_update_abort();
        }
        quiet(false);
        set_status("The update stopped part way");
    }
}

#else   // no comm channel, so no app to update from

void updater_init(void)
{
    lv_timer_t *confirm = lv_timer_create(confirm_cb, CONFIRM_MS, NULL);
    lv_timer_set_repeat_count(confirm, 1);
}

bool updater_owns_timer(const lv_timer_t *t)
{
    (void)t;
    return false;
}

bool updater_app_available(void) { return false; }
update_result_t updater_app_begin(size_t length, const char *board, const char *version) { (void)length; (void)board; (void)version; return UPDATE_CANT_START; }
update_result_t updater_app_write(size_t offset, const void *data, size_t len) { (void)offset; (void)data; (void)len; return UPDATE_NOT_STARTED; }
size_t updater_app_received(void) { return 0; }
update_result_t updater_app_finish(void) { return UPDATE_NOT_STARTED; }
bool updater_app_installing(void) { return false; }
bool updater_app_outcome(update_result_t *out) { (void)out; return false; }
void updater_app_cancel(void) {}

void updater_progress(update_progress_t *out)
{
    memset(out, 0, sizeof(*out));
    out->from = out->to = "";
}

#endif
