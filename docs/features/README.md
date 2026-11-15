# Features

The display is organized into features.  You swipe up and down to move between them, and left and right between each feature's pages (see [Using the Display](../using-the-display.md)).  Each feature can be left out of the build (see [Choosing features](../building-firmware.md#choosing-features)), and a feature that needs hardware the board doesn't have hides itself.

| Feature | What it does |
|---|---|
| [Images](images.md) | Shows still images and animated GIFs that you swipe through |
| [Images on the SD card](images.md#images-on-the-sd-card) | Adds images from a micro SD card, without rebuilding the firmware |
| [Visualizer](visualizer.md) | Moving pictures of your voice and the speaker: KITT, a 3D spectrum, an oscilloscope and more |
| [Voice Ring](voice-ring.md) | A glowing ring round the edge that lights up with your voice, over the images |
| [Voice Effects](voice-effects.md) | Changes your voice: female, robot, Dalek, Borg and more.  Needs the speaker housing |
| [Voice Lab](voice-lab.md) | Streams the microphone to a computer, for trying out voice effects |
| [Sound](sound.md) | Plays sound files from the SD card.  Needs the speaker housing |
| [Terminal](terminal.md) | Shows text typed on a phone, like a green screen terminal |
| [Lovense](lovense.md) | Controls up to three Lovense devices over Bluetooth |
| [WiFi Hotspot Remote](phone-remote.md) | Runs the display from a phone's web browser |
| [Comm](comm.md) | Talks to a group through a phone and the DroneLab app, like a radio, with a status screen showing who's talking |
| [Settings](settings.md) | Brightness, rotation, the [Level](level.md), what's shown at startup, and the battery voltage |

Every feature runs on the [ESP32-S3-Touch-AMOLED-1.75](../hardware/waveshare_esp32s3_touch_amoled_1_75.md).  The low-profile housing has no speaker, so sound and voice effects need the speaker housing.  The firmware also runs on a few [other boards](../other-boards.md), which have fewer features.
