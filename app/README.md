# DroneLab app

The app that goes with a unit, in Flutter, for **Android** phones and tablets and for **Linux** computers (a desktop, a laptop, or a Raspberry Pi 4 or 5).  It connects to the unit over Bluetooth, runs it from the phone, and is its way to the hive: voice and text over a Mumble server, calls, recordings and firmware updates.  On Linux it also comes with a virtual unit, the firmware itself running on the computer, so it works without any hardware.

To install a released copy instead of building it, see [Installing the App](../docs/app/installing.md).  How to use it is in [The DroneLab App](../docs/app/README.md).

Building it: the steps every platform shares come first, then each platform's own, from start to finish: [Android](#android), [Linux](#linux).

## What's where

- `lib/main.dart`: the app's start, and its tabs.
- `lib/ui/`: the pages (`hivemind_page.dart`, `text_page.dart`, `control_page.dart`, `record_page.dart`, `setup_page.dart`, ...) and the pieces they share.
- `lib/comm/comm_controller.dart`: what ties it together: the unit, the server, the people and the conversations.
- `lib/comm/board_link.dart`, `board_protocol.dart`: the unit, as in `core/app/comm.h`.  `board_transport.dart` is how it's reached: Bluetooth LE for a real unit, or a local socket for a virtual one (`virtual_unit.dart`).
- `lib/comm/mumble_client.dart`, `protobuf.dart`, `voice_packet.dart`, `crypt_state.dart`: a small Mumble client.  Voice goes over UDP while it gets through, encrypted as Mumble does (OCB2-AES128, checked against Mumble's own test vectors), and inside its TLS connection otherwise.
- `lib/comm/identity.dart`, `known_people.dart`: each person's Ed25519 key, and the people it knows.
- `lib/comm/jitter.dart`, `audio_out.dart`: a jitter buffer for each speaker, the mixer, and Opus decoding and playback.  It plays silence between voices, so Bluetooth headphones stay awake and don't cut off the start of what's said.
- `lib/comm/firmware_update.dart`: updating the unit over Bluetooth, with the firmware the app carries.
- `lib/comm/background.dart`: Android's foreground service, so it keeps going with the screen off.
- `lib/comm/linux_pairing.dart`: pairing with a unit through BlueZ, on Linux.
- `android/`: the Android project, and its signing.
- `linux/`: the Linux runner (`--profile`, in `runner/main.cc`), and the `README.md` that goes in the Linux tarball.
- `native/audio_out.c`: sound out on Linux, through miniaudio.
- `test/`: the unit tests.

## Getting the code

```
git clone https://github.com/rcat3/DroneLab.git
cd DroneLab
```

The app is in `app/`.  Some platforms need some of the firmware's submodules too; their sections say which.

## Flutter

The app needs **Flutter 3.47** (the release builds use 3.47.9), on the `PATH`.  `flutter doctor` says whether it's set up, and what else is missing for each platform.

## Tests

```
cd app
flutter test                                   # the protocol, the transports, identities, the jitter buffer and the mixer
MUMBLE_HOST=192.168.1.10 MUMBLE_PASSWORD=secret flutter test test/mumble_test.dart
```

The Mumble test logs two clients in to a real server and sends voice from one to the other.  Without `MUMBLE_HOST` it's skipped.

## The firmware it carries

For a release, the app carries the release's firmware, so it can keep units up to date with it: `tools/release/bundle_firmware.sh` puts it in `app/assets/firmware/`, and every platform's build picks it up from there.  It has to be built from the release's tag, so follow the [release checklist](../docs/development/README.md#release-checklist), which has the order and the names the files need.

An app built without it works the same, but doesn't offer to update units.  To try updates out with a development build, `tools/release/bundle_firmware.sh --dev build-s3-175` bundles any build (a version later than the unit's, to be offered).  It stays in `assets/firmware/` (not in git) for every build after, until it's removed.

## Android

### Tools

Besides Flutter, JDK 17 or later and the Android SDK.  It doesn't need any submodules.

### Building

```
cd app
flutter build apk --release
```

