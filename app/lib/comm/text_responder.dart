import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'board_link.dart';
import 'comm_controller.dart';
import 'conversations.dart';
import 'message_details.dart';
import 'mumble_client.dart';

/// The developer options' text auto responder: the app as a second person,
/// for testing range and relays alone. Each text heard is echoed back to
/// the conversation it came in, by the ways a text there goes; one sent us
/// privately that starts with / is a command instead, answered privately.
/// The same commands, and switching the options, can be had over adb
/// ([DevRemote]).
///
/// Two responders would echo each other for ever, so a text typed here in
/// the last minute isn't echoed, nor one echoed in the last few seconds.
class TextResponder {
  final CommController comm;
  TextResponder(this.comm);

  bool on = false;
  bool echo = true;       // echo texts; off leaves only the commands

  /// A second, as the voice responder waits: the copies of what came, and
  /// the other way's, are in its details by then, and off the air.
  static const delay = Duration(seconds: 1);

  /// Texts echoed lately: the same isn't echoed again this soon, as another
  /// responder's echo of our echo comes back in a second or two.
  final Map<String, int> _echoed = {};
  static const echoAgainMs = 5000;

  /// A text someone sent us, just added to its conversation.
  void received(Conversation c, ConversationEntry e) {
    if (!on || e.mine || e.kind != ConversationEntry.text) return;
    final text = e.body.trim();
    if (text.isEmpty) return;
    final private = c.kind == ConversationKind.person;
    if (private && text.startsWith('/')) {
      Timer(delay, () async {
        final reply = await run(text, command: e);
        _reply(c, reply);
      });
      return;
    }
    if (!echo || comm.sentLately(text)) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _echoed.removeWhere((_, at) => now - at > echoAgainMs);
    if (_echoed.containsKey(text)) return;
    _echoed[text] = now;
    Timer(delay, () {
      if (on && echo) comm.sendText(c, text, typed: false);
    });
  }

  /// A reply, in texts short enough to go direct (a few parts each), split
  /// at lines.
  void _reply(Conversation c, String reply) {
    const most = 480;     // bytes, within OthersCommand.longTextMax's parts
    final texts = <String>[];
    var now = StringBuffer();
    for (final line in reply.split('\n')) {
      final l = utf8.encode(line).length > most ? line.substring(0, most ~/ 3) : line;
      if (now.isNotEmpty && utf8.encode('$now\n$l').length > most) {
        texts.add(now.toString());
        now = StringBuffer();
      }
      if (now.isNotEmpty) now.write('\n');
      now.write(l);
    }
    if (now.isNotEmpty) texts.add(now.toString());
    for (final t in texts) {
      comm.sendText(c, t, typed: false);
    }
  }

  static const help = '''Commands, in a private text:
/help  these
/ping  how your ping came
/status  this phone and unit
/nearby  units heard direct, with RSSI
/details [N]  the last N texts' details (5), not their words
/talk server|direct  the voice channel talked to
/channels  the server's channels
/join <name>  move to a server channel
/voice on|off  the voice responder
/echo on|off  echoing texts''';

