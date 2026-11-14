# Features

The display is organized into features.  You swipe up and down to move between them, and left and right between each feature's pages (see [Using the Display](../using-the-display.md)).  Each feature can be left out of the build (see [Choosing features](../building-firmware.md#choosing-features)), and a feature that needs hardware the board doesn't have hides itself.

| Feature | What it does |
|---|---|
| [Images](images.md) | Shows still images and animated GIFs that you swipe through |
| [Images on the SD card](images.md#images-on-the-sd-card) | Adds images from a micro SD card, without rebuilding the firmware |
| [KITT and the Voice Ring](kitt-and-voice-ring.md) | Bars or a glowing ring that light up with your voice |
| [Voice Effects](voice-effects.md) | Changes your voice: female, robot, Dalek and more.  Needs the speaker housing |
| [Voice Lab](voice-lab.md) | Streams the microphone to a computer, for trying out voice effects |
| [Sound](sound.md) | Plays sound files from the SD card.  Needs the speaker housing |
| [Lovense](lovense.md) | Controls up to three Lovense devices over Bluetooth |
| [Level](level.md) | A spirit level, for lining the display up on the mask |
| [Terminal](terminal.md) | Shows text typed on a phone, like a green screen terminal |
| [Phone Remote](phone-remote.md) | Runs the display from a phone's web browser |
| [Settings](settings.md) | Brightness, rotation, what's shown at startup, and the battery voltage |

Every feature runs on the [ESP32-S3-Touch-AMOLED-1.75](../hardware/waveshare_esp32s3_touch_amoled_1_75.md).  The low-profile housing has no speaker, so sound and voice effects need the speaker housing.  The firmware also runs on a few [other boards](../other-boards.md), which have fewer features.