The APK is in `build/app/outputs/flutter-apk/app-release.apk`.  For handing the app out, `flutter build apk --release --split-per-abi` makes one smaller APK per CPU type instead; most phones want the arm64-v8a one.  Releases are always built that way (see the [release checklist](../docs/development/README.md#release-checklist)).

Release builds are signed with the key that `android/key.properties` names (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`); it and the keystore stay out of the repo.  Without it they're signed with the debug key.

Debug builds (`flutter run`, or `flutter build apk --debug`) are a separate app, `io.github.rcat3.dronelab.debug` named "DroneLab dev", so they install beside a released copy with their own settings.

### Installing on a phone

Switch on USB debugging on the phone (in *Developer options*), connect it over USB, and install with `adb`:

```
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

`-r` installs over the copy that's there and keeps its settings.  Don't use `flutter install`: it uninstalls the app first, which wipes its settings.  Or copy the APK to the phone and open it there, as in [Installing the App](../docs/app/installing.md).

A release build only installs over a copy signed with the same key.  Built without the project's key, it won't install over a copy from the releases page (`adb` says `INSTALL_FAILED_UPDATE_INCOMPATIBLE`): uninstall that first, which loses its settings, or build a debug copy, which installs beside it.

### Developer commands

With the developer options shown in the app, it takes developer commands over `adb`; see [Developer Options](../docs/app/developer-options.md#over-adb).

## Linux

On Ubuntu 22.04 or newer, Debian 12, or 64-bit Raspberry Pi OS.

### Submodules

The app's sound needs miniaudio, and the virtual unit the rest.  A shallow copy of each is enough, and much quicker to fetch.  From the top of the repository:

```
git submodule update --init --depth 1 third_party/miniaudio third_party/lvgl \
    third_party/dr_libs third_party/mbedtls third_party/opus
```

### Tools

Besides Flutter, the desktop build's tools and libraries, and what the virtual unit needs:

```
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev \
    python3-pil libx11-dev libjpeg-dev
flutter config --enable-linux-desktop
```

### Building

From the top of the repository, build the virtual unit first, into `build-host`, where the app's build looks for it:

```
cmake -S platforms/host -B build-host -DCMAKE_BUILD_TYPE=Release
cmake --build build-host -j
```

Then the app:

```
cd app
flutter build linux --release
```

On a Raspberry Pi, it's in `arm64` in place of `x64` in the paths below.  The `build/linux/x64/release/bundle` folder is the whole app, with `dronelab-unit` beside it, and can be copied anywhere; it's what the release tarballs hold, renamed `DroneLab`.  Without the virtual unit built first, the app still builds and runs, but can't start a virtual unit.  Built afterwards, it's picked up on the app's next build.  The virtual unit can also be run on its own, and has options of its own: see [`platforms/host/README.md`](../platforms/host/README.md).

### Running

```
build/linux/x64/release/bundle/dronelab
```

Or, while working on it, with hot reload:

```
flutter run -d linux
```

A debug build on Linux is the same app as a released copy, and shares its identity and settings in `~/.local/share/io.github.rcat3.dronelab`.  To keep them apart, run it as a profile of its own:

```
flutter run -d linux --dart-entrypoint-args=--profile=dev
build/linux/x64/release/bundle/dronelab --profile dev
```

A profile is a separate person, with its own identity, settings, unit and developer socket; see [`linux/README.md`](linux/README.md#two-at-once).  That's also how to run two copies at once, for trying out voice and text between them on one computer.

Running it needs `libgtk-3-0 libopus0 libsecret-1-0 libx11-6 bluez`, which a machine that built it already has.  Built on a newer system, it may not run on an older one: the release builds are made on Ubuntu 22.04 for that reason, by the [Linux app](../.github/workflows/linux.yml) workflow.  Using it, with a real unit or the virtual one, is in [`linux/README.md`](linux/README.md), the README that goes in the tarball.

### Developer commands

With the developer options shown in the app, it takes developer commands over a socket in place of `adb`:

```
echo /nearby | nc -U -q 5 $XDG_RUNTIME_DIR/dronelab-dev.sock
```

A profile's is `dronelab-dev-NAME.sock`.  The commands are in [Developer Options](../docs/app/developer-options.md).
