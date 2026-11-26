import 'package:flutter/material.dart';

import '../comm/remote_model.dart';
import 'card_saving.dart';
import 'theme.dart';
import 'widgets.dart';

/// Remote → Screen: a snapshot of what the unit's display shows, arrows
/// round it that do what a swipe does, and a tree to jump to any page.
class RemoteScreenTab extends StatefulWidget {
  final RemoteModel model;
  const RemoteScreenTab({super.key, required this.model});

  @override
  State<RemoteScreenTab> createState() => _RemoteScreenTabState();
}

class _RemoteScreenTabState extends State<RemoteScreenTab> {
  RemoteModel get model => widget.model;

  int? _open;           // the feature whose pages are listed: looking, not showing
  int? _seen;           // the feature that was showing when we last looked

  @override
  Widget build(BuildContext context) {
    final features = model.features;
    final (cf, cp) = model.current;
    // The list follows the display when it moves to another feature, but
    // opening one to look doesn't move the display
    if (_seen != cf) {
      _seen = cf;
      _open = cf;
    }
    final here = cf < features.length ? features[cf] : null;
    // The picture and its arrows stay put; the list under them scrolls
    final side = (MediaQuery.sizeOf(context).height * 0.26).clamp(130.0, 220.0);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(children: [
          _Arrow(Icons.keyboard_arrow_up, 'Up', () => model.step('u')),
          Row(mainAxisSize: MainAxisSize.min, children: [
            _Arrow(Icons.keyboard_arrow_left, 'Left', () => model.step('l')),
            SizedBox(width: side, child: _Snapshot(model: model)),
            _Arrow(Icons.keyboard_arrow_right, 'Right', () => model.step('r')),
          ]),
          _Arrow(Icons.keyboard_arrow_down, 'Down', () => model.step('d')),
          Row(children: [
            const SizedBox(width: 48),
            Expanded(
              child: Text(
                here == null ? '' : '${here.$1}  \u00B7  ${cp < here.$2.length ? here.$2[cp] : 'Page ${cp + 1}'}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Kc.muted),
              ),
            ),
            IconButton(
              tooltip: 'Update the picture',
              icon: const Icon(Icons.refresh),
              onPressed: model.refreshScreen,
            ),
          ]),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            const SectionHeader('Show on the display'),
            if (features.isEmpty)
              const Panel(children: [PanelRow(title: 'Waiting for the unit')])
            else
              Panel(children: [
                for (var f = 0; f < features.length; f++) ..._feature(context, f, features[f], cf, cp),
              ]),
            ...cardPictures(context, model),
          ],
        ),
      ),
    ]);
  }

  /// A feature, and under it, if it's the one showing, its pages (and the
  /// Sound Visualizer's styles), indented.
  List<Widget> _feature(BuildContext context, int f, (String, List<String>) feature, int cf, int cp) {
    final (name, pages) = feature;
    final open = f == _open;
    final styles = name == 'Sound Visualizer' ? (model.info['visualizers'] as List? ?? const []) : const [];
    final style = model.state['vis'];
    final hasChildren = pages.length > 1 || styles.isNotEmpty;
    final showing = f == cf;
    return [
      PanelRow(
        title: name,
        leading: Icon(
            !hasChildren ? Icons.circle_outlined : open ? Icons.expand_more : Icons.chevron_right,
            color: showing ? Kc.green : Kc.dim),
        // Opening a feature only lists its pages; one with nothing under it
        // is shown by tapping it
        onTap: hasChildren ? () => setState(() => _open = open ? null : f) : () => model.show(f, 0),
      ),
      if (open) ...[
        if (pages.length > 1)
          for (var p = 0; p < pages.length; p++)
            _Child(
              title: pages[p].isEmpty ? 'Page ${p + 1}' : pages[p],
              on: showing && p == cp,
              onTap: () => model.show(f, p),
              onDelete: model.isReceived(f, p) ? () => _delete(context, f, p, pages[p]) : null,
            ),
        for (var v = 0; v < styles.length; v++)
          _Child(
            title: '${styles[v]}',
            on: showing && style == v,
            leading: Icons.graphic_eq,
            onTap: () => model.command('vis', {'v': v, 'show': 1}),
          ),
      ],
    ];
  }

  Future<void> _delete(BuildContext context, int f, int p, String name) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this picture?'),
        content: Text('"${name.isEmpty ? 'Page ${p + 1}' : name}" goes from the unit. Whoever sent it can send it again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (yes == true) {
      await model.command('picture', {'f': f, 'p': p, 'del': 1});
      model.refreshScreen();
    }
  }
}

/// A page (or style) under its feature.
class _Child extends StatelessWidget {
  final String title;
  final bool on;
  final IconData? leading;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  const _Child({required this.title, required this.on, required this.onTap, this.leading, this.onDelete});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: on ? Kc.raised : null,
        padding: const EdgeInsets.fromLTRB(44, 2, 8, 2),
        constraints: const BoxConstraints(minHeight: 40),
        child: Row(children: [
          Icon(leading ?? (on ? Icons.radio_button_checked : Icons.radio_button_unchecked),
              size: 18, color: on ? Kc.green : Kc.dim),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: TextStyle(color: on ? Kc.text : Kc.muted))),
          if (onDelete != null)
            IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline, color: Kc.softRed), onPressed: onDelete),
        ]),
      ),
    );
  }
}

class _Arrow extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _Arrow(this.icon, this.tooltip, this.onTap);

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        iconSize: 30,
        visualDensity: VisualDensity.compact,
        color: Kc.green,
        icon: Icon(icon),
        onPressed: onTap,
      );
}

/// The snapshot, round if the unit's screen is.
class _Snapshot extends StatelessWidget {
  final RemoteModel model;
  const _Snapshot({required this.model});

  @override
  Widget build(BuildContext context) {
    final image = model.screen;
    return AspectRatio(
      aspectRatio: image == null ? 1 : image.width / image.height,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black,
          border: Border.all(color: Kc.line),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: image == null
            ? const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)))
            : RawImage(image: image, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
      ),
    );
  }
}
