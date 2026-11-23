/// Talking from the phone's own microphone, for those without a display
/// unit: push to talk only. The phone's (or computer's) mic, 48 kHz mono,
/// coded to Opus as the unit does it (core/app/comm.c: 20 ms packets,
/// 24 kbit/s, voice, error correction for 5% loss), each packet handed on
/// for the server.
///
/// The mic opens at each press and closes at its end, so it's only in use
/// while talking, or while its level's being tried in Setup. On Android
/// it's the voice-call source, with the phone's echo cancelling, noise
/// suppression and level control.
///
/// Which mic: the phone's, with Bluetooth headphones left as they are
/// (media sound); or, picked in Setup, a Bluetooth headset's, which puts it
/// in call mode ([Headset]) while the server's connected, so what's heard
/// comes through the call's narrower sound too.
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:opus_codec_dart/opus_dart.dart';
import 'package:opus_codec_dart/wrappers/opus_defines.dart' as od;
import 'package:record/record.dart';

import 'audio_out.dart' show loadOpus;
import 'voice_fx.dart';

/// What the app runs on, for what's said about its mic: "phone" or
/// "computer".
String get thisDevice => Platform.isLinux || Platform.isMacOS || Platform.isWindows ? 'computer' : 'phone';

class PhoneMic {
  /// Each packet as it's coded; [last] on the one ending a transmission.
  final void Function(Uint8List opus, {required bool last}) onPacket;
  PhoneMic(this.onPacket);

  static const _rate = 48000;
  static const _frame = _rate * 20 ~/ 1000;     // samples in a packet
  static const _frameBytes = _frame * 2;

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _sub;
  BufferedOpusEncoder? _encoder;
  BufferedOpusEncoder? _encoder16;      // the effect's voice, at its 16 kHz
  VoiceFx? _fx;
  bool _fxUsed = false;                 // this transmission went through the effect
  final BytesBuilder _pending = BytesBuilder(copy: false);
  bool _open = false;         // the recorder's open, or opening
  bool _sending = false;      // talking: packets go out
  bool _metering = false;     // Setup's trying the level
  bool _sentAny = false;
  int _generation = 0;

  /// Whether it's sending.
  bool get on => _sending;

  /// Whether Setup's trying the level.
  bool get metering => _metering;

  /// A boost for a quiet mic, in dB (0 to [maxGainDb]): some phones and
  /// tablets come out low even with their own level control. Loud parts
  /// are eased down to fit rather than clipped.
  int gainDb = 0;

  /// The board's voice effect on it (voice_fx.dart), by preset from 0, or
  /// -1 for none: as a unit would sound. The boost comes first, as the
  /// effect's gate goes by the level; the meter shows what comes out.
  int voicePreset = -1;
  static const maxGainDb = 18;

  /// How loud it is, as others get it: the peak of each 20 ms after the
  /// phone's own processing and the boost, just as it's coded, in dB below
  /// full scale (-60 for silence), falling back slowly.
  final ValueNotifier<double> level = ValueNotifier(-60);

  /// Why the mic couldn't open, last time; null once it did.
  String? error;

  /// Whether the app may use the mic, without asking.
  Future<bool> hasPermission() async {
    try {
      return await (_recorder ??= AudioRecorder()).hasPermission(request: false);
    } catch (e) {
      return false;
    }
  }

  /// Open the mic and send from it. False if it can't: no permission, or no
  /// mic ([error] says), or [stop] came first.
  Future<bool> start() async {
    if (_sending) return true;
    _sending = true;
    _sentAny = false;
    _fxUsed = false;
    final ok = await _openMic();
    if (!ok) _sending = false;
    if (ok && !_sending && !_metering) await _closeMic();     // let go while it opened
    return ok && _sending;
  }