  /// A command's answer. [command] is the text it came in, if it did.
  Future<String> run(String line, {ConversationEntry? command}) async {
    final words = line.trim().split(RegExp(r'\s+'));
    final name = words.first.toLowerCase();
    final arg = words.length > 1 ? line.trim().substring(words.first.length).trim() : '';
    bool? onOff() => switch (arg.toLowerCase()) { 'on' => true, 'off' => false, _ => null };
    switch (name) {
      case '/help' || '/?':
        return help;
      case '/ping':
        final d = command?.details;
        return d == null || d.routes.isEmpty ? 'pong' : 'pong: your ping came\n${_routes(d)}';
      case '/status':
        return _status();
      case '/nearby':
        return _nearby();
      case '/details':
        final n = (int.tryParse(arg) ?? 5).clamp(1, 20);
        return _details(n, skip: command);
      case '/talk':
        final to = arg.toLowerCase();
        if (to != 'server' && to != 'direct') return 'Talk to server or direct?';
        await comm.setTalkTo(to == 'server' ? const TalkTarget.server() : const TalkTarget.direct());
        return 'Talking to ${comm.talkTo.kind.name}${comm.talkTo.kind.name != to ? ' ($to is not up)' : ''}';
      case '/channels':
        final m = comm.mumble;
        if (m == null || m.state != MumbleState.connected) return 'Not on the server';
        final counts = m.channelCounts;
        final ids = m.channels.keys.toList()..sort((a, b) => m.channelPath(a).compareTo(m.channelPath(b)));
        return [
          for (final id in ids) '${id == m.myChannel ? '* ' : ''}${m.channelPath(id)} (${counts[id] ?? 0})'
        ].join('\n');
      case '/join':
        final m = comm.mumble;
        if (m == null || m.state != MumbleState.connected) return 'Not on the server';
        final want = arg.toLowerCase();
        if (want.isEmpty) return 'Join which channel? /channels lists them';
        final found = m.channels.keys.where((id) => m.channels[id]!.toLowerCase() == want).toList();
        if (found.isEmpty) found.addAll(m.channels.keys.where((id) => m.channelPath(id).toLowerCase().contains(want)));
        if (found.length != 1) return found.isEmpty ? 'No channel "$arg"' : '"$arg" is more than one channel';
        m.joinChannel(found.first);
        return 'Joining ${m.channelPath(found.first)}';
      case '/voice':
        final v = onOff();
        if (v == null) return 'Voice responder ${comm.voiceResponder.on ? 'on' : 'off'}: /voice on or off';
        await comm.setVoiceResponder(v);
        return 'Voice responder ${v ? 'on' : 'off'}';
      case '/echo':
        final v = onOff();
        if (v == null) return 'Echo ${echo ? 'on' : 'off'}: /echo on or off';
        await comm.setTextEcho(v);
        return 'Echo ${v ? 'on' : 'off'}';
      default:
        return 'Not a command: $name. /help lists them';
    }
  }

  String _status() {
    final b = comm.board;
    final up = b.state == BoardState.connected && b.status != null;
    final m = comm.mumble;
    final d = comm.boardSettings?.direct;
    final s = b.status;
    return [
      up
          ? 'Unit ${b.name ?? '?'}, firmware ${b.firmware ?? '?'}'
              '${s?.battery == null ? '' : ', battery ${s!.battery}%${s.charging ? ' charging' : ''}'}'
          : 'Unit: not linked',
      'Talking to ${comm.talkTo.kind.name}',
      m != null && m.state == MumbleState.connected
          ? 'Server ${comm.server.host}:${comm.server.port}, ${m.channelPath(m.myChannel)} '
              '(${m.channelUsers.length} others), ${m.udpActive ? 'UDP' : 'TCP'}'
          : 'Server: not connected',
      d == null
          ? 'Direct: not known'
          : d.on
              ? 'Direct: ${d.keyed ? d.group : 'Open channel'}, frequency ${d.channel}${d.longRange ? ', Long Range' : ''}, '
                  '${comm.nearby.length} unit${comm.nearby.length == 1 ? '' : 's'} heard'
              : 'Direct: off',
      'Responders: voice ${comm.voiceResponder.on ? 'on' : 'off'}, text ${on ? 'on' : 'off'} (echo ${echo ? 'on' : 'off'})',
    ].join('\n');
  }

  String _nearby() {
    if (comm.nearby.isEmpty) return 'No units heard direct';
    final now = DateTime.now().millisecondsSinceEpoch;
    final boards = comm.nearby.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
    return [
      for (final b in boards)
        '${b.name}${b.key != null && comm.personOfBoard(b).name != b.name ? ' (${comm.personOfBoard(b).name})' : ''}: '
            '${b.rssi} dBm, ${((now - b.seenMs) / 1000).toStringAsFixed(1)} s ago'
            '${b.firmware.isEmpty ? '' : ', fw ${b.firmware}'}'
            '${b.app.isEmpty ? ', no app' : ', ${b.app}'}'
            '${b.key == null ? ', no key' : ''}${b.talking ? ', TALKING' : ''}'
    ].join('\n');
  }

