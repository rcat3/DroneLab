# Installing the App

The DroneLab app is for **Android** phones and tablets.  It isn't on the Play Store: you install it from a file on the project's [releases page](https://github.com/rcat3/DroneLab/releases/latest).  To build it yourself instead, see [`app/README.md`](../../app/README.md).

**No Android phone?**  iPhones, and any phone without the app, can still run the unit from a web browser, through the unit's own [WiFi Hotspot Remote](../features/phone-remote.md).  That covers what's on the display, the settings, the Lovense toys, the voice effect, sounds and the Terminal; it doesn't cover [HiveMind](hivemind.md), messages to others, or recording, which need the app.

Back to [the app](README.md).

## Installing a release

1. On the phone, open the [latest release](https://github.com/rcat3/DroneLab/releases/latest) and download the APK under *Assets*:
   - `DroneLab.apk` for most phones (anything from the last several years, which is 64-bit).
   - `DroneLab-armv7.apk` for older 32-bit phones, if `DroneLab.apk` won't install.

   The direct link to the usual one is <https://github.com/rcat3/DroneLab/releases/latest/download/DroneLab.apk>, which always gets the newest release.
2. Open the downloaded file, from the browser's downloads or the *Files* app.
3. Android asks whether to allow that app (the browser, or *Files*) to install unknown apps.  Go into its setting, switch *Allow from this source* on, and go back.
4. Tap *Install*.
5. Open it.  The first time, it asks for permission to find and connect to nearby devices (Bluetooth), and to show notifications, which it needs to keep going with the screen off.  On older versions of Android, finding Bluetooth devices needs the location permission too.

You can switch *Allow from this source* off again once it's installed.

Then [connect it to your unit](connecting.md).

## If the phone won't let you install it

Phones guard against apps from outside the Play Store, and a few of their protections can get in the way.  The app is safe to install, but none of these know that:

- **Play Protect** may say the app is from an unknown developer, that it hasn't seen it before, or offer to scan it.  Choose *Install anyway* (it may be under *More details*), or let it scan and then install.
- **Samsung Auto Blocker** (Samsung phones and tablets, *Settings* › *Security and privacy* › *Auto Blocker*) blocks every app that isn't from the Galaxy Store or the Play Store, without asking.  If tapping the file does nothing, or says it's blocked, switch Auto Blocker off, install the app, and switch it back on: the app keeps working with it on.
- **Advanced Protection** (on some phones with Android 16 and later) blocks apps from outside the Play Store altogether.  It has to be off while you install.
- **Work phones** and phones with parental controls may not allow it at all: that's up to whoever manages the phone.

## Updating

The app says when there's a new release, with a banner under the status strip:

<img src="../images/app/release_banner.png" width="400" alt="DroneLab 0.9.6 is available, with Download and a close button">

**Download** opens the release's page in the browser, to get the APK.  The **×** hides the banner until the app next starts.  To know, the app asks GitHub for the latest release when it starts, and once a day while it's open; nothing about you or your unit is sent.

Download the new release's APK and install it the same way.  It installs over the old one, and keeps its settings, the server and the paired unit.

Then let it update the unit, when it offers: each release of the app carries the firmware released with it.  See [Updating the unit's firmware](firmware-updates.md).

If Android says the app conflicts with one that's installed, the copy on the phone was signed with a different key: usually one you built yourself (see [`app/README.md`](../../app/README.md#installing-on-a-phone)).  Uninstall it first, which loses its settings, then install the release.