  /// Stop sending, ending the transmission with what's left. The mic stays
  /// open while Setup's trying the level.
  Future<void> stop() async {
    if (!_sending) return;
    _sending = false;
    // What's left, made up to a packet with silence, as the last: silence
    // alone after the effect, which holds on to a little of the voice anyway
    final rest = _pending.takeBytes();
    final enc16 = _encoder16;
    if (_fxUsed && enc16 != null && _sentAny) {
      enc16.inputBuffer.fillRange(0, _frame16 * 2, 0);
      enc16.inputBufferIndex = _frame16 * 2;
      onPacket(enc16.encode(), last: true);
      if (!_metering) await _closeMic();
      return;
    }
    final enc = _encoder;
    if (enc != null && _sentAny) {
      final buf = enc.inputBuffer;
      buf.fillRange(0, _frameBytes, 0);
      buf.setRange(0, rest.length.clamp(0, _frameBytes), rest);
      enc.inputBufferIndex = _frameBytes;
      onPacket(enc.encode(), last: true);
    }
    if (!_metering) await _closeMic();
  }

  /// Open the mic to show its [level], sending nothing.
  Future<bool> startMeter() async {
    if (_metering) return true;
    _metering = true;
    final ok = await _openMic();
    if (!ok) _metering = false;
    return ok;
  }

  Future<void> stopMeter() async {
    if (!_metering) return;
    _metering = false;
    level.value = -60;
    if (!_sending) await _closeMic();
  }

  /// Close and open again, if it's open: after the mic's changed.
  Future<void> reopen() async {
    if (!_open) return;
    await _closeMic();
    await _openMic();
  }

