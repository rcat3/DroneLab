# Build Guide

<img src="../images/katcorp_mark.png" width="72" align="left" alt="KatCorp">

**KatCorp Drone Systems**<br>DroneLab: Owner Assembly Instructions

<br clear="left">

DroneLab units aren't sold.  They're built by their owners, from a Waveshare display board, a battery, a 3D printed housing and a handful of screws.  Nothing needs soldering: the battery and the speaker plug straight into the board.  This guide takes you from nothing to a unit in your mask.

## The steps

1. **[Choose a model](#choose-a-model)** (below).
2. **Order the parts** and **print the housing**: see your model's page, [speaker model](speaker-housing.md) or [low-profile model](low-profile-housing.md).  The board takes a week or two to arrive from most shops, so order first and print while you wait.
3. **Put it together**, on the same page.
4. **[Install the firmware](../building-firmware.md)** from a computer, over USB.  This can be done before the board goes into the housing, or after: the USB-C port stays reachable.
5. **[Set it up](first-start.md)**: turn the picture the right way round, level it in the mask, and load your own images and sounds.
6. **[Install the app](../installing-the-app.md)** on an Android phone, if you want [comms](../features/comms.md), recording, or to run it from your phone.

## Choose a model

![The two models, to scale: the speaker model (left) and the low-profile model (right)](../images/housings_to_scale.png)

| | [Speaker model](speaker-housing.md) | [Low-profile model](low-profile-housing.md) |
|---|---|---|
| Voice effects and sound | Yes | No speaker |
| Everything else (images, visualizers, comms, Lovense, terminal, remote) | Yes | Yes |
| Battery | 2000 mAh, about 13.5 hours (9.5 with comms on) | 700-850 mAh, about 4.5-5.5 hours |
| Stands out of the mask | About 33 mm | About 23 mm |
| Levelling | A turning collar: hold the display level and screw the collar in | The whole housing screws in; set once in the design |
| Printed parts | 7, one of them in TPU, and an optional USB port cover | 3, and an optional USB port cover |
| Status | Built, worn and working | Printed, waiting on parts for its first assembly |

**Pick the speaker model** if you want the voice effects: they're the headline feature, and the comms send your voice through them.  **Pick the low-profile model** for a slimmer, simpler, cheaper unit that still shows images, lights up as you talk, and does comms and device control.  (Comms on the low-profile model still works: your voice goes to the others through the effect, you just don't hear it out loud.)

## What you'll need

Each model's page has its own parts list.  On top of that:

- **A 3D printer** that prints PLA, and ideally TPU for the speaker model's gasket and the optional USB port cover (they can be PLA at a pinch, or the gasket cut from craft foam).  No special settings, but the [test prints](speaker-housing.md#2-print-the-parts) are worth doing first on a printer you haven't used for these before.
- **Small tools:** a hex key or screwdriver to fit M2 screws, a craft knife, scissors and a toothpick.
- **A USB-C cable that carries data**, not just charging, and a computer (Linux, macOS or Windows) to [install the firmware](../building-firmware.md).
- **A micro SD card** (optional), for your own images, sounds and Lovense patterns.
- **A compatible gas mask**, of course: the housings are made to fit the voice port of the MSA Millennium (an MSA trademark; DroneLab isn't made or endorsed by MSA).  The housing screws into its voice port in place of the cover.  With it fitted, the mask is a costume, not a respirator: don't rely on it for protection.

## About the board

Both models are built around the [Waveshare ESP32-S3-Touch-AMOLED-1.75](https://docs.waveshare.com/ESP32-S3-Touch-AMOLED-1.75).  Order the **bare board**, not the -B version, which comes in its own case.  The -G version, with GPS, works too, but its GPS isn't used.  The [board notes](../hardware/waveshare_esp32s3_touch_amoled_1_75.md) have the technical details, for the curious.

## Also available

- **[Travel case](../../hardware/boards/waveshare_esp32s3_touch_amoled_1_75/travel_case/):** a hinged, clip-shut case for either model, shaped to it, that prints with no supports.  The speaker model's case is printed and works; the low-profile model's is designed, not printed yet.
