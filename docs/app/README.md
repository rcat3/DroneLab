# The DroneLab App

The DroneLab app is the phone's half of your display unit.  It links your display unit to the rest of the hive, so you can talk and listen to other drones, sends messages and commands to them, records your voice for videos, runs the display unit's screen from your hand, and keeps the display unit's firmware up to date.  It's for Android phones and tablets.

<p align="center">
<img src="../images/app_hivemind.png" width="260" alt="The HiveMind tab: who's in the hive, with their avatars, and the talk button">
&nbsp;
<img src="../images/app_remote.png" width="260" alt="The Remote tab: running the unit's display from the phone">
</p>

**On an iPhone?**  The app is Android only for now.  An iPhone, or any phone with a web browser, can still run the display unit through its own [WiFi Hotspot Remote](../features/phone-remote.md): what's on the display, its settings, the Lovense toys, the voice effect, sounds and the Terminal.  Talking to the hive, messaging others and recording need the app.

## What it does

- **[HiveMind](hivemind.md)**: talk to other drones and hear them, like a radio, over the internet through a shared server, or display unit to display unit with no signal at all.  Your voice goes out through your voice effect; theirs comes to your headphones, through the phone.
- **[Terminal](terminal.md)**: send text messages to one drone, several, or the whole hive, shown on their display and in their app, with or without your name.
- **[Control](control.md)**: run other drones' [Lovense](../features/lovense.md) toys, if they've allowed you.
- **[Record](record.md)**: record your voice effect to the phone as WAV files, for videos, with a beep to line it up with the camera.
- **[Remote](remote.md)**: everything on the display unit's screen, from the phone, so nobody has to reach the display in the mask.
- **[Firmware updates](firmware-updates.md)**: the app carries the latest firmware for your display unit and offers to put it on.

## Getting started

1. **[Install the app](installing.md)** from the project's releases page.
2. **[Connect it](connecting.md)**: pair it with your display unit, which is all it needs.  If your hive uses a server, join it too, and pick your avatar.
3. **[Talk to the hive](hivemind.md#talking)**: hold the talk button and speak.

## The screen

Five tabs along the bottom, and the status strip along the top of every one:

| Tab | What it's for |
|---|---|
| **HiveMind** | Who's in the hive, and talking to them.  The gear opens *Setup*. |
| **Terminal** | Messages, in and out.  A number on the tab counts the ones you haven't seen. |
| **Control** | Others' Lovense toys. |
| **Record** | Recording your voice, and your recordings. |
| **Remote** | The display unit's own controls, as on its display. |

**Setup**, behind the gear on the HiveMind tab, has what's set once: [connecting](connecting.md) the display unit and the server, your avatar, how you [talk](hivemind.md#setup-talking), [direct mode](hivemind.md#direct-channels), and the [display unit's firmware](firmware-updates.md).  The (i) buttons throughout the app explain each setting.

### The status strip

<img src="../images/app/status_strip.png" width="540" alt="The status strip, numbered: 1 board, 2 server, 3 direct, 4 arrows, 5 battery">

| | Shows | |
|---|---|---|
| 1 | **BOARD** | Green while the app's connected to your display unit over Bluetooth. |
| 2 | **SERVER** | Green while it's connected to the hive's server, for the [cloud link](hivemind.md#two-links-server-and-direct). |
| 3 | **DIRECT** | Green while [direct mode](hivemind.md#two-links-server-and-direct) is on, with how many display units it hears nearby. |
| 4 | **Arrows** | Up, pink: your voice is going out.  Down, green: you're hearing someone.  Down, grey: someone's talking on another direct channel nearby, which you can't hear. |
| 5 | **Battery** | Your display unit's charge, with a bolt while it charges.  It turns red at 15%. |

A grey dot is a link that's off, or not connected.  Tap the strip to open the [links sheet](connecting.md#the-links-sheet), which connects or disconnects each one.

### Other signs

- **TX**, in pink at the top of the HiveMind tab: you're talking.  The talk button glows pink too.
- **A message card** on the HiveMind tab when the hive can't be reached, saying why:
  - *Not linked yet*: the display unit isn't paired, or the server isn't set up.  *Set up* goes to Setup.
  - *Board offline*: the app can't reach your display unit.  It keeps trying by itself.
  - *No link to the hive*: the display unit's connected, but neither the server nor direct mode is.
- **A yellow warning sign** by the channel's name: display units nearby run [a different firmware](firmware-updates.md#display-units-on-different-versions), and can't be heard.
- **An offer to update the display unit**, when the app has newer firmware for it: see [Firmware updates](firmware-updates.md).
- **A banner under the status strip** when a newer version of the app itself is out: see [Updating the app](installing.md#updating).

## More

- [Installing the App](installing.md), and what to do if the phone won't let you.
- [Connecting](connecting.md): pairing, the server, your avatar.
- [HiveMind](hivemind.md), [Terminal](terminal.md), [Control](control.md), [Record](record.md), [Remote](remote.md).
- [Updating the display unit's firmware](firmware-updates.md).
- [HiveMind (Comms)](../features/comms.md): the display unit's side of HiveMind, setting up a server, and how it works underneath.
