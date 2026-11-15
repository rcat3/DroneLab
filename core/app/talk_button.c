/*
 * The comm channel's talk button (see talk_button.h): pairing, and keeping
 * the paired one in use while the comm channel's on. The Bluetooth side is
 * the board's (rcat_hal_ble_button_* in hal.h).
 */
#include <stdio.h>
#include <string.h>

#include "app/settings.h"
#include "app/talk_button.h"
#include "hal.h"

// Look this long before picking the nearest, so it isn't just the first heard
#define FIND_SETTLE_MS      1500
#define FIND_TIMEOUT_MS     30000
#define PAIR_TIMEOUT_MS     20000
#define MAX_FOUND           8

typedef enum
{
    PAIR_IDLE,
    PAIR_FINDING,
    PAIR_PAIRING,
    PAIR_NOT_FOUND,
    PAIR_FAILED,
} pair_step_t;

static bool in_use;             // the comm channel's on
static pair_step_t step;
static uint32_t step_ms;        // when the step began, 0 until the first poll
static rcat_hal_ble_device_t pairing;
static char name[SETTINGS_BUTTON_NAME_LEN];

static bool saved(rcat_hal_ble_device_t *out)
{
    const settings_t *s = settings_get();
    if (!s->button_paired)
    {
        return false;
    }
    memset(out, 0, sizeof(*out));
    memcpy(out->addr, s->button_addr, 6);
    out->addr_type = s->button_addr_type;
    snprintf(out->name, sizeof(out->name), "%s", s->button_name);
    return true;
}

void talk_button_start(void)
{
    in_use = true;
    rcat_hal_ble_device_t d;
    if (step == PAIR_IDLE && saved(&d))
    {
        rcat_hal_ble_button_use(&d, false);
    }
}

void talk_button_stop(void)
{
    in_use = false;
    if (step == PAIR_IDLE)
    {
        rcat_hal_ble_button_stop();
    }
}

bool talk_button_pair(void)
{
    if (!rcat_hal_ble_button_find())
    {
        return false;
    }
    rcat_hal_ble_button_stop();
    step = PAIR_FINDING;
    step_ms = 0;
    return true;
}

static void finish_pairing(void)
{
    rcat_hal_ble_button_find_stop();
    step = PAIR_IDLE;
    // Back to the paired one, if any, if the comm channel's on
    rcat_hal_ble_device_t d;
    if (in_use && saved(&d))
    {
        rcat_hal_ble_button_use(&d, false);
    }
    else
    {
        rcat_hal_ble_button_stop();
    }
}

void talk_button_cancel(void)
{
    if (step != PAIR_IDLE)
    {
        finish_pairing();
    }
}

void talk_button_forget(void)
{
    talk_button_cancel();
    rcat_hal_ble_device_t d;
    if (saved(&d))
    {
        rcat_hal_ble_button_forget(&d);
    }
    settings_set_button(NULL, 0, NULL);
}

void talk_button_poll(uint32_t now_ms)
{
    if (step == PAIR_IDLE || step == PAIR_NOT_FOUND || step == PAIR_FAILED)
    {
        return;
    }
    if (step_ms == 0)
    {
        step_ms = now_ms ? now_ms : 1;
    }
    uint32_t elapsed = now_ms - step_ms;

    if (step == PAIR_FINDING)
    {
        rcat_hal_ble_device_t found[MAX_FOUND];
        size_t n = elapsed >= FIND_SETTLE_MS ? rcat_hal_ble_button_found(found, MAX_FOUND) : 0;
        if (n > 0)
        {
            size_t best = 0;
            for (size_t i = 1; i < n; i++)
            {
                if (found[i].rssi > found[best].rssi)
                {
                    best = i;
                }
            }
            pairing = found[best];
            // Names can be longer than the settings keep
            memcpy(name, pairing.name, sizeof(name) - 1);
            name[sizeof(name) - 1] = '\0';
            rcat_hal_ble_button_find_stop();
            // A new button replaces the old one, whose pairing goes.
            rcat_hal_ble_device_t old;
            if (saved(&old) && (old.addr_type != pairing.addr_type || memcmp(old.addr, pairing.addr, 6) != 0))
            {
                rcat_hal_ble_button_forget(&old);
                settings_set_button(NULL, 0, NULL);
            }
            rcat_hal_ble_button_use(&pairing, true);
            step = PAIR_PAIRING;
            step_ms = now_ms;
        }
        else if (elapsed >= FIND_TIMEOUT_MS)
        {
            rcat_hal_ble_button_find_stop();
            step = PAIR_NOT_FOUND;
        }
        return;
    }

    // Pairing
    if (rcat_hal_ble_button_state() == RCAT_HAL_BLE_BUTTON_CONNECTED)
    {
        printf("talk button: paired with %s\n", name);
        settings_set_button(pairing.addr, pairing.addr_type, name);
        step = PAIR_IDLE;
        if (!in_use)
        {
            rcat_hal_ble_button_stop();
        }
    }
    else if (elapsed >= PAIR_TIMEOUT_MS)
    {
        rcat_hal_ble_button_forget(&pairing);
        step = PAIR_FAILED;
        rcat_hal_ble_device_t d;
        if (in_use && saved(&d))
        {
            rcat_hal_ble_button_use(&d, false);
        }
    }
}

talk_button_state_t talk_button_state(void)
{
    switch (step)
    {
    case PAIR_FINDING:
        return TALK_BUTTON_FINDING;
    case PAIR_PAIRING:
        return TALK_BUTTON_PAIRING;
    case PAIR_NOT_FOUND:
        return TALK_BUTTON_NOT_FOUND;
    case PAIR_FAILED:
        return TALK_BUTTON_FAILED;
    default:
        break;
    }
    if (!settings_get()->button_paired)
    {
        return TALK_BUTTON_NONE;
    }
    switch (rcat_hal_ble_button_state())
    {
    case RCAT_HAL_BLE_BUTTON_WAITING:
        return TALK_BUTTON_WAITING;
    case RCAT_HAL_BLE_BUTTON_CONNECTING:
        return TALK_BUTTON_CONNECTING;
    case RCAT_HAL_BLE_BUTTON_CONNECTED:
        return TALK_BUTTON_CONNECTED;
    default:
        return TALK_BUTTON_OFF;
    }
}

const char *talk_button_name(void)
{
    if (step == PAIR_IDLE)
    {
        snprintf(name, sizeof(name), "%s", settings_get()->button_name);
    }
    return name;
}

bool talk_button_paired(rcat_hal_ble_device_t *out)
{
    return saved(out);
}

bool talk_button_held(void)
{
    return rcat_hal_ble_button_held() != 0;
}
