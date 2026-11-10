# MSA Millennium Housing for the RP2040/RP2350-Touch-LCD-1.28

A 3D printable housing that screws the [Waveshare RP2040-Touch-LCD-1.28](https://www.waveshare.com/wiki/RP2040-Touch-LCD-1.28) or [RP2350-Touch-LCD-1.28](https://www.waveshare.com/wiki/RP2350-Touch-LCD-1.28) into the voice port of an MSA Millennium mask, with the battery and a power switch inside.

This README is about the design files.  For the whole build, with the parts to buy, wiring, putting it together and charging, see the [build guide](../../../docs/hardware/waveshare_touch_lcd_1_28.md).

**Status: printed and working with the RP2040 board, in PLA+.**  It's modeled from Waveshare's 3D model of the RP2040 board, then adjusted from test prints.  Their model of the RP2350 board leaves out the touch panel and the battery socket, so it's taken to be the same apart from its thicker PCB.  The RP2350 board hasn't been tried in it yet.

## How it goes together

It's two printed parts and no screws:

- **The body** is one piece, with the voice port thread on its back.  Nothing sticks out of the back, so it screws all the way in and sits flat on the port.
- **The board** drops into the body from the front and rests on three small pads behind the edge of its PCB.
- **The battery** sits behind the board, in a closed compartment inside the thread, in a shallow cradle in the floor so it can't slide around.  There's 1 mm between the top of the battery and the tallest parts on the back of the board, for a piece of 1 mm foam tape on top of the battery.  The board presses it down, so the battery stays put and nothing on the board can rub against it.
- **A slide switch** in the side wall turns the battery on and off.  It sits in a pocket in the wall, with its lever out through a slot, so there's nothing to drill.  A catch holds it in: a little finger either side of the pocket, standing up from near the back of the body, with a hook that reaches into the pocket.  The switch pushes them apart as it goes in, and they spring back behind it.
- **The bezel** goes over the front of the body, flush with the glass, so the front is one smooth surface.  A thin lip on its inside edge holds the board in by the wider part behind the glass.  It twist-locks on: line up the small arrow on its edge with the one on the body, push it down so the three lugs inside it drop into their slots, and turn it clockwise about 25 degrees until it clicks.  The grooves pull it down tight as it turns.  To take it off, turn it back and lift it off.  Nothing has to stretch, so it doesn't crack.
- **The USB-C port** is reachable through a pocket in the right side (seen from the front), for charging and flashing.  The board is turned a quarter turn so the port isn't facing the mask's filter mount, below the voice port.  Set the display's Rotation to 90 degrees to match.

The housing stands about 11.6 mm out of the mask, with either board.

### Making it sit level

The whole housing turns as it's screwed in, so how it ends up sitting depends on where the thread starts, which is the same on every Millennium mask.  `thread_phase` turns the thread on the body so the housing ends up level.

1. Print `phase_test`, which is just the thread with a scale around its front.
2. Screw it all the way into the mask.
3. Hold the mask upright and read the number at the top of the scale.
4. Set `thread_phase` to that number in `msa_housing.scad`, and print the body.

The numbers count up clockwise from the arrow, seen from the front.  If you read between them, the number is the arrow's angle counter-clockwise from the top.  `thread_phase` is already set from a housing screwed into a mask, and as the thread starts in the same place on every Millennium, you shouldn't need to print `phase_test` unless yours doesn't sit level.  If it's only a little out, there's no need for `phase_test` either: if the housing sits turned clockwise, make `thread_phase` smaller by that many degrees, and if it's turned counter-clockwise, make it larger.  The USB-C port should be exactly at the right.

## Files

- `msa_housing.scad` - The design, in [OpenSCAD](https://openscad.org/).  All of the dimensions are named settings at the top.  Its preview shows the board, the battery, and the mask's filter mount in red.
- `board.scad` - The boards' dimensions.  Set `board` to `"rp2040"` or `"rp2350"` here.
- `render.sh` - Renders all of the parts to STL files in `stl/`.
- `travel_case/` - A hinged case to carry the housing in, with the board in it.

## Parts

Set `board` in `board.scad` to `"rp2040"` or `"rp2350"` first, then run `./render.sh` in this folder to render the housing's parts to the `stl/` folder.  It needs [OpenSCAD](https://openscad.org/).  `./render.sh tests` renders `phase_test` and `fit_test`, and `./render.sh body bezel` just those parts.  A single part can also be rendered by hand with, for example, `openscad -D 'part="body"' -o body.stl msa_housing.scad`.  The parts are all turned the right way up to print.

There are no screws: the bezel twist-locks on and the switch clicks into place.

**Materials:** PETG is best for the `body`, as the switch's catch flexes; PLA+ works, but the catch is more likely to break.  The `bezel` and the test prints are fine in PLA or PETG.

- **`body`** - Printed back down.  Its front is hidden under the bezel, so printing it on its side gains nothing, and makes the USB-C pocket rough where the supports were.  The top of the pocket bridges, or use a little support there.  The switch's pocket and its catch print without supports: the fingers stand upright, and the top of the pocket bridges across.  If your slicer adds supports there anyway, block them, as they can't be got out of the pocket.
- **`bezel`** - Printed front down, with no supports.
- **`phase_test`** - The thread with a scale on its front, for `thread_phase` (see above).
- **`fit_test`** - The front of the body without the thread, to check the board, the switch and the bezel fit before printing the whole body.

### Check these first

These have been checked on a print with the RP2040 board, but printers differ, so check them with `fit_test`:

- The board's fit in its pocket (`clearance`) and on its pads.  If the board rattles once the bezel is on, the pads are too low.  If the bezel won't turn to lock, they're too high.  Two posts behind the board, either side of the USB-C port's metal shell, keep it from turning, so the port stays in line with its opening.  If the port won't go down between them, make `usb_key_gap` bigger, and if the board still turns, smaller.
- With the RP2350 board, its thickness: from the front of the glass to the back of the PCB should be about 5.5 mm (`pcb_back_z` in `board.scad`).
- The switch's fit in its pocket (`switch_body`), that the lever moves freely in its slot, and that the catch clicks behind it (`catch_hook`, and `catch_finger` for how stiff the fingers are).  If the catch is too stiff or breaks, print the body in PETG, which bends more than PLA before it breaks.
- That the bezel is flush with the glass.  The 3D model has the glass standing 0.5 mm in front of the board behind it (`glass_t` in `board.scad`), and the bezel's lip is set from that.
- How firmly the bezel locks.  `lock_play` sets how tight the grooves pull it down, and `lock_detent` how firmly it clicks.

## Parts to buy, wiring and putting it together

See the [build guide](../../../docs/hardware/waveshare_touch_lcd_1_28.md).

## Charge current

The boards charge their battery at 1 A, set by R15 (160k) next to the charger chip, which is several times what a 250-310 mAh battery should take.  Changing R15 to about 560k brings it down to about 0.3 A.  The [build guide](../../../docs/hardware/waveshare_touch_lcd_1_28.md#charging) has the details and other values.

## Travel case

There's a hinged case to carry the housing in, in [`travel_case`](travel_case/).

## Credits and License

The voice port thread is from [RP2040-LCD-1.28-MSA](https://www.printables.com/model/538771-rp2040-lcd-128-msa) by whyrlpool, which adapted it from the [Gas Mask VPU Cover (MSA compatible)](https://cults3d.com/en/3d-model/various/gas-mask-vpu-cover-msa-compatible).

Like the design it's from, everything in this folder (apart from the travel case, which has its own license) is licensed under the [Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License](https://creativecommons.org/licenses/by-nc-sa/4.0/).  This is separate from the license of the rest of the repository.

Board dimensions come from Waveshare's 3D models of the RP2040-Touch-LCD-1.28 and RP2350-Touch-LCD-1.28.
