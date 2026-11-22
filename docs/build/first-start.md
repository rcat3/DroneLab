# First Start

<a href="../../README.md#about-katcorp"><img src="../images/katcorp_mark.png" width="72" align="left" alt="KatCorp"></a>

**KatCorp Drone Systems**<br>DroneLab: Commissioning Your Unit

<br clear="left">

With the unit built and the [firmware installed](../building-firmware.md), a few minutes of setup gets it ready to wear.

Back to the [Build Guide](README.md).

## 1. Charge it

Plug a USB-C cable into the port on the right side (pull out the port's cover by its notch first, if you fitted one).  Any USB port or phone charger will do.  A lightning bolt beside the battery's charge, on the *Brightness* page in Settings, shows it's charging.  From flat, the speaker model's battery takes about 5.5 hours, and the low-profile model's about 2.5.

The board learns its own battery as it goes.  The first time it runs from a full charge until it switches itself off, it learns that battery's curve, and the percentage is more accurate from then on (see [Battery Log](../features/settings.md#battery-log)).

## 2. Turn it on

Press `PWR`, the lower button on the left side, marked with a power symbol.  The DroneLab logo shows while it starts.  Hold `PWR` for 2 seconds to turn it off.

The first time a new unit starts, it asks **Which model is this?**  Tap **Speaker** for the speaker model, or **Low-profile** for the low-profile model, which has no speaker: the features that need one are left out.  It only asks once.  To change it later, it's **Model** on Settings' **Setup** page (see [Model](../features/settings.md#model)).

> **Photo to come:** the left side of the speaker model, with the `PWR` and `BOOT` plungers and their engraved marks, and the micro SD slot.

## 3. Find your way around

Swipe **up and down** to move between features, and **left and right** between a feature's pages.  Settings is the last feature.  See [Using the Display](../using-the-display.md).

## 4. Check the picture's the right way up

<a href="../features/settings.md#setup"><img src="../images/screens/settings_setup.png" width="180" align="right" alt="The Setup page: Rotation set to 180 degrees, the model, and the Level button"></a>

The picture should be upright with the speaker below the display, or on the low-profile model, with the USB-C port on the right.  In the housing, the board sits turned from its usual way up, and the firmware already turns the picture to match: Rotation starts at 180°.

If the picture isn't upright (on a board that's been used before, say, which keeps its old setting), swipe to **Settings**, then to the **Setup** page, and tap the **Rotation** that puts it upright: 180° in both housings.

<br clear="right">

## 5. Level it in the mask

<a href="../features/level.md"><img src="../images/screens/settings_level.png" width="180" align="right" alt="The Level"></a>

Screw the unit into the mask, put the mask on (or set it upright on a head form), and tap **Level** on Settings' **Setup** page.  The line across the screen stays level with the ground, and turns green when the display is within a degree of level.  Swipe to close it.

- **Speaker model:** turn the housing on its collar until it's level.
- **Low-profile model:** it should be level once screwed in.  If it's a little crooked, see `lp_phase_test` in the [design's README](../../hardware/boards/waveshare_esp32s3_touch_amoled_1_75/README.md#test-prints-1).

## 6. Test the seal (speaker model)

<a href="seal-test.md"><img src="../images/screens/seal_test_result.png" width="180" align="right" alt="The Seal Test's results"></a>

The speaker and the microphones share one small housing, so how much of the speaker gets back into the microphones decides how loud the voice effects can go before they feed back.  The **Seal Test** page, the last in the **Voice** feature, checks it in about 20 seconds.

Screw the unit into the mask, put the mask on, somewhere quiet, and tap **Start**.  Keep quiet and still while the screen says **Quiet**, then after the beep, say **"aaah"** steadily until it finishes.  It shows how far over full volume the voice effects can go before they feed back, as **Spare**, and whether the two microphones match, as **Mics**, each *good*, *fair* or *check*, and what to look at if one isn't good.

See [The Seal Test](seal-test.md) for what each result measures, the numbers behind the grades, and what to check for each.

<br clear="right">

## 7. Try the voice effect (speaker model)

<br clear="right">

<a href="../features/voice-effects.md"><img src="../images/screens/voice_effect.png" width="180" align="right" alt="The Voice Effect page"></a>

Swipe to the **Voice** feature, and to the **Voice Effect** page.  Pick a preset, and switch **Play on speaker** on.  The **Effect Volume** page, next to it, sets how loud.  Every preset holds at 100% in a finished housing, but anything close in front of the mask reflects sound back into it: if it starts to howl, turn it down.  The `BOOT` button, the upper one on the left side, switches the speaker off and on, to stop feedback quickly.

*Play on speaker* is always off when the unit starts, in case it feeds back.  See [Voice Effects](../features/voice-effects.md).

<br clear="right">

## 8. Add your own images and sounds

Format a micro SD card as FAT32 (most come that way), and make these folders on it:

- `images` for pictures and animated GIFs (PNG, JPG, BMP or GIF).  A 240 x 240 image fills the screen; bigger artwork, up to 466 x 466, looks sharper.  See [Images on the SD card](../features/images.md#images-on-the-sd-card).
- `sounds` for WAV, MP3 or FLAC files (speaker model).  See [Sound](../features/sound.md#sounds-on-the-sd-card).
- `patterns` for your own Lovense patterns.  See [Lovense](../features/lovense.md#patterns-on-the-sd-card).

Put the card in the slot on the left side and restart the unit: it reads the card while the logo shows.

## 9. Pick what it shows at startup

In Settings, **Startup** picks what's on screen when the unit turns on: **Images**, **Visualizer**, **HiveMind** or **Terminal**.  With **Images**, pick which image in the list under them.

## 10. Connect your phone (optional)

[Install the DroneLab app](../app/installing.md) on an Android phone, and pair it with the unit, for [comms](../features/comms.md), recording, sending messages and running the unit from the phone.  Without the app, any phone can run it through the unit's [WiFi hotspot](../features/phone-remote.md).

## Something wrong?

- **The picture's shifted, or touches land in the wrong place:** connect it over USB, run `idf.py ... monitor` as in [Installing the Firmware](../building-firmware.md#4-flash-it), and [open an issue](https://github.com/rcat3/DroneLab/issues) with the log.
- **It restarted by itself:** see [Troubleshooting](../building-firmware.md#troubleshooting).
- **The voice effect howls at low volume:** run the [Seal Test](#6-test-the-seal-speaker-model), and check what it points to.
