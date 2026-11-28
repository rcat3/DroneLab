import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../comm/comm_controller.dart';
import '../comm/conversations.dart';
import '../comm/hivesight_guide.dart';
import '../comm/hivesight_invite.dart';
import '../comm/hivesight_join.dart';
import '../comm/hivesight_vessel_toys.dart';
import '../comm/permissions.dart';
import '../comm/rules.dart' show RuleClass;
import 'hivesight_code.dart';
import 'hivesight_guide_page.dart';
import 'hivesight_scan_page.dart';
import 'theme.dart';

/// HiveSight on the Vessel's side: joining a Guide's invitation, and the
/// way back into the last one. The view itself is the Android app's
/// HiveSightActivity; this checks the invitation and the Guide's
/// permissions, signs for who we are, and hands it the session.

const _channel = MethodChannel('dronelab/hivesight');

/// Whether this phone can be a Vessel (Android 11 or newer).
Future<bool> hiveSightSupported() async {
  if (!Platform.isAndroid) return false;
  try {
    return await _channel.invokeMethod<bool>('supported') ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Join [i]: from a text, [from] who sent it and [who] who they are as the
/// text came; or [fromCode], a scanned QR code, which nobody sent, so the
/// Guide is named from the people we know. Checked, allowed (asked first if
/// they aren't yet), and opened. Returns why not, or null once it's open or
/// was left.
Future<String?> joinHiveSight(
  BuildContext context,
  CommController comm,
  HiveSightInvite i, {
  String from = '',
  String who = '',
  bool fromCode = false,
}) async {
  if (!await hiveSightSupported()) return 'HiveSight needs an Android phone with Android 11 or newer';
  final me = comm.identity;
  final d = await decideJoin(
    i,
    rules: comm.permissions.rules,
    people: comm.people,
    who: who,
    from: from,
    fromCode: fromCode,
  );
  if (d.refusal != null) return d.refusal;
  if (me == null) return "This phone's identity isn't ready";
  from = d.from;
  final keyHex = _hex(i.guideKey);
  final rules = comm.permissions.rules;
  if (!context.mounted) return null;
  if (d.ask) {
    if (!await _askAllow(context, from, fromCode: fromCode)) return null;
    await comm.permissions.grant(keyHex, d.savedName, {RuleClass.hiveSight});
  } else {
    if (!context.mounted || !await _notice(context)) return null;
  }
  final sig = await me.sign(HiveSightInvite.joinMessage(i.token, i.fingerprint));
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('hiveSightLast', '${fromCode ? '' : who}\n$from\n${i.link}');
  if (!context.mounted) return null;
  // Off to Android's settings to give it: back here, join again
  if (!await _offerQuiet(context)) return null;
  // Toys the Guide drives go to our unit under these rules, and stop with the view
  final toys = VesselToys(comm, keyHex, _channel);
  _channel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'closed':
        toys.dispose();
        comm.setVesselView(false);
      case 'toys':
        toys.onCommand(call.arguments as String);
      case 'toysStop':
        toys.stop();
    }
  });
  try {
    await _channel.invokeMethod<void>('open', {
      'hosts': i.hosts,
      'port': i.port,
      'fingerprint': i.fingerprint,
      'token': i.token,
      'expires': i.expires.millisecondsSinceEpoch,
      'guide': from,
      'key': _hex(me.publicKey),
      'sig': _hex(sig),
      // The light pulse is a switch of its own in Permissions (set to begin with)
      'lightPulse': rules.rule(RuleClass.hiveSight).ignore & ignoreLightPulse == 0,
      'name': comm.server.username,
    });
    // HiveMind voice waits while the view is open; the view says when it's closed
    comm.setVesselView(true);
  } on PlatformException catch (e) {
    toys.dispose();
    return e.message ?? "Couldn't open HiveSight";
  }
  return null;
}

