# Virtual unit

The unit's firmware, `core/`, built to run on a Linux computer instead of a
board: the 1.75" board's round screen in a window, the computer's microphone
and speakers for its own, and, in place of Bluetooth, a local socket the
DroneLab app on the same computer connects to. It's for using DroneLab from
a computer without any hardware, for trying it before building one, and for
developing the firmware without flashing a board.

## Building

It needs CMake, a C compiler, Python with Pillow (for the images, as the
ESP-IDF build does), and the X11 and JPEG headers:

    sudo apt install cmake build-essential python3-pil libx11-dev libjpeg-dev

LVGL, Mbed TLS, Opus, miniaudio and dr_libs come from the submodules
(`git submodule update --init`). Then, from the top of the repository:

    cmake -S platforms/host -B build-host
    cmake --build build-host -j
    build-host/dronelab-unit

`-DRCAT_SERIAL_CONSOLE=ON` builds in the development console
(`core/app/console.h`), read from the terminal it's started in.

## Running

    build-host/dronelab-unit [--unit N] [--sdcard DIR] [--scale N] [--no-mic] [--no-speaker]

- **The screen** is the window: the mouse is a finger. **B** is the BOOT
  button, **F12** takes a screenshot (what PWR and BOOT do on the board).
- **The app** finds it in its list of units, as *Virtual unit*, *On this
  computer*. It listens on `$XDG_RUNTIME_DIR/dronelab-unit.sock` (see
  "Virtual units" in `app/linux/README.md`); there's no pairing, as only
  the computer's user can reach it. The comm channel is on from the start.
- **Several units** can run at once, each with its own `--unit` number,
  socket (`dronelab-unit-2.sock`, *Virtual unit 2*) and settings.
- **Settings** are kept in `~/.local/share/io.github.rcat3.dronelab/unit`
  (`unit-2` for unit 2, ...), with its made-up MAC address and a `sdcard`
  folder that stands in for the SD card. `--sdcard DIR` uses another folder.
- **Without a microphone**, or with `--no-mic`, it hears silence: the comm
  channel still works for listening.
- **Voice effects** played out loud feed back through the computer's
  speakers, as there's no echo cancelling like the board's: use headphones.

## Direct comms

Virtual units can't reach real ones over the radio. They talk among
themselves instead, by UDP multicast (group 239.255.68.76, port 47268, not
leaving the local network), so units on this computer and on others nearby
hear each other, on the same channel, as boards would. A real unit
connected to the app is still the way to take part in a real Direct mesh.

## What it leaves out

The battery, the accelerometer (the spirit level isn't built), Bluetooth of
its own (so no Lovense or Terminal, and no talk button), the hotspot, and
firmware updates: it's updated by building it again. The HAL is in the
`hal_*.c` files here; see `core/include/hal.h`.
