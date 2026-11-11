# Settings

*All boards*

Settings that apply to the whole display, one per page.  Settings that belong to a single feature, like the [Voice Ring](kitt-and-voice-ring.md#voice-ring)'s color or the [Sound](sound.md) volume, are on that feature's own pages.

Settings are saved about two seconds after you change them, and are restored when the display is powered back on.  They also survive flashing new firmware.

## Brightness

How bright the screen is, and the battery's charge above it, in percent and volts.  On the ESP32-S3-Touch-AMOLED-1.75, which has no backlight, the screen dims itself.

The ESP32-S3-Touch-AMOLED-1.75's power chip has its own fuel gauge, which gives the percentage and shows a lightning bolt while it's charging.  The other boards work the percentage out from the voltage, along a LiPo's discharge curve, so it reads high while USB is plugged in and charging, and settles back once it's unplugged.  The voltage is smoothed over about 10 seconds, so the percentage doesn't jump around as the screen's brightness or the speaker changes how much the board draws.

## Rotation

Turns the whole display, touch included, in 90 degree steps.  It helps when the display ends up sitting at an angle in the mask, and some housings turn the board a quarter turn, which this puts right (each board's build guide says which).  The new rotation is applied about a second after you stop scrolling the roller.

## Startup

What's shown when the display turns on: any image (see [Images](images.md)), the blank page, [KITT](kitt-and-voice-ring.md), the [Level](level.md) or the [Terminal](terminal.md), depending on what the board has.

## Battery Log

Records the battery's voltage once a minute, for working out how the percentage on the Brightness page should follow the voltage on your board.  It keeps the log in flash, so it's still there after the battery runs flat.

1. Charge the battery until the charger stops.
2. Unplug USB, and tap **Start log**.
3. Leave the display running, as you'd use it, until it switches off.
4. Plug it back in and run `tools/battery_log.py` with the board's name (`rp2040`, `rp2350` or `esp32`, with `--port` for the ESP32 boards' serial port, from ESP-IDF's environment).  It writes the log to `battery_log.csv`, and prints the curve it shows as a table for `core/app/battery.c`.

The page shows how long the log's been running, and once the board's been off, how long the last one ran.  The button is hidden while it's running, as starting again throws the log away.  After the first 17 hours or so, it records every 2 minutes instead, and so on, so it never runs out of room.

## Phone Remote

*Boards with WiFi*

Runs the display from a phone, without touching it.  See [Phone Remote](phone-remote.md).

## Firmware Update

On the ESP32-S3 boards, lets new firmware be sent over the board's hotspot from a computer, with `tools/update.py`.  Switching it on shows a code for the script, and the hotspot's name and password.  See [Updating over WiFi](../building-firmware.md#updating-over-wifi).
