# Deprecated Hardware

Designs that are no longer supported, kept for anyone who wants to build them or bring them back.  They aren't kept up to date with the firmware or the other housings.  Each folder's README says why it was dropped and what replaces it.

The [ESP32-S3-Touch-AMOLED-1.75](../boards/waveshare_esp32s3_touch_amoled_1_75/) and its housings replace all of them.  The 1.75" board needs no soldering: its charger is set by the firmware, and the battery and speaker plug straight in.

| Design | For | Why it was dropped |
|---|---|---|
| [1.28" housing](waveshare_touch_lcd_1_28/) | Waveshare RP2040-Touch-LCD-1.28 and RP2350-Touch-LCD-1.28 | Needs a switch soldered into the battery's lead, and a tiny resistor on the board changed to charge its small battery safely. |
| [1.46" housing](waveshare_esp32s3_touch_lcd_1_46/) | Waveshare ESP32-S3-Touch-LCD-1.46 | Needs a tiny resistor on the board changed to charge its small battery safely.  Its speaker faces into the mask, so it has no voice effects. |
| [1.46" speaker housing](waveshare_esp32s3_touch_lcd_1_46_speaker_housing/) | Waveshare ESP32-S3-Touch-LCD-1.46, with two speakers, their amplifiers and the J9 header adapter PCB | A hard build, with a custom PCB and fine soldering, no USB access, and one microphone.  The firmware no longer drives its amplifiers. |

The firmware still supports the 1.28" and 1.46" boards, for other projects: see [Other Boards](../../docs/other-boards.md).  The housings for them each have their build guide (`build_guide.md`) in their folder.

Each design keeps its own license, given in its README.
