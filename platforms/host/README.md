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

    build-host/dronelab-unit [--unit N] [--sdcard DIR] [--scale N] [--toy MODEL] [--no-mic] [--no-speaker]

- **The screen** is the window, titled *DroneLab: Virtual Display Unit*:
  the mouse is a finger. **B** is the BOOT button, **F12** takes a
  screenshot (what PWR and BOOT do on the board), and **T** shows or hides
  the virtual toys.
- **The app** finds it in its list of units, as *Virtual unit*, *On this
  computer*, and starts it itself when it isn't running (*Start a virtual
  unit*): the Linux app carries it, and a build of the app picks up
  `build-host/dronelab-unit` if it's there. It listens on a loopback TCP port, found in
  `$XDG_RUNTIME_DIR/dronelab-units/unit-1.ep` (see "Virtual units" in
  `app/linux/README.md`); there's no pairing, as only the computer's user can
  read the token in it. The comm channel is on from the start.
- **Several units** can run at once, each with its own `--unit` number,
  endpoint (`unit-2.ep`, *Virtual unit 2*) and settings.
- **Settings** are kept in `~/.local/share/io.github.rcat3.dronelab/unit`
  (`unit-2` for unit 2, ...), with its made-up MAC address and a `sdcard`
  folder that stands in for the SD card. `--sdcard DIR` uses another folder.
- **Without a microphone**, or with `--no-mic`, it hears silence: the comm
  channel still works for listening.
- **Voice effects** played out loud feed back through the computer's
  speakers, as there's no echo cancelling like the board's: use headphones.

## Virtual Lovense toys

For trying the Lovense feature, and the app's remote for it, without a toy:
press **T** for the panel beside the screen, and switch on up to three
toys (Lush, Edge, Nora, Max, Gravity, Lapis or Solace), or start with
`--toy Lush --toy Nora`. Each advertises as a real one does (`LVS-S01`),
for the Lovense feature's scan to find, connects when it's tapped, and
answers Lovense's own commands, so `core/app/lovense.c` drives it as it
would a real toy. The panel shows each one's state, battery (which runs
down slowly while it's running), the last command it was sent, and its
motors' levels. **Off** switches one off, as if its button were pressed:
its connection drops.

They're in `hal_ble.c`, behind the HAL's Bluetooth central functions,
which is where the computer's own Bluetooth will go, for real toys.

## Direct comms

Virtual units can't reach real ones over the radio. They talk among
themselves instead, by UDP multicast (group 239.255.68.76, port 47268, not
leaving the local network), so units on this computer and on others nearby
hear each other, on the same channel, as boards would. A real unit
connected to the app is still the way to take part in a real Direct mesh.

## What it leaves out

The battery, the accelerometer (the spirit level isn't built), Bluetooth of
its own (so only virtual toys, and no talk button), the hotspot, and
firmware updates: it's updated by building it again. The HAL is in the
`hal_*.c` files here; see `core/include/hal.h`.
