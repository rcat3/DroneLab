# DroneLab app

The phone side of the [comm channel](../docs/features/comm.md), in Flutter, for Android (and later iPhone).  It connects to the board over Bluetooth, passes the board's voice on to a Mumble server, and plays everyone else to the phone's audio, usually Bluetooth headphones.

- `lib/comm/board_link.dart`, `board_protocol.dart`: the board, as in `core/app/comm.h`.
- `lib/comm/mumble_client.dart`, `protobuf.dart`, `voice_packet.dart`: a small Mumble client.  Voice goes over UDP while it gets through, encrypted as Mumble does (`crypt_state.dart`, OCB2-AES128, checked against Mumble's own test vectors), and inside its TLS connection otherwise.  It trusts the server's certificate the first time and warns if it changes.
- `lib/comm/jitter.dart`: a jitter buffer for each speaker, and the mixer.  The buffer is set in the app (60 ms to start) and doesn't grow.
- `lib/comm/audio_out.dart`: Opus decoding and playback.  It plays silence between voices, so Bluetooth headphones stay awake and don't cut off the start of what's said.
- `lib/comm/background.dart`: an Android foreground service, so it keeps going with the screen off.

To install a released copy instead of building it, see [Installing the App](../docs/installing-the-app.md).

## Getting the code

The app is all in this folder, and doesn't need the firmware's submodules, so a plain clone is enough:

```
git clone https://github.com/rcat3/DroneLab.git
cd DroneLab/app
```

## Building

It needs Flutter 3.47 and JDK 17 or later, and the Android SDK.  `flutter doctor` says whether they're all set up.

```
flutter test                                   # the protocol, the jitter buffer and the mixer
MUMBLE_HOST=192.168.1.10 MUMBLE_PASSWORD=secret flutter test test/mumble_test.dart
flutter build apk --release
```

The Mumble test logs two clients in to a real server and sends voice from one to the other.

The APK is in `build/app/outputs/flutter-apk/app-release.apk`.  For handing the app out, `flutter build apk --release --split-per-abi` makes one smaller APK per CPU type instead; most phones want the arm64-v8a one.

Release builds are signed with the key that `android/key.properties` names (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`); it and the keystore stay out of the repo.  Without it they're signed with the debug key.

Debug builds (`flutter run`, or `flutter build apk --debug`) are a separate app, `io.github.rcat3.dronelab.debug` named "DroneLab dev", so they install beside a released copy with their own settings.

## Installing on a phone

Switch on USB debugging on the phone (in *Developer options*), connect it over USB, and install with `adb`:

```
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

`-r` installs over the copy that's there and keeps its settings.  Don't use `flutter install`: it uninstalls the app first, which wipes its settings.  Or copy the APK to the phone and open it there, as in [Installing the App](../docs/installing-the-app.md).

A release build only installs over a copy signed with the same key.  Built without the project's key, it won't install over a copy from the releases page (`adb` says `INSTALL_FAILED_UPDATE_INCOMPATIBLE`): uninstall that first, which loses its settings, or build a debug copy, which installs beside it.
