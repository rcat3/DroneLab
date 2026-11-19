# Using the Display

When it turns on, the display shows the DroneLab logo for a couple of seconds while it gets ready.  Then it's organized into features, like Images, Voice and Settings (see [Features](features/README.md) for them all).

- **Swipe up and down** to move between features.
- **Swipe left and right** to move between the pages of a feature.  Each feature remembers which page you were on.

After each swipe, dots along the right edge show which feature you're in, and dots along the bottom show which page (or "3 / 26" when there are a lot of pages).  They fade out after a moment.

On pages with a slider or roller, start your swipe beside it rather than on it, or you'll move the control instead of the page.

Every page has a dark theme, with pink controls.

Settings are saved about two seconds after you change them, and are restored when the display is turned back on.  They also survive flashing new firmware.  What's shown when the display turns on is picked in [Settings](features/settings.md#startup).

On boards with WiFi, the whole display can also be run from a phone, with the [WiFi Hotspot Remote](features/phone-remote.md).

## Screenshots

Hold `PWR` and press `BOOT` to save a picture of the screen to the SD card, exactly as it's shown, as a BMP file in a `screenshots` folder (`shot_0001.bmp` and on).  Its name shows at the bottom of the screen for a moment, or *No SD card*.  Holding `PWR` for a screenshot doesn't turn the unit off: let go of both, and it carries on.  `BOOT` on its own still switches the voice effect's speaker off and on.

The screenshots in this documentation were taken over USB instead, with `tools/screenshots.py` (see [Developing](development/README.md#screenshots)).

## Turning it on and off

Press `PWR` on the side to turn it on.  Hold it for 2 seconds to turn it off.
