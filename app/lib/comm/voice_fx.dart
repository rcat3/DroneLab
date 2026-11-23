/// The board's voice effects on the phone's microphone: the same code as
/// the board's (core/audio/voice_fx_chain.c), in libdronelab_fx
/// (native/voice_fx_app.c) through dart:ffi. Android and Linux; elsewhere
/// there are none ([VoiceFx.available] false).
///
/// 48 kHz from the mic in, the effect's voice out at the effects' 16 kHz.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// The effects' own rate, as the board's (VOICE_FX_SAMPLE_RATE).
const voiceFxRate = 16000;

class _Lib {
  final int Function() presetCount;
  final Pointer<Utf8> Function(int) presetName;
  final Pointer<Void> Function() create;
  final void Function(Pointer<Void>, int) set;
  final int Function(Pointer<Void>, Pointer<Int16>, int, Pointer<Int16>) process;
  final void Function(Pointer<Void>) destroy;

  _Lib(DynamicLibrary l)
      : presetCount = l.lookupFunction<Int32 Function(), int Function()>('dl_fx_preset_count'),
        presetName = l.lookupFunction<Pointer<Utf8> Function(Int32), Pointer<Utf8> Function(int)>('dl_fx_preset_name'),
        create = l.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('dl_fx_new'),
        set = l.lookupFunction<Void Function(Pointer<Void>, Int32), void Function(Pointer<Void>, int)>('dl_fx_set'),
        process = l.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Int16>, Int32, Pointer<Int16>),
            int Function(Pointer<Void>, Pointer<Int16>, int, Pointer<Int16>)>('dl_fx_process'),
        destroy = l.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('dl_fx_free');

  static _Lib? _loaded;
  static bool _tried = false;

  static _Lib? get() {
    if (_tried) return _loaded;
    _tried = true;
    try {
      if (Platform.isAndroid) {
        _loaded = _Lib(DynamicLibrary.open('libdronelab_fx.so'));
      } else if (Platform.isLinux) {
        final dir = File(Platform.resolvedExecutable).parent.path;
        _loaded = _Lib(DynamicLibrary.open('$dir/lib/libdronelab_fx.so'));
      }
    } catch (e) {
      debugPrint('voice fx: $e');
    }
    return _loaded;
  }
}

class VoiceFx {
  /// Whether this platform has the effects.
  static bool get available => _Lib.get() != null;

  /// The presets' names, in order, as the board's.
  static List<String> get presets {
    final l = _Lib.get();
    if (l == null) return const [];
    return [for (var i = 0; i < l.presetCount(); i++) l.presetName(i).toDartString()];
  }

  final _Lib _lib;
  final Pointer<Void> _fx;
  Pointer<Int16> _in = nullptr;
  Pointer<Int16> _out = nullptr;
  int _size = 0;

  VoiceFx._(this._lib, this._fx);

  /// One for a voice: null without the library or the memory.
  static VoiceFx? create() {
    final l = _Lib.get();
    if (l == null) return null;
    final p = l.create();
    return p == nullptr ? null : VoiceFx._(l, p);
  }

  int _preset = -1;
  int get preset => _preset;

  /// The preset, from 0 (-1 for none), built afresh with nothing kept from
  /// before: at each transmission too, as the board does.
  void setPreset(int preset) {
    _preset = preset;
    _lib.set(_fx, preset);
  }

  /// [input] at 48 kHz (whole 10 ms blocks: 480 samples each) in, the
  /// effect's voice at 16 kHz out, a third as many.
  Int16List process(Int16List input) {
    if (input.length > _size) {
      if (_in != nullptr) malloc.free(_in);
      if (_out != nullptr) malloc.free(_out);
      _size = input.length;
      _in = malloc<Int16>(_size);
      _out = malloc<Int16>(_size ~/ 3 + 1);
    }
    _in.asTypedList(input.length).setAll(0, input);
    final n = _lib.process(_fx, _in, input.length, _out);
    return Int16List.fromList(_out.asTypedList(n));
  }

  void dispose() {
    _lib.destroy(_fx);
    if (_in != nullptr) malloc.free(_in);
    if (_out != nullptr) malloc.free(_out);
    _in = _out = nullptr;
  }
}
