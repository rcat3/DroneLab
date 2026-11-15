# Comm

*The ESP32-S3-Touch-AMOLED-1.75.  In development: the board's side works, and the Android app is being tried out.*

The comm channel lets a group talk to each other, like a radio.  The board sends the wearer's voice, through the [voice effect](voice-effects.md), to their phone over Bluetooth, and the phone passes it on to a [Mumble](https://www.mumble.info) server on the internet that everyone's on.  What the others say comes back through the phone, to the wearer's headphones.  People without a display can join from the Mumble app.

The board only sends while the wearer talks: in *Push to talk*, while the talk button is held, and in *Voice*, whenever it hears them speak.

```mermaid
flowchart LR
    mic["Microphone"] --> fx["Voice effect"] --> opus["Opus encoder"]
    opus -- "Bluetooth LE" --> phone["Phone"]
    phone -- "internet" --> mumble["Mumble server"]
    mumble --> others["The others' phones and computers"]
    mumble -- "the others' voices" --> phone --> headphones["Headphones"]
```

## On the display

The *Phone App* page is in [Settings](settings.md), after Brightness.

1. Switch it on.  The board starts advertising over Bluetooth for a phone to connect, under the phone remote's name (`DroneLab-` and four letters), shown at the bottom of the page.
2. Pick *Push to talk* or *Voice*.
3. The title shows what it's doing: waiting for a phone, connected, or talking.  *Hold to talk* is for trying it out with the display in hand.  In the mask, the phone, or a button paired with it, does the talking.

It stays on, or off, from one startup to the next.  The voice effect has to run the whole time it's on, so it uses more battery than with the voice effect off.

## The talk button

A Bluetooth camera shutter remote can be the talk button: hold it to talk, in either mode.  It has to be a Bluetooth LE one, which shows up as a keyboard (the ATUMTEK one does); the cheapest ones are often older Bluetooth only, which the board can't use.

1. On the *Talk Button* page, after *Paired Phones*, tap *Pair a button*.
2. Put the remote in pairing mode: switch it on, or hold its button until it blinks.  The board pairs with the nearest one it finds, and shows its name.

The board remembers it.  The remote goes to sleep after a minute or so; pressing it wakes it, the board connects again, and that press counts, a moment late.  It's only used while Comm is on.  *Forget it* unpairs it.  A remote usually remembers only the last thing it paired with, so pairing it with the board unpairs it from a computer or phone it was used with.

## The app

The DroneLab app, in [`app/`](../../app/), is the phone's side, for Android for now.  Set up the server (the gear at the top: its address, your name and the server password), connect to it, then *Find the board* and pick yours.  The app passes the board's voice on to the server and plays the others to your headphones.  It has its own *Hold to talk*, and the board's mode can be changed from it too.

The first time the app connects, the phone asks to pair, and the board shows a 6-digit code over whatever's on its screen: type it into the phone.  The board only talks to a phone that's paired like that, so nobody else nearby can listen in or take over, and the phone and board remember each other after that.

The app's *Remote* tab is the [WiFi Hotspot Remote](phone-remote.md)'s page, run over the same Bluetooth link instead of the board's WiFi hotspot, so the phone keeps its internet for the comm channel.  It needs *Comm* on, like the rest of the app.

The headphones' play/pause button talks too, while the app's connected to the board and the server.  Headphones send a press rather than a hold, so a press starts talking and another stops it, with a rising chirp in your ear as it starts and a falling one as it stops.  It stops by itself after two minutes, in case it's been left on.  Holding the button down usually starts the phone's voice assistant instead.

It keeps going with the screen off, with a notification while it's on.  It trusts the server's certificate the first time it connects, and if the certificate changes after that it won't connect without asking, as that could be someone pretending to be the server.

Voice goes to and from the server over UDP, which is quicker on a patchy connection, as a lost packet doesn't hold up the ones after it.  Where UDP is blocked, it goes inside the connection to the server instead, and the server card says which.  The server needs both its TCP and UDP port open (64738).

The *Buffer* (in the server settings) is how long the others' voices wait before they play, to ride out an uneven connection: 60 ms to start, more on mobile data.  It doesn't grow by itself, so the delay stays put.

See [`app/README.md`](../../app/README.md) to build it.

## Trying it without the app

`tools/comm_bridge.py` stands in for the phone, on a computer with Bluetooth.  It can play what the board sends, save it to a file, or pass it on to a Mumble server, and pressing Enter talks:

```
python3 tools/comm_bridge.py --play
python3 tools/comm_bridge.py --wav comm.wav
python3 tools/comm_bridge.py --mumble 192.168.1.10 --password secret --user Pup
```

The computer has to pair with the board first, as the app does: in `bluetoothctl`, `agent on`, `pair` and the board's address, and type in the code the board shows.  See the top of the script for more.  It needs `pip install bleak`, and for `--play`, `numpy` and `sounddevice`.  [`tools/mumble/`](../../tools/mumble/) runs a Mumble server with Docker.

## How it works

The board is a Bluetooth LE peripheral with one service.  It notifies the phone with the voice, as 20 ms Opus packets of 16 kHz mono at about 24 kb/s, and with its status.  The phone writes to it to talk and to change the mode.  The messages are described at the top of [`core/app/comm.h`](../../core/app/comm.h).

The Opus packets go on to Mumble as they are, so the phone doesn't need to decode or encode anything.  `comm_bridge.py` shows how: it logs in to Mumble and sends the packets inside its TCP connection.

The voice is turned up by an automatic gain, separate from the speaker's volume, which evens out the voice effects' levels: it settles at about 17 to 21 dB.  The settings to tune are at the top of [`core/app/comm.c`](../../core/app/comm.c): how loud the voice is made (`AGC_TARGET_DB`), how loud speech has to be for voice mode (`VOX_DB`), and how long it keeps talking after the voice stops (`VOX_HANG_MS`).  `COMM_DEBUG` prints how loud the voice is, the gain, and how long encoding takes, every two seconds.
