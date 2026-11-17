# Level

*Boards with a supported accelerometer: the ESP32-S3 boards*

A page of [Settings](settings.md#level), after Rotation.  A spirit level, for lining the display up when it's mounted on the mask.  A line across the screen stays level with the ground, and turns green once the screen is within a degree of it.  The angle is shown under it.  It assumes the wearer is sitting or standing upright.

<img src="../images/screens/settings_level.png" width="220" alt="The Level, level">

Use it with the [Rotation](settings.md#rotation) setting, which turns the picture in 90 degree steps.

The RP2040 and RP2350 1.28" boards (see [Other Boards](../other-boards.md)) have an accelerometer too, but the firmware doesn't support it yet, so the Level is left out of their build.
