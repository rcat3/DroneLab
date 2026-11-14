# Other Boards

DroneLab is built around the [Waveshare ESP32-S3-Touch-AMOLED-1.75](hardware/waveshare_esp32s3_touch_amoled_1_75.md).  The same firmware also runs on three other Waveshare round displays, which may be useful for projects of your own:

| | RP2040-Touch-LCD-1.28 | RP2350-Touch-LCD-1.28 | ESP32-S3-Touch-LCD-1.46 |
|---|---|---|---|
| Screen | 1.28" round LCD, 240x240 | 1.28" round LCD, 240x240 | 1.46" round LCD, 412x412 |
| Processor | RP2040, 2 cores, 133 MHz | RP2350, 2 cores, 150 MHz | ESP32-S3, 2 cores, 240 MHz |
| RAM | 264 kB | 520 kB | 512 kB + 8 MB PSRAM |
| Microphone | | | One |
| Speaker | | | Built in |
| Micro SD card | | | Yes |
| WiFi and Bluetooth LE | | | Yes |
| Accelerometer | Yes (not supported yet) | Yes (not supported yet) | Yes |
| Battery charging | 1 A, set by a resistor | 1 A, set by a resistor | Up to 2 A, set by a resistor |
| Power button | | | Yes |

Their housings for the MSA Millennium mask are no longer supported.  They're kept, with their build guides, in [`hardware/deprecated`](../hardware/deprecated/): the [1.28" housing](../hardware/deprecated/waveshare_touch_lcd_1_28/) and the [1.46" housing](../hardware/deprecated/waveshare_esp32s3_touch_lcd_1_46/).

## Which features run on them

| Feature | RP2040 1.28" | RP2350 1.28" | ESP32-S3 1.46" |
|---|:-:|:-:|:-:|
| [Images](features/images.md) | Yes | Yes | Yes |
| [Full screen animated GIFs](features/images.md#animated-gif-memory-use) | | Yes | From the SD card |
| [Images from the SD card](features/images.md#images-on-the-sd-card) | | | Yes |
| [KITT and the Voice Ring](features/kitt-and-voice-ring.md) | | | Yes |
| [Voice Effects](features/voice-effects.md) | | | |
| [Voice Lab](features/voice-lab.md) | | | Yes |
| [Sound](features/sound.md) | | | Yes |
| [Lovense](features/lovense.md) | | | Yes |
| [Level](features/level.md) | | | Yes |
| [Terminal](features/terminal.md) | | | Yes |
| [Phone Remote](features/phone-remote.md) | | | Yes |
| [Settings](features/settings.md) | Yes | Yes | Yes |

The RP2040 and RP2350 boards have no microphone, speaker, SD card slot, WiFi or Bluetooth, so they show images and settings.  They do have an accelerometer, which the firmware doesn't support yet, so the Level isn't on them.  The RP2350 has twice the RAM of the RP2040, enough for full screen animated GIFs.

The ESP32-S3-Touch-LCD-1.46 has no voice effects: it can't hear what its speaker is playing, so it can't cancel it out of its microphone, and would feed back long before an effect was loud enough to hear.

## Board notes

### RP2040-Touch-LCD-1.28 and RP2350-Touch-LCD-1.28

- **Power:** they have no power button.  They run from USB-C, or from a 3.7 V LiPo on their JST 1.25 mm battery socket, and are switched on and off by connecting the battery, so a switch in its lead is the usual way.  Check the battery's polarity against the board before plugging it in: many batteries are wired the other way.
- **Charging:** they charge their battery at 1 A, set by R15 (160k) next to the charger chip, and the firmware can't change it.  That's too much for a small battery, so change R15 (560k gives about 0.3 A), or charge the battery separately.  The [1.28" build guide](../hardware/deprecated/waveshare_touch_lcd_1_28/build_guide.md#charging) has the details.
- **Flashing:** see [Building the Firmware](building-firmware.md#rp2040-and-rp2350-boards).  The images are built into the firmware, so changing them means rebuilding it.

### ESP32-S3-Touch-LCD-1.46

- **Power:** it runs from USB-C or from a 3.7 V LiPo on its MX1.25 socket (check the polarity first).  Press `PWR` to turn it on, and hold it for 2 seconds to turn it off.
- **Charging:** it charges its battery at up to 2 A, set by R8 (82k) next to the charger chip, and the firmware can't change it.  That's too much for most small batteries, so change R8 (390k gives about 0.4 A).  The [1.46" build guide](../hardware/deprecated/waveshare_esp32s3_touch_lcd_1_46/build_guide.md#board-notes) has the details.
- **Speaker:** the small round trimmer on the back of the board sets the built-in speaker's volume, on top of the volume setting.
- **Flashing:** see [Building the Firmware](building-firmware.md#esp32-s3-boards), with `build-s3-146` and `-DBOARD=waveshare_esp32s3_touch_lcd_1_46`.  Images for this board are 412 pixels across.
