# Building the Firmware

The firmware is built with Espressif's [ESP-IDF](https://docs.espressif.com/projects/esp-idf/en/v5.5.5/esp32s3/get-started/linux-macos-setup.html) for the [ESP32-S3-Touch-AMOLED-1.75](hardware/waveshare_esp32s3_touch_amoled_1_75.md#building-the-firmware).  The same firmware also builds for the [other boards](other-boards.md) it supports: the ESP32-S3-Touch-LCD-1.46, also with ESP-IDF, and the RP2040 and RP2350 1.28" boards, with the Raspberry Pi [pico-sdk](https://github.com/raspberrypi/pico-sdk).

## Getting the code

LVGL and the sound file decoders are included as git submodules, so clone with `--recursive`:

```
git clone --recursive https://github.com/rcat3/DroneLab.git
```

If you already cloned without it, run `git submodule update --init` inside the repo.

Building needs Python 3 with [Pillow](https://pypi.org/project/pillow/) installed (`pip install pillow`), which is used to convert the images.

## ESP32-S3 boards

### Installing ESP-IDF

The ESP32-S3 boards are built with ESP-IDF version 5.5.  On Linux, the short version is:

```
mkdir -p ~/esp && cd ~/esp
git clone -b v5.5.5 --recursive https://github.com/espressif/esp-idf.git esp-idf-v5.5.5
cd esp-idf-v5.5.5
./install.sh esp32s3
```

In each new terminal where you want to build, set up the environment first:

```
. ~/esp/esp-idf-v5.5.5/export.sh
```

ESP-IDF uses its own copy of Python, so Pillow needs to be installed there too.  This only needs to be done once, in a terminal where you've run `export.sh`:

```
python -m pip install pillow
```

### Building

From the top of the repo, for the ESP32-S3-Touch-AMOLED-1.75:

```
idf.py -C platforms/esp-idf -B build-s3-175 -DBOARD=waveshare_esp32s3_touch_amoled_1_75 build
```

For the ESP32-S3-Touch-LCD-1.46 (see [Other Boards](other-boards.md)):

```
idf.py -C platforms/esp-idf -B build-s3-146 -DBOARD=waveshare_esp32s3_touch_lcd_1_46 build
```

Give each board its own build folder, as here.  The first build downloads the board's display, touch and audio drivers from Espressif's component registry.

### Flashing

Connect the board's USB-C port and run, for the 1.75" board:

```
idf.py -C platforms/esp-idf -B build-s3-175 -p /dev/ttyACM0 flash monitor
```

For the 1.46" board, use `build-s3-146`.  Use the port your board shows up as (on Linux it's usually `/dev/ttyACM0`).  `monitor` shows the board's log.  Press `Ctrl+]` to exit it.

A few things that can come up:

- **The log stops at `waiting for download`.**  The board was reset into its programming mode instead of starting the firmware.  Press `Ctrl+T` then `Ctrl+R` in the monitor to reset it, or unplug it and plug it back in.
- **The board isn't found when flashing.**  Hold the `BOOT` button while plugging in the USB cable, then try again.
- **Watching the log without flashing:** `idf.py -C platforms/esp-idf -B build-s3-175 -p /dev/ttyACM0 monitor`
- **After updating the code, a setting doesn't seem to take effect.**  ESP-IDF keeps its configuration in the build folder and doesn't apply new defaults to an existing one.  Delete the build folder and build again.

### Updating over WiFi

Once a board has firmware with updates over WiFi in it (flashed over USB, as above, once), later firmware can go over its hotspot, with the board still in its housing:

1. On the board, go to Settings, **Firmware Update**, and switch it on.  It shows a six digit code, and the name and password of the board's hotspot, which it starts if it isn't on already.
2. Join the hotspot from your computer.
3. From the top of the repo, run `tools/update.py build-s3-175/dronelab.bin <code>` (or `build-s3-146` for the 1.46" board).

The script checks the firmware is for that board and that its battery is at 20% or more, then sends it.  The board writes it beside the firmware it's running, checks it, and restarts into it.  If the new firmware doesn't start properly and run for 15 seconds, the board goes back to the old one the next time it's restarted, so switch it off and on again.

It has nothing to do with the [phone remote](features/phone-remote.md)'s page, which can't update the board.  The updates run on a separate port, only while they're switched on on the board itself, and need the code from its screen, which is new each time.  They switch off again after 10 minutes, after 3 wrong codes, and when the board restarts.

The first flash with this in it has to be over USB, as it changes how the flash is laid out (into two places for firmware, so a new one can be written while the old one runs).  The settings are kept.  After that, it won't need USB again unless the update over WiFi itself goes wrong.

## RP2040 and RP2350 boards

The 1.28" boards (see [Other Boards](other-boards.md)).

### Installing pico-sdk

Clone the [pico-sdk](https://github.com/raspberrypi/pico-sdk) project from GitHub somewhere, and note where you put it:

```
git clone https://github.com/raspberrypi/pico-sdk.git
```

### Building

From the top of the repo:

```
export PICO_SDK_PATH=$HOME/pico-sdk   (or wherever you put it)
```

Use an absolute path for `PICO_SDK_PATH`.  A relative path gets resolved from inside the build folder, not from where you run the command, which is confusing.

Each board gets its own build folder, so you can build for both without them getting in each other's way.  For the RP2350 board:

```
cmake -S platforms/pico -B build-rp2350 -DBOARD=waveshare_rp2350_touch_lcd_1_28
cmake --build build-rp2350 -j
```

For the RP2040 board:

```
cmake -S platforms/pico -B build-rp2040 -DBOARD=waveshare_rp2040_touch_lcd_1_28
cmake --build build-rp2040 -j
```

When it's done, the firmware is `dronelab.uf2` in the build folder.

If CMake complains that `PICO_PLATFORM` doesn't match the board, the build folder was set up for the other board.  Use the other board's folder, or delete the folder and run the `cmake -S` command again.

### Flashing

Either way works:

- **With the buttons:** connect the board's USB-C port to your computer.  Hold `BOOT`, press and release `RESET`, then release `BOOT`.  The screen goes off, and a USB drive appears on the computer.  Copy the `.uf2` file onto it.  When the copy's done, the board restarts with the new firmware.
- **Without the buttons**, if [picotool](https://github.com/raspberrypi/picotool) is installed and the board is already running this firmware: `picotool load -f -x build-rp2350/dronelab.uf2`.  The `-f` restarts the board into its programming mode by itself, so this works with the board in its housing.

## Choosing features

Each of the display's [features](features/README.md) can be left out of the build.  Each platform has a file listing them:

- `platforms/pico/features.cmake` for the RP2040 and RP2350 boards
- `platforms/esp-idf/features.cmake` for the ESP32-S3 boards

Set a feature to `OFF` to leave it out, or `ON` to build it in, then build as usual.  The build picks up the change by itself and prints the features it's building, for example `-- Features: IMAGES, VOICE, SOUND`.  Settings is always built in.

A feature that needs hardware the board doesn't have (a microphone, a speaker, an accelerometer) hides itself even when it's built in.

Two more settings are fixed when the firmware is built:

- `RCAT_VOICE_FX`, in each ESP32 board's `board.cmake`, picks whether [voice effects](features/voice-effects.md) are built in.  They're on for the ESP32-S3-Touch-AMOLED-1.75, whose echo canceller lets them play on the speaker without feeding back, and off for the ESP32-S3-Touch-LCD-1.46.
- `RCAT_LARGE_IMAGES`, in each board's `.cmake` file, picks whether full screen animated GIFs are built in (see [Animated GIF memory use](features/images.md#animated-gif-memory-use)).
