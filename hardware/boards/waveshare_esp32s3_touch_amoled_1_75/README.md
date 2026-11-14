# MSA Millennium Housings for the ESP32-S3-Touch-AMOLED-1.75

3D printable housings that screw the [Waveshare ESP32-S3-Touch-AMOLED-1.75](https://www.waveshare.com/esp32-s3-touch-amoled-1.75.htm) into the voice port of an MSA Millennium mask.  They're for the bare board, not the -B version that comes in its own case.  There are two:

- **The speaker housing** (`msa_speaker_housing.scad`): a speaker in a pod below the display, for sound and voice effects, and a 2000 mAh battery in a chamber behind it, with a turning collar.
- **The low-profile housing** (`msa_low_profile_housing.scad`): no speaker, a flat 700-850 mAh battery in a shallow chamber, and the thread fixed to the back.  It stands about 23 mm out of the mask, where the speaker housing stands about 33 mm out, and it has fewer parts and screws.

This README is about the design files.  For the whole build, with the parts to buy, wiring and putting it together, see the [build guide](../../../docs/hardware/waveshare_esp32s3_touch_amoled_1_75.md).

## The speaker housing

**Status: printed and working.**  It's modeled from Waveshare's 3D model and drawing of the board, and its clearance from the mask from a 3D scan, and the first print fits the board and the mask.  The display, touch, microphones, speaker, micro SD card and level all work in it.  A 2000 mAh battery runs it for about 13.5 hours.  The current version, with the battery standing upright and the microphones in a sealed cell of their own (`mic_cell`), has been printed and worn too.

The board has its own amplifier, speaker socket, microphones and battery charger, so the speaker and the battery plug straight into it.  There are no other boards to wire in.

### How it goes together

- The board sits in a cup at the front, with its glass flush with the front, and screws to the cup's back plate with three M2 countersunk screws (about M2 x 5) into the standoffs on its back.
- It's turned a quarter turn from its usual way up, so its USB-C port faces right, out through the side of the housing.  The port is in a pocket in the side, only about 3 mm behind the pocket's floor, so any cable's plug reaches it, not just the slimmest.  Its side buttons and micro SD slot are on the left, and its pin header is at the top.  Set Rotation to 90 degrees in the settings to match.
- The speaker sits in a shallow pod below the display.  Right below the voice port is the mask's filter mount, so the pod is only as deep as the speaker needs, and the **chin** behind it slopes back to the body, over the mount.  From the scan, the chin clears the mount by about 4.7 mm at its closest, at the mount's top edge, and the pod by about 8 mm.
- The speaker goes in from the back of the pod before the chin goes on, and the adhesive frame on its front sticks it to the grille.  Its wire comes out of a notch in the middle of either short side of the pocket, and runs in a 2 mm gap behind it to the pocket's inner end, where an opening 7 mm wide lets its plug through into the chamber, to the board's speaker socket.  That end of the pocket reaches over the chamber's edge, and a 1.6 mm floor (`pocket_floor`) closes it off, so the opening is the only way through.  Plasticine seals the opening around the wire, and fills the gap behind the speaker, so less of the speaker reaches the microphones.
- The chamber behind the board holds a 2000 mAh battery, standing upright and taped to the back.  The back's four screws are either side of it.  The board's speaker and battery sockets stand up off the back of the board, and their plugs go in through openings in the back plate, from the chamber.  The two sockets look the same, and the plate hides their labels, so a speaker and a battery are engraved in the plate beside them (`socket_marks`).
- The microphones are on the back of the board, near its USB-C edge, and listen backwards, so in the housing they're on the right.  They have a cell of their own (`mic_cell`): the strip of the chamber beside the battery, walled off from the rest of it by ribs on the back plate, and closed by the battery's side.  The voice port opens straight into it, through an opening in the back beside the battery.  The sockets, their plugs and the speaker's wire are all on the other side of the ribs.  In front of the battery, the ribs stop 0.5 mm short of it, for foam tape that seals them against it.
- The board sits on its standoffs 3.5 mm in front of the back plate, so the gap behind it reaches the USB-C and micro SD openings, and the sockets' openings into the chamber.  A sleeve around each microphone's hole reaches up to 1.5 mm short of the board, and a small foam ring on it seals it against the board, so the microphones hear the cell and nothing else.
- The voice port thread is on a collar that turns freely on the back, so the housing can be held level while the collar is screwed in.  It's the same collar the 1.46" board's [deprecated speaker housing](../../deprecated/waveshare_esp32s3_touch_lcd_1_46_speaker_housing/) used, from [`../../masks/msa_millennium`](../../masks/msa_millennium/).

### Parts

**Materials:** print the `gasket` and the `usb_plug` in TPU.  Everything else is PLA or PLA+.

- **`body`** - The display cup and the speaker pod.  Like the 1.46" speaker housing's body, it'll probably print best standing on one of its sides with tree supports.  The microphone cell's ribs hang off the back plate in front of the battery, so they need supports too.
- **`chin`** - Closes the back of the pod and slopes back to the body.  It prints on the flat face that meets the pod, with no supports.
- **`back`** - Closes the chamber, with the posts the collar turns on.  Use 4 or more walls so the posts are solid.
- **`collar`**, **`washer`** and **`gasket`** - The turning collar, as on the 1.46" board's deprecated speaker housing.  The gasket is TPU, or cut from 1 mm rubber or craft foam.
- **`plungers`** - Two pins that press the board's side buttons through the wall.  Behind each one, a small mark is engraved in the side wall (`button_marks`): a power symbol for PWR, the lower one, nearer the pod, and a download arrow for BOOT, which is held down to flash the board.
- **`usb_plug`** - Covers the USB-C port when it's not in use, flush with the outside of the housing.  A tongue on its back pushes into the slot for the plug, and the notch at its top edge is for a fingernail to pull it out.  It's a tight push fit, best printed in TPU.  In PLA or PETG, loosen it with the second number in `usb_tongue` if it's too tight.
#### Test prints

These are worth printing first on a new printer (`./render.sh tests`):

- **`pod_test`** - The pod on its own, to check the speaker's fit and hear how it sounds.
- **`lens_fit`** - The front 3 mm of the body around the display.  The glass should drop in with a little play, but not rattle.  Adjust `clearance` if it doesn't.
- **`plunger_test`** - Plungers in three lengths, two of each, standing 1.3, 1.8 and 2.3 mm out of the housing.  Set `plunger_proud` to the one that works best.

#### Screws

| Screws | How many | Where they go |
|---|---|---|
| M2 x 5 countersunk | 3 | Through the display cup's back plate into the standoffs on the back of the board, from inside the chamber.  Their heads sit flush. |
| M2 x 8 socket head | 4 | Hold the chin onto the pod, from its sloped underside, deep in counterbores, into the pod's walls. |
| M2 x 8 socket head | 4 | Hold the back onto the body.  They cut their own thread in the body. |
| M2 x 6 socket head | 4 | Hold the two halves of the washer to the ends of the collar's posts, inside the collar.  Stop when the collar turns firmly but smoothly. |

The board's charger (an AXP2101) charges at up to 400 mA, set by the firmware, so there's no resistor to change.

#### Check these first

These come from the 3D model, not from a print, so check them with test prints:

- The glass's fit in the cup (`clearance`), with `lens_fit`.
- That the micro SD card lines up with its slot.  If it doesn't, move the slot with `sd_shift`.  The 1.46" board's slot needed moving by 1 to 1.5 mm.
- That the speaker and battery plugs go into their sockets from behind, as the model suggests.  If the sockets turn out to face sideways, the openings in the back plate need to be bigger.
- That nothing on the back of the board, beside each microphone, gets in the way of its sleeve (`mic_sleeve`): 4 mm across, around the microphone's hole, and reaching to 1.5 mm short of the board.  Each microphone is a small part about 1 mm tall, and the foam ring takes up the rest.

## The low-profile housing

**Status: designed, not printed yet.**  It's the speaker housing without the pod, with a smaller battery, and with the thread fixed to the back in place of the turning collar.  The display's cup, the micro SD and USB-C openings, the plungers, the USB-C plug, the microphones' sleeves and the marks are the speaker housing's, so they've been checked with a print.  What's new is the battery's place, the thread's position (`thread_phase`), the grip and the back.

### How it goes together

- The board sits in the cup and screws to its back plate, as in the speaker housing, turned a quarter turn with its USB-C port in a pocket on the right, and its side buttons and micro SD slot on the left.  Set Rotation to 90 degrees in the settings to match.
- Behind the board is a chamber 7.1 mm deep, for a 603040 battery (6 x 30 x 40 mm, about 700-850 mAh) lying on its side and taped to the back.  It fits between the board's battery socket below it, its pin header above it, and the microphones to its right.  The battery's plug goes into the socket from behind, beside the battery rather than in front of it, so the battery can sit just behind the back plate, with 0.8 mm to spare (`battery_gap`) for foam tape.  Its outline is engraved on the front of the back, to show where to tape it.  That's what makes the housing thin.  It runs the board for about 4.5-5.5 hours.  The board charges it at 400 mA, about half its capacity an hour, the standard rate in LiPo datasheets, and it charges in about 2.5 hours.
- There's no speaker.  The board's speaker socket is left empty, and the speaker and battery marks beside the two sockets show which is the battery's.  The sound player and the voice effects need a speaker, so this housing is for images, the voice displays, Lovense control and the phone remote.
- The microphones don't need the speaker housing's cell, walled off from the chamber, as there's no speaker to keep out.  They keep its sleeves, sealed against the board by foam rings, so they hear the chamber, and not the gap behind the board, which is open to the outside through the USB-C and micro SD openings.  The chamber opens into the voice port through an opening in the back beside the battery, about 4 x 23 mm.
- The thread is part of the back, so the whole housing turns as it's screwed in.  Where it ends up depends on where the thread starts, which is the same on every Millennium, so `thread_phase` turns the thread to bring the housing level.  It's 123 degrees, from the deprecated [1.28" housing](../../deprecated/waveshare_touch_lcd_1_28/), whose thread is fixed to its back in the same way.  Shallow ridges around the back of the side (`grip_count`, `grip_depth`) give a grip for screwing it in.
- The back is held on with four M2 x 8 socket head screws, whose heads sit in counterbores under the mask's rim.  They're placed around the battery in a lopsided pattern, so the back only goes on one way, with the thread and the opening behind the microphones in the right place.

### Parts

**Materials:** print the `usb_plug` in TPU.  Everything else is PLA or PLA+.

- **`lp_body`** - The display cup and the chamber.  It prints back down, with supports only for the openings in the side.
- **`lp_back`** - Closes the chamber and carries the thread.  It prints on its front, with the thread pointing up, so the thread needs no supports.  Use 4 or more walls so the thread is solid.
- **`plungers`** and **`usb_plug`** - The same as the speaker housing's.

#### Test prints

- **`lp_lens_fit`** - The front 3 mm of the body around the display, to check the glass's fit.
- **`lp_phase_test`** - The thread with a scale on its front.  Screw it all the way into the mask, hold the mask upright, and read the number at the top.  If it isn't 123, set `thread_phase` to it.  If the housing only sits a little crooked, there's no need for the test: if it sits turned clockwise, make `thread_phase` smaller by that many degrees, and if it's turned counter-clockwise, make it larger.
- **`plunger_test`** - The same as the speaker housing's.

#### Screws

| Screws | How many | Where they go |
|---|---|---|
| M2 x 5 countersunk | 3 | Through the display cup's back plate into the standoffs on the back of the board, from inside the chamber.  Their heads sit flush. |
| M2 x 8 socket head | 4 | Hold the back onto the body.  They cut their own thread in the body. |

#### Check these first

- That the battery's plug and its wires fit beside the battery, below it, with the battery's own leads (`plug_clear`).
- That the housing ends up level when it's screwed in (see `lp_phase_test`).
- That the grip is enough to screw it in and out.

## Files

- `msa_speaker_housing.scad` - The speaker housing, in [OpenSCAD](https://openscad.org/).  All of the dimensions are named settings at the top.  Its preview shows the mask's filter mount and hose in red, to check the housing clears them.
- `msa_low_profile_housing.scad` - The low-profile housing.
- `housing_parts.scad` - What the two housings share: the chamber's layout, the microphones' cell and sleeves, the plungers, the USB-C plug and the engraved marks, and their settings.
- `board.scad` - The board's dimensions, measured from Waveshare's 3D model.
- `render.sh` - Renders the parts to STL files.

## Making the STL files

Run `./render.sh` in this folder to render both housings' parts to the `stl/` folder.  It needs [OpenSCAD](https://openscad.org/).  `./render.sh speaker` or `./render.sh low_profile` renders one housing, `./render.sh tests` the test prints, and `./render.sh body chin` just those parts.  The low-profile housing's own parts are named `lp_body` and so on, so their files don't mix with the speaker housing's.  A single part can also be rendered by hand with, for example, `openscad -D 'part="body"' -o body.stl msa_speaker_housing.scad`.  The parts are all turned the right way up to print.

## Parts to buy, wiring and putting it together

See the [build guide](../../../docs/hardware/waveshare_esp32s3_touch_amoled_1_75.md).

## Credits and License

The housings are based on the 1.46" board's speaker housing, now in [`../../deprecated`](../../deprecated/waveshare_esp32s3_touch_lcd_1_46_speaker_housing/), which in turn is based on [RP2040-LCD-1.28-MSA](https://www.printables.com/model/538771-rp2040-lcd-128-msa) by whyrlpool.

Like the designs it's based on, everything in this folder is licensed under the [Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License](https://creativecommons.org/licenses/by-nc-sa/4.0/).  This is separate from the license of the rest of the repository.

Board dimensions come from Waveshare's published drawing and 3D model of the ESP32-S3-Touch-AMOLED-1.75.
