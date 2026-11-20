# DroneLab for Linux

The DroneLab app, for a Linux computer in place of an Android phone: a
desktop or laptop, or a Raspberry Pi 4 or 5 on 64-bit Raspberry Pi OS.

## Running it

Unpack it anywhere and start `dronelab` in the `DroneLab` folder:

    tar xzf DroneLab-linux-arm64.tar.gz
    DroneLab/dronelab

`x64` is for an ordinary PC, `arm64` for a Raspberry Pi. It needs Bluetooth
switched on, and these, which a desktop usually has already:

    sudo apt install libgtk-3-0 libopus0 libsecret-1-0 libx11-6 bluez

## Without a unit

The app comes with a virtual one: the unit's firmware, running on the
computer, with its round screen in a window of its own. In the app, tap the
status strip at the top, then *Find*, and *Start a virtual unit*. It's
connected to as a real one is, without pairing, and the app starts it again
next time, when it's the unit you were using. Closing its window switches it
off (*Start* in the app's Links brings it back); closing the app leaves it
running, as a unit stays on when the phone's app is closed.

Its settings are kept in `~/.local/share/io.github.rcat3.dronelab/unit`. It
hears through the computer's microphone and plays through its speakers: use
headphones, or a voice effect played out loud feeds back. It's
`DroneLab/dronelab-unit`, and can be started by hand too (`--help` says
how). Virtual units reach each other over the local network, not real units
over the radio: for that, use a real unit.

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
- Your settings, conversations, photos and recordings are kept beside it,
  in the same folder.
- With the developer options shown in the app, the developer commands come
  over a socket in place of adb:

      echo /nearby | nc -U -q 5 $XDG_RUNTIME_DIR/dronelab-dev.sock

## Two at once

Each copy of the app is a person, so a second one running beside the first
needs a profile of its own, or the two are the same person, signed in
twice, and get in each other's way:

    DroneLab/dronelab --profile 2

A profile (up to 32 letters, digits and `_`) has its own identity,
settings, conversations and recordings, in
`~/.local/share/io.github.rcat3.dronelab.profile_2`, and its window says
*DroneLab (2)*. It's a new person the first time: set it up as you would a
new phone, with a unit of its own (another real one, or *Start a virtual
unit*, which picks the next free one): the first app's virtual unit is
listed as in use, as a unit takes one app at a time. Its developer socket is
`dronelab-dev-2.sock`. Without `--profile` (or with `--profile default`)
it's the usual one.

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
phone were connected, paired and had notifications on. One app at a time:
another is sent an empty message and turned away, and while one's
connected there's an empty file beside the socket (`dronelab-unit.sock.inuse`),
so other apps can list the unit as in use without connecting to it.

`platforms/host` builds one: the firmware itself, running on the computer
(see its README). The app carries it as `dronelab-unit`, beside its own
program, and starts it (`--unit N`, detached) when one it's connecting to
isn't listening: when it's picked, or the app starts and it's the unit from
last time, but not when it stops while connected, as closing its window is
switching it off. A build of the app picks it up from `build-host` at the
top of the repository, once it's been built there.
