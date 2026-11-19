# Former Boards

DroneLab is built around the [Waveshare ESP32-S3-Touch-AMOLED-1.75](hardware/waveshare_esp32s3_touch_amoled_1_75.md), and its firmware runs on that board only.  It used to run on three other Waveshare round displays too: the RP2040-Touch-LCD-1.28, the RP2350-Touch-LCD-1.28 and the ESP32-S3-Touch-LCD-1.46.  Their firmware was dropped after release 0.9.7, so it's no longer built, tested or kept up to date.

Their gas mask housings are kept, with their build guides, in [`hardware/deprecated`](../hardware/deprecated/): the [1.28" housing](../hardware/deprecated/waveshare_touch_lcd_1_28/), the [1.46" housing](../hardware/deprecated/waveshare_esp32s3_touch_lcd_1_46/) and the [1.46" speaker housing](../hardware/deprecated/waveshare_esp32s3_touch_lcd_1_46_speaker_housing/).

## Getting their firmware back

Their code is still in the project's history.  Check out one of the commits below and build it as that commit's own [Installing the Firmware](building-firmware.md) says.  The board notes and the features each one had are in that commit's `docs/other-boards.md`.

| | RP2040-Touch-LCD-1.28 | RP2350-Touch-LCD-1.28 | ESP32-S3-Touch-LCD-1.46 |
|---|---|---|---|
| **Last actively developed** | [`951a636`](https://github.com/rcat3/DroneLab/tree/951a636), 2026-11-11: battery curves learned from the board's own runs | [`951a636`](https://github.com/rcat3/DroneLab/tree/951a636), 2026-11-11 | [`b40f542`](https://github.com/rcat3/DroneLab/tree/b40f542), 2026-11-13: the speaker housing dropped, voice effects off |
| **Last run on the board** | [`951a636`](https://github.com/rcat3/DroneLab/tree/951a636), 2026-11-11 | [`951a636`](https://github.com/rcat3/DroneLab/tree/951a636), 2026-11-11 | [`713892e`](https://github.com/rcat3/DroneLab/tree/713892e), 2026-11-15: direct comms and commands with a 1.75" |
| **Last built** (compiled, not run) | [`2a2e8e5`](https://github.com/rcat3/DroneLab/tree/2a2e8e5), 2026-11-19 | [`a06d99c`](https://github.com/rcat3/DroneLab/tree/a06d99c), 2026-11-17 | [`c0b2cb1`](https://github.com/rcat3/DroneLab/tree/c0b2cb1), 2026-11-18 |
| **Housing retired** | [`d614135`](https://github.com/rcat3/DroneLab/tree/d614135), 2026-11-14 | [`d614135`](https://github.com/rcat3/DroneLab/tree/d614135), 2026-11-14 | [`d614135`](https://github.com/rcat3/DroneLab/tree/d614135), 2026-11-14 |
| **Last with its code** | [`v0.9.7`](https://github.com/rcat3/DroneLab/tree/v0.9.7) | [`v0.9.7`](https://github.com/rcat3/DroneLab/tree/v0.9.7) | [`v0.9.7`](https://github.com/rcat3/DroneLab/tree/v0.9.7) |

Commits after *last run on the board* weren't tried on it, and those after *last built* weren't even compiled for it.  To use one of these boards, start from the *last run on the board* commit: it's the newest one known to work.

### The 1.46" speaker housing

The speaker housing has two external amplifiers on the board's J9 header, and its board's USB-C port can't be reached, so it was updated over WiFi.

- **Last with its amplifiers:** [`f45ee43`](https://github.com/rcat3/DroneLab/tree/f45ee43), 2026-11-13, built with `set(RCAT_SPEAKER EXTERNAL)` (see [the housing's README](../hardware/deprecated/waveshare_esp32s3_touch_lcd_1_46_speaker_housing/README.md#firmware)).  The next commit, [`b40f542`](https://github.com/rcat3/DroneLab/tree/b40f542), dropped the housing, and with it the amplifiers' code and voice effects on the 1.46".
- **Updates over WiFi:** added in [`77b9390`](https://github.com/rcat3/DroneLab/tree/77b9390) (2026-11-10, tested on the board that day), and last in [`e3fb8d9`](https://github.com/rcat3/DroneLab/tree/e3fb8d9), the last release with them being [0.9.6](https://github.com/rcat3/DroneLab/releases/tag/v0.9.6).  [`38eadfb`](https://github.com/rcat3/DroneLab/tree/38eadfb) (2026-11-18) replaced them with updates from the app over Bluetooth.

So the newest firmware for the housing as built, with its amplifiers and updates over WiFi, is [`f45ee43`](https://github.com/rcat3/DroneLab/tree/f45ee43).  A board already running firmware from `77b9390` on takes it over WiFi; an older one has to come out of the housing to be flashed over USB.
