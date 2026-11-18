# Installing the App

The DroneLab app is the phone's side of the [comms](features/comms.md), with the [remote](features/phone-remote.md) and recording over Bluetooth.  It's for Android for now, and it isn't on the Play Store: it's installed from an APK file on the project's [releases page](https://github.com/rcat3/DroneLab/releases/latest).  To build it yourself instead, see [`app/README.md`](../app/README.md).

## Installing a release

1. On the phone, open the [latest release](https://github.com/rcat3/DroneLab/releases/latest) and download the APK under *Assets*:
   - `DroneLab.apk` for most phones (anything from the last several years, which is 64-bit).
   - `DroneLab-armv7.apk` for older 32-bit phones, if `DroneLab.apk` won't install.

   The direct link to the usual one is <https://github.com/rcat3/DroneLab/releases/latest/download/DroneLab.apk>, which always gets the newest release.
2. Open the downloaded file, from the browser's downloads or the Files app.
3. Android asks whether to allow that app (the browser, or Files) to install unknown apps.  Go into its setting, switch *Allow from this source* on, and go back.
4. Tap *Install*.  Play Protect may say the app is from an unknown developer, or that it hasn't seen it before: choose *Install anyway* (it may be under *More details*).  This is because the app isn't from the Play Store.
5. Open it.  The first time, it asks for permission to find and connect to nearby devices (Bluetooth), and to show notifications, which it needs to keep going with the screen off.  On older versions of Android, finding Bluetooth devices needs the location permission too.

You can switch *Allow from this source* off again once it's installed.

## Updating

Download the new release's APK and install it the same way.  It installs over the old one, and keeps its settings, the server and the paired board.

If Android says the app conflicts with one that's installed, the copy on the phone was signed with a different key: usually one you built yourself (see [`app/README.md`](../app/README.md#installing-on-a-phone)).  Uninstall it first, which loses its settings, then install the release.

## First time with the board

1. On the board, switch on the *Phone App* page in [Settings](features/settings.md).  Pairing is open for two minutes after it's switched on.
2. In the app's *HiveMind Settings*, behind the gear on the HiveMind tab, *Find* the board and pick yours, by the name on the *Phone App* page.
3. The phone asks to pair, and the board shows a 6-digit code: type it into the phone.

After that, they remember each other.  Setting up the server, and the rest of the app, are in [Comms](features/comms.md#the-app).
