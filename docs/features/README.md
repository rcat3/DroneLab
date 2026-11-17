# Features

The display is organized into features.  You swipe up and down to move between them, and left and right between each feature's pages (see [Using the Display](../using-the-display.md)).  Each feature can be left out of the build (see [Choosing features](../building-firmware.md#choosing-features)), and a feature that needs hardware the board doesn't have hides itself.

| Feature | What it does |
|---|---|
| [Voice Effects](voice-effects.md) | Changes your voice: female, robot, Dalek, Borg and more.  Needs the speaker model |
| [HiveMind (Comms)](comms.md) | Links the hive's drones into one mind: they talk to each other, like a radio, with a status screen showing who's talking.  Cloud mode goes through a phone and a Mumble server; direct mode goes unit to unit over the radio (in development) |
| [Visualizer](visualizer.md) | Moving pictures of your voice and the speaker: KITT, a 3D spectrum, an oscilloscope and more |
| [Lovense](lovense.md) | Controls up to three Lovense devices over Bluetooth, with patterns and reactions to your voice and movement |
| [Images](images.md) | Shows still images and animated GIFs, built in or from a micro SD card |
| [Voice Ring](voice-ring.md) | A glowing ring round the edge that lights up with your voice, over the images |
| [Terminal](terminal.md) | Shows text typed on a phone, like a green screen terminal |
| [WiFi Hotspot Remote](phone-remote.md) | Runs the display from a phone's web browser |
| [Sound](sound.md) | Plays sound files from the SD card.  Needs the speaker model |
| [Voice Lab](voice-lab.md) | Streams and records the voice effect on a computer or phone |
| [Settings](settings.md) | Brightness, the phone app, rotation, the [Level](level.md), what's shown at startup, and the battery |

Every feature runs on the [ESP32-S3-Touch-AMOLED-1.75](../hardware/waveshare_esp32s3_touch_amoled_1_75.md).  The [low-profile model](../build/low-profile-housing.md) has no speaker, so sound and voice effects need the [speaker model](../build/speaker-housing.md).  The firmware also runs on a few [other boards](../other-boards.md), which have fewer features.
