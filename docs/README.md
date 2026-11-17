# Documentation

New here?  Start with the [project page](../README.md).

## Building a unit

- [Build Guide](build/README.md): choosing a model, and what you'll need.
  - [Speaker model](build/speaker-housing.md): parts, printing and putting it together.
  - [Low-profile model](build/low-profile-housing.md): parts, printing and putting it together.
- [Installing the Firmware](building-firmware.md): the web installer, flashing a release by hand, or building it yourself, and updating.
- [First Start](build/first-start.md): rotation, levelling, the voice effect, and your own images and sounds.
- [Installing the App](installing-the-app.md): the DroneLab app for Android, and pairing it with the unit.

## Using it

- [Using the Display](using-the-display.md): finding your way around, and turning it on and off.
- [Features](features/README.md): [Voice Effects](features/voice-effects.md), [HiveMind (Comms)](features/comms.md), [Visualizer](features/visualizer.md), [Lovense](features/lovense.md), [Images](features/images.md), [Voice Ring](features/voice-ring.md), [Terminal](features/terminal.md), [WiFi Hotspot Remote](features/phone-remote.md), [Sound](features/sound.md), [Voice Lab](features/voice-lab.md) and [Settings](features/settings.md), with the [Level](features/level.md).
- [Updating over WiFi](updating-over-wifi.md): for boards whose USB port can't be reached.

## Under the hood

- [The board](hardware/waveshare_esp32s3_touch_amoled_1_75.md): technical notes on the ESP32-S3-Touch-AMOLED-1.75.
- [Hardware designs](../hardware/README.md): the housings' OpenSCAD designs.
- [Developing](development/README.md): how the firmware is put together, [adding a feature](development/adding-a-feature.md), [the hardware abstraction layer](development/hardware-abstraction.md), [adding a board](development/adding-a-board.md) and [contributing](development/contributing.md).
- [The app's source](../app/README.md): building the app yourself.
- [Other Boards](other-boards.md): the other displays the firmware runs on.

The pictures of the housings in `images/` are rendered from their designs by `tools/doc_renders/render.sh`.
