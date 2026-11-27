import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../comm/comm_controller.dart';
import '../comm/conversations.dart';
import '../comm/hivesight_guide.dart';
import '../comm/hivesight_invite.dart';
import '../comm/permissions.dart';
import '../comm/rules.dart' show RuleClass;
import 'hivesight_guide_page.dart';
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

/// Join [i], from [from] ([who] who they are, as the text came): checked,
/// allowed (asked first if they aren't yet), and opened. Returns why not,
/// or null once it's open or was left.
Future<String?> joinHiveSight(
  BuildContext context,
  CommController comm,
  HiveSightInvite i, {
  required String from,
  required String who,
}) async {
  if (!await hiveSightSupported()) return 'HiveSight needs an Android phone with Android 11 or newer';
  if (who != 'k:${i.guideId}' || !await i.verify()) return "This invitation isn't from the person who sent it";
  if (i.expired) return 'This session ended at ${HiveSightInvite.clock(i.expires)}';
  final me = comm.identity;
  if (me == null) return "This phone's identity isn't ready";
  final keyHex = _hex(i.guideKey);
  final rules = comm.permissions.rules;
  if (rules.policy(RuleClass.hiveSight) == Policy.off) return 'HiveSight is set to Nobody in Setup → Permissions';
  if (!context.mounted) return null;
  if (!rules.allows(keyHex, RuleClass.hiveSight)) {
    final pulse = await _askAllow(context, from);
    if (pulse == null) return null;
    await comm.permissions.grant(keyHex, from, {RuleClass.hiveSight, if (pulse) RuleClass.hiveSightPulse});
  } else {
    if (!context.mounted || !await _notice(context)) return null;
  }
  final sig = await me.sign(HiveSightInvite.joinMessage(i.token, i.fingerprint));
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('hiveSightLast', '$who\n$from\n${i.link}');
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
      'lightPulse': rules.allows(keyHex, RuleClass.hiveSightPulse),
      'name': comm.server.username,
    });
  } on PlatformException catch (e) {
    return e.message ?? "Couldn't open HiveSight";
  }
  return null;
}

/// Ask whether [from] may guide us, and with the light pulse: null if not.
Future<bool?> _askAllow(BuildContext context, String from) {
  var pulse = false;
  return showDialog<bool>(
    context: context,
    builder: (d) => StatefulBuilder(
      builder: (d, setState) => AlertDialog(
        title: Text('Let $from guide you?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Experimental. In a HiveSight session your Guide controls what you see and hear through the '
              'headset. Back leaves the view. You can change this later in Setup → Permissions.',
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: pulse,
              onChanged: (on) => setState(() => pulse = on ?? false),
              title: const Text('Allow the light pulse'),
              subtitle: const Text(
                'Flashing light, up to 30 times a second. Leave it off if flashing lights can '
                'affect you.',
                style: TextStyle(color: Kc.muted, fontSize: 13),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, pulse), child: const Text('Allow and join')),
        ],
      ),
    ),
  );
}

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
    if (i == null || i.expired) {
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('HiveSight'),
          content: const Text("To be a Vessel, join a Guide's invitation: it comes as a text, with a Join button."),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
        ),
      );
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    widget.before?.call();
    final why = await joinHiveSight(context, widget.comm, i, who: last![0], from: last[1]);
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
  final go = await showDialog<bool>(
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
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: Text(starting ? 'Start and invite' : 'Send invitation'),
          ),
        ],
      ),
    ),
  );
  if (go != true) return;
  final why = await g.inviteStarting(c);
  messenger.showSnackBar(SnackBar(content: Text(why ?? 'Invitation to HiveSight sent to ${c.audience}')));
  if (why == null && open) {
    navigator.push(MaterialPageRoute<void>(builder: (_) => HiveSightGuidePage(comm: comm)));
  }
}
