/// What a Vessel decides about an invitation before joining: from a text
/// (the one who sent it must be the Guide whose key signed it) or from a QR
/// code (nobody sent it, so the Guide is looked up by key in the people
/// already known, and said so if it isn't).
library;

import 'hivesight_invite.dart';
import 'known_people.dart';
import 'rules.dart';

/// What reading a scanned code gave.
enum CodeResult { ok, notHiveSight, damaged, altered, expired }

/// A scanned code: the invitation if it's a good one, and what it was if not.
class ScannedCode {
  final CodeResult result;
  final HiveSightInvite? invite;
  const ScannedCode(this.result, [this.invite]);

  /// What to tell the person, for a code that can't be used.
  String get problem => switch (result) {
    CodeResult.ok => '',
    CodeResult.notHiveSight => "That isn't a HiveSight code",
    CodeResult.damaged => "That HiveSight code can't be read",
    CodeResult.altered => 'That HiveSight code has been altered',
    CodeResult.expired => 'That session ended at ${HiveSightInvite.clock(invite!.expires)}',
  };
}

/// Read [text] from a scanned code: anything but a HiveSight link isn't one.
Future<ScannedCode> readCode(String text) async {
  final t = text.trim();
  if (!t.startsWith(HiveSightInvite.linkPrefix)) return const ScannedCode(CodeResult.notHiveSight);
  final i = HiveSightInvite.parse(t);
  if (i == null) return const ScannedCode(CodeResult.damaged);
  if (!await i.verify()) return const ScannedCode(CodeResult.altered);
  if (i.expired) return ScannedCode(CodeResult.expired, i);
  return ScannedCode(CodeResult.ok, i);
}

/// How to name a Guide we don't know: by the start of their key's id.
String shortKey(HiveSightInvite i) => '⬡ ${i.guideId.substring(0, 8)}';

String unknownGuide(HiveSightInvite i) => "a Guide you don't know yet (${shortKey(i)})";

/// Where a decision comes to.
class JoinDecision {
  /// Why not, or null.
  final String? refusal;

  /// The Guide as the allow step names them.
  final String from;

  /// The name to keep them under once allowed: the Guide's, or their key's
  /// short id if we don't know them.
  final String savedName;

  /// Whether it's from a code (the allow step says so).
  final bool fromCode;

  /// Whether they must be allowed first (not yet allowed, and not Anyone).
  final bool ask;
  const JoinDecision.no(this.refusal) : from = '', savedName = '', fromCode = false, ask = false;
  const JoinDecision(this.from, {required this.savedName, required this.fromCode, required this.ask}) : refusal = null;
}

/// Decide about [i]. From a text, [who] is the id of the person it came from
/// and [from] their name; from a code ([fromCode]) they're ignored: the
/// Guide's key is looked up in [people]. Either way the signature has to
/// verify, and the session not be over, and HiveSight not be set to Nobody.
Future<JoinDecision> decideJoin(
  HiveSightInvite i, {
  required HiveRules rules,
  required KnownPeople people,
  String? who,
  String from = '',
  bool fromCode = false,
}) async {
  if (!fromCode && who != KnownPerson.keyId(i.guideKey)) return const JoinDecision.no("This invitation isn't from the person who sent it");
  if (!await i.verify()) {
    return JoinDecision.no(fromCode ? 'That HiveSight code has been altered' : "This invitation isn't from the person who sent it");
  }
  if (i.expired) return JoinDecision.no('This session ended at ${HiveSightInvite.clock(i.expires)}');
  if (rules.policy(RuleClass.hiveSight) == Policy.off) return const JoinDecision.no('HiveSight is set to Nobody in Setup → Permissions');
  var name = from, saved = from;
  if (fromCode) {
    final known = people[KnownPerson.keyId(i.guideKey)]?.name ?? '';
    name = known.isNotEmpty ? known : unknownGuide(i);
    saved = known.isNotEmpty ? known : shortKey(i);
  }
  return JoinDecision(name, savedName: saved, fromCode: fromCode, ask: !rules.allows(_hex(i.guideKey), RuleClass.hiveSight));
}

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
