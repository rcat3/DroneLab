# Updating over WiFi

*The ESP32-S3 boards.  Not recommended: flash over USB instead, as in [Building the Firmware](building-firmware.md#updating).*

Every supported housing leaves the board's USB-C port reachable, so new firmware is best flashed over USB.  Updates over WiFi were made for the [1.46" speaker housing](../hardware/deprecated/waveshare_esp32s3_touch_lcd_1_46_speaker_housing/), whose USB port couldn't be reached, and are kept for boards in housings like that.  Over WiFi, a board doesn't get a new flash layout (partition table): the [core dump](development/README.md#crashes-and-hangs) partition, for one, is only made by flashing over USB.

## Sending an update

Once a board has firmware with updates over WiFi in it (flashed over USB once, as in [Building the Firmware](building-firmware.md#flashing)), later firmware can go over its hotspot, with the board still in its housing:

1. On the board, go to Settings, **Firmware Update**, and switch it on.  It shows a six digit code, and the name and password of the board's hotspot, which it starts if it isn't on already.
2. Join the hotspot from your computer.
3. From the top of the repo, run `tools/update.py build-s3-175/dronelab.bin <code>` (or `build-s3-146` for the 1.46" board).

The script checks the firmware is for that board and that its battery is at 20% or more, then sends it.  The board writes it beside the firmware it's running, checks it, and restarts into it.  If the new firmware doesn't start properly and run for 15 seconds, the board goes back to the old one the next time it's restarted, so switch it off and on again.

It has nothing to do with the [phone remote](features/phone-remote.md)'s page, which can't update the board.  The updates run on a separate port, only while they're switched on on the board itself, and need the code from its screen, which is new each time.  They switch off again after 10 minutes, after 3 wrong codes, and when the board restarts.

The first flash with this in it has to be over USB, as it changes how the flash is laid out (into two places for firmware, so a new one can be written while the old one runs).  The settings are kept.  After that, it won't need USB again unless the update over WiFi itself goes wrong.