  Future<bool> _openMic() async {
    if (_open) return true;
    _open = true;
    final gen = ++_generation;
    try {
      await loadOpus();
      final r = _recorder ??= AudioRecorder();
      if (!await r.hasPermission()) {
        error = "The app may not use the microphone: allow it in the $thisDevice's settings";
        _open = false;
        return false;
      }
      if (gen != _generation) return false;      // closed while asking
      _encoder ??= _newEncoder(_rate);
      _pending.clear();
      _startFx();
      final stream = await r.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _rate,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
        androidConfig: AndroidRecordConfig(
          audioSource: AndroidAudioSource.voiceCommunication,
          // A headset's mic is set up by [Headset], held for as long as
          // the server's connected, not at each press
          manageBluetooth: false,
        ),
      ));
      if (gen != _generation) {
        // Closed while it opened
        await r.stop();
        return false;
      }
      _sub = stream.listen(_onPcm);
      error = null;
      return true;
    } catch (e) {
      debugPrint('phone mic: $e');
      error = 'The microphone would not open';
      _open = false;
      return false;
    }
  }

  Future<void> _closeMic() async {
    if (!_open) return;
    _open = false;
    _generation++;
    await _sub?.cancel();
    _sub = null;
    _pending.clear();
    try {
      await _recorder?.stop();
    } catch (e) {
      debugPrint('phone mic stop: $e');
    }
  }

  void _onPcm(Uint8List pcm) {
    if (!_open) return;
    _pending.add(pcm);
    if (_pending.length < _frameBytes) return;
    final all = _pending.takeBytes();
    final enc = _encoder!;
    final samples = enc.inputBuffer.buffer.asInt16List(enc.inputBuffer.offsetInBytes, _frame);
    if ((_fx?.preset ?? -1) != voicePreset) _startFx();     // changed in Setup meanwhile
    final fx = voicePreset >= 0 ? _fx : null;
    var i = 0;
    for (; i + _frameBytes <= all.length; i += _frameBytes) {
      enc.inputBuffer.setRange(0, _frameBytes, all, i);
      if (gainDb > 0) _boost(samples);
      if (fx != null) {
        // Through the effect, and coded at its 16 kHz, as the board does
        final voice = fx.process(samples);
        _measure(voice);
        final e16 = _encoder16 ??= _newEncoder(voiceFxRate);
        if (_sending && voice.length == _frame16) {
          e16.inputBuffer.buffer.asInt16List(e16.inputBuffer.offsetInBytes, _frame16).setAll(0, voice);
          e16.inputBufferIndex = _frame16 * 2;
          onPacket(e16.encode(), last: false);
          _sentAny = true;
          _fxUsed = true;
        }
        continue;
      }
      _measure(samples);
      if (_sending) {
        enc.inputBufferIndex = _frameBytes;
        onPacket(enc.encode(), last: false);
        _sentAny = true;
        _fxUsed = false;
      }
    }
    if (i < all.length) _pending.add(Uint8List.sublistView(all, i));
  }

  void _measure(Int16List s) {
    var peak = 0;
    for (var i = 0; i < s.length; i++) {
      final a = s[i].abs();
      if (a > peak) peak = a;
    }
    final db = peak <= 0 ? -60.0 : math.max(-60.0, 20 * math.log(peak / 32767) / math.ln10);
    // Up at once, down 1 dB each 20 ms, so a word's peak can be read
    level.value = math.max(db, level.value - 1);
  }

  // Above this the boost eases off, towards full scale and never past it
  static const _knee = 20000.0;
  static const _room = 32767.0 - _knee;

  /// Where the boost starts easing loud parts down, in dB below full scale.
  static final kneeDb = 20 * math.log(_knee / 32767) / math.ln10;

  void _boost(Int16List s) {
    final g = math.pow(10, gainDb / 20).toDouble();
    for (var i = 0; i < s.length; i++) {
      var y = s[i] * g;
      final a = y.abs();
      if (a > _knee) {
        final t = (a - _knee) / _room;
        // tanh, eased: 0 at the knee, towards 1 at full scale
        final e = math.exp(-2 * t);
        y = (_knee + _room * (1 - e) / (1 + e)) * y.sign;
      }
      s[i] = y.round();
    }
  }

  static const _frame16 = voiceFxRate * 20 ~/ 1000;

  /// The effect, built afresh as the mic opens (each transmission, as the
  /// board does) or the preset's changed; none if this platform hasn't it.
  void _startFx() {
    if (voicePreset < 0) {
      _fx?.setPreset(-1);
      return;
    }
    _fx ??= VoiceFx.create();
    _fx?.setPreset(voicePreset);
  }

  static BufferedOpusEncoder _newEncoder(int rate) {
    final e = BufferedOpusEncoder(sampleRate: rate, channels: 1, application: Application.voip);
    e.encoderCtl(request: od.OPUS_SET_BITRATE_REQUEST, value: 24000);
    e.encoderCtl(request: od.OPUS_SET_COMPLEXITY_REQUEST, value: 5);
    e.encoderCtl(request: od.OPUS_SET_SIGNAL_REQUEST, value: od.OPUS_SIGNAL_VOICE);
    e.encoderCtl(request: od.OPUS_SET_INBAND_FEC_REQUEST, value: 1);
    e.encoderCtl(request: od.OPUS_SET_PACKET_LOSS_PERC_REQUEST, value: 5);
    return e;
  }

  Future<void> dispose() async {
    await stop();
    await stopMeter();
    _encoder?.destroy();
    _encoder = null;
    _encoder16?.destroy();
    _encoder16 = null;
    _fx?.dispose();
    _fx = null;
    await _recorder?.dispose();
    _recorder = null;
  }
}

/// A Bluetooth headset in call mode, for its mic (MainActivity.kt,
/// "dronelab/headset"): Android only. Call mode takes it out of media sound,
/// so everything heard through it is the call's narrower sound, which the
/// app plays as a call's voice to go there.
class Headset {
  static const _channel = MethodChannel('dronelab/headset');

  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// The headset's name while it's in call mode for us.
  static String? active;

  /// The headset there is to use, by name; null for none.
  static Future<String?> find() async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<String>('find');
    } catch (e) {
      return null;
    }
  }

  /// Put it in call mode: its name, or null if there's none or it wouldn't.
  static Future<String?> start() async {
    if (!supported) return null;
    try {
      return active = await _channel.invokeMethod<String>('start');
    } catch (e) {
      debugPrint('headset: $e');
      return active = null;
    }
  }

  static Future<void> stop() async {
    if (!supported || active == null) return;
    active = null;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (e) {
      debugPrint('headset stop: $e');
    }
  }
}
