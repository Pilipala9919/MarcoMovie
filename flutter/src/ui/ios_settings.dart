import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'apple_theme.dart';

class SettingsPane {
  final String id, title, subtitle;
  final IconData icon;
  final Color color;
  final List<SettingsPane> children;
  final Widget? content;
  const SettingsPane(this.id, this.title, this.subtitle, this.icon, this.color,
      {this.children = const [], this.content});
}

typedef SettingsPanes = List<SettingsPane> Function(VoidCallback refresh);

class IosSettingsPage extends StatelessWidget {
  final SettingsPanes pages;
  final VoidCallback onChanged;
  final String version;
  const IosSettingsPage(
      {super.key,
      required this.pages,
      required this.onChanged,
      required this.version});

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ListView(
          key: const ValueKey('ios-settings-root'),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          children: [
            const Text('设置',
                style: TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.7)),
            const SizedBox(height: 6),
            Text('Marco Movie · $version',
                style: const TextStyle(
                    color: AppleColors.labelSecondary, fontSize: 13)),
            const SizedBox(height: 24),
            LayoutBuilder(builder: (context, constraints) {
              final entries = pages(onChanged);
              final columns = constraints.maxWidth >= 620 ? 2 : 1;
              final width =
                  (constraints.maxWidth - (columns - 1) * 14) / columns;
              return Wrap(spacing: 14, runSpacing: 12, children: [
                for (final entry in entries)
                  SizedBox(
                      width: width,
                      child: SettingsCapsule(
                        key: ValueKey('settings-category-${entry.id}'),
                        pane: entry,
                        onPressed: () => showAppleModalSheet<void>(
                          context: context,
                          title: '设置',
                          builder: (_) => _SettingsDrawer(
                              pages: pages,
                              rootId: entry.id,
                              onChanged: onChanged),
                        ),
                      )),
              ]);
            }),
          ],
        ),
      );
}

class SettingsCapsule extends StatelessWidget {
  final SettingsPane pane;
  final VoidCallback onPressed;
  const SettingsCapsule(
      {super.key, required this.pane, required this.onPressed});
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: onPressed,
          child: AppleSettingsGlassCard(
            borderRadius: BorderRadius.circular(36),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(children: [
              Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                      color: pane.color.withValues(alpha: .18),
                      shape: BoxShape.circle),
                  child: Icon(pane.icon, color: pane.color, size: 21)),
              const SizedBox(width: 13),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(pane.title,
                        style: const TextStyle(
                            color: AppleColors.labelPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(pane.subtitle,
                        style: const TextStyle(
                            color: AppleColors.labelSecondary,
                            fontSize: 12,
                            height: 1.4)),
                  ])),
              const SizedBox(width: 10),
              const Icon(CupertinoIcons.chevron_forward,
                  color: AppleColors.labelTertiary, size: 15),
            ]),
          ),
        ),
      );
}

class _SettingsDrawer extends StatefulWidget {
  final SettingsPanes pages;
  final String rootId;
  final VoidCallback onChanged;
  const _SettingsDrawer(
      {required this.pages, required this.rootId, required this.onChanged});
  @override
  State<_SettingsDrawer> createState() => _SettingsDrawerState();
}

class _SettingsDrawerState extends State<_SettingsDrawer> {
  final _path = <String>[];
  void _refresh() {
    if (!mounted) return;
    setState(() {});
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    // Resolve from fresh storage values on every rebuild, including after back
    // navigation. Do not retain a stale widget / selection in the page stack.
    var pane = widget.pages(_refresh).firstWhere((p) => p.id == widget.rootId);
    final parents = [pane];
    for (final id in _path) {
      pane = pane.children.firstWhere((p) => p.id == id);
      parents.add(pane);
    }
    return PopScope(
      canPop: _path.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _path.isNotEmpty) setState(() => _path.removeLast());
      },
      child: SizedBox(
        height: math.min(MediaQuery.sizeOf(context).height * .72, 680),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                if (_path.isNotEmpty)
                  AppleCapsuleButton(
                      key: const ValueKey('settings-drawer-back'),
                      label: '返回',
                      icon: CupertinoIcons.chevron_back,
                      onPressed: () => setState(() => _path.removeLast())),
                for (var i = 0; i < parents.length; i++)
                  AppleCapsuleButton(
                      key: ValueKey('settings-breadcrumb-$i'),
                      label: parents[i].title,
                      primary: i == parents.length - 1,
                      onPressed: i < parents.length - 1
                          ? () =>
                              setState(() => _path.removeRange(i, _path.length))
                          : null),
              ])),
          Expanded(
              child: ListView(
            key: ValueKey('settings-page-${pane.id}'),
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
            children: [
              Text(pane.subtitle,
                  style: const TextStyle(
                      color: AppleColors.labelSecondary,
                      fontSize: 13,
                      height: 1.5)),
              const SizedBox(height: 18),
              for (final child in pane.children)
                Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: SettingsCapsule(
                      key: ValueKey('settings-open-${child.id}'),
                      pane: child,
                      onPressed: () => setState(() => _path.add(child.id)),
                    )),
              if (pane.content != null) pane.content!,
            ],
          )),
        ]),
      ),
    );
  }
}

class SettingsChoices<T> extends StatelessWidget {
  final String title;
  final T value;
  final List<(T, String)> choices;
  final Future<void> Function(T) onSelected;
  const SettingsChoices(
      {super.key,
      required this.title,
      required this.value,
      required this.choices,
      required this.onSelected});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: const TextStyle(
                  color: AppleColors.labelPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 10, children: [
            for (final choice in choices)
              Semantics(
                  selected: choice.$1 == value,
                  child: AppleCapsuleButton(
                    key: ValueKey('choice-$title-${choice.$1}'),
                    label: choice.$2,
                    icon: choice.$1 == value ? CupertinoIcons.checkmark : null,
                    primary: choice.$1 == value,
                    onPressed: () => onSelected(choice.$1),
                  )),
          ]),
        ]),
      );
}