  String _details(int n, {ConversationEntry? skip}) {
    final got = <(Conversation, ConversationEntry)>[
      for (final c in comm.conversations.all.values)
        for (final e in c.entries)
          if (!e.mine && e != skip && (e.kind == ConversationEntry.text || e.kind == ConversationEntry.photo)) (c, e)
    ]..sort((a, b) => b.$2.time.compareTo(a.$2.time));
    if (got.isEmpty) return 'No texts received';
    final out = <String>[];
    for (final (i, (c, e)) in got.take(n).indexed) {
      final d = e.details;
      out.add('#${i + 1} ${_clock(e.time)} from ${e.from} in ${c.title}'
          '${e.kind == ConversationEntry.text ? ', ${utf8.encode(e.body).length} B' : ', photo'}');
      out.add(d == null ? '  no details' : _routes(d, indent: '  '));
    }
    return out.join('\n');
  }

  /// Each way a text came, in a line.
  static String _routes(MessageDetails d, {String indent = ''}) {
    final first = d.routes.map((r) => r.atMs).reduce((a, b) => a < b ? a : b);
    return [
      for (final r in d.routes)
        '$indent${r.via}${r.atMs == first ? '' : ' +${((r.atMs - first) / 1000).toStringAsFixed(2)} s'}: '
            '${r.via == MessageRoute.server ? '${r.bytes} B' : _direct(r)}'
    ].join('\n');
  }

  static String _direct(MessageRoute r) {
    final copies = [for (final p in r.packets) ...p.copies];
    if (copies.isEmpty) return '${r.packets.length} pkt, no copies reported';
    final heard = r.packets.fold(0, (n, p) => n + p.sendsHeard);
    final rssi = [for (final c in copies) c.rssi]..sort();
    final relayed = copies.where((c) => c.hops > 0).length;
    final missing = r.packets.where((p) => p.counter == null).length;
    final spread = (r.lastCopyMs ?? 0) - (r.firstCopyMs ?? 0);
    return '${r.packets.length} pkt, sends $heard/${r.packets.length * r.sends}, relayed $relayed, '
        '${rssi.last == rssi.first ? '${rssi.first}' : '${rssi.last}..${rssi.first}'} dBm, spread $spread ms'
        '${missing > 0 ? ', $missing MISSING' : ''}';
  }

  static String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.${t.millisecond.toString().padLeft(3, '0')}';
}

/// The developer options over adb, for testing and debugging without the
/// screen: MainActivity passes on a broadcast only the shell can send (it
/// needs android.permission.DUMP), and its answer is the broadcast's result:
///
///   adb shell am broadcast -a io.github.rcat3.dronelab.DEV -p io.github.rcat3.dronelab -e c "/nearby"
///
/// c is a responder command (/help lists them), or: dev on|off (the
/// developer options), voice on|off, text on|off, echo on|off; none says how
/// they are. Each is in `adb logcat -s flutter` too.
class DevRemote {
  static const _channel = MethodChannel('dronelab/dev');

  static void listen(CommController comm) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'command') return null;
      final line = (call.arguments as String? ?? '').trim();
      final answer = await _run(comm, line);
      debugPrint('dev: ${line.isEmpty ? '(state)' : line}\n$answer');
      return answer;
    });
  }

  static Future<String> _run(CommController comm, String line) async {
    final r = comm.textResponder;
    if (line.startsWith('/')) return r.run(line);
    final words = line.toLowerCase().split(RegExp(r'\s+'));
    final on = words.length > 1 ? switch (words[1]) { 'on' => true, 'off' => false, _ => null } : null;
    switch (words.first) {
      case '':
      case 'state':
        return 'Developer options ${comm.developerOptions ? 'shown' : 'hidden'}; '
            'voice ${comm.voiceResponder.on ? 'on' : 'off'}, text ${r.on ? 'on' : 'off'}, echo ${r.echo ? 'on' : 'off'}';
      case 'dev' when on != null:
        await comm.setDeveloperOptions(on);
        return 'Developer options ${on ? 'shown' : 'hidden'}';
      case 'voice' when on != null:
        if (on) await comm.setDeveloperOptions(true);
        await comm.setVoiceResponder(on);
        return 'Voice responder ${on ? 'on' : 'off'}';
      case 'text' when on != null:
        if (on) await comm.setDeveloperOptions(true);
        await comm.setTextResponder(on);
        return 'Text responder ${on ? 'on' : 'off'}';
      case 'echo' when on != null:
        await comm.setTextEcho(on);
        return 'Echo ${on ? 'on' : 'off'}';
      default:
        return 'c is a /command, or dev|voice|text|echo on|off; none says how they are\n${TextResponder.help}';
    }
  }
}
