# Connecting the App

The app has two links to set up, each once: **your unit**, over Bluetooth, and, for talking to the hive over the internet, **a Mumble server**.  Both are in *Setup*, behind the gear at the top of the HiveMind tab, as numbered steps that tick themselves off.  After that, the app connects to both by itself whenever it starts.

<img src="../images/app/setup_connected.png" width="300" alt="Setup's Get connected section: the unit paired and connected, the server joined, and an avatar">

Back to [the app](README.md).

## 1. Pair the unit

The unit only talks to a phone that's paired with it, so nobody else nearby can listen in or take it over.

1. On the unit, switch on the *Phone App* page in [Settings](../features/settings.md), just after Brightness.  Pairing is open for two minutes after it's switched on.  (Later, to pair another phone, use *Pair a phone* on the *Paired Phones* page instead.)
2. In the app's *Setup*, tap *Find* by *Pair the board*.  It lists the units nearby with the Phone App on, the strongest signal first.
3. Pick yours, by the name on its *Phone App* page: `DroneLab-` and four letters.  With several units about, check the name: if you pick someone else's, the code shows on their display, not yours.
4. The phone asks to pair, and the unit shows a 6-digit code over whatever's on its screen.  Type it into the phone.

After that the phone and unit remember each other.  The *Phone App* page stays on from one startup to the next.

Pairing only opens when someone at the display asks for it, because the display faces outward while the mask's worn, where anyone could read a code.  The rest of the time, a phone that isn't paired is turned away before any code's shown.

## 2. Join the server

This is for the hive's [cloud link](hivemind.md#two-links-server-and-direct).  Direct mode, unit to unit, doesn't need it.

<img src="../images/app/server.png" width="300" alt="The Server page: address, port, your name, the server password, and the buffer">

Tap *Set up* by *Join the server*, and fill in what the hive's server needs:

- **Address**: the server's name or IP address.
- **Port**: 64738, unless you've been told otherwise.
- **Your name**: what the others see, on their app and their display.  It's your name over direct mode too.
- **Server password**: if it has one.
- **Buffer**: how long the others' voices wait before playing, to ride out an uneven connection.  60 ms is right on WiFi; more is smoother on mobile data.

*Save*, and the app connects.  The hive needs one server between everyone: if it hasn't got one yet, see [Setting up a Mumble server](../features/comms.md#setting-up-a-mumble-server).

The first time it connects, the app trusts the server's certificate.  If the certificate ever changes, the app won't connect without asking, as that could be someone pretending to be the server: *Trust the new certificate* appears under the server in the [links sheet](#the-links-sheet), only to be tapped if you know the server was set up again.

## 3. Your avatar

Your picture, shown to the hive on their app and their display while you talk.  *Change* picks a photo, cut square from the middle.  It's your [Mumble](https://www.mumble.info) avatar too, so the Mumble apps show it, and it goes to units nearby over direct mode.  Anyone without one shows as a head in a visor.

## The links sheet

Tap the [status strip](README.md#the-status-strip) at the top of any tab to see each link and connect or disconnect it: the unit (*Find* or *Disconnect*), the server (*Connect* or *Disconnect*), and *Direct* on or off.  The arrows' meanings are there too.

<img src="../images/app/links.png" width="300" alt="The links sheet: the unit connected, the server connected, Direct on with one unit nearby, and what the traffic arrows mean">

## Staying connected

- When the app starts, it connects to the unit and the server it had last, unless you disconnected them.  *Disconnect* is remembered: the app leaves that link alone until you connect it again.
- If the unit goes out of range, restarts or runs out of battery, the app tries again every few seconds by itself: the HiveMind tab says *Board offline* meanwhile.
- The app keeps going with the screen off, so you can talk and listen with the phone in a pocket.  A notification says so while it's on.

If the app can't find the unit at all, check its *Phone App* page is on, and that the phone isn't connected to it already from another app.  A unit talks to one phone at a time.
