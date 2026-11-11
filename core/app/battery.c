#include "app/battery.h"

#include <stddef.h>

#include "hal.h"

// How much of each new reading goes into the smoothed voltage. At one reading
// a second, it follows a change over about 10 seconds.
#define SMOOTHING 0.1f

// A single LiPo cell, at a light load: [volts, percent], highest first.
// Between the points, it's a straight line.
static const float curve[][2] = {
    { 4.20f, 100 }, { 4.15f, 95 }, { 4.11f, 90 }, { 4.08f, 85 }, { 4.02f, 80 },
    { 3.98f, 75 },  { 3.95f, 70 }, { 3.91f, 65 }, { 3.87f, 60 }, { 3.85f, 55 },
    { 3.84f, 50 },  { 3.82f, 45 }, { 3.80f, 40 }, { 3.79f, 35 }, { 3.77f, 30 },
    { 3.75f, 25 },  { 3.73f, 20 }, { 3.71f, 15 }, { 3.69f, 10 }, { 3.61f, 5 },
    { 3.30f, 0 },
};
#define CURVE_POINTS (sizeof(curve) / sizeof(curve[0]))

static float smoothed;
static bool have_reading;

uint8_t battery_percent_from_volts(float volts)
{
    if (volts >= curve[0][0])
    {
        return 100;
    }
    for (size_t i = 1; i < CURVE_POINTS; i++)
    {
        if (volts >= curve[i][0])
        {
            float t = (volts - curve[i][0]) / (curve[i - 1][0] - curve[i][0]);
            float percent = curve[i][1] + t * (curve[i - 1][1] - curve[i][1]);
            return (uint8_t)(percent + 0.5f);
        }
    }
    return 0;
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

    uint8_t percent;
    bool charging;
    if (rcat_hal_battery_gauge(&percent, &charging))
    {
        status->percent = percent > 100 ? 100 : percent;
        status->charging = charging;
        status->charging_known = true;
    }
    else
    {
        status->percent = battery_percent_from_volts(smoothed);
        status->charging = false;
        status->charging_known = false;
    }
    return true;
}
