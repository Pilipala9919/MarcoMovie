import 'dart:async';
import 'windows_appearance.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart' show Colors, Material;
import '../core/danmu/danmu_prefs.dart';
import '../core/ios_avplayer_controller.dart';
import '../core/ios_mpv_profile.dart';
import '../core/local_media_proxy.dart';
import '../core/ohos_runtime.dart';
import '../core/storage_service.dart';
import 'apple_theme.dart';
import 'danmu/danmu_settings_sheet.dart';
import 'ios_liquid_glass.dart';
import 'motion/ios27_springs.dart';
import 'player/player_hud_prefs.dart';

class SettingsPane {
  final String id, title, subtitle;
  final String? trailingText;
  final String sectionGroup;
  final IconData icon;
  final Color color;
  final List<SettingsPane> children;
  final Widget? content;
  const SettingsPane(
    this.id,
    this.title,
    this.subtitle,
    this.icon,
    this.color, {
    this.trailingText,
    this.sectionGroup = 'default',
    this.children = const [],
    this.content,
  });
}

typedef SettingsPanes = List<SettingsPane> Function(VoidCallback refresh);

/// Level-1 iOS Settings tab styled after native iOS System Settings (`UITableViewStyleInsetGrouped`).
/// Version information lives inside the `关于与更新` secondary page rather than on the root header,
/// and tapping any category pushes a full-screen `CupertinoPageRoute` secondary page.
class IosSettingsPage extends StatefulWidget {
  final SettingsPanes pages;
  final VoidCallback onChanged;
  final String version;
  final ValueChanged<bool>? onSecondaryRouteActive;
  const IosSettingsPage({
    super.key,
    required this.pages,
    required this.onChanged,
    this.version = '',
    this.onSecondaryRouteActive,
  });

  @override
  State<IosSettingsPage> createState() => _IosSettingsPageState();
}

