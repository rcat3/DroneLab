# Building the Speaker Model

<img src="../images/katcorp_mark.png" width="96" align="right" alt="KatCorp">

*KatCorp Drone Systems, DroneLab speaker model: owner assembly instructions.  Status: built, worn and working.*

![The speaker model](../images/speaker_housing_1_75.png)

The full unit: the display, a speaker facing out in a pod below it for [voice effects](../features/voice-effects.md) and [sound](../features/sound.md), and a 2000 mAh battery in a chamber behind, for about 13.5 hours.  A turning collar carries the thread, so you hold the display level while you screw the collar into the mask.  It stands about 33 mm out of the mask, and the pod's sloped chin clears the filter mount below the voice port.

Back to the [Build Guide](README.md).

## 1. Order the parts

> **Photo to come:** all the parts for the speaker model laid out: the board, speaker, battery, printed parts, screws, plasticine and foam.

| Part | How many | Notes |
|---|---|---|
| [Waveshare ESP32-S3-Touch-AMOLED-1.75](https://docs.waveshare.com/ESP32-S3-Touch-AMOLED-1.75) | 1 | The **bare board**, not the -B version in its own case |
| Speaker module | 1 | A sealed box 35 x 25 x 6.5 mm with an oval cone on the front, 4 ohm, with an MX1.25 2-pin plug (or one crimped on) |
| LiPo battery, 103450 size | 1 | 3.7 V, 2000 mAh, no bigger than 50.5 x 34 x 9.9 mm, with an MX1.25 2-pin plug |
| M2 x 5 countersunk screws | 3 | Hold the board in |
| M2 x 8 socket head screws | 8 | Four hold the chin on, four hold the back on |
| M2 x 6 socket head screws | 4 | Hold the washer that keeps the collar on |
| Plasticine | About 20 g | Modelling clay that never hardens, a lump about the size of a walnut.  It seals the speaker off from the microphones, and holds the battery |
| Thin foam tape | A few cm | About 1 mm thick, double-sided |
| Soft foam sheet | A scrap | About 2 mm thick, such as craft foam |
| Open-cell foam | A small block | Soft and spongy, that air passes through, as used behind speaker grilles |

> **Check the battery's polarity.**  MX1.25 batteries aren't all wired the same way round.  Before plugging one in, check its red wire goes to the positive side of the board's battery socket, as Waveshare's documentation for the board shows it, and swap the pins in the plug if it doesn't.  A battery plugged in backwards can damage the board.

## 2. Print the parts

The design is [`msa_speaker_housing.scad`](../../hardware/boards/waveshare_esp32s3_touch_amoled_1_75/msa_speaker_housing.scad), in [OpenSCAD](https://openscad.org/).  To make the STL files, run `./render.sh speaker` in [`hardware/boards/waveshare_esp32s3_touch_amoled_1_75`](../../hardware/boards/waveshare_esp32s3_touch_amoled_1_75/) (or open the file in OpenSCAD, set `part`, render and export).  The parts come out turned the right way up to print.

**Print the test pieces first** (`./render.sh tests`), on a printer you haven't printed these on before.  They're small and quick, and save a wasted body:

- **`lens_fit`**: the front of the housing around the display.  The board's glass should drop in with a little play, but not rattle.  If it doesn't, change `clearance` in [`board.scad`](../../hardware/boards/waveshare_esp32s3_touch_amoled_1_75/board.scad).
- **`plunger_test`**: button plungers in three lengths.  Pick the length that presses the board's buttons best, and set `plunger_proud` to it.
- **`pod_test`**: the speaker's pod on its own, to check the speaker fits.

Then the parts:

| Part | Material | How to print it |
|---|---|---|
| `body` | PLA or PLA+ | On one of its sides, with tree supports.  The ribs inside need supports too |
| `chin` | PLA or PLA+ | On its flat face, no supports |
| `back` | PLA or PLA+ | As it comes out, with 4 or more walls so the posts are solid |
| `collar` | PLA or PLA+ | Grip down, as it comes out |
| `washer` | PLA or PLA+ | Two halves, flat |
| `gasket` | TPU | Flat.  Or cut it from 1 mm rubber or craft foam |
| `plungers` | PLA or PLA+ | Two small pins |
| `usb_plug` | TPU | A cover for the USB-C port.  In PLA, loosen it with the second number of `usb_tongue` |

The [design's README](../../hardware/boards/waveshare_esp32s3_touch_amoled_1_75/README.md) explains how the housing works, with every setting worth knowing about.

## 3. Put it together

Here's how the parts go together, front to back: the board drops into the front of the body, the speaker into the pod and the chin behind it, then the battery, the back, the gasket, the collar, and the washer, through the collar's threaded end.

![The speaker model, pulled apart in the order it goes together](../images/speaker_housing_1_75_exploded.png)

### The board

1. **Fit the plungers.**  Push the two plungers into their holes in the side of the body, from inside the display's pocket.  The marks beside them on the outside are a power symbol for `PWR` and an arrow for `BOOT`.
2. **Seal the microphones.**  Cut two small squares of the soft foam sheet, about 4 mm across, and poke a hole through the middle of each with a toothpick.  Put one over the end of each of the two microphone sleeves standing up from the back plate inside the pocket, lined up with its hole.  They seal the microphones against the board, so they only hear the voice port.
3. **Fit the board.**  Lay it in the pocket, glass forward, with its USB-C port towards the side opening on the right, and screw it to the back plate from behind with the three M2 x 5 countersunk screws.

   > **Photo to come:** the inside of the display's pocket, with the foam squares on the microphone sleeves, before the board goes in.

### The speaker

4. **Feed the speaker's plug through.**  Push the speaker's plug through the opening at the inner end of the speaker's pocket, into the chamber behind the board.
   > **Photo to come:** the speaker's plug going through the opening at the inner end of its pocket.

5. **Fit the speaker.**  Stick it into its pocket from the back of the pod, cone facing out through the grille, with its wire in the notch in the side of the pocket, and run the wire behind the speaker to the opening.
6. **Pad it with plasticine.**  Spread a thin layer of plasticine over the back of the speaker, so it fills the space between the speaker and the chin.
7. **Close the pod.**  Screw the chin on with four M2 x 8 screws, from its sloped underside.

   > **Photo to come:** the speaker in its pod from behind, with plasticine over it, before the chin goes on.

### The chamber

8. **Plug in the speaker.**  Plug it into the board's speaker socket, through the opening in the back plate marked with a speaker.
9. **Seal the speaker off.**  Press plasticine into the opening between the speaker's pocket and the chamber, all round the wire.  The microphones listen into the chamber, so the less of the speaker that reaches it, the louder the voice effect can go before it feeds back.  Keep plasticine off the board and out of its sockets.
10. **Fill the microphones' cell.**  Stick foam tape along the tops of the ribs on the right, which wall off the microphones.  Cut a block of the open-cell foam to fill the cell between the ribs and the wall, and push it in.  It must be open-cell foam, which sound passes through: the microphones hear you through it.
11. **Line the chamber with plasticine.**  Press plasticine around the inside of the chamber's wall, all the way round where the battery will go, in a band about as deep as the battery.  It fills the space around the battery, so less of the speaker's sound echoes around, and holds the battery in place.  Keep it off the sockets, the openings in the back plate and the screw holes.
12. **Fit the battery.**  [Check its polarity](#1-order-the-parts), plug it into the socket marked with a battery, and press it in, standing upright, inside the ring of plasticine, so its side presses on the foam tape on the ribs.  Press a little more plasticine into any gap where the ribs meet the battery, so the microphones' cell is sealed.

    ![The chamber, with the battery out: plasticine around the wall, and foam in the microphones' cell, seen from the back](../images/speaker_housing_1_75_chamber.jpg)

### The back and the collar

13. **Close the back.**  Screw it on with four M2 x 8 screws.  They cut their own thread in the body.
14. **Fit the gasket and collar.**  Put the gasket over the four posts on the back, then the collar, grip first, so its thread points away from the housing.
    > **Photo to come:** the back with the gasket and collar on, the washer halves beside it.

15. **Fit the washer.**  Drop each half of the washer into the collar through its threaded end, line its holes up with two of the posts, and screw it down with two M2 x 6 screws.  Tighten them evenly, and stop when the collar turns firmly but smoothly: the gasket's friction is what keeps the housing from turning by itself once it's in the mask.
16. **Fit the USB plug.**  Push the USB plug into the port's pocket on the right side.  The notch at its top edge is for a fingernail to pull it out again.

## 4. Into the mask

> **Photo to come:** the finished speaker model screwed into a mask.

Unscrew the mask's original voice port cover.  Hold the housing level, display forward, with the pod at the bottom, and turn the collar's grip to screw it into the port until it's snug.  If the display ends up a little crooked, hold the collar still and turn the housing.

The thread screws into a metal adapter in the mask, which itself screws into the mask.  Hold that adapter still when you unscrew the housing, so it doesn't come out with it.

## Next

[Install the firmware](../building-firmware.md), if you haven't already, then [set it up](first-start.md).
