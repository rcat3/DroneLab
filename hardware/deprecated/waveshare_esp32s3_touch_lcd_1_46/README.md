# MSA Millennium Housing for the ESP32-S3-Touch-LCD-1.46 (deprecated)

**This housing is no longer supported.**  The [ESP32-S3-Touch-AMOLED-1.75](../../boards/waveshare_esp32s3_touch_amoled_1_75/) and its housings replace it: they need no soldering to charge their batteries safely, as the 1.75" board's charger is set by the firmware, where this board's needs a tiny resistor changed.  The design is kept here for anyone who wants to build it.  The firmware still supports the board (see [Other Boards](../../../docs/other-boards.md)).

A 3D printable housing that screws the [Waveshare ESP32-S3-Touch-LCD-1.46](https://docs.waveshare.com/ESP32-S3-Touch-LCD-1.46) into the voice port of an MSA Millennium mask.  It's for the version of the board **with the cover glass** (44.77 mm round lens).  It's one printed part, holding the board and a small battery.

This README is about the design files.  For the whole build, with the parts to buy and putting it together, see the [build guide](build_guide.md) in this folder.

There was also a speaker housing for this board, with two speakers and their own amplifiers, in [`../waveshare_esp32s3_touch_lcd_1_46_speaker_housing`](../waveshare_esp32s3_touch_lcd_1_46_speaker_housing/).  It uses this folder's `board.scad`.

## Making the STL files

Run `render.sh` in this folder.  It needs [OpenSCAD](https://openscad.org/).

```
./render.sh             # the housing
./render.sh tests       # the test prints
```

The STL files go in the `stl/` folder, turned the right way up to print.  A single part can also be rendered by hand, with for example `openscad -D 'part="housing"' -o housing.stl msa_housing.scad`.

**Status:** the board, thread, micro SD slot and buttons have all been checked with full prints.

## How it goes together

- The board sits in a cup on the outside of the mask, with the glass flush with the front.  Its micro SD slot (left) and PWR/BOOT side buttons (right) stay reachable from the outside.  The buttons are pressed through flexible tabs in the wall, hinged at the front edge.
- The board screws to the cup's back plate, which carries the MSA voice port thread.  The space inside the thread (42 mm across, 8 mm deep) holds the battery, a 702030 LiPo (7 x 20 x 30 mm).  The PWR button turns the board on and off (hold it for 2 seconds to turn off), so there's no separate switch.
- The board's battery connector sits between the board and the back plate, so it can't be reached once the board is screwed in.  Plug a short extension cable into it first, and connect the battery to that.  The extension's wires come out over the speaker, through the opening in the back plate.
- There's a hole in the back plate behind the microphone.
- The USB-C port is covered by the wall, so the board can't be plugged in to charge by accident (see [Charge current](#charge-current)).  Take the board out to use USB, and unplug the battery first.  To print the housing with an opening for the port, set `usb_access = true`.

## Parts to print

**Materials:** PLA or PLA+.

- **`housing`** - The whole housing, in one piece.  It prints with its front on the bed.

## Screws

| Screws | How many | Where they go |
|---|---|---|
| M2 countersunk, about M2 x 5 | 3 | Through the back plate into the standoffs on the back of the board.  They go in from the back, through the inside of the thread, and their heads sit flush. |

## Charge current

The board charges its battery at up to 2 A, set by R8 (82k) next to its charger chip.  That's far more than the housing's 702030 battery, about 400 mAh, should take, so it's worth changing R8 to about 390k, which charges at about 0.4 A.  The charge current is roughly 165 kΩ·A divided by R8.

R8 is a tiny 0201 part, so changing it is fine soldering work.  Measure the charge current with a USB meter afterwards.

## Test prints

You don't need to print these to build a housing: the design's already been checked and tuned with them.  They're for checking the fit on a different printer or with a different material, before printing a whole housing.  Render them with `./render.sh tests`.

- **`fit_test`** - The housing without the thread, to check the openings and buttons with the board fitted.
- **`lens_fit`** - The front 3 mm of the housing's cup.  The board's glass should drop in with a little play, but not rattle.  If it doesn't, adjust `clearance`.
- **`thread_test`** - Three thin thread rings at 99.4%, 99.7% and 100% of the original thread's diameter, numbered 1 to 3 by notches on the rim.  99.7% fit best, which is what `thread_scale` is set to (98% was too loose and 102% too tight).  `thread_scale` and the thread's beveled start, `thread_lead_in`, are in `../../masks/msa_millennium/voice_port.scad`, so they change the thread for every board's housing.

## Files

- `msa_housing.scad` - The housing, in OpenSCAD.  All of the dimensions are named settings at the top.
- `board.scad` - The board's dimensions.
- `render.sh` - Renders the parts to STL files.
- `travel_case/` - A case to carry the housing in.
- `build_guide.md` - The whole build: the parts to buy, putting it together and building the firmware.
- `images/` - The housing's picture, and `render_view.scad`, the view it was rendered from.

The MSA voice port thread and the thread test rings are shared with the other boards' housings, in [`../../masks/msa_millennium`](../../masks/msa_millennium/).

## Travel case

There's a hinged case to carry the housing in, in [`travel_case`](travel_case/).

## Credits and License

This design is based on [RP2040-LCD-1.28-MSA](https://www.printables.com/model/538771-rp2040-lcd-128-msa) by whyrlpool, whose voice port thread was in turn adapted from the [Gas Mask VPU Cover (MSA compatible)](https://cults3d.com/en/3d-model/various/gas-mask-vpu-cover-msa-compatible).

Like the design it's based on, everything in this folder (apart from the travel case, which has its own license) is licensed under the [Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License](https://creativecommons.org/licenses/by-nc-sa/4.0/).  This is separate from the license of the rest of the repository.

Board dimensions come from Waveshare's published drawing and 3D model of the ESP32-S3-Touch-LCD-1.46.