class _IosSettingsPageState extends State<IosSettingsPage> {
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';
  bool _showCompactNavBar = false;
  bool _searchFocused = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    _searchFocusNode.addListener(_handleSearchFocus);
  }

  void _handleSearchFocus() {
    final focused = _searchFocusNode.hasFocus;
    if (focused != _searchFocused && mounted) {
      setState(() => _searchFocused = focused);
    }
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    final next = _scrollController.offset > 52;
    if (next != _showCompactNavBar && mounted) {
      setState(() => _showCompactNavBar = next);
    }
  }

  @override
  void dispose() {
    _searchFocusNode.removeListener(_handleSearchFocus);
    _searchFocusNode.dispose();
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    _searchController.dispose();
    _revision.dispose();
    super.dispose();
  }

  void _notifyChanged() {
    _revision.value++;
    if (mounted) setState(() {});
    widget.onChanged();
  }

  void _openPanePath(
    BuildContext context,
    List<String> pathIds, {
    String parentTitle = '设置',
  }) {
    widget.onSecondaryRouteActive?.call(true);
    Navigator.of(context)
        .push<void>(
          buildApplePageRoute<void>(
            builder: (_) => IosSettingsSubPage(
              pages: widget.pages,
              pathIds: pathIds,
              parentTitle: parentTitle,
              revision: _revision,
              onChanged: _notifyChanged,
            ),
          ),
        )
        .then((_) {
          widget.onSecondaryRouteActive?.call(false);
          if (mounted) setState(() {});
        });
  }

  void _openRootPane(BuildContext context, SettingsPane entry) {
    _openPanePath(context, [entry.id], parentTitle: '设置');
  }

  List<List<SettingsPane>> _groupEntries(List<SettingsPane> entries) {
    final groups = <List<SettingsPane>>[];
    for (final entry in entries) {
      if (groups.isEmpty ||
          groups.last.first.sectionGroup != entry.sectionGroup) {
        groups.add([entry]);
      } else {
        groups.last.add(entry);
      }
    }
    return groups;
  }

  String? _sectionHeaderFor(String group) => switch (group) {
    'core' => '偏好与视听体验',
    'account' => '片源、扩展与数据',
    'about' => '应用信息',
    _ => null,
  };

  List<({SettingsPane pane, List<String> pathIds, String breadcrumb})>
  _searchMatches(List<SettingsPane> roots, String rawQuery) {
    final q = rawQuery.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final hits =
        <({SettingsPane pane, List<String> pathIds, String breadcrumb})>[];
    for (final root in roots) {
      final rootMatch =
          root.title.toLowerCase().contains(q) ||
          root.subtitle.toLowerCase().contains(q) ||
          (root.trailingText?.toLowerCase().contains(q) ?? false);
      if (rootMatch) {
        hits.add((pane: root, pathIds: [root.id], breadcrumb: root.subtitle));
      }
      for (final child in root.children) {
        final childMatch =
            child.title.toLowerCase().contains(q) ||
            child.subtitle.toLowerCase().contains(q) ||
            (child.trailingText?.toLowerCase().contains(q) ?? false);
        if (childMatch) {
          hits.add((
            pane: child,
            pathIds: [root.id, child.id],
            breadcrumb: '${root.title} · ${child.subtitle}',
          ));
        }
      }
    }
    return hits;
  }

  Widget _buildIos26SearchPill(BuildContext context) {
    final p = ApplePalette.of(context);
    final reduceMotion = Ios27ConcentricGeometry.isReduceMotion(context);
    final duration = reduceMotion
        ? Ios27ConcentricGeometry.reducedMotionDuration
        : Ios27Spring.bouncy.nominalDuration;
    final curve = reduceMotion ? Curves.linear : Ios27Spring.bouncy.curve;
    return AnimatedScale(
      scale: (!reduceMotion && _searchFocused) ? 1.012 : 1.0,
      duration: duration,
      curve: curve,
      child: AnimatedContainer(
        key: const ValueKey('ios-settings-search'),
        duration: duration,
        curve: curve,
        height: 40,
        decoration: BoxDecoration(
          color: p.isDark
              ? (_searchFocused
                  ? const Color(0xF525252A)
                  : const Color(0xEB1C1C1E))
              : (_searchFocused
                  ? const Color(0xFFF4F6FB)
                  : const Color(0xFFE1E5EE)),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _searchFocused
                ? p.systemBlue.withValues(alpha: p.isDark ? 0.55 : 0.42)
                : p.glassBorder,
            width: _searchFocused ? 1.0 : 0.6,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Icon(
              CupertinoIcons.search,
              color: _searchFocused ? p.systemBlue : p.labelSecondary,
              size: 17,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: CupertinoTextField(
                controller: _searchController,
                focusNode: _searchFocusNode,
                placeholder: '搜索设置',
                placeholderStyle: TextStyle(
                  color: p.labelSecondary,
                  fontSize: 16,
                ),
                style: TextStyle(
                  color: p.labelPrimary,
                  fontSize: 16,
                ),
                padding: EdgeInsets.zero,
                decoration: null,
                clearButtonMode: OverlayVisibilityMode.never,
                onChanged: (v) => setState(() => _searchQuery = v),
              ),
            ),
            if (_searchQuery.isNotEmpty)
              Ios27Pressable(
                pressedScale: Ios27Spring.pressSwellScale,
                borderRadius: 999,
                onTap: () {
                  _searchController.clear();
                  setState(() => _searchQuery = '');
                },
                child: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(
                    CupertinoIcons.clear_circled_solid,
                    color: p.labelSecondary,
                    size: 18,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaPadding = MediaQuery.paddingOf(context);
    final safeBottom = mediaPadding.bottom;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isWide = screenWidth >= 600;
    final hPad = screenWidth < 360 ? 12.0 : (isWide ? 24.0 : 16.0);
    final groupGap = isWide ? 22.0 : 16.0;
    final entries = widget.pages(_notifyChanged);
    final grouped = _groupEntries(entries);
    final query = _searchQuery.trim();
    final searchHits = query.isNotEmpty
        ? _searchMatches(entries, query)
        : const <
            ({SettingsPane pane, List<String> pathIds, String breadcrumb})
          >[];

    return Stack(
      children: [
        SafeArea(
          bottom: false,
          child: ListView(
            key: const ValueKey('ios-settings-root'),
            controller: _scrollController,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            padding: EdgeInsets.fromLTRB(hPad, 6, hPad, safeBottom + 108),
            children: [
              Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 740),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
                        child: Text(
                          '设置',
                          style: TextStyle(
                            color: ApplePalette.of(context).labelPrimary,
                            fontSize: 34,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.6,
                            height: 1.15,
                          ),
                        ),
                      ),
                      _buildIos26SearchPill(context),
                      const SizedBox(height: 14),
                      if (query.isNotEmpty) ...[
                        if (searchHits.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 36),
                            child: Center(
                              child: Text(
                                '未找到匹配的设置项',
                                style: TextStyle(
                                  color: ApplePalette.of(context).labelSecondary,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                          )
                        else
                          IosSettingsGroup(
                            header: '搜索结果 (${searchHits.length})',
                            children: [
                              for (final hit in searchHits)
                                IosSettingsRow(
                                  icon: hit.pane.icon,
                                  iconColor: hit.pane.color,
                                  title: hit.pane.title,
                                  subtitle: hit.breadcrumb.isNotEmpty
                                      ? hit.breadcrumb
                                      : null,
                                  subtitleMaxLines: 1,
                                  trailingText: hit.pane.trailingText,
                                  showChevron: true,
                                  onTap: () => _openPanePath(
                                    context,
                                    hit.pathIds,
                                    parentTitle: '设置',
                                  ),
                                ),
                            ],
                          ),
                      ] else ...[
                        for (var gIdx = 0; gIdx < grouped.length; gIdx++) ...[
                          if (gIdx > 0) SizedBox(height: groupGap),
                          IosSettingsGroup(
                            header: _sectionHeaderFor(
                              grouped[gIdx].first.sectionGroup,
                            ),
                            children: [
                              for (final entry in grouped[gIdx])
                                IosSettingsRow(
                                  key: ValueKey(
                                    'settings-category-${entry.id}',
                                  ),
                                  icon: entry.icon,
                                  iconColor: entry.color,
                                  title: entry.title,
                                  trailingText: entry.trailingText,
                                  compact: true,
                                  showChevron: true,
                                  onTap: () => _openRootPane(context, entry),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        // Sticky collapsing inline iOS 26 navigation title bar when scrolled in portrait.
        if (MediaQuery.sizeOf(context).height >= 500)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              ignoring: true,
              child: AnimatedOpacity(
                duration: Ios27ConcentricGeometry.isReduceMotion(context)
                    ? Ios27ConcentricGeometry.reducedMotionDuration
                    : Ios27Spring.smooth.nominalDuration,
                curve: Ios27Spring.smooth.curve,
                opacity: _showCompactNavBar ? 1.0 : 0.0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: ApplePalette.isDarkOf(context)
                        ? const Color(0xEB0A0A0D)
                        : const Color(0xF2EDF0F5),
                    border: Border(
                      bottom: BorderSide(
                        color: ApplePalette.of(context).separator,
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: EdgeInsets.only(top: mediaPadding.top),
                    child: SizedBox(
                      height: 44,
                      child: Center(
                        child: Text(
                          '设置',
                          style: TextStyle(
                            color: ApplePalette.of(context).labelPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Full-screen iOS System Settings secondary/tertiary page scaffold with standard
/// `< 返回` top navigation bar, dark inset-grouped background, and swipe-back support.
class IosSettingsScaffold extends StatelessWidget {
  final String title;
  final String backLabel;
  final Widget? trailing;
  final Widget body;

  const IosSettingsScaffold({
    super.key,
    required this.title,
    this.backLabel = '设置',
    this.trailing,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final mediaPadding = MediaQuery.paddingOf(context);
    final p = ApplePalette.of(context);
    final bgColor = p.isDark ? const Color(0xFF000000) : p.canvas;
    return Material(
      color: bgColor,
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: p.isDark
                      ? const [
                          Color(0xF008080A),
                          Color(0xCC08080A),
                          Color(0x0008080A),
                        ]
                      : const [
                          Color(0xFAEDF0F5),
                          Color(0xE8E9ECF2),
                          Color(0x00E9ECF2),
                        ],
                  stops: const [0.0, 0.78, 1.0],
                ),
              ),
              child: Padding(
                padding: EdgeInsets.only(
                  top: mediaPadding.top + 4,
                  bottom: 6,
                  left: mediaPadding.left + 12,
                  right: mediaPadding.right + 12,
                ),
                child: SizedBox(
                  height: 42,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IosNativeGlassButton(
                          key: const ValueKey('settings-drawer-back'),
                          style: 'circle',
                          symbol: 'chevron.backward',
                          symbolSize: 17,
                          width: 40,
                          height: 40,
                          accessibilityLabel: backLabel,
                          onTap: () => Navigator.of(context).maybePop(),
                          fallback: Ios27Pressable(
                            pressedScale: Ios27Spring.pressSwellScale,
                            borderRadius: 20,
                            onTap: () => Navigator.of(context).maybePop(),
                            child: LiquidGlass(
                              width: 40,
                              height: 40,
                              borderRadius: 20,
                              elevated: false,
                              tint: p.isDark
                                  ? const Color(0x521E1E22)
                                  : const Color(0xD8FFFFFF),
                              child: Center(
                                child: Icon(
                                  CupertinoIcons.back,
                                  color: p.labelPrimary,
                                  size: 20,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 64),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: p.labelPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      if (trailing != null)
                        Align(
                          alignment: Alignment.centerRight,
                          child: trailing!,
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: SafeArea(
                top: false,
                bottom: false,
                child: RepaintBoundary(child: body),
              ),
            ),
          ],
        ),
    );
  }
}

class IosSettingsSubPage extends StatefulWidget {
  final SettingsPanes pages;
  final List<String> pathIds;
  final String parentTitle;
  final ValueNotifier<int> revision;
  final VoidCallback onChanged;

  const IosSettingsSubPage({
    super.key,
    required this.pages,
    required this.pathIds,
    required this.parentTitle,
    required this.revision,
    required this.onChanged,
  });

  @override
  State<IosSettingsSubPage> createState() => _IosSettingsSubPageState();
}

class _IosSettingsSubPageState extends State<IosSettingsSubPage> {
  void _refresh() {
    widget.onChanged();
    if (mounted) setState(() {});
  }

  SettingsPane _resolveCurrentPane() {
    // Resolve from fresh storage values on every rebuild, including after back
    // navigation. Do not retain a stale widget / selection in the page stack.
    final roots = widget.pages(_refresh);
    var pane = roots.firstWhere(
      (p) => p.id == widget.pathIds.first,
      orElse: () => roots.first,
    );
    for (var i = 1; i < widget.pathIds.length; i++) {
      final id = widget.pathIds[i];
      pane = pane.children.firstWhere(
        (p) => p.id == id,
        orElse: () => pane,
      );
    }
    return pane;
  }

  void _openChild(BuildContext context, SettingsPane current, SettingsPane child) {
    Navigator.of(context)
        .push<void>(
          buildApplePageRoute<void>(
            builder: (_) => IosSettingsSubPage(
              pages: widget.pages,
              pathIds: [...widget.pathIds, child.id],
              parentTitle: current.title,
              revision: widget.revision,
              onChanged: widget.onChanged,
            ),
          ),
        )
        .then((_) {
          if (mounted) setState(() {});
        });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: widget.revision,
      builder: (context, _, __) {
        final pane = _resolveCurrentPane();
        final safeBottom = MediaQuery.paddingOf(context).bottom;
        final screenWidth = MediaQuery.sizeOf(context).width;
        final hPad = screenWidth >= 600 ? 24.0 : 18.0;
        return IosSettingsScaffold(
          title: pane.title,
          backLabel: widget.parentTitle,
          body: ListView(
            key: ValueKey('settings-page-${pane.id}'),
            padding: EdgeInsets.fromLTRB(hPad, 22, hPad, safeBottom + 40),
            children: [
              Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 740),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (pane.children.isNotEmpty) ...[
                        IosSettingsGroup(
                          footer: pane.subtitle.isNotEmpty ? pane.subtitle : null,
                          children: [
                            for (final child in pane.children)
                              IosSettingsRow(
                                key: ValueKey('settings-open-${child.id}'),
                                icon: child.icon,
                                iconColor: child.color,
                                title: child.title,
                                subtitle: child.subtitle.isNotEmpty
                                    ? child.subtitle
                                    : null,
                                trailingText: child.trailingText,
                                showChevron: true,
                                onTap: () => _openChild(context, pane, child),
                              ),
                          ],
                        ),
                        if (pane.content != null) const SizedBox(height: 24),
                      ],
                      if (pane.content != null) pane.content!,
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Native iOS 26 System Settings inset-grouped table section (`#1C1C1E` 22pt
/// rounded card with `0.5pt` `#38383A` hairlines).
class IosSettingsGroup extends StatelessWidget {
  final String? header;
  final String? footer;
  final double dividerIndent;
  final List<Widget> children;

  const IosSettingsGroup({
    super.key,
    this.header,
    this.footer,
    this.dividerIndent = 58,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    if (usesWindowsSettings(context)) {
      return WinSettingsGroup(header: header, footer: footer, children: children);
    }
    final p = ApplePalette.of(context);
    final separated = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      separated.add(children[i]);
      if (i < children.length - 1) {
        separated.add(
          Container(
            height: 0.5,
            margin: EdgeInsets.only(left: dividerIndent, right: 16),
            color: p.isDark ? const Color(0xA638383A) : p.separator,
          ),
        );
      }
    }
    final cardBg = p.isDark
        ? const Color(0xFF1C1C1E)
        : Colors.white;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (header != null && header!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 18, right: 18, bottom: 9),
            child: Text(
              header!,
              style: TextStyle(
                color: p.labelSecondary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
              ),
            ),
          ),
        ClipPath(
          clipper: ShapeBorderClipper(
            shape: Ios27ConcentricGeometry.continuousShape(radius: 22),
          ),
          clipBehavior: Clip.antiAlias,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: cardBg,
              shape: Ios27ConcentricGeometry.continuousShape(
                radius: 22,
                side: BorderSide(
                  color: p.isDark
                      ? Colors.white.withValues(alpha: 0.10)
                      : Colors.black.withValues(alpha: 0.06),
                  width: 0.65,
                ),
              ),
              shadows: p.isDark
                  ? null
                  : const [
                      BoxShadow(
                        color: Color(0x0C0F172A),
                        blurRadius: 12,
                        offset: Offset(0, 3),
                      ),
                    ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: separated,
            ),
          ),
        ),
        if (footer != null && footer!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 18, right: 18, top: 9),
            child: Text(
              footer!,
              style: TextStyle(
                color: p.labelSecondary,
                fontSize: 13.5,
                height: 1.5,
              ),
            ),
          ),
      ],
    );
  }
}

/// Native iOS 26 System Settings cell with optional vivid `30×30` squircle icon
/// badge, title, optional subtitle, right-side detail text, or disclosure chevron.
class IosSettingsRow extends StatefulWidget {
  final IconData? icon;
  final Color iconColor;
  final String title;
  final Color? titleColor;
  final String? subtitle;
  final int subtitleMaxLines;
  final String? trailingText;
  final Widget? trailing;
  final bool compact;
  final bool showChevron;
  final VoidCallback? onTap;

  const IosSettingsRow({
    super.key,
    this.icon,
    this.iconColor = AppleColors.systemBlue,
    required this.title,
    this.titleColor,
    this.subtitle,
    this.subtitleMaxLines = 2,
    this.trailingText,
    this.trailing,
    this.compact = false,
    this.showChevron = false,
    this.onTap,
  });

  @override
  State<IosSettingsRow> createState() => _IosSettingsRowState();
}

class _IosSettingsRowState extends State<IosSettingsRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    if (usesWindowsSettings(context)) {
      return WinSettingsRow(title: widget.title, titleColor: widget.titleColor,
          subtitle: widget.subtitle, icon: widget.icon, value: widget.trailingText,
          trailing: widget.trailing, onTap: widget.onTap);
    }
    final p = ApplePalette.of(context);
    final hasSubtitle = widget.subtitle != null && widget.subtitle!.isNotEmpty;
    final minHeight = hasSubtitle
        ? 64.0
        : (widget.compact ? 52.0 : 56.0);
    final vPad = hasSubtitle
        ? 12.5
        : (widget.compact ? 11.0 : 12.5);
    final reduceMotion = Ios27ConcentricGeometry.isReduceMotion(context);
    final row = AnimatedContainer(
      duration: reduceMotion
          ? Ios27ConcentricGeometry.reducedMotionDuration
          : Ios27Spring.snappy.nominalDuration,
      curve: reduceMotion ? Curves.linear : Ios27Spring.snappy.curve,
      color: _pressed
          ? (p.isDark ? const Color(0xFF2C2C2E) : const Color(0x14000000))
          : const Color(0x00000000),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 16,
            vertical: vPad,
          ),
          child: Row(
            children: [
              if (widget.icon != null) ...[
                DecoratedBox(
                  decoration: ShapeDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color.alphaBlend(
                          const Color(0x28FFFFFF),
                          widget.iconColor,
                        ),
                        widget.iconColor,
                      ],
                    ),
                    shape: RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: const BorderSide(
                        color: Color(0x28FFFFFF),
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: SizedBox(
                    width: 32,
                    height: 32,
                    child: Icon(widget.icon, color: Colors.white, size: 17.5),
                  ),
                ),
                const SizedBox(width: 13),
              ],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: TextStyle(
                        color: widget.titleColor ?? p.labelPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.2,
                      ),
                    ),
                    if (hasSubtitle) ...[
                      const SizedBox(height: 3.5),
                      Text(
                        widget.subtitle!,
                        maxLines: widget.subtitleMaxLines,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.labelSecondary,
                          fontSize: 13.5,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.trailingText != null &&
                  widget.trailingText!.isNotEmpty) ...[
                const SizedBox(width: 8),
                Flexible(
                  flex: 0,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth:
                          MediaQuery.sizeOf(context).width < 360 ? 108 : 152,
                    ),
                    child: Text(
                      widget.trailingText!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.labelSecondary,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ],
              if (widget.trailing != null) ...[
                const SizedBox(width: 10),
                widget.trailing!,
              ] else if (widget.showChevron) ...[
                const SizedBox(width: 6),
                Icon(
                  CupertinoIcons.chevron_forward,
                  color: p.labelTertiary,
                  size: 14.5,
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (widget.onTap == null) return row;
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: row,
      ),
    );
  }
}

/// Native iOS 26 System Settings switch row backed by genuine UIKit `UISwitch`
/// (with Liquid Glass expanding thumb on iOS 26+) and `CupertinoSwitch` fallback.
class IosSettingsSwitchRow extends StatelessWidget {
  final IconData? icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const IosSettingsSwitchRow({
    super.key,
    this.icon,
    this.iconColor = AppleColors.systemBlue,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return IosSettingsRow(
      icon: icon,
      iconColor: iconColor,
      title: title,
      subtitle: subtitle,
      trailing: IosNativeSwitch(
        value: value,
        activeColor: AppleColors.systemGreen,
        accessibilityLabel: title,
        onChanged: onChanged,
      ),
    );
  }
}

/// Single selectable option cell inside an iOS System Settings checkmark group.
class IosSettingsChoiceTile extends StatefulWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const IosSettingsChoiceTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  State<IosSettingsChoiceTile> createState() => _IosSettingsChoiceTileState();
}

class _IosSettingsChoiceTileState extends State<IosSettingsChoiceTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final p = ApplePalette.of(context);
    return Semantics(
      button: true,
      selected: widget.selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Ios27ConcentricGeometry.isReduceMotion(context)
              ? Ios27ConcentricGeometry.reducedMotionDuration
              : Ios27Spring.snappy.nominalDuration,
          curve: Ios27ConcentricGeometry.isReduceMotion(context)
              ? Curves.linear
              : Ios27Spring.snappy.curve,
          color: _pressed
              ? (p.isDark ? const Color(0xFF2C2C2E) : const Color(0x14000000))
              : const Color(0x00000000),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 54),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        color: p.labelPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                  if (widget.selected)
                    Icon(
                      CupertinoIcons.checkmark_alt,
                      color: p.systemBlue,
                      size: 19.5,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SettingsChoices<T> extends StatelessWidget {
  final String title;
  final String? footer;
  final T value;
  final List<(T, String)> choices;
  final Future<void> Function(T) onSelected;
  const SettingsChoices({
    super.key,
    required this.title,
    this.footer,
    required this.value,
    required this.choices,
    required this.onSelected,
  });
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: IosSettingsGroup(
          header: title,
          footer: footer,
          dividerIndent: 18,
          children: [
            for (final choice in choices)
              IosSettingsChoiceTile(
                key: ValueKey('choice-$title-${choice.$1}'),
                label: choice.$2,
                selected: choice.$1 == value,
                onTap: () => onSelected(choice.$1),
              ),
          ],
        ),
      );
}

/// Global Danmaku settings section using [IosSettingsSwitchRow] (`IosNativeSwitch`
/// on iOS 26+, `CupertinoSwitch` fallback elsewhere). Guarded with `!OhosRuntime.isOhos`.
class IosDanmuSettingsSection extends StatefulWidget {
  final DanmuSettings? initialSettingsOverride;
  final VoidCallback? onChanged;

  const IosDanmuSettingsSection({
    super.key,
    this.initialSettingsOverride,
    this.onChanged,
  });

  @override
  State<IosDanmuSettingsSection> createState() =>
      _IosDanmuSettingsSectionState();
}

class _IosDanmuSettingsSectionState extends State<IosDanmuSettingsSection> {
  DanmuSettings _settings = const DanmuSettings();

  @override
  void initState() {
    super.initState();
    if (OhosRuntime.isOhos) return;
    if (widget.initialSettingsOverride != null) {
      _settings = widget.initialSettingsOverride!;
    } else {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final loaded = await DanmuPrefs.load();
    if (!mounted) return;
    setState(() => _settings = loaded);
  }

  Future<void> _update(DanmuSettings next) async {
    if (OhosRuntime.isOhos) return;
    setState(() => _settings = next);
    await DanmuPrefs.save(next);
    if (!mounted) return;
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (OhosRuntime.isOhos) return const SizedBox.shrink();
    final serverCount = _settings.normalizedOrigins.length;
    return IosSettingsGroup(
      header: '分片弹幕',
      footer: '默认服务地址为空，需自行填写兼容弹幕服务地址后启用拉取。',
      children: [
        IosSettingsSwitchRow(
          key: const ValueKey('ios-switch-danmu-enabled'),
          icon: CupertinoIcons.chat_bubble_text_fill,
          iconColor: AppleColors.systemTeal,
          title: '默认开启弹幕',
          subtitle: '进入点播播放页时自动开启弹幕叠加层',
          value: _settings.enabled,
          onChanged: (v) => unawaited(_update(_settings.copyWith(enabled: v))),
        ),
        IosSettingsSwitchRow(
          key: const ValueKey('ios-switch-danmu-scroll'),
          icon: CupertinoIcons.arrow_left_right,
          iconColor: AppleColors.systemBlue,
          title: '滚动弹幕',
          value: _settings.showScroll,
          onChanged: (v) =>
              unawaited(_update(_settings.copyWith(showScroll: v))),
        ),
        IosSettingsSwitchRow(
          key: const ValueKey('ios-switch-danmu-top'),
          icon: CupertinoIcons.arrow_up_to_line,
          iconColor: AppleColors.systemIndigo,
          title: '顶部固定弹幕',
          value: _settings.showTop,
          onChanged: (v) => unawaited(_update(_settings.copyWith(showTop: v))),
        ),
        IosSettingsSwitchRow(
          key: const ValueKey('ios-switch-danmu-bottom'),
          icon: CupertinoIcons.arrow_down_to_line,
          iconColor: AppleColors.systemPurple,
          title: '底部固定弹幕',
          value: _settings.showBottom,
          onChanged: (v) =>
              unawaited(_update(_settings.copyWith(showBottom: v))),
        ),
        IosSettingsRow(
          key: const ValueKey('ios-open-danmu-advanced'),
          icon: CupertinoIcons.slider_horizontal_3,
          iconColor: AppleColors.systemOrange,
          title: '弹幕样式、服务地址与屏蔽词',
          subtitle: '调节透明度、字号、显示区域、兼容服务源与正则屏蔽词',
          trailingText: serverCount > 0 ? '$serverCount 个服务源' : '未配置',
          showChevron: true,
          onTap: () {
            unawaited(
              DanmuSettingsSheet.show(
                context,
                initialSettings: _settings,
                onChanged: (updated) {
                  if (!mounted) return;
                  setState(() => _settings = updated);
                  widget.onChanged?.call();
                },
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Global Player HUD & gesture switches backed by [PlayerHudPrefs] using
/// [IosSettingsSwitchRow] (`IosNativeSwitch` on iOS). Guarded with `!OhosRuntime.isOhos`.
class IosPlayerHudSettingsSection extends StatefulWidget {
  final PlayerHudPrefs? debugHudPrefs;
  final VoidCallback? onChanged;

  const IosPlayerHudSettingsSection({
    super.key,
    this.debugHudPrefs,
    this.onChanged,
  });

  @override
  State<IosPlayerHudSettingsSection> createState() =>
      _IosPlayerHudSettingsSectionState();
}

class _IosPlayerHudSettingsSectionState
    extends State<IosPlayerHudSettingsSection> {
  late final PlayerHudPrefs _hudPrefs;
  late final bool _ownsPrefs;

  @override
  void initState() {
    super.initState();
    final isDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);
    _ownsPrefs = widget.debugHudPrefs == null;
    _hudPrefs = widget.debugHudPrefs ?? PlayerHudPrefs(isDesktop: isDesktop);
    _hudPrefs.addListener(_onPrefsChanged);
    if (!OhosRuntime.isOhos) {
      unawaited(_hudPrefs.load());
    }
  }

  void _onPrefsChanged() {
    if (mounted) setState(() {});
    widget.onChanged?.call();
  }

  @override
  void dispose() {
    _hudPrefs.removeListener(_onPrefsChanged);
    if (_ownsPrefs) {
      _hudPrefs.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (OhosRuntime.isOhos) return const SizedBox.shrink();
    final data = _hudPrefs.data;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IosSettingsGroup(
          header: '播放界面与 HUD',
          footer: '仅保存在本机，不影响跨端配置同步。',
          children: [
            IosSettingsSwitchRow(
              key: const ValueKey('ios-switch-hud-start-spec'),
              icon: CupertinoIcons.sparkles,
              iconColor: AppleColors.systemBlue,
              title: '起播规格提示',
              subtitle: '首帧就绪后展示 4K / HDR / 杜比等媒体规格徽章',
              value: data.startSpecHud,
              onChanged: (v) => unawaited(_hudPrefs.setStartSpecHud(v)),
            ),
            IosSettingsSwitchRow(
              key: const ValueKey('ios-switch-hud-slim-progress'),
              icon: CupertinoIcons.minus_rectangle_fill,
              iconColor: AppleColors.systemTeal,
              title: '隐藏控制栏时显示细进度条',
              subtitle: '点播播放隐藏主控栏后在底部常驻细进度指示条',
              value: data.slimProgress,
              onChanged: (v) => unawaited(_hudPrefs.setSlimProgress(v)),
            ),
            IosSettingsSwitchRow(
              key: const ValueKey('ios-switch-hud-skip-countdown'),
              icon: CupertinoIcons.forward_end_alt_fill,
              iconColor: AppleColors.systemIndigo,
              title: '跳过片头/片尾 3 秒倒计时',
              subtitle: '关闭后达到跳过点将静默立即跳转',
              value: data.skipCountdown,
              onChanged: (v) => unawaited(_hudPrefs.setSkipCountdown(v)),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingsChoices<String>(
          title: '两侧双击手势',
          value: data.doubleTapSides,
          choices: const [
            ('seek_10s', '快进 / 快退 10 秒（默认）'),
            ('seek_15s', '快进 / 快退 15 秒'),
            ('seek_5s', '快进 / 快退 5 秒'),
            ('play_pause', '全屏双击播放 / 暂停'),
          ],
          onSelected: (v) => _hudPrefs.setDoubleTapSides(v),
        ),
        SettingsChoices<String>(
          title: '长按倍速松手恢复',
          value: data.longPressRestoreMode,
          choices: const [
            ('previous', '恢复长按前常驻倍速（默认）'),
            ('1.0x', '强制恢复 1.0× 原速'),
          ],
          onSelected: (v) => _hudPrefs.setLongPressRestoreMode(v),
        ),
      ],
    );
  }
}

/// iOS 27 dual-engine (`AVPlayer` / `MPV`), HDR tone-mapping, 4-tier vocal
/// loudness gain, and Apple Silicon thermal-guarded single-pass Anime4K settings.
class IosPlaybackEngineSettingsSection extends StatelessWidget {
  final StorageService storage;
  final VoidCallback? onChanged;

  const IosPlaybackEngineSettingsSection({
    super.key,
    required this.storage,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (OhosRuntime.isOhos) return const SizedBox.shrink();
    final engineMode = IosPlaybackEngineMode.fromId(storage.iosPlaybackEngineMode);
    final hdrMode = IosHdrToneMappingMode.fromId(storage.iosHdrToneMappingMode);
    final loudness = VocalLoudnessPreset.fromId(storage.vocalLoudnessPreset);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsChoices<String>(
          title: '播放内核偏好',
          footer:
              'Apple 原生 AVPlayer 支持低功耗 4K/HDR 硬件直出、画中画 (PiP) 与 AirPlay 2（遇到 MKV/FLV/ASS 特效字幕或异常时自动无感切换 MPV）；MPV 全能解码原生支持全格式与 Anime4K 超分。',
          value: engineMode.id,
          choices: [
            for (final mode in IosPlaybackEngineMode.values)
              (mode.id, mode.labelZh),
          ],
          onSelected: (val) async {
            await storage.setIosPlaybackEngineMode(val);
            onChanged?.call();
          },
        ),
        SettingsChoices<String>(
          title: 'HDR 色调映射（MPV 内核）',
          footer: '在 iOS / iPadOS XDR 屏幕与标准屏幕间自动适配杜比视界 / HDR10 峰值亮度曲线。',
          value: hdrMode.id,
          choices: [
            for (final mode in IosHdrToneMappingMode.values)
              (mode.id, mode.labelZh),
          ],
          onSelected: (val) async {
            await storage.setIosHdrToneMappingMode(val);
            onChanged?.call();
          },
        ),
        SettingsChoices<String>(
          title: '人声响度增强（4 档）',
          footer: '动态均衡 5.1 / 7.1 环绕声下混双声道时偏轻的对白人声（支持 AVPlayer 之外的 MPV 全能模式与跨端播放）。',
          value: loudness.id,
          choices: [
            for (final preset in VocalLoudnessPreset.values)
              (preset.id, '${preset.labelZh} · ${preset.descriptionZh}'),
          ],
          onSelected: (val) async {
            await storage.setVocalLoudnessPreset(val);
            onChanged?.call();
          },
        ),
        IosSettingsGroup(
          header: 'Apple Silicon 轻量超分与高内存缓冲',
          footer:
              '单 Pass Anime4K（Anime4K_Upscale_CNN_x2_S.glsl）仅在 MPV 内核生效，推荐 A15+ / M 系芯片开启；当系统检测到 serious / critical 高温状态时将自动关闭以防降频掉帧。',
          children: [
            IosSettingsSwitchRow(
              key: const ValueKey('ios-switch-anime4k-lightweight'),
              icon: CupertinoIcons.wand_stars,
              iconColor: AppleColors.systemPurple,
              title: 'Apple Silicon 轻量 Anime4K 超分',
              subtitle: '高温自动降级保护（仅 MPV 路径生效）',
              value: storage.iosAnime4kLightweightEnabled,
              onChanged: (v) async {
                await storage.setIosAnime4kLightweightEnabled(v);
                onChanged?.call();
              },
            ),
            IosSettingsSwitchRow(
              key: const ValueKey('ios-switch-mpv-large-buffer'),
              icon: CupertinoIcons.gauge,
              iconColor: AppleColors.systemTeal,
              title: '6 GB+ 设备大容量预读缓冲',
              subtitle: '将 MPV 前向缓冲从 128 MB 提升至 256 MB，减少 4K 高码率卡顿',
              value: storage.iosLargeBufferEnabled,
              onChanged: (v) async {
                await storage.setIosLargeBufferEnabled(v);
                onChanged?.call();
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// Local media 256 KiB disk block cache limit/clear & HLS VOD ad-removal settings.
class IosMediaCacheAndAdSection extends StatefulWidget {
  final StorageService storage;
  final VoidCallback? onChanged;

  const IosMediaCacheAndAdSection({
    super.key,
    required this.storage,
    this.onChanged,
  });

  @override
  State<IosMediaCacheAndAdSection> createState() =>
      _IosMediaCacheAndAdSectionState();
}

class _IosMediaCacheAndAdSectionState
    extends State<IosMediaCacheAndAdSection> {
  bool _clearing = false;

  static String _formatCacheBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _setLimitMb(int mb) async {
    await widget.storage.setMediaDiskCacheLimitMb(mb);
    await DiskBlockCache.shared.setCapacityMb(mb);
    if (mounted) setState(() {});
    widget.onChanged?.call();
  }

  Future<void> _clearMediaDiskCache() async {
    if (_clearing) return;
    setState(() => _clearing = true);
    try {
      await DiskBlockCache.shared.clear();
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
    widget.onChanged?.call();
    if (!mounted) return;
    await showAppleNativeAlert(
      context,
      title: '媒体缓存已清理',
      message: '已清空本地媒体 256 KiB 分块落盘缓存。',
      actions: const [
        AppleNativeAlertAction(id: 'ok', title: '好的', isDefault: true),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (OhosRuntime.isOhos) return const SizedBox.shrink();
    final limitMb = widget.storage.mediaDiskCacheLimitMb;
    final usedLabel = _formatCacheBytes(DiskBlockCache.shared.currentBytes);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IosSettingsGroup(
          header: '点播流净化与拦截',
          footer: '仅对点播（含 #EXT-X-ENDLIST 或 VOD 标记）生效，直播流永远不会触发广告剔除。',
          children: [
            IosSettingsSwitchRow(
              key: const ValueKey('ios-switch-hls-ad-removal'),
              icon: CupertinoIcons.scissors,
              iconColor: AppleColors.systemOrange,
              title: 'HLS 点播自动去广告',
              subtitle: '启发式剔除 #EXT-X-DISCONTINUITY 插播广告切片',
              value: widget.storage.hlsAdRemovalEnabled,
              onChanged: (v) async {
                await widget.storage.setHlsAdRemovalEnabled(v);
                if (mounted) setState(() {});
                widget.onChanged?.call();
              },
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingsChoices<int>(
          title: '本地媒体落盘缓存上限',
          footer: '按 256 KiB 块对齐缓存点播拖动分片（当前已占用 $usedLabel），超出上限时自动按 LRU 淘汰。',
          value: limitMb,
          choices: const [
            (0, '关闭（仅内存播放）'),
            (128, '128 MB'),
            (256, '256 MB（默认）'),
            (512, '512 MB'),
          ],
          onSelected: _setLimitMb,
        ),
        IosSettingsGroup(
          dividerIndent: 18,
          children: [
            IosSettingsRow(
              key: const ValueKey('ios-media-disk-cache-usage'),
              icon: CupertinoIcons.tray_full_fill,
              iconColor: AppleColors.systemBlue,
              title: '媒体分块落盘缓存占用',
              trailingText: usedLabel,
            ),
            IosSettingsRow(
              key: const ValueKey('ios-clear-media-disk-cache-row'),
              title: _clearing ? '正在清理媒体缓存…' : '一键清理媒体落盘缓存',
              titleColor: AppleColors.systemRed,
              onTap: _clearing ? null : _clearMediaDiskCache,
            ),
          ],
        ),
      ],
    );
  }
}
