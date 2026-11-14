# Hardware

3D printable housings and other hardware for the displays the firmware runs on.

This is the design side.  To build one, start with the [build guide](../docs/hardware/waveshare_esp32s3_touch_amoled_1_75.md), which has the parts to buy, printing, wiring and putting it together.

## What fits what

| Board | Firmware | Housings for the MSA Millennium | Other hardware |
|---|---|---|---|
| [Waveshare ESP32-S3-Touch-AMOLED-1.75](boards/waveshare_esp32s3_touch_amoled_1_75/) | Yes | Speaker housing with one speaker below the display; low-profile housing without a speaker (designed, not printed yet) | |

The housings for the 1.28" and 1.46" boards are [deprecated](#deprecated-designs).

## How it's organized

```
hardware/
  boards/<board>/       everything for one board: its dimensions, the housings
                        for it, and any PCBs or accessories made for it
  masks/<mask>/         what every housing for one mask shares: the thread,
                        the turning collar, and the shape of the mask around
                        the port
  common/               shape helpers and the render script the boards share
  deprecated/<design>/  designs that are no longer supported, kept for anyone
                        who wants to build them or bring them back
```

The board folders have the same names as the firmware's board folders in `platforms/*/boards/`, so it's easy to find both halves of a board.  (The two 1.28" boards, now deprecated, share one folder, as they share `platforms/pico/boards/touch_lcd_1_28/` in the firmware, with a setting to pick between them.)  Inside one:

- `board.scad` - The board's dimensions, in the coordinates of the maker's 3D model: the front of the glass at z = 0, the board towards -z, and x/y seen from the front with the USB port at the bottom.  Every housing for the board includes it.
- `<mask>_<kind>.scad` - A housing, named for the mask it fits and what it is, such as `msa_speaker_housing.scad`.  Each has a `part` setting that picks which part to render.
- `render.sh` - Renders a housing's parts to STL files in `stl/`.  The STL files are made from the `.scad` files, so they aren't kept in the repository.
- `README.md` - How it goes together, what to buy, what's been checked with a print, and which parts need a material other than PLA (such as TPU for gaskets).
- A subfolder for anything else, such as a case (`travel_case/`).

## Deprecated designs

Designs that are no longer supported are in [`deprecated/`](deprecated/), with a README each saying why and what replaces it: the 1.28" housing, the 1.46" housing, and the 1.46" board's speaker housing, with its two speakers and the J9 header adapter PCB.  The 1.75" board's housings replace them all.  The firmware still supports the 1.28" and 1.46" boards, for other projects.

## Adding a board

1. Make `boards/<board>/`, named like the firmware's board folder.
2. Write its `board.scad` from the maker's drawing and 3D model, with the same coordinates as the others.  Include `../../common/shapes.scad` and the mask's `voice_port.scad`.
3. Start a housing from the closest existing one.  Include the mask's `turning_collar.scad` for the collar, and `keepout.scad` to show the mask around the port in the preview.
4. Copy a `render.sh` and list the housing's parts in it.
5. Add a README, and a row to the table above.

## Adding a mask

Make `masks/<mask>/` with its port's thread and the shape of the mask around the port, in the port's coordinates: the center of the front of the port's rim at the origin, z out of the mask, and y up.

## Licenses

The housings are based on whyrlpool's RP2040-LCD-1.28-MSA design, and like it, everything here is licensed under the [Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License](https://creativecommons.org/licenses/by-nc-sa/4.0/), unless its folder says otherwise.  The travel cases are under the [Creative Commons Attribution-ShareAlike 4.0 International License](https://creativecommons.org/licenses/by-sa/4.0/).  Both are separate from the license of the rest of the repository.