/// Other apps' notifications are held back while the view's in front, if
/// Android's Do Not Disturb access is given. Offered once, to give it.
/// False if they went to the settings for it, so the view isn't opened over them.
Future<bool> _offerQuiet(BuildContext context) async {
  try {
    if (await _channel.invokeMethod<bool>('quietAccess') ?? true) return true;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('hiveSightQuietAsked') ?? false) return true;
    await prefs.setBool('hiveSightQuietAsked', true);
    if (!context.mounted) return true;
    final go = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Keep notifications out?'),
        content: const Text(
          "Other apps' notifications can pop up over the view. To hold them back while a session is open, "
          'allow DroneLab Do Not Disturb access in Android\'s settings. It puts your settings back when '
          'you leave the view. You can allow it later there too.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Open settings')),
        ],
      ),
    );
    if (go == true) {
      await _channel.invokeMethod<void>('quietSettings');
      return false;
    }
    return true;
  } on PlatformException {
    return true;
  } on MissingPluginException {
    return true;
  }
}

/// Ask whether [from] may guide us.
Future<bool> _askAllow(BuildContext context, String from, {bool fromCode = false}) async =>
    await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Let $from guide you?'),
        content: Text(
          '${fromCode ? 'This came from a code you scanned, which can be shown by anyone. ' : ''}'
          'Experimental. In a HiveSight session your Guide controls what you see and hear through the '
          'headset. Back leaves the view. The flashing light pulse is only shown if you turn off '
          '"Ignore light pulses" in Setup → Permissions → HiveSight. Your toys only answer a Guide '
          'you have allowed on Vibe there, and "Ignore toys" stops that altogether.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Allow and join')),
        ],
      ),
    ) ??
    false;

/// The notice before the view opens, for a Guide already allowed.
Future<bool> _notice(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('HiveSight'),
        content: const Text('Experimental. Your Guide controls what you see and hear. Back leaves the view.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Open as Vessel')),
        ],
      ),
    ) ==
    true;

/// HiveSight in the status sheet: back into the last session joined, while
/// it lasts. Experimental, so only with developer options on, and only on a
/// phone that can run it.
class HiveSightButton extends StatefulWidget {
  final CommController comm;

  /// Runs just before the view opens (closes the sheet this sits in).
  final VoidCallback? before;
  const HiveSightButton({super.key, required this.comm, this.before});

  @override
  State<HiveSightButton> createState() => _HiveSightButtonState();
}

class _HiveSightButtonState extends State<HiveSightButton> {
  late final Future<bool> _supported = hiveSightSupported();

  Future<void> _open() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString('hiveSightLast')?.split('\n');
    final i = last == null || last.length < 3 ? null : HiveSightInvite.parse(last.sublist(2).join('\n'));
    if (!mounted) return;
    final again = i == null || i.expired ? null : i;
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('HiveSight'),
        content: Text(
          again == null
              ? "To be a Vessel, join a Guide's invitation: it comes as a text, with a Join button. "
                    "Or scan the code on a Guide's screen."
              : 'Join the last session again (until ${HiveSightInvite.clock(again.expires)}), or scan a Guide\'s code.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, 'scan'), child: const Text("Scan a Guide's code")),
          if (again != null) FilledButton(onPressed: () => Navigator.pop(c, 'last'), child: const Text('Join again')),
          if (again == null) TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK')),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    if (choice == 'scan') {
      final scanned = await navigator.push<HiveSightInvite>(MaterialPageRoute(builder: (_) => const HiveSightScanPage()));
      if (scanned == null || !mounted) return;
      widget.before?.call();
      final why = await joinHiveSight(context, widget.comm, scanned, fromCode: true);
      if (why != null) messenger.showSnackBar(SnackBar(content: Text(why)));
      return;
    }
    widget.before?.call();
    final why = await joinHiveSight(context, widget.comm, again!, who: last![0], from: last[1], fromCode: last[0].isEmpty);
    if (why != null) messenger.showSnackBar(SnackBar(content: Text(why)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.comm,
      builder: (context, _) {
        if (!widget.comm.developerOptions) return const SizedBox.shrink();
        return FutureBuilder<bool>(
          future: _supported,
          builder: (context, snap) {
            if (snap.data != true) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton(onPressed: _open, child: const Text('HiveSight')),
            );
          },
        );
      },
    );
  }
}

/// An invitation to a HiveSight session, in its text's bubble: whose, until
/// when, and for one sent us, Join.
class HiveSightInviteCard extends StatefulWidget {
  final CommController comm;
  final HiveSightInvite i;
  final ConversationEntry e;
  final String from;
  final bool ended; // its Guide has said the session's over
  const HiveSightInviteCard(this.comm, this.i, this.e, {super.key, required this.from, this.ended = false});

