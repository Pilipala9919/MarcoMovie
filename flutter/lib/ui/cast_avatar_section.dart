import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/cast_avatar_service.dart';
import 'apple_theme.dart';
import 'desktop_horizontal_scroller.dart';
import 'windows_appearance.dart';

/// Horizontal circular actor/director avatar carousel used on the Detail page
/// (iOS / macOS / Windows) and the iOS Portrait Companion Player.
class CastAvatarSection extends StatefulWidget {
  final String title;
  final String actorRaw;
  final String year;
  final String doubanId;
  final bool? wantMotionComic;
  final List<CastMember>? initialMembers;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? containerMargin;
  final EdgeInsetsGeometry? containerPadding;
  final BoxDecoration? containerDecoration;
  final bool forceDark;
  final bool allowExternalLookup;
  final ValueChanged<CastMember>? onTapMember;

  const CastAvatarSection({
    super.key,
    required this.title,
    this.actorRaw = '',
    this.year = '',
    this.doubanId = '',
    this.wantMotionComic,
    this.initialMembers,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.containerMargin,
    this.containerPadding,
    this.containerDecoration,
    this.forceDark = false,
    this.allowExternalLookup = true,
    this.onTapMember,
  });

  @override
  State<CastAvatarSection> createState() => _CastAvatarSectionState();
}

