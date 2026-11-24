import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../comm/comm_controller.dart';
import '../comm/patterns.dart';
import 'pattern_editor_page.dart';
import 'pattern_sparkline.dart';
import 'theme.dart';
import 'widgets.dart';

/// The Vibe patterns kept on the phone: the board's built-in ones (to make
/// new ones from), our own, and those others have sent. Our own and the
/// starred ones sent us are on HiveMind Control's Patterns, to play on
/// others' toys.
class PatternsPage extends StatelessWidget {
  final CommController comm;
  const PatternsPage({super.key, required this.comm});

  static String describe(VibePattern p) {
    final rows = p.rowCount;
    return '${rows == 1 ? '1 row' : '$rows rows'} · ${(p.lengthMs / 1000).toStringAsFixed(1)} s';
  }

  Future<void> _open(BuildContext context, {PatternEntry? entry, VibePattern? start, String? builtIn}) =>
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PatternEditorPage(comm: comm, entry: entry, start: start, builtIn: builtIn)));

  Future<void> _import(BuildContext context) async {
    final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    if (!context.mounted) return;
    final text = TextEditingController(text: VibePattern.fromLovense(clip) != null ? clip : '');
    final name = TextEditingController(text: 'Imported');
    final p = await showDialog<VibePattern>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Import a pattern'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
          const SizedBox(height: 8),
          TextField(
            controller: text,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
                labelText: "In Lovense's pattern format", hintText: 'V:1;F:v;S:100#0;4;8;12;16;20;'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(d, VibePattern.fromLovense(text.text, name: name.text.trim())),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    text.dispose();
    name.dispose();
    if (!context.mounted) return;
    if (p == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("That isn't a pattern in Lovense's format")));
      return;
    }
    await _open(context, start: p);
  }

  Widget _tile(BuildContext context, PatternEntry e, Set<PatternEntry> left) {
    final lib = comm.patterns;
    return PanelRow(
      leading: PatternSparkline(pattern: e.pattern, color: e.kind == PatternEntry.mine ? Kc.pink : Kc.green),
      title: e.pattern.name,
      subtitle: '${describe(e.pattern)}${e.from.isEmpty ? '' : ' · from ${e.from}'}'
          '${left.contains(e) ? " · doesn't fit on your unit" : ''}',
      onTap: () => _open(context, entry: e),
      trailing: [
        IconButton(
          tooltip: e.favourite ? 'Unstar' : "Star: a favourite, on your unit's Patterns page and on Control",
          icon: Icon(e.favourite ? Icons.star : Icons.star_border, color: e.favourite ? Kc.warn : Kc.muted),
          onPressed: () => lib.setFavourite(e, !e.favourite),
        ),
        PopupMenuButton<String>(
          onSelected: (v) async {
            switch (v) {
              case 'copy':
                await _open(context, start: e.pattern.copy(name: '${e.pattern.name} copy'));
              case 'export':
                await Clipboard.setData(ClipboardData(text: e.pattern.toLovense()));
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text("Copied in Lovense's pattern format")));
                }
              case 'delete':
                lib.remove(e);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'copy', child: Text('Duplicate')),
            PopupMenuItem(value: 'export', child: Text("Copy in Lovense's format")),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    const small = TextStyle(color: Kc.muted, fontSize: 13);
    return ListenableBuilder(
      listenable: Listenable.merge([comm, comm.patterns]),
      builder: (context, _) {
        final mine = comm.patterns.mine.toList(), received = comm.patterns.received.toList().reversed.toList();
        final (doc, leftOut) = comm.favouritesForUnit();
        final left = leftOut.toSet();
        final stars = comm.patterns.favourites.length - left.length;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Vibe Patterns'),
            actions: [
              IconButton(tooltip: 'Import', icon: const Icon(Icons.download), onPressed: () => _import(context)),
              IconButton(tooltip: 'New pattern', icon: const Icon(Icons.add), onPressed: () => _open(context)),
            ],
          ),
          body: SafeArea(
            top: false,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              Explained(
                help: 'Star patterns to make them favourites: they go to your unit, first on its Patterns page, '
                    'kept there when it restarts, and on Control with your own.',
                helpPadding: const EdgeInsets.only(bottom: 6),
                builder: (context, info) => Row(children: [
                  Icon(Icons.star, size: 16, color: stars > 0 ? Kc.warn : Kc.dim),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                        !comm.unitTakesFavourites
                            ? 'Favourites go to your unit when it connects'
                            : comm.unitFavouritesRoom == 0
                                ? 'Your unit needs updating over USB once to keep favourites'
                                : '${stars == 1 ? '1 favourite' : '$stars favourites'} on your unit · '
                                    '${(doc.length / 1024).toStringAsFixed(1)} of '
                                    '${comm.unitFavouritesRoom ~/ 1024} KB'
                                    '${comm.unitFavouritesUpToDate ? '' : ' · sending'}',
                        style: small),
                  ),
                  info,
                ]),
              ),
              const SectionHeader('Yours'),
              if (mine.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('None yet: make one with +, or from a built-in one below', style: small),
                )
              else
                Panel(children: [for (final e in mine) _tile(context, e, left)]),
              const SectionHeader('Built in'),
              Panel(children: [
                for (final name in builtInPatterns)
                  PanelRow(
                    leading: PatternSparkline(builtIn: name, color: Kc.muted),
                    title: name,
                    subtitle: 'On every unit · tap to make one of yours from it',
                    onTap: () => _open(context, builtIn: name),
                  ),
              ]),
              const SectionHeader('Sent to you'),
              if (received.isEmpty)
                const Text('Patterns others play on your toys, or share in a message, are kept here', style: small)
              else
                Panel(children: [for (final e in received) _tile(context, e, left)]),
            ]),
          ),
        );
      },
    );
  }
}

/// Pick one of our patterns, or one sent us: for sharing in a message.
Future<PatternEntry?> pickPattern(BuildContext context, CommController comm) => showModalBottomSheet<PatternEntry>(
      context: context,
      backgroundColor: Kc.panel,
      builder: (sheet) {
        final all = [...comm.patterns.mine, ...comm.patterns.received];
        return SafeArea(
          child: all.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No patterns to share yet: make one in Setup → Toys → Vibe Patterns'),
                )
              : ListView(shrinkWrap: true, children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text('Share a pattern', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                  ),
                  for (final e in all)
                    PanelRow(
                      leading: PatternSparkline(pattern: e.pattern),
                      title: e.pattern.name,
                      subtitle: PatternShare.fits(e.pattern)
                          ? PatternsPage.describe(e.pattern)
                          : 'Too long to share as a message',
                      onTap: PatternShare.fits(e.pattern) ? () => Navigator.pop(sheet, e) : null,
                    ),
                ]),
        );
      },
    );
