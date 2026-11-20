# DroneLab for Linux

The DroneLab app, for a Linux computer in place of an Android phone: a
desktop or laptop, or a Raspberry Pi 4 or 5 on 64-bit Raspberry Pi OS.

## Running it

Unpack it anywhere and start `dronelab` in the `DroneLab` folder:

    tar xzf DroneLab-linux-arm64.tar.gz
    DroneLab/dronelab

`x64` is for an ordinary PC, `arm64` for a Raspberry Pi. It needs Bluetooth
switched on, and these, which a desktop usually has already:

    sudo apt install libgtk-3-0 libopus0 libsecret-1-0 bluez

## Pairing with your unit

On the unit, open Settings, Paired Phones, and tap *Pair a phone*. In the
app, tap the status strip at the top, find your unit and connect. The app
asks for the code the unit shows.

To pair again from scratch, disconnect in the app first, then forget it in
the computer's Bluetooth settings (or `bluetoothctl remove <address>`).
Forgetting it while it's connected doesn't stick.

## Good to know

- Sound plays through PulseAudio or PipeWire, or straight to ALSA without
  either.
- The Remote tab opens the unit's remote in your browser.
- Your identity is kept in `~/.local/share/io.github.rcat3.dronelab/identity-seed`,
  readable only by you. Back it up from the app (Setup, Your identity) like on
  a phone.
- With the developer options shown in the app, the developer commands come
  over a socket in place of adb:

      echo /nearby | nc -U -q 5 $XDG_RUNTIME_DIR/dronelab-dev.sock

## Virtual units

Besides units over Bluetooth, the app finds units running on the same
computer: anything listening on a Unix socket named
`$XDG_RUNTIME_DIR/dronelab-unit*.sock` shows up in the list of units, as
*Virtual unit* (`dronelab-unit-2.sock` is *Virtual unit 2*). Only its owner
can reach the runtime directory, so there's no pairing.

The socket carries the same messages as the unit's Bluetooth service, the
app's writes one way and the unit's notifications the other, each as its
length (2 bytes, little-endian) and then the message, up to 244 bytes. The
app connects once the unit's listening; while it's connected, it's as if the
phone were connected, paired and had notifications on. One app at a time.