  @override
  State<HiveSightInviteCard> createState() => _HiveSightInviteCardState();
}

class _HiveSightInviteCardState extends State<HiveSightInviteCard> {
  bool _joining = false;

  // The session's end is in the invitation itself: shown when it comes,
  // whether or not the Guide says so
  Timer? _end;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(HiveSightInviteCard old) {
    super.didUpdateWidget(old);
    if (old.i.expires != widget.i.expires) _schedule();
  }

  void _schedule() {
    _end?.cancel();
    final left = widget.i.expires.difference(DateTime.now());
    if (left > Duration.zero) _end = Timer(left + const Duration(seconds: 1), () => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _end?.cancel();
    super.dispose();
  }

  Future<void> _join() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _joining = true);
    try {
      final why = await joinHiveSight(context, widget.comm, widget.i, from: widget.from, who: widget.e.who);
      if (why != null) messenger.showSnackBar(SnackBar(content: Text(why)));
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.i, mine = widget.e.mine;
    final over = i.expired || widget.ended;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.visibility_outlined, size: 18, color: Kc.pink),
            const SizedBox(width: 6),
            Text(
              mine ? 'You invited them to HiveSight' : 'Invitation to a HiveSight session',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          widget.ended
              ? 'The session has ended'
              : i.expired
              ? 'The session ended at ${HiveSightInvite.clock(i.expires)}'
              : 'As a Vessel, until ${HiveSightInvite.clock(i.expires)}',
          style: const TextStyle(color: Kc.muted, fontSize: 13),
        ),
        if (!mine && !over) ...[
          const SizedBox(height: 8),
          FutureBuilder<bool>(
            future: hiveSightSupported(),
            builder: (context, snap) => snap.data == false
                ? const Text('Join it on an Android phone', style: TextStyle(color: Kc.muted, fontSize: 13))
                : FilledButton.icon(
                    onPressed: _joining || snap.data != true ? null : _join,
                    icon: _joining
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.login),
                    label: const Text('Join as Vessel'),
                  ),
          ),
        ],
      ],
    );
  }
}

/// Whether we can invite people to a HiveSight session: on a computer that
/// can guide one, with developer options on.
bool canInviteToHiveSight(CommController comm) => HiveSightGuide.supported && comm.developerOptions;

/// Invite [c] to our HiveSight session, as a text with a Join button,
/// after asking (the sender and a session are started first if they aren't
/// yet), and then, unless unticked, open the Guide page.
Future<void> inviteToHiveSight(BuildContext context, CommController comm, Conversation c) async {
  final g = HiveSightGuide.of(comm);
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  final starting = !g.canInvite;
  var open = true;
  final go = await showDialog<String>(
    context: context,
    builder: (d) => StatefulBuilder(
      builder: (d, setState) => AlertDialog(
        title: Text(starting ? 'Start a HiveSight session?' : 'Invite to HiveSight?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${starting ? 'Experimental. ' : ''}'
              '${c.kind == ConversationKind.person ? '${c.title} gets' : 'Everyone in ${c.title} gets'} a text '
              'with a Join button, to join as a Vessel '
              '${starting ? 'for the next ${HiveSightInvite.lifetime.inHours} hours' : 'until ${HiveSightInvite.clock(g.session!.expires)}'}'
              ' or until you end the session.',
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: open,
              onChanged: (on) => setState(() => open = on ?? false),
              title: const Text('Open the Guide page'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, 'code'), child: const Text('Show code instead')),
          FilledButton(
            onPressed: () => Navigator.pop(d, 'send'),
            child: Text(starting ? 'Start and invite' : 'Send invitation'),
          ),
        ],
      ),
    ),
  );
  if (go == null) return;
  if (go == 'code') {
    if (!context.mounted) return;
    final why = await showHiveSightCode(context, g);
    if (why != null) messenger.showSnackBar(SnackBar(content: Text(why)));
    return;
  }
  final why = await g.inviteStarting(c);
  messenger.showSnackBar(SnackBar(content: Text(why ?? 'Invitation to HiveSight sent to ${c.audience}')));
  if (why == null && open) {
    navigator.push(MaterialPageRoute<void>(builder: (_) => HiveSightGuidePage(comm: comm)));
  }
}
