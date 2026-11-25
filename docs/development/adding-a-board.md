# Adding a Board

A new display means a board folder with its HAL and its screen size, without copying the application around.  Start from the 1.75" board's folder.  The firmware used to run on RP2040 and RP2350 boards too, with a pico-sdk build of its own: the [former boards](../other-boards.md) page says which commits have it, for a board that isn't an ESP32.

## In the firmware

### An ESP32 board

Add `platforms/esp-idf/boards/<board>/`, named after the board, with:

- `board.cmake` - Sets `IDF_TARGET`, `RCAT_IMAGE_SIZE`, `RCAT_LARGE_IMAGES` and `RCAT_VOICE_FX` (whether voice effects are built in: only for a board whose speaker can play them without feeding back), and optionally `RCAT_DEFAULT_ROTATION` (the display's rotation on a new board, in clockwise quarter turns, if its housing turns it) `RCAT_HALF_TURNS_ONLY` (on if the display only turns to 0 or 180 degrees) and `RCAT_SPEAKER_OPTIONAL` (on if the speaker plugs in, so a housing may have none).
- `CMakeLists.txt` - Registers the board's component, which requires `rcat_core` and `rcat_esp32`.
- `hal_board.c` - The board's own HAL: display, touch, audio, battery, accelerometer axes and the SD card's pins.  Everything else is in `components/rcat_esp32/` already.
- `idf_component.yml` - The drivers it needs from Espressif's component registry.  The first build makes `dependencies.lock`, which pins their versions; commit it.
- `sdkconfig.defaults` - Its flash size, PSRAM and partition table, starting from another board's.
- `partitions.csv` - Start from another board's, and keep its `coredump` partition, where the board saves a core dump when it crashes or the watchdog restarts it (see [Crashes and hangs](README.md#crashes-and-hangs)).

Build it with `-DBOARD=<board>` and its own build folder.  The [ESP32-S3-Touch-AMOLED-1.75](../../platforms/esp-idf/boards/waveshare_esp32s3_touch_amoled_1_75/) is a recent example of all of this.

### Then

- Check which features it can run, and set them in the platform's `features.cmake` if a feature needs switching off for the whole platform.
- Give it board notes in [`docs/hardware/`](../hardware/).  A board with a housing for the mask gets a build guide in [`docs/build/`](../build/README.md), and a place in the [top-level README](../../README.md#the-two-models).

## A housing for it

The housings are in `hardware/boards/<board>/`, named like the firmware's board folder, with the board's dimensions in `board.scad` and the mask's thread and turning collar shared from `hardware/masks/`.  [`hardware/README.md`](../../hardware/README.md#adding-a-board) has the steps.  Add a scene for it in `tools/doc_renders/` and run `render.sh`, so it has a picture in the documentation.
