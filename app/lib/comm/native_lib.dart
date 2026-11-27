/// Where the desktop app's own native libraries are (native/, built by the
/// runner's CMake): in lib/ beside the program on Linux, beside the program
/// on Windows.
library;

import 'dart:io';

/// Whether sound out is the app's own player (native/audio_out.c, through
/// miniaudio), as there's no flutter_pcm_sound for the desktop.
bool get nativeAudio => Platform.isLinux || Platform.isWindows;

/// The path of the native library [name] ("dronelab_audio").
String nativeLibraryPath(String name) {
  final dir = File(Platform.resolvedExecutable).parent.path;
  return Platform.isWindows ? '$dir\\$name.dll' : '$dir/lib/lib$name.so';
}
