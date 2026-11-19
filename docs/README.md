# Documentation

New here?  Start with the [project page](../README.md).

## Building a unit

- [Build Guide](build/README.md): choosing a model, and what you'll need.
  - [Speaker model](build/speaker-housing.md): parts, printing and putting it together.
  - [Low-profile model](build/low-profile-housing.md): parts, printing and putting it together.
- [Installing the Firmware](building-firmware.md): the web installer, flashing a release by hand, or building it yourself, and updating.
- [First Start](build/first-start.md): rotation, levelling, the voice effect, and your own images and sounds.
- [Installing the App](app/installing.md): the DroneLab app for Android, and [connecting](app/connecting.md) it to the unit.

## Using it

- [The DroneLab App](app/README.md): what it does, the screen and its signs.
  - [Connecting](app/connecting.md): pairing the unit, joining the server, your avatar.
  - [HiveMind](app/voice.md): talking to other drones, over the server and direct, and hearing them.
  - [Text](app/text.md): texts with one drone, a channel or all of the hive, words on their displays, and who can put words on yours.
  - [Control](app/control.md): others' Lovense toys, and who can control yours.
  - [Record](app/record.md): your voice effect to WAV files, for videos.
  - [Remote](app/remote.md): the unit's controls on the phone, and the WiFi hotspot for iPhones.
  - [Updating the unit's firmware](app/firmware-updates.md): from the app, or over USB.

- [Using the Display](using-the-display.md): finding your way around, and turning it on and off.
- [Features](features/README.md): [Voice Effects](features/voice-effects.md), [HiveMind (Comms)](features/comms.md), [Visualizer](features/visualizer.md), [Lovense](features/lovense.md), [Images](features/images.md), [Voice Ring](features/voice-ring.md), [Terminal](features/terminal.md), [WiFi Hotspot Remote](features/phone-remote.md), [Sound](features/sound.md), [Voice Lab](features/voice-lab.md) and [Settings](features/settings.md), with the [Level](features/level.md).

## Under the hood

- [The board](hardware/waveshare_esp32s3_touch_amoled_1_75.md): technical notes on the ESP32-S3-Touch-AMOLED-1.75.
- [Hardware designs](../hardware/README.md): the housings' OpenSCAD designs.
- [Developing](development/README.md): how the firmware is put together, [adding a feature](development/adding-a-feature.md), [the hardware abstraction layer](development/hardware-abstraction.md), [adding a board](development/adding-a-board.md) and [contributing](development/contributing.md).
- [The app's source](../app/README.md): building the app yourself.
- [Other Boards](other-boards.md): the other displays the firmware runs on.

The pictures of the housings and travel cases in `images/` are rendered from their designs by `tools/doc_renders/render.sh`, and the README's How it works diagram by `tools/doc_renders/make_diagram.py`.
