#include "app/battery.h"

#include <stddef.h>

#include "app/settings.h"
#include "hal.h"

// How much of each new reading goes into the smoothed voltage. At one reading
// a second, it follows a change over about 10 seconds.
#define SMOOTHING 0.1f

// The most it shows while the charger's still going.
#define CHARGING_MAX_PERCENT 99

// A typical LiPo cell, at a light load, highest first, for boards that haven't
// had theirs measured. Between the points, it's a straight line.
static const rcat_battery_point_t typical_curve[] = {
    { 4.20f, 100 }, { 4.15f, 95 }, { 4.11f, 90 }, { 4.08f, 85 }, { 4.02f, 80 },
    { 3.98f, 75 },  { 3.95f, 70 }, { 3.91f, 65 }, { 3.87f, 60 }, { 3.85f, 55 },
    { 3.84f, 50 },  { 3.82f, 45 }, { 3.80f, 40 }, { 3.79f, 35 }, { 3.77f, 30 },
    { 3.75f, 25 },  { 3.73f, 20 }, { 3.71f, 15 }, { 3.69f, 10 }, { 3.61f, 5 },
    { 3.30f, 0 },
};

static float smoothed;
static bool have_reading;
static battery_status_t latest;

size_t battery_default_curve(const rcat_battery_point_t **curve)
{
    size_t points = rcat_hal_battery_curve(curve);
    if (points < 2)
    {
        *curve = typical_curve;
        points = sizeof(typical_curve) / sizeof(typical_curve[0]);
    }
    return points;
}

static size_t active_curve(const rcat_battery_point_t **curve)
{
    // The one the board learned, if it has (see app/battery_log.h)
    static rcat_battery_point_t learned[SETTINGS_CURVE_POINTS];
    const settings_t *s = settings_get();
    if (s->battery_curve_runs == 0)
    {
        return battery_default_curve(curve);
    }
    for (int k = 0; k < SETTINGS_CURVE_POINTS; k++)
    {
        learned[k].volts = s->battery_curve_mv[k] / 1000.0f;
        learned[k].percent = (uint8_t)(100 - k * 100 / (SETTINGS_CURVE_POINTS - 1));
    }
    *curve = learned;
    return SETTINGS_CURVE_POINTS;
}

uint8_t battery_percent_from_volts(float volts)
{
    const rcat_battery_point_t *curve;
    size_t points = active_curve(&curve);

    if (volts >= curve[0].volts)
    {
        return curve[0].percent;
    }
    for (size_t i = 1; i < points; i++)
    {
        if (volts >= curve[i].volts)
        {
            float t = (volts - curve[i].volts) / (curve[i - 1].volts - curve[i].volts);
            float percent = curve[i].percent + t * (curve[i - 1].percent - curve[i].percent);
            return (uint8_t)(percent + 0.5f);
        }
    }
    return curve[points - 1].percent;
}

bool battery_update(battery_status_t *status)
{
    float volts;
    if (!rcat_hal_battery_voltage(&volts))
    {
        return false;
    }

    if (!have_reading)
    {
        smoothed = volts;
        have_reading = true;
    }
    else
    {
        smoothed += SMOOTHING * (volts - smoothed);
    }
    status->volts = smoothed;

    status->percent = battery_percent_from_volts(smoothed);
    rcat_charger_t charger = rcat_hal_battery_charger();
    status->charging = charger == RCAT_CHARGER_CHARGING;
    status->charging_known = charger != RCAT_CHARGER_UNKNOWN;
    if (charger == RCAT_CHARGER_FULL)
    {
        status->percent = 100;
    }
    else if (status->charging && status->percent > CHARGING_MAX_PERCENT)
    {
        // Charging holds the voltage up, at the top for the last part of the
        // charge, so only the charger can say when it's full.
        status->percent = CHARGING_MAX_PERCENT;
    }
    latest = *status;
    return true;
}

bool battery_latest(battery_status_t *status)
{
    *status = latest;
    return have_reading;
}
