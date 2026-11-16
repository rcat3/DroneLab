# WiFi Hotspot Remote

*Boards with WiFi: the ESP32-S3 boards*

The *WiFi Hotspot Remote* page in [Settings](settings.md) lets people run the display from a phone's web browser, so nobody has to reach the display in the mask.  On the ESP32-S3-Touch-AMOLED-1.75, the [DroneLab app](#in-the-app) is the better way: it shows the same page over Bluetooth, and the phone stays on the internet, which it can't while it's joined to the hotspot.  The hotspot is for phones without the app, like iPhones for now.  They can pick what it shows, set its brightness and other settings, control the [Lovense](lovense.md) devices, run the voice ring, the [voice effect](voice-effects.md) and the [sound player](sound.md), and type messages onto the [Terminal](terminal.md).  The phone needs no app.

1. Connect the devices on the display first (the Lovense feature's Devices page).  The phone can connect them too, but the display is quicker.
2. On the *WiFi Hotspot Remote* page, switch it on.  The board starts a WiFi hotspot of its own, called `DroneLab-` and four letters, and shows a QR code with its name and password under it.
3. On the phone, point the camera at the QR code and tap *Join*.  (Or join the network in the phone's WiFi settings and type the password.)
4. The remote's page opens on its own after a few seconds, the way a hotel's WiFi sign-in page does.  If it doesn't, open `http://192.168.4.1` in the phone's browser.

The page has five tabs:

- **Screen**: what's on the display now, with arrows to step through every page.  Under them, the [Visualizer](visualizer.md)'s styles, to switch to one and show it.  Then every feature's pages are listed, to jump straight to one.
- **Toys**: a slider for each motor of each connected device, the patterns and their speed, the reactions, a list of devices to connect, and a big **STOP** at the bottom that stops every device the moment it's touched.  *From others* says who may send your devices commands over the comm channel (see [Commands from others](lovense.md#commands-from-others)).
- **Sound**: the voice effect, with *Play on speaker*, the presets, and *Effect Volume* as a slider with buttons to step it by 1% or 5%.  Then the [voice ring](voice-ring.md), on or off and its color.  Under it, the sound player: the track playing, play and pause, the next and last tracks, a bar to move through the track, its volume, the repeat modes, *Play at startup*, and every track, to play one with a tap.
- **Terminal**: type a message and *Send* it (or press Enter) to show it on the Terminal.  *Switch to it* (on to start with) brings the Terminal on screen when you send.  *Add a line* puts the message under what's there instead of replacing it, dropping the oldest lines when it's full.  *Clear* empties it, and *Letter size* picks how big it's shown.  The last few messages are listed under it, to send again with a tap.  *From others* says who may send you messages over the comm channel (see [Messages from others](terminal.md#messages-from-others)).
- **Setup**, always the last tab: the display's [Settings](settings.md).  The battery's charge and how long the display's been on, then the brightness, the rotation, and what it shows at startup, and *Start at power-up* for the remote itself (see below).  The Battery Log, switching the WiFi Hotspot Remote off, and Firmware Update are only on the display: so nobody can forget the board's battery curve, turn the remote off from under the phones, or send firmware from a phone.

The display and the phones control the same things, so each shows what the others do.  Up to four phones can join at once, and the title on the display says how many have.  Adding `#screen`, `#toys`, `#sound`, `#term` or `#setup` to the page's address opens that tab.

The name and password are made up the first time the remote is switched on, and kept from then on.  Anyone who has the password can join, so if it's got around, switch the remote off, which drops every phone, and tap *New password*.  The new QR code lets the phones you want back in.  The hotspot is off at startup, unless *Start at power-up* is on: then it switches itself on as the display starts, with the same name and password, so phones that have joined before join again by themselves.  It's on the display's WiFi Hotspot Remote page while the remote is off, and on the phone's Setup tab.  While the hotspot's on, the phone has no internet over WiFi (it may use mobile data for everything else).

On an iPhone, the page opens in a small sign-in window.  Leave it open, or tap *Done* and open `http://192.168.4.1` in Safari.  Android phones may show a "Sign in to network" notification while they're joined; tapping it opens the page.

The WiFi Hotspot Remote and the [Voice Lab](voice-lab.md) both use WiFi, so they can't run at once: switching one on stops the other.

## In the app

The [comm channel](comm.md)'s Android app has the same page on its *Remote* tab, sent over the comm channel's Bluetooth link instead of the hotspot, so the phone stays on its own WiFi or mobile data.  It needs the board's *Comm* switched on, and the phone paired with it; the hotspot isn't used.

The page is `core/app/remote_page.html`.  After changing it, run `python3 tools/gen_remote_page.py` to turn it into the C file that's built into the firmware, and to copy it into the app.
