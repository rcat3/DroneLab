import 'dart:convert';
import 'dart:typed_data';

import 'package:dronelab/comm/board_protocol.dart';
import 'package:dronelab/comm/sent_sounds.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('a sound goes in a speaker picture, and comes out again', () {
    final bytes = Uint8List.fromList(List.generate(5000, (i) => i * 7 & 0xFF));
    final html = soundMessage(SentSound(bytes, soundOpus));
    final got = soundsIn(html);
    expect(got.length, 1);
    expect(got.first.$1, soundOpus);
    expect(got.first.$2, bytes);

    // Still a picture, for plain Mumble, small beside the sound
    final b64 = RegExp(r'base64,([^"]+)"').firstMatch(html)!.group(1)!;
    final png = base64Decode(b64);
    final pic = img.decodePng(png)!;
    expect(pic.width, 48);
    expect(png.length - bytes.length, lessThan(2048));
    expect(html, contains('A sound for DroneLab units'));
  });

  test('a picture without a sound, or a broken one, has none', () {
    final plain = base64Encode(img.encodePng(img.Image(width: 4, height: 4)));
    expect(soundsIn('<img src="data:image/png;base64,$plain" />'), isEmpty);
    final html = soundMessage(SentSound(Uint8List.fromList([1, 2, 3]), soundFile));
    final b64 = RegExp(r'base64,([^"]+)"').firstMatch(html)!.group(1)!;
    final png = base64Decode(b64);
    png[png.length - 20] ^= 0xFF;     // in the sound's chunk
    expect(soundsIn('<img src="data:image/png;base64,${base64Encode(png)}" />'), isEmpty);
  });
}
