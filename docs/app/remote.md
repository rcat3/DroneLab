# Remote

The Remote tab puts your unit's own controls on the phone: what its display shows, its settings, your toys, the voice effect, sounds and the Terminal.  Everything you'd do by touching the display, without touching it.

<img src="../images/app_remote.png" width="300" alt="The Remote tab: what the display shows, and buttons to change it">

Back to [the app](README.md).

## What it's for

Once the unit's screwed into the mask, its display faces outward, where you can't see it or reach it comfortably.  The Remote lets you:

- **Change what the display shows** while you're wearing it: an image, a visualizer, the Terminal, the HiveMind screen.
- **Run the show from your hand**: play a sound, switch the voice effect, turn the voice ring on, start a toy's pattern, without lifting a hand to the mask.
- **Hand control to someone else**: a handler with the phone can run the unit while you wear it.

## What's on it

The Remote tab is the app's own, with four tabs along the top and a link to Setup, like the other tabs:

- **Screen**: a picture of what's on the display now.  It isn't live: it updates every few seconds, a moment after you move to another page, and when you tap the refresh button.  Arrows above, below and at each side do what a swipe on the display does.  The picture and arrows stay in place, and under them a list scrolls, to jump straight to any page.  Tap a feature to open its pages (and, for the Sound Visualizer, its styles) without leaving the page that's showing; the display only changes when you tap one of them.  Pictures others have sent are listed with a bin to delete them.
- **Sound** has three parts.  *Voice Effects*: the effect, *Play on speaker*, its volume and *Loud room*.  A low-profile unit has no speaker, so its voice effect isn't here: pick it as *HiveMind voice* in Setup, or on the unit.  *Visualizer*: the [Sound Visualizer](../features/visualizer.md)'s style, to show it on the display, and the [voice ring](../features/voice-ring.md).  *Playback*: the sound player, with its tracks.
- **Toys**: your own [toys](../features/toys.md): a slider for each of the screen's controls, the patterns, the reactions, the toys to connect, and a big **STOP** that's always at the bottom.
- **Terminal**: type a message onto your own display, add a line, clear it, and pick the letter size.

Both tabs also save files to the unit's SD card: see [below](#saving-pictures-and-sounds-to-the-units-sd-card).

The unit's own settings (brightness, rotation, what it shows at startup, the hotspot) are in Setup's *Display Unit*, under [General Setup](#setup-general-setup).  The display and the phone control the same things, so each shows what the other does.

The WiFi hotspot's web page has the same things in a page, and a Setup tab of its own: see [WiFi Hotspot Remote](../features/phone-remote.md).

## Saving pictures and sounds to the unit's SD card

With a card in the unit, the Remote saves pictures and sounds to it, so you can use them without taking the card out.  They stay on the card, work with the unit off and without the phone, and are the unit's [Images](../features/images.md#images-on-the-sd-card) and [sounds](../features/sound.md#sounds-on-the-sd-card) like any you copied there.

- **Pictures**: at the bottom of the *Screen* tab, *Save a picture to the unit*.  Take a photo or choose a picture, name it, and pick **Crop** (you choose the part that fills the round display) or **As it is** (the whole picture, made no bigger than the display).  An animated GIF is saved as it is, to play, up to 2 MB.  A PNG with see-through parts stays a PNG.  Everything else is saved as a JPEG.  *Show it when it is saved* brings it onto the display.
- **Sounds**: at the bottom of *Sound*, *Playback*, *Save a sound to the unit*.  A WAV, MP3 or FLAC file, up to 3 MB.  A WAV that is stereo or too big is mixed down to mono, and to a lower sample rate if it has to be, to fit.  It becomes a track after the others in the player; *Play it when it is saved* starts it.
- **What's on the card**: the pictures are listed under the Screen tab's pages, and the sounds among the player's tracks, each with a bin to delete it (it asks first).  The pictures go in with the card's others, in order of name; the sounds go after the card's others, till the unit is restarted, when they're all in order of name.
- **A name that's taken**: the app asks whether to replace the file or keep both (it adds a number to the new one).

A file goes in the background: you can leave the page, and its progress, with a *Cancel*, shows at the top of the lists when you come back.  It waits while there's voice (you talking, someone heard, a call) so the file doesn't take the link from it, and carries on after.  Over Bluetooth, a 3 MB sound takes a minute or two.  A sound that's playing pauses while one is saved, and carries on after.

The unit keeps at most 32 pictures and 100 sounds from its card.  If a file is too big, the card is full or is missing, or the picture can't be shown, the app says so.  The unit needs the firmware from 0.9.15 on; with older firmware the section isn't there.

## The app, or the WiFi hotspot

There are two ways to reach the same page:

| | **The app's Remote tab** | **The WiFi Hotspot Remote** |
|---|---|---|
| Phones | Android, with the app (and the Linux app) | Any phone with a web browser: **iPhones**, or someone else's phone |
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
