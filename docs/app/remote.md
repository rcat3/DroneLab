# Remote

The Remote tab puts your unit's own controls on the phone: what its display shows, its settings, your toys, the voice effect, sounds and the Terminal.  Everything you'd do by touching the display, without touching it.

<img src="../images/app_remote.png" width="300" alt="The Remote tab: what the display shows, and buttons to change it">

Back to [the app](README.md).

## What it's for

Once the unit's screwed into the mask, its display faces outward, where you can't see it or reach it comfortably.  The Remote lets you:

- **Change what the display shows** while you're wearing it: an image, a visualizer, the Terminal, the HiveMind screen.
- **Run the show from your hand**: play a sound, switch the voice effect, turn the voice ring on, start a toy's pattern, without lifting a hand to the mask.
- **Hand control to someone else**: a handler with the phone can run the unit while you wear it.
- **Set it up** in comfort: brightness, rotation, what it shows at startup.

## What's on it

The page is the unit's own, so it always matches the unit's firmware.  It has five tabs:

- **Screen**: what's on the display now, with arrows to step through every page, the visualizer styles, and every feature's pages to jump straight to one.
- **Toys**: your own [toys](../features/toys.md): a slider for each of the screen's controls, the patterns, the reactions, the toys with the channel each output follows, and a big **STOP**.
- **Sound**: the voice effect and its volume, the voice ring, and the sound player.  A low-profile unit has no speaker, so its voice effect isn't here: pick it as *HiveMind voice* in Setup, or on the unit.
- **Terminal**: type a message onto your own display.
- **Setup**: the display's settings: brightness, rotation, what it shows at startup, and the battery.  The same settings are in the app's own Setup too, under [General Setup](#setup-general-setup).

Each tab is described in full in [WiFi Hotspot Remote](../features/phone-remote.md), which is the same page.  The display and the phone control the same things, so each shows what the other does.

## The app, or the WiFi hotspot

There are two ways to reach the same page:

| | **The app's Remote tab** | **The WiFi Hotspot Remote** |
|---|---|---|
| Phones | Android, with the app | Any phone with a web browser: **iPhones**, or someone else's phone |
| Link | Bluetooth, the app's link to the unit | The unit's own WiFi hotspot, joined from the phone's WiFi settings or a QR code |
| The phone's internet | Kept | Lost over WiFi while it's joined (mobile data may still work) |
| Set up | Nothing more: it works once the app's [connected](connecting.md) | Switch on the *WiFi Hotspot Remote* in the unit's Settings, and join it |
| At once | One phone | Up to four phones |

With the app, use the Remote tab: it keeps the phone online, so HiveMind's server link keeps working.  For an iPhone, or to let a friend's phone in without the app, use the [WiFi Hotspot Remote](../features/phone-remote.md).

If the Remote tab says the unit isn't connected, it needs the app linked to the unit first: see [Connecting](connecting.md).

## Setup: General Setup

Setup's **General Setup**, under *Display Unit*, has the display's settings without opening the Remote: its **brightness**, **rotation** and what it shows **at startup**.  They're the unit's own, the same as on its display's Settings and the Remote's Setup tab, so a change in any of them shows in the others.  A link at the top jumps to the Remote tab for everything else.  It's there while the app's connected to the unit.

Its *WiFi hotspot remote* section runs the unit's [WiFi Hotspot Remote](../features/phone-remote.md), as the display's own page does:

- **Hotspot** switches it on or off, and says how many phones have joined.
- While it's on, its **QR code**: a phone's camera turns it into "join this network".
- The **network** name and **password**, with a button to copy the password.
- **Join on this phone** (Android) or **Join on this computer** (Linux) joins the hotspot from the device the app's on.  Android asks to save the network, then shows WiFi to connect to it; on Linux, NetworkManager joins it.  The device's WiFi then has no internet, so the server link may drop.
- **New password** makes up a new one; phones that joined with the old one are dropped, and have to join again.
- **Start at power-up** switches the hotspot on as the display starts.

Switching it on and the password need the unit's firmware from this release on; on older firmware, only *Start at power-up* is here.
