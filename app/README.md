# DroneLab app

The phone side of the [comm channel](../docs/features/comm.md), in Flutter, for Android (and later iPhone).  It connects to the board over Bluetooth, passes the board's voice on to a Mumble server, and plays everyone else to the phone's audio, usually Bluetooth headphones.

- `lib/comm/board_link.dart`, `board_protocol.dart`: the board, as in `core/app/comm.h`.
- `lib/comm/mumble_client.dart`, `protobuf.dart`, `voice_packet.dart`: a small Mumble client.  Voice goes over UDP while it gets through, encrypted as Mumble does (`crypt_state.dart`, OCB2-AES128, checked against Mumble's own test vectors), and inside its TLS connection otherwise.  It trusts the server's certificate the first time and warns if it changes.
- `lib/comm/jitter.dart`: a jitter buffer for each speaker, and the mixer.  The buffer is set in the app (60 ms to start) and doesn't grow.
- `lib/comm/audio_out.dart`: Opus decoding and playback.  It plays silence between voices, so Bluetooth headphones stay awake and don't cut off the start of what's said.
- `lib/comm/background.dart`: an Android foreground service, so it keeps going with the screen off.

## Building

It needs Flutter 3.47 and JDK 17 or later, and the Android SDK.

```
flutter test                                   # the protocol, the jitter buffer and the mixer
MUMBLE_HOST=192.168.1.10 MUMBLE_PASSWORD=secret flutter test test/mumble_test.dart
flutter build apk --release
flutter install                                # to a phone with USB debugging on
```

The Mumble test logs two clients in to a real server and sends voice from one to the other.