class _CastAvatarSectionState extends State<CastAvatarSection> {
  final ScrollController _scrollController = ScrollController();
  List<CastMember> _members = const [];
  bool _loading = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _initAndLoad();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant CastAvatarSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title ||
        oldWidget.actorRaw != widget.actorRaw ||
        oldWidget.year != widget.year ||
        oldWidget.doubanId != widget.doubanId ||
        oldWidget.wantMotionComic != widget.wantMotionComic ||
        oldWidget.allowExternalLookup != widget.allowExternalLookup ||
        oldWidget.initialMembers != widget.initialMembers) {
      _initAndLoad();
    }
  }

  void _initAndLoad() {
    final gen = ++_generation;
    if (widget.initialMembers != null) {
      _members = widget.initialMembers!;
      _loading = false;
      return;
    }
    final hasExplicitDouban = widget.doubanId.trim().isNotEmpty;
    final cached =
        hasExplicitDouban ? null : CastAvatarService.peekCached(widget.title);
    if (cached != null &&
        cached.isNotEmpty &&
        (cached.any((m) => m.avatarUrl.isNotEmpty) ||
            !widget.allowExternalLookup ||
            Platform.environment.containsKey('FLUTTER_TEST'))) {
      _members = cached;
      _loading = false;
      return;
    }
    _members = cached != null && cached.isNotEmpty
        ? cached
        : CastAvatarService.parseRawActors(widget.actorRaw);
    if (!widget.allowExternalLookup) {
      _loading = false;
      return;
    }
    _loading = widget.title.trim().isNotEmpty || hasExplicitDouban;
    if (!_loading) return;
    CastAvatarService.resolveCast(
      title: widget.title,
      actorRaw: widget.actorRaw,
      year: widget.year,
      doubanId: widget.doubanId,
      wantMotionComic: widget.wantMotionComic,
      onProgress: (partial) {
        if (!mounted || gen != _generation || partial.isEmpty) return;
        setState(() => _members = partial);
      },
    ).then((resolved) {
      if (!mounted || gen != _generation) return;
      setState(() {
        if (resolved.isNotEmpty) {
          _members = resolved;
        }
        _loading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_members.isEmpty && !_loading) return const SizedBox.shrink();
    final winScope = WindowsAppearanceScope.maybeOf(context);
    final palette = widget.forceDark
        ? ApplePalette.dark
        : (winScope != null
            ? (winScope.dark ? ApplePalette.dark : ApplePalette.light)
            : ApplePalette.of(context));
    final list = _members.isEmpty
        ? ListView.separated(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            padding: widget.padding,
            itemCount: 5,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (_, __) => _CastSkeletonItem(palette: palette),
          )
        : ListView.separated(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            padding: widget.padding,
            itemCount: _members.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final member = _members[index];
              return _CastAvatarCard(
                member: member,
                palette: palette,
                onTap: widget.onTapMember != null
                    ? () => widget.onTapMember!(member)
                    : null,
              );
            },
          );
    Widget body = Column(
      key: const Key('cast-avatar-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: widget.padding,
          child: Row(
            children: [
              Text(
                '演职员',
                style: TextStyle(
                  color: palette.labelPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
              if (_members.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(
                  '${_members.length}',
                  style: TextStyle(
                    color: palette.labelTertiary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (_loading && _members.isEmpty) ...[
                const SizedBox(width: 8),
                CupertinoActivityIndicator(
                  radius: 7,
                  color: palette.labelTertiary,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 104,
          child: DesktopHorizontalScroller(
            controller: _scrollController,
            child: list,
          ),
        ),
      ],
    );
    if (widget.containerDecoration != null ||
        widget.containerPadding != null ||
        widget.containerMargin != null) {
      body = Container(
        margin: widget.containerMargin,
        padding: widget.containerPadding,
        decoration: widget.containerDecoration,
        child: body,
      );
    }
    return body;
  }
}

class _CastAvatarCard extends StatelessWidget {
  final CastMember member;
  final ApplePalette palette;
  final VoidCallback? onTap;

  const _CastAvatarCard({
    required this.member,
    required this.palette,
    this.onTap,
  });

  static const List<List<Color>> _monogramGradients = [
    [Color(0xFF4A6CF7), Color(0xFF2F45C5)],
    [Color(0xFFE05D6F), Color(0xFFA9364C)],
    [Color(0xFF2BA89C), Color(0xFF196E6C)],
    [Color(0xFFD9822B), Color(0xFF9F5114)],
    [Color(0xFF845EF7), Color(0xFF5333B5)],
    [Color(0xFF3A9BDC), Color(0xFF1E6091)],
  ];

  @override
  Widget build(BuildContext context) {
    final gradient = _monogramGradients[
        member.name.hashCode.abs() % _monogramGradients.length];
    final initial = member.name.isNotEmpty
        ? String.fromCharCode(member.name.runes.first).toUpperCase()
        : '?';

    final fallbackAvatar = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradient,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 22,
          fontWeight: FontWeight.w700,
        ),
      ),
    );

    final avatar = Container(
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: palette.isDark
              ? Colors.white.withValues(alpha: 0.16)
              : Colors.black.withValues(alpha: 0.08),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: palette.isDark ? 0.28 : 0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipOval(
        child: member.avatarUrl.isNotEmpty
            ? _CastPortraitImage(
                url: member.avatarUrl,
                placeholder: fallbackAvatar,
              )
            : fallbackAvatar,
      ),
    );

    return GestureDetector(
      key: Key('cast-avatar-item-${member.name}'),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 68,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            avatar,
            const SizedBox(height: 6),
            Text(
              member.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: palette.labelPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                height: 1.15,
              ),
            ),
            if (member.role.isNotEmpty) ...[
              const SizedBox(height: 1.5),
              Text(
                member.role,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.labelTertiary,
                  fontSize: 10,
                  height: 1.1,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CastPortraitImage extends StatefulWidget {
  final String url;
  final Widget placeholder;

  const _CastPortraitImage({
    required this.url,
    required this.placeholder,
  });

  @override
  State<_CastPortraitImage> createState() => _CastPortraitImageState();
}

class _CastPortraitImageState extends State<_CastPortraitImage> {
  Uint8List? _bytes;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _CastPortraitImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _load();
    }
  }

  void _load() {
    final gen = ++_gen;
    final sync = CastAvatarService.peekAvatarBytes(widget.url);
    if (sync != null) {
      _bytes = sync;
      return;
    }
    _bytes = null;
    CastAvatarService.loadAvatarBytes(widget.url).then((data) {
      if (!mounted || gen != _gen || data == null) return;
      setState(() => _bytes = data);
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = _bytes;
    if (data == null) return widget.placeholder;
    return Image.memory(
      data,
      width: 60,
      height: 60,
      fit: BoxFit.cover,
      alignment: Alignment.topCenter,
      cacheWidth: 180,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => widget.placeholder,
    );
  }
}

class _CastSkeletonItem extends StatelessWidget {
  final ApplePalette palette;
  const _CastSkeletonItem({required this.palette});

  @override
  Widget build(BuildContext context) {
    final fill = palette.isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);
    return SizedBox(
      width: 68,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
          ),
          const SizedBox(height: 7),
          Container(
            width: 44,
            height: 10,
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(5),
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: 30,
            height: 8,
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ],
      ),
    );
  }
}
