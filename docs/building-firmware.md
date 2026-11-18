# Installing the Firmware

<img src="images/katcorp_mark.png" width="72" align="left" alt="KatCorp">

**KatCorp Drone Systems**<br>DroneLab: Loading the Operating Firmware

<br clear="left">

The firmware is what makes the board a DroneLab unit.  There are three ways to put it on the board, all over USB:

1. **[The web installer](#the-web-installer)**, straight from the browser.  The easiest, and the one to use unless you have a reason not to.
2. **[Flashing a release by hand](#flashing-a-release-by-hand)**, with Espressif's `esptool`.
3. **[Building it yourself](#building-it-yourself)**, from the source code, to change it or to run the newest code before it's released.

Whichever you use, you'll need a USB-C cable that carries data, not just charge.  The board can stay in its housing: the USB-C port is on its right side (under its cover, if you printed one).

Back to the [Build Guide](build/README.md).

## The web installer

> **Screenshot to come:** the web installer's page, with its *Install DroneLab* button.

1. On a computer, open **<https://rcat3.github.io/DroneLab/>** in **Chrome or Edge**.  Other browsers, and phones, can't reach USB devices.
2. Plug the board in, and press **Install DroneLab**.
3. Pick the board from the list: it's called `USB JTAG/serial debug unit`, or something with `ttyACM`, `usbmodem` or `COM` in it.
4. On a **new board**, tick **Erase device** when it asks.  To **update** a board, leave it unticked, and its settings are kept.
5. Wait for it to finish, about a minute.  The board restarts with the DroneLab logo.

That's it: on to [First Start](build/first-start.md).

It always installs the latest release.  On Linux, if it can't open the board, see [Troubleshooting](#troubleshooting).

## Flashing a release by hand

Each [release](https://github.com/rcat3/DroneLab/releases/latest) has the firmware in one file, `DroneLab-firmware-1.75.bin`.  Flashing it erases the board first, so it clears the settings: to update a board and keep them, use the web installer.

With [esptool](https://docs.espressif.com/projects/esptool/en/latest/esp32s3/) (`pip install esptool`), and the board on `/dev/ttyACM0` (on macOS `/dev/cu.usbmodem...`, on Windows `COM3` or similar):

```
esptool --chip esp32s3 -p /dev/ttyACM0 erase-flash
esptool --chip esp32s3 -p /dev/ttyACM0 write-flash 0x0 DroneLab-firmware-1.75.bin
```

(Older versions of esptool are called `esptool.py`, and spell the commands `erase_flash` and `write_flash`.)  Then unplug the board and plug it back in, or press `PWR`, to start it.

Espressif's own [web flasher](https://espressif.github.io/esptool-js/) works too: connect, *Erase Flash*, then program the file at address `0x0`.

## Building it yourself

This builds the firmware from the source code on your own computer.  It takes a while the first time, mostly downloading tools, and a couple of minutes after that.  These steps are written for Linux, and work the same way on macOS.  On Windows, use Espressif's [Windows installer](https://docs.espressif.com/projects/esp-idf/en/v5.5.5/esp32s3/get-started/windows-setup.html) for step 2, and run the rest from the *ESP-IDF 5.5 CMD* prompt it installs, with `COM3` (or whichever port the board shows up as) in place of `/dev/ttyACM0`.

### 1. Get the code

The firmware includes other projects, such as the LVGL graphics library, as git submodules, so clone it with `--recursive`:

```
git clone --recursive https://github.com/rcat3/DroneLab.git
cd DroneLab
```

If you've already cloned it without `--recursive`, run `git submodule update --init` inside it.

### 2. Install ESP-IDF

The board's processor is an Espressif ESP32-S3, built with Espressif's [ESP-IDF](https://docs.espressif.com/projects/esp-idf/en/v5.5.5/esp32s3/get-started/linux-macos-setup.html), version 5.5.  First install the [prerequisites](https://docs.espressif.com/projects/esp-idf/en/v5.5.5/esp32s3/get-started/linux-macos-setup.html#step-1-install-prerequisites) for your system, then:

```
mkdir -p ~/esp && cd ~/esp
git clone -b v5.5.5 --recursive https://github.com/espressif/esp-idf.git esp-idf-v5.5.5
cd esp-idf-v5.5.5
./install.sh esp32s3
```

Then, **in each new terminal** where you build, set up its environment:

```
. ~/esp/esp-idf-v5.5.5/export.sh
```

The build converts the images with [Pillow](https://pypi.org/project/pillow/), which needs installing in ESP-IDF's own Python.  Once, in a terminal where you've run `export.sh`:

```
python -m pip install pillow
```

### 3. Build it

From the top of the `DroneLab` folder:

```
idf.py -C platforms/esp-idf -B build-s3-175 -DBOARD=waveshare_esp32s3_touch_amoled_1_75 build
```

The first build downloads the board's display, touch and audio drivers, and takes a few minutes.  It finishes with `Project build complete`.

### 4. Flash it

Connect the board's USB-C port to the computer, and run:

```
idf.py -C platforms/esp-idf -B build-s3-175 -p /dev/ttyACM0 flash monitor
```

On Linux the board usually shows up as `/dev/ttyACM0`; on macOS, look for `/dev/cu.usbmodem*`.  When it's done, the board restarts with the DroneLab logo, and `monitor` shows its log.  Press `Ctrl+]` to leave the monitor.  Your settings are kept.

That's it: on to [First Start](build/first-start.md).

### Updating your own build

Get the new code and its submodules, then build and flash again, as in steps 3 and 4:

```
git pull
git submodule update --init
```

If something doesn't seem to change after an update, delete the `build-s3-175` folder and build again.  ESP-IDF keeps the board's configuration in the build folder, and doesn't pick up new defaults in an existing one.

## Updating

**From the app**: the app carries the firmware of its own release, and offers to update the unit over Bluetooth when it connects, in about 3 minutes, keeping the settings.  So updating the app is all it takes: see [Updating the unit's firmware](app/firmware-updates.md).

**With the web installer:** run the [web installer](#the-web-installer) again, leaving *Erase device* unticked: the settings are kept.  The board stays in its housing.  Boards with firmware before 0.9.7 need this once, to get firmware the app can update; the app says so when it connects to one.


## Troubleshooting

- **The board isn't found when flashing.**  Check the cable carries data (some are charge-only), and try another USB port.  If it still isn't found, hold `BOOT` (the upper button on the left side) while plugging in the USB cable, then try again.  Afterwards, press `PWR`, or unplug it and plug it back in, to start it.
- **On Linux, "permission denied" on `/dev/ttyACM0`.**  Add yourself to the `dialout` group (`sudo usermod -aG dialout $USER`), then log out and back in.
- **The log stops at `waiting for download`.**  The board was reset into its programming mode instead of starting the firmware.  Press `Ctrl+T` then `Ctrl+R` in the monitor to reset it, or unplug it and plug it back in.
- **Watching the log without flashing:** `idf.py -C platforms/esp-idf -B build-s3-175 -p /dev/ttyACM0 monitor`
- **The board restarted by itself.**  If a task stops, for example the audio (the sound stops and the visualizer freezes), the board restarts itself after 5 seconds and saves a core dump: what everything was doing at the time.  The log says why it restarted the next time it starts.  To read the core dump, connect it over USB and run `idf.py -C platforms/esp-idf -B build-s3-175 -p /dev/ttyACM0 coredump-info`, with the build folder of the firmware that's on the board, and [open an issue](https://github.com/rcat3/DroneLab/issues) with what it prints.  See [Crashes and hangs](development/README.md#crashes-and-hangs) for more.

## Choosing features

Each of the display's [features](features/README.md) can be left out of the build, in `platforms/esp-idf/features.cmake` (or `platforms/pico/features.cmake` for the RP2040 and RP2350 boards).  Set a feature to `OFF` to leave it out, or `ON` to build it in, then build as usual.  The build prints the features it's building, for example `-- Features: IMAGES, VOICE, SOUND`.  Settings is always built in.  A feature that needs hardware the board doesn't have, like a microphone or a speaker, hides itself even when it's built in.

Two more settings are fixed when the firmware is built:

- `RCAT_VOICE_FX`, in each ESP32 board's `board.cmake`, picks whether [voice effects](features/voice-effects.md) are built in.  They're on for the ESP32-S3-Touch-AMOLED-1.75, whose echo canceller lets them play on the speaker without feeding back, and off for the ESP32-S3-Touch-LCD-1.46.
- `RCAT_LARGE_IMAGES`, in each board's `.cmake` file, picks whether full screen animated GIFs are built in (see [Animated GIF memory use](features/images.md#animated-gif-memory-use)).
- `RCAT_DEFAULT_ROTATION`, in a board's `.cmake` file, sets the display's [Rotation](features/settings.md#rotation) on a new board, in clockwise quarter turns, to suit the way its housing holds it.  It's 2 (180 degrees) for the ESP32-S3-Touch-AMOLED-1.75, and 0 when it isn't set.  A board that already has saved settings keeps its own.
- `RCAT_SPEAKER_OPTIONAL`, in a board's `.cmake` file, is for a board whose speaker plugs in, so a housing may not have one.  A new board then asks which model it is at its first start, and Settings has a [Model](features/settings.md#model) page.  It's on for the ESP32-S3-Touch-AMOLED-1.75.

## Other boards

> [!NOTE]
> **These boards aren't supported.**  DroneLab is built and tested for the ESP32-S3-Touch-AMOLED-1.75, and its housings are only for that board.  The firmware still builds for the [other boards](other-boards.md) below, for anyone who wants to use them in a project of their own, but they're not tested with each release, they have fewer features, and there are no ready-made firmware downloads for them.

### ESP32-S3-Touch-LCD-1.46

As above, with its own build folder and board name:

```
idf.py -C platforms/esp-idf -B build-s3-146 -DBOARD=waveshare_esp32s3_touch_lcd_1_46 build
idf.py -C platforms/esp-idf -B build-s3-146 -p /dev/ttyACM0 flash monitor
```

### RP2040 and RP2350 boards

The 1.28" boards.

These are built with the Raspberry Pi [pico-sdk](https://github.com/raspberrypi/pico-sdk), and Python 3 with Pillow (`pip install pillow`).  Clone the pico-sdk somewhere, and point `PICO_SDK_PATH` at it, with an absolute path (a relative one is resolved from inside the build folder, which is confusing):

```
git clone https://github.com/raspberrypi/pico-sdk.git
export PICO_SDK_PATH=$HOME/pico-sdk
```

Then, from the top of the repo, for the RP2350 board:

```
cmake -S platforms/pico -B build-rp2350 -DBOARD=waveshare_rp2350_touch_lcd_1_28
cmake --build build-rp2350 -j
```

or for the RP2040 board:

```
cmake -S platforms/pico -B build-rp2040 -DBOARD=waveshare_rp2040_touch_lcd_1_28
cmake --build build-rp2040 -j
```

The firmware is `dronelab.uf2` in the build folder.  If CMake complains that `PICO_PLATFORM` doesn't match the board, the build folder was set up for the other board: use the other board's folder, or delete it and run the `cmake -S` command again.

To flash it, either:

- **With the buttons:** connect the board's USB-C port to your computer.  Hold `BOOT`, press and release `RESET`, then release `BOOT`.  A USB drive appears on the computer: copy the `.uf2` file onto it, and the board restarts with the new firmware.
- **Without the buttons**, if [picotool](https://github.com/raspberrypi/picotool) is installed and the board is already running this firmware: `picotool load -f -x build-rp2350/dronelab.uf2`.
