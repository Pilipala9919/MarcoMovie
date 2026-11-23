import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/curated_discovery.dart';
import '../core/models.dart';
import '../core/storage_service.dart';
import 'apple_theme.dart';
import 'ios_liquid_glass.dart';
import 'poster_expand_route.dart';
import 'poster_image.dart';

/// Callback carrying the tapped poster card's live [BuildContext], corner
/// radius, and unique [cardId] so the host can launch a zero-ghosting
/// [PosterExpandRoute].
typedef CuratedCardOpenCallback = void Function(
  CmsVideo video,
  BuildContext cardContext,
  double cardRadius,
  String cardId,
);

/// Distinct physics entrance styles when opening any discovery collection into
/// the interactive 3-column Poster Wall.
enum CuratedWallEntranceStyle {
  /// Floating cards orbit and get pulled spiralling into a central black hole,
  /// then burst outward into the 3-column Poster Wall.
  blackHoleVortex,

  /// Mixed horizontal & vertical poster blocks tumble down like Tetris pieces
  /// stacking crookedly atop one another, then scatter into the Poster Wall.
  tetrisTumble,

  /// Posters free-fall under gravity with damped bounce into a center card
  /// pile, then spring-expand outward into the Poster Wall.
  gravityStack,
}

/// Original Marco Movie multi-style curated discovery feed:
/// - `disc_widescreen_radar`: 16:9 widescreen cinema frames (`光影风向标`)
/// - `disc_editorial_picks`: Botanical vine-entwined editorial cards (`月度策划`)
/// - `disc_hot_stream`: 2:3 ranked vertical poster shelf (`热播剧影榜`)
/// - `disc_mood_capsules`: Angled 3-ticket mood capsules (`灵感片单`)
/// - `disc_studio_galleries`: Sprocket-accented studio archive fan cards (`影业档案室`)
/// - `disc_poster_mosaics`: 3-row staggered collector mosaics (`口碑典藏馆`)
///
/// Supports rendering all discovery sections together or an arbitrary subset
/// in custom user-defined order via [visibleSectionIds].
class CuratedDiscoverySection extends StatefulWidget {
  final ValueChanged<CmsVideo> onOpenVideo;
  final CuratedCardOpenCallback? onOpenVideoFromCard;
  final bool hasUserSources;
  final bool loadLive;
  final List<String>? visibleSectionIds;
  final Color? headerInkOverride;

  static const List<String> defaultDiscoverySectionIds = <String>[
    StorageService.homeSectionWidescreenRadar,
    StorageService.homeSectionEditorialPicks,
    StorageService.homeSectionHotStream,
    StorageService.homeSectionMoodCapsules,
    StorageService.homeSectionStudioGalleries,
    StorageService.homeSectionPosterMosaics,
  ];

  const CuratedDiscoverySection({
    super.key,
    required this.onOpenVideo,
    this.onOpenVideoFromCard,
    required this.hasUserSources,
    this.loadLive = true,
    this.visibleSectionIds,
    this.headerInkOverride,
  });

  @override
  State<CuratedDiscoverySection> createState() =>
      _CuratedDiscoverySectionState();
}

class _CuratedDiscoverySectionState extends State<CuratedDiscoverySection> {
  static final ValueNotifier<int> _sharedRevision = ValueNotifier<int>(0);
  static Future<void>? _sharedLiveFetch;
  final Map<String, List<CmsVideo>> _itemsByModule = {};

  @override
  void initState() {
    super.initState();
    _syncFromCache();
    _sharedRevision.addListener(_onSharedUpdated);
    if (widget.loadLive) {
      _ensureSharedRefresh();
    }
  }

  @override
  void dispose() {
    _sharedRevision.removeListener(_onSharedUpdated);
    super.dispose();
  }

  void _syncFromCache() {
    for (final spec in CuratedDiscoveryService.modules) {
      _itemsByModule[spec.id] = CuratedDiscoveryService.peekModule(spec);
    }
  }

  void _onSharedUpdated() {
    if (!mounted) return;
    setState(_syncFromCache);
  }

  void _ensureSharedRefresh() {
    if (_sharedLiveFetch != null) return;
    _sharedLiveFetch = () async {
      try {
        for (final spec in CuratedDiscoveryService.modules) {
          await CuratedDiscoveryService.fetchModule(spec);
          _sharedRevision.value++;
        }
      } finally {
        _sharedLiveFetch = null;
      }
    }();
  }

  CuratedModuleSpec _specById(String id) {
    return CuratedDiscoveryService.modules.firstWhere(
      (m) => m.id == id,
      orElse: () => CuratedDiscoveryService.modules.first,
    );
  }

  List<CmsVideo> _itemsFor(String id) {
    final spec = _specById(id);
    return _itemsByModule[id] ?? spec.seedItems;
  }

  void _openVideoFromCard(
    CmsVideo video,
    BuildContext cardContext,
    double cardRadius,
    String cardId,
  ) {
    if (widget.onOpenVideoFromCard != null) {
      widget.onOpenVideoFromCard!(video, cardContext, cardRadius, cardId);
    } else {
      widget.onOpenVideo(video);
    }
  }

  void _openCollectionWithWall(
    CuratedModuleSpec spec, {
    String? customTitle,
    List<CmsVideo>? customItems,
    CuratedWallEntranceStyle entranceStyle =
        CuratedWallEntranceStyle.gravityStack,
  }) {
    HapticFeedback.mediumImpact();
    final items = customItems ?? _itemsFor(spec.id);
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, __, ___) => _CuratedGravityWallPage(
          title: customTitle ?? spec.title,
          subtitle: spec.subtitle,
          accentColor: spec.accentColor,
          items: items,
          hasUserSources: widget.hasUserSources,
          initialEntranceStyle: entranceStyle,
          onOpenVideo: widget.onOpenVideo,
          onOpenVideoFromCard: widget.onOpenVideoFromCard,
        ),
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            ),
            child: child,
          );
        },
      ),
    );
  }

  Widget? _buildDiscoverySlot(String sectionId, ApplePalette palette) {
    final cnHotSpec = _specById('cn_hot');
    final trendingSpec = _specById('weekly_trending');
    final varietySpec = _specById('cn_variety');
    final doubanSpec = _specById('douban_top');
    final rtSpec = _specById('rotten_tomatoes');
    final disneySpec = _specById('disney');
    final marvelSpec = _specById('marvel');
    final dcSpec = _specById('dc');

    final hdrInk = widget.headerInkOverride;
    return switch (sectionId) {
      StorageService.homeSectionWidescreenRadar => _LandscapeDiscoveryShelf(
          key: Key('curated-module-${trendingSpec.id}'),
          title: '光影风向标',
          accentColor: trendingSpec.accentColor,
          items: _itemsFor(trendingSpec.id),
          palette: palette,
          headerInkOverride: hdrInk,
          onOpenAll: () => _openCollectionWithWall(
            trendingSpec,
            customTitle: '光影风向标',
            entranceStyle: CuratedWallEntranceStyle.gravityStack,
          ),
          onOpenVideo: _openVideoFromCard,
        ),
      StorageService.homeSectionEditorialPicks => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeaderRow(
              title: '月度策划',
              palette: palette,
              badgeText: '藤蔓特辑',
              inkOverride: hdrInk,
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              key: const Key('curated-editorial-collections'),
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _EditorialCollectionCard(
                    key: Key('curated-module-${varietySpec.id}'),
                    title: '当月欢笑 · 热门综艺',
                    items: _itemsFor(varietySpec.id),
                    tintBase: palette.isDark
                        ? const Color(0xFF3E3A32)
                        : const Color(0xFF70685A),
                    accentColor: varietySpec.accentColor,
                    onOpenCollection: () => _openCollectionWithWall(
                      varietySpec,
                      customTitle: '当月欢笑 · 热门综艺',
                      entranceStyle: CuratedWallEntranceStyle.blackHoleVortex,
                    ),
                    onOpenVideo: _openVideoFromCard,
                  ),
                  const SizedBox(width: 14),
                  _EditorialCollectionCard(
                    key: const Key('curated-editorial-cn-drama'),
                    title: '当月热追 · 精选剧集',
                    items: _itemsFor(cnHotSpec.id),
                    tintBase: palette.isDark
                        ? const Color(0xFF21312F)
                        : const Color(0xFF3A5451),
                    accentColor: cnHotSpec.accentColor,
                    onOpenCollection: () => _openCollectionWithWall(
                      cnHotSpec,
                      customTitle: '当月热追 · 精选剧集',
                      entranceStyle: CuratedWallEntranceStyle.tetrisTumble,
                    ),
                    onOpenVideo: _openVideoFromCard,
                  ),
                  const SizedBox(width: 14),
                  _EditorialCollectionCard(
                    key: const Key('curated-editorial-douban'),
                    title: '高分必刷 · 影迷片单',
                    items: _itemsFor(doubanSpec.id),
                    tintBase: palette.isDark
                        ? const Color(0xFF1D3125)
                        : const Color(0xFF31523E),
                    accentColor: doubanSpec.accentColor,
                    onOpenCollection: () => _openCollectionWithWall(
                      doubanSpec,
                      customTitle: '高分必刷 · 影迷片单',
                      entranceStyle: CuratedWallEntranceStyle.blackHoleVortex,
                    ),
                    onOpenVideo: _openVideoFromCard,
                  ),
                  const SizedBox(width: 14),
                  _EditorialCollectionCard(
                    key: const Key('curated-editorial-rt'),
                    title: '口碑风向 · 全球严选',
                    items: _itemsFor(rtSpec.id),
                    tintBase: palette.isDark
                        ? const Color(0xFF372028)
                        : const Color(0xFF5D3542),
                    accentColor: rtSpec.accentColor,
                    onOpenCollection: () => _openCollectionWithWall(
                      rtSpec,
                      customTitle: '口碑风向 · 全球严选',
                      entranceStyle: CuratedWallEntranceStyle.tetrisTumble,
                    ),
                    onOpenVideo: _openVideoFromCard,
                  ),
                ],
              ),
            ),
          ],
        ),
      StorageService.homeSectionHotStream => _PortraitDiscoveryShelf(
          key: Key('curated-module-${cnHotSpec.id}'),
          title: '热播剧影榜',
          accentColor: cnHotSpec.accentColor,
          items: _itemsFor(cnHotSpec.id),
          palette: palette,
          headerInkOverride: hdrInk,
          showRankBadges: true,
          onOpenAll: () => _openCollectionWithWall(
            cnHotSpec,
            customTitle: '热播剧影榜',
            entranceStyle: CuratedWallEntranceStyle.gravityStack,
          ),
          onOpenVideo: _openVideoFromCard,
        ),
      StorageService.homeSectionMoodCapsules => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeaderRow(
              title: '灵感片单',
              palette: palette,
              inkOverride: hdrInk,
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              key: const Key('curated-category-pills'),
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  for (final entry in [
                    (
                      spec: disneySpec,
                      label: '轻松解压',
                      style: CuratedWallEntranceStyle.tetrisTumble,
                    ),
                    (
                      spec: cnHotSpec,
                      label: '高能热剧',
                      style: CuratedWallEntranceStyle.blackHoleVortex,
                    ),
                    (
                      spec: varietySpec,
                      label: '下饭综艺',
                      style: CuratedWallEntranceStyle.gravityStack,
                    ),
                    (
                      spec: trendingSpec,
                      label: '院线新片',
                      style: CuratedWallEntranceStyle.blackHoleVortex,
                    ),
                    (
                      spec: marvelSpec,
                      label: '热血超英',
                      style: CuratedWallEntranceStyle.tetrisTumble,
                    ),
                    (
                      spec: dcSpec,
                      label: '暗黑悬疑',
                      style: CuratedWallEntranceStyle.blackHoleVortex,
                    ),
                  ]) ...[
                    _StackedCategoryPill(
                      label: entry.label,
                      items: _itemsFor(entry.spec.id),
                      palette: palette,
                      onTap: () => _openCollectionWithWall(
                        entry.spec,
                        customTitle: entry.label,
                        entranceStyle: entry.style,
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                ],
              ),
            ),
          ],
        ),
      StorageService.homeSectionStudioGalleries => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeaderRow(
              title: '影业档案室',
              palette: palette,
              badgeText: widget.hasUserSources ? '点播自动匹配片源' : '需添加片源播放',
              inkOverride: hdrInk,
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              key: const Key('curated-studio-shelf'),
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _StudioFanCard(
                    key: Key('curated-module-${disneySpec.id}'),
                    style: _StudioBrandStyle.disney,
                    spec: disneySpec,
                    items: _itemsFor(disneySpec.id),
                    onTap: () => _openCollectionWithWall(
                      disneySpec,
                      entranceStyle: CuratedWallEntranceStyle.tetrisTumble,
                    ),
                  ),
                  const SizedBox(width: 12),
                  _StudioFanCard(
                    key: Key('curated-module-${marvelSpec.id}'),
                    style: _StudioBrandStyle.marvel,
                    spec: marvelSpec,
                    items: _itemsFor(marvelSpec.id),
                    onTap: () => _openCollectionWithWall(
                      marvelSpec,
                      entranceStyle: CuratedWallEntranceStyle.blackHoleVortex,
                    ),
                  ),
                  const SizedBox(width: 12),
                  _StudioFanCard(
                    key: Key('curated-module-${dcSpec.id}'),
                    style: _StudioBrandStyle.dc,
                    spec: dcSpec,
                    items: _itemsFor(dcSpec.id),
                    onTap: () => _openCollectionWithWall(
                      dcSpec,
                      entranceStyle: CuratedWallEntranceStyle.tetrisTumble,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      StorageService.homeSectionPosterMosaics => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeaderRow(
              title: '口碑典藏馆',
              palette: palette,
              inkOverride: hdrInk,
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              key: const Key('curated-mosaic-shelf'),
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _PosterWallMosaicCard(
                    key: Key('curated-module-${doubanSpec.id}'),
                    title: '高分殿堂',
                    subtitle: '影迷严选年度佳作',
                    items: _itemsFor(doubanSpec.id),
                    accentColor: doubanSpec.accentColor,
                    palette: palette,
                    onTap: () => _openCollectionWithWall(
                      doubanSpec,
                      customTitle: '高分殿堂',
                      entranceStyle: CuratedWallEntranceStyle.tetrisTumble,
                    ),
                  ),
                  const SizedBox(width: 14),
                  _PosterWallMosaicCard(
                    key: Key('curated-module-${rtSpec.id}'),
                    title: '口碑新片',
                    subtitle: '全球影评新鲜直击',
                    items: _itemsFor(rtSpec.id),
                    accentColor: rtSpec.accentColor,
                    palette: palette,
                    onTap: () => _openCollectionWithWall(
                      rtSpec,
                      customTitle: '口碑新片',
                      entranceStyle: CuratedWallEntranceStyle.blackHoleVortex,
                    ),
                  ),
                  const SizedBox(width: 14),
                  _PosterWallMosaicCard(
                    key: const Key('curated-mosaic-hero-universe'),
                    title: '英雄宇宙',
                    subtitle: '漫威 · DC 史诗巡礼',
                    items: [
                      ..._itemsFor(marvelSpec.id).take(6),
                      ..._itemsFor(dcSpec.id).take(6),
                    ],
                    accentColor: marvelSpec.accentColor,
                    palette: palette,
                    onTap: () => _openCollectionWithWall(
                      marvelSpec,
                      customTitle: '英雄宇宙',
                      customItems: [
                        ..._itemsFor(marvelSpec.id),
                        ..._itemsFor(dcSpec.id),
                      ],
                      entranceStyle: CuratedWallEntranceStyle.blackHoleVortex,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    final ids = widget.visibleSectionIds ??
        CuratedDiscoverySection.defaultDiscoverySectionIds;
    final builtSlots = <Widget>[];
    for (final id in ids) {
      final slot = _buildDiscoverySlot(id, palette);
      if (slot != null) {
        builtSlots.add(slot);
      }
    }
    if (builtSlots.isEmpty) return const SizedBox.shrink();
    if (builtSlots.length == 1) {
      return builtSlots.first;
    }
    return Column(
      key: const Key('curated-discovery-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < builtSlots.length; i++) ...[
          if (i > 0) const SizedBox(height: 22),
          builtSlots[i],
        ],
      ],
    );
  }
}

class _SectionHeaderRow extends StatelessWidget {
  final String title;
  final ApplePalette palette;
  final String? badgeText;
  final VoidCallback? onTapChevron;
  final Color? inkOverride;

  const _SectionHeaderRow({
    required this.title,
    required this.palette,
    this.badgeText,
    this.onTapChevron,
    this.inkOverride,
  });

  @override
  Widget build(BuildContext context) {
    final titleColor = inkOverride ?? palette.labelPrimary;
    final chevronColor = inkOverride != null
        ? inkOverride!.withValues(alpha: 0.72)
        : palette.labelTertiary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              color: titleColor,
              fontSize: 18,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.35,
            ),
          ),
          if (badgeText != null && badgeText!.isNotEmpty) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7.5, vertical: 2.5),
                decoration: BoxDecoration(
                  color: palette.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  badgeText!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.accent,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
          const Spacer(),
          if (onTapChevron != null)
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              minimumSize: const Size(28, 28),
              onPressed: onTapChevron,
              child: Icon(
                CupertinoIcons.chevron_right,
                size: 16,
                color: chevronColor,
              ),
            ),
        ],
      ),
    );
  }
}

/// Ranked 2:3 vertical poster shelf (`热播剧影榜`).
class _PortraitDiscoveryShelf extends StatelessWidget {
  final String title;
  final Color accentColor;
  final List<CmsVideo> items;
  final ApplePalette palette;
  final Color? headerInkOverride;
  final bool showRankBadges;
  final VoidCallback onOpenAll;
  final CuratedCardOpenCallback onOpenVideo;

  const _PortraitDiscoveryShelf({
    super.key,
    required this.title,
    required this.accentColor,
    required this.items,
    required this.palette,
    this.headerInkOverride,
    this.showRankBadges = false,
    required this.onOpenAll,
    required this.onOpenVideo,
  });

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 2.2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeaderRow(
          title: title,
          palette: palette,
          onTapChevron: onOpenAll,
          inkOverride: headerInkOverride,
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 168 + 42 * textScale,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 11),
            itemBuilder: (context, index) {
              final video = items[index];
              final cid = 'curated-portrait-${video.id}-$index';
              return _CuratedPosterCard(
                video: video,
                cardId: cid,
                accentColor: accentColor,
                palette: palette,
                rankNumber: showRankBadges ? index + 1 : null,
                onTap: (cardCtx) {
                  HapticFeedback.selectionClick();
                  onOpenVideo(video, cardCtx, 13.0, cid);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Wide 16:9 widescreen cinema frame shelf (`光影风向标`).
class _LandscapeDiscoveryShelf extends StatelessWidget {
  final String title;
  final Color accentColor;
  final List<CmsVideo> items;
  final ApplePalette palette;
  final Color? headerInkOverride;
  final VoidCallback onOpenAll;
  final CuratedCardOpenCallback onOpenVideo;

  const _LandscapeDiscoveryShelf({
    super.key,
    required this.title,
    required this.accentColor,
    required this.items,
    required this.palette,
    this.headerInkOverride,
    required this.onOpenAll,
    required this.onOpenVideo,
  });

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 2.2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeaderRow(
          title: title,
          palette: palette,
          onTapChevron: onOpenAll,
          inkOverride: headerInkOverride,
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 126 + 40 * textScale,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final video = items[index];
              final cid = 'curated-landscape-${video.id}-$index';
              return _CuratedLandscapeCard(
                video: video,
                cardId: cid,
                palette: palette,
                onTap: (cardCtx) {
                  HapticFeedback.selectionClick();
                  onOpenVideo(video, cardCtx, 14.0, cid);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _CuratedLandscapeCard extends StatelessWidget {
  final CmsVideo video;
  final String cardId;
  final ApplePalette palette;
  final void Function(BuildContext cardContext) onTap;

  const _CuratedLandscapeCard({
    required this.video,
    required this.cardId,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final genre = CuratedDiscoveryService.genreFor(video);
    final metaParts = <String>[
      if (video.year.isNotEmpty) video.year,
      if (genre.isNotEmpty)
        genre
      else if (video.remarks.isNotEmpty)
        video.remarks,
    ];
    final subtitle = metaParts.join(' · ');
    final imgUrl = CuratedDiscoveryService.backdropFor(video);

    BuildContext? posterCtx;
    return GestureDetector(
      key: Key('curated-landscape-${video.id}'),
      onTap: () => onTap(posterCtx ?? context),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 210,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PosterExpandSourceCard(
              cardId: cardId,
              child: Builder(
                builder: (ctx) {
                  posterCtx = ctx;
                  return Container(
                    width: 210,
                    height: 118,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: palette.isDark
                            ? Colors.white.withValues(alpha: 0.11)
                            : Colors.black.withValues(alpha: 0.06),
                        width: 0.8,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: palette.isDark ? 0.32 : 0.10,
                          ),
                          blurRadius: 14,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(13.5),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          PosterImage(
                            url: imgUrl,
                            title: video.title,
                            year: video.year,
                            fit: BoxFit.cover,
                            forBackdrop: true,
                            highRes: true,
                            placeholder: _buildFallbackThumb(video.title, palette),
                          ),
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.transparent,
                                    Colors.black.withValues(alpha: 0.08),
                                    Colors.black.withValues(alpha: 0.42),
                                  ],
                                  stops: const [0.0, 0.55, 1.0],
                                ),
                              ),
                            ),
                          ),
                          if (video.doubanScore != null || video.rtScore != null)
                            Positioned(
                              top: 7,
                              right: 7,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2.5,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.65),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  video.rtScore != null
                                      ? '🍅 ${video.rtScore}%'
                                      : '豆 ${video.doubanScore!.toStringAsFixed(1)}',
                                  style: const TextStyle(
                                    color: Color(0xFFFFD86B),
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 7),
            Text(
              video.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.labelPrimary,
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.15,
              ),
            ),
            if (subtitle.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 1.5),
                child: Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.labelTertiary,
                    fontSize: 11,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Original Marco Movie Botanical Vine Collection Card (`月度策划`):
/// top full-bleed spotlight + intertwined climbing vine tendrils & starlight
/// buds + bottom 2-up 16:9 mini-cards.
class _EditorialCollectionCard extends StatelessWidget {
  final String title;
  final List<CmsVideo> items;
  final Color tintBase;
  final Color accentColor;
  final VoidCallback onOpenCollection;
  final CuratedCardOpenCallback onOpenVideo;

  const _EditorialCollectionCard({
    super.key,
    required this.title,
    required this.items,
    required this.tintBase,
    required this.accentColor,
    required this.onOpenCollection,
    required this.onOpenVideo,
  });

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 2.2);
    final heroItem = items.isNotEmpty ? items.first : null;
    final subItems = items.length > 2
        ? items.sublist(1, 3)
        : (items.length == 2 ? items : items.take(2).toList(growable: false));
    final heroBackdrop =
        heroItem != null ? CuratedDiscoveryService.backdropFor(heroItem) : '';

    return GestureDetector(
      onTap: onOpenCollection,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 306,
        height: 274 + 48 * textScale,
        decoration: BoxDecoration(
          color: tintBase,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.14),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(21.5),
          child: Column(
            children: [
              // Top 54%: Spotlight HD backdrop + Laurel Wreath Title
              SizedBox(
                height: 174,
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (heroItem != null)
                      PosterImage(
                        url: heroBackdrop,
                        title: heroItem.title,
                        year: heroItem.year,
                        fit: BoxFit.cover,
                        forBackdrop: true,
                        highRes: true,
                        placeholder: Container(color: tintBase),
                      ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.12),
                            tintBase.withValues(alpha: 0.38),
                            tintBase.withValues(alpha: 0.96),
                          ],
                          stops: const [0.0, 0.56, 1.0],
                        ),
                      ),
                    ),
                    // Top-right expand hint pill
                    Positioned(
                      top: 10,
                      right: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3.5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.42),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.18),
                            width: 0.6,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '共 ${items.length} 部',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 2),
                            const Icon(
                              CupertinoIcons.chevron_right,
                              size: 10,
                              color: Colors.white70,
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Intertwined botanical vines curling across top-left & title frame
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          key: const Key('editorial-botanical-vine-overlay'),
                          painter: _BotanicalVineBannerPainter(
                            accentColor: accentColor,
                          ),
                        ),
                      ),
                    ),
                    // Centered Vine-Entwined Title + Spotlight Name
                    Positioned(
                      left: 14,
                      right: 14,
                      bottom: 10,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _BotanicalVineFlourish(
                                flip: false,
                                accentColor: accentColor,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 17.5,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.2,
                                    shadows: [
                                      Shadow(
                                        color: Color(0x88000000),
                                        blurRadius: 10,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              _BotanicalVineFlourish(
                                flip: true,
                                accentColor: accentColor,
                              ),
                            ],
                          ),
                          if (heroItem != null) ...[
                            const SizedBox(height: 3),
                            Text(
                              heroItem.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.78),
                                fontSize: 11.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // Bottom 46%: 2-column 16:9 mini-cards inside the collection frame
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  decoration: BoxDecoration(
                    color: tintBase.withValues(alpha: 0.94),
                  ),
                  child: Row(
                    children: [
                      for (int i = 0; i < subItems.length; i++) ...[
                        if (i > 0) const SizedBox(width: 10),
                        Expanded(
                          child: _EditorialMiniWideTile(
                            video: subItems[i],
                            cardId: 'curated-editorial-${title}_${subItems[i].id}_$i',
                            onTap: (cardCtx) {
                              HapticFeedback.selectionClick();
                              onOpenVideo(
                                subItems[i],
                                cardCtx,
                                11.0,
                                'curated-editorial-${title}_${subItems[i].id}_$i',
                              );
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditorialMiniWideTile extends StatelessWidget {
  final CmsVideo video;
  final String cardId;
  final void Function(BuildContext cardContext) onTap;

  const _EditorialMiniWideTile({
    required this.video,
    required this.cardId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final genre = CuratedDiscoveryService.genreFor(video);
    final sub = [
      if (video.year.isNotEmpty) video.year,
      if (genre.isNotEmpty)
        genre
      else if (video.remarks.isNotEmpty)
        video.remarks,
    ].join(' · ');

    BuildContext? posterCtx;
    return GestureDetector(
      onTap: () => onTap(posterCtx ?? context),
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: PosterExpandSourceCard(
              cardId: cardId,
              child: Builder(
                builder: (ctx) {
                  posterCtx = ctx;
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        PosterImage(
                          url: CuratedDiscoveryService.backdropFor(video),
                          title: video.title,
                          year: video.year,
                          fit: BoxFit.cover,
                          forBackdrop: true,
                          placeholder: Container(
                            color: Colors.black.withValues(alpha: 0.28),
                          ),
                        ),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(11),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.14),
                              width: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            video.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (sub.isNotEmpty)
            Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.65),
                fontSize: 10.5,
              ),
            ),
        ],
      ),
    );
  }
}

/// Original Marco Movie climbing botanical vine flourish (replaces laurel wreath)
/// featuring curling organic tendrils, asymmetric leaves & glowing starlight buds.
class _BotanicalVineFlourish extends StatelessWidget {
  final bool flip;
  final Color accentColor;

  const _BotanicalVineFlourish({
    required this.flip,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scaleX: flip ? -1.0 : 1.0,
      child: CustomPaint(
        size: const Size(24, 24),
        painter: _BotanicalVinePainter(accentColor: accentColor),
      ),
    );
  }
}

class _BotanicalVinePainter extends CustomPainter {
  final Color accentColor;
  const _BotanicalVinePainter({required this.accentColor});

  @override
  void paint(Canvas canvas, Size size) {
    final vinePaint = Paint()
      ..color = Color.lerp(Colors.white, accentColor, 0.28)!
          .withValues(alpha: 0.88)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.45
      ..strokeCap = StrokeCap.round;

    // Flowing S-curve main climbing vine
    final mainStem = Path()
      ..moveTo(size.width * 0.92, size.height * 0.86)
      ..cubicTo(
        size.width * 0.56,
        size.height * 0.92,
        size.width * 0.26,
        size.height * 0.62,
        size.width * 0.34,
        size.height * 0.34,
      )
      ..cubicTo(
        size.width * 0.42,
        size.height * 0.14,
        size.width * 0.16,
        size.height * 0.08,
        size.width * 0.08,
        size.height * 0.24,
      );
    canvas.drawPath(mainStem, vinePaint);

    // Delicate spiral tendril curling off the mid-vine
    final tendril = Path()
      ..moveTo(size.width * 0.50, size.height * 0.72)
      ..quadraticBezierTo(
        size.width * 0.18,
        size.height * 0.88,
        size.width * 0.12,
        size.height * 0.64,
      )
      ..quadraticBezierTo(
        size.width * 0.09,
        size.height * 0.52,
        size.width * 0.20,
        size.height * 0.56,
      );
    canvas.drawPath(tendril, vinePaint..strokeWidth = 1.05);

    // Asymmetric pointed botanical leaves
    final leafPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.90)
      ..style = PaintingStyle.fill;
    const leaves = [
      (0.32, 0.40, -0.75, 1.0),
      (0.46, 0.58, 0.45, 0.9),
      (0.68, 0.80, -0.35, 0.85),
      (0.24, 0.20, -1.10, 0.75),
    ];
    for (final (fx, fy, angle, scale) in leaves) {
      canvas.save();
      canvas.translate(size.width * fx, size.height * fy);
      canvas.rotate(angle);
      final leaf = Path()
        ..moveTo(0, 0)
        ..quadraticBezierTo(3.2 * scale, -2.2 * scale, 6.2 * scale, 0)
        ..quadraticBezierTo(3.2 * scale, 2.2 * scale, 0, 0)
        ..close();
      canvas.drawPath(leaf, leafPaint);
      canvas.restore();
    }

    // Starlight dew bud accent
    canvas.drawCircle(
      Offset(size.width * 0.10, size.height * 0.28),
      1.7,
      Paint()..color = const Color(0xFFFFE7A3),
    );
  }

  @override
  bool shouldRepaint(covariant _BotanicalVinePainter oldDelegate) =>
      oldDelegate.accentColor != accentColor;
}

/// Subtle sweeping corner vines entwining the top edge of editorial collection cards.
class _BotanicalVineBannerPainter extends CustomPainter {
  final Color accentColor;
  const _BotanicalVineBannerPainter({required this.accentColor});

  @override
  void paint(Canvas canvas, Size size) {
    final vinePaint = Paint()
      ..color = Color.lerp(Colors.white, accentColor, 0.30)!
          .withValues(alpha: 0.26)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25
      ..strokeCap = StrokeCap.round;

    final leftVine = Path()
      ..moveTo(-4, 24)
      ..cubicTo(22, 10, 44, 34, 72, 14)
      ..quadraticBezierTo(88, 4, 104, 12);
    canvas.drawPath(leftVine, vinePaint);

    final leafPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.24)
      ..style = PaintingStyle.fill;
    for (final (x, y, a) in const [
      (26.0, 17.0, -0.4),
      (52.0, 23.0, 0.5),
      (78.0, 12.0, -0.6),
    ]) {
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(a);
      canvas.drawOval(const Rect.fromLTWH(-4, -1.7, 8, 3.4), leafPaint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _BotanicalVineBannerPainter oldDelegate) =>
      oldDelegate.accentColor != accentColor;
}

enum _StudioBrandStyle { disney, marvel, dc }

/// Ref Image 2 Top: Wide studio card with bold brand emblem on the left and a
/// 3D-tilted diagonal multi-poster collage fan on the right.
class _StudioFanCard extends StatelessWidget {
  final _StudioBrandStyle style;
  final CuratedModuleSpec spec;
  final List<CmsVideo> items;
  final VoidCallback onTap;

  const _StudioFanCard({
    super.key,
    required this.style,
    required this.spec,
    required this.items,
    required this.onTap,
  });

  List<Color> get _gradientColors => switch (style) {
        _StudioBrandStyle.disney => const [
            Color(0xFF0E1B36),
            Color(0xFF142A54),
          ],
        _StudioBrandStyle.marvel => const [
            Color(0xFF221015),
            Color(0xFF3E131B),
          ],
        _StudioBrandStyle.dc => const [
            Color(0xFF0D1729),
            Color(0xFF102A56),
          ],
      };

  @override
  Widget build(BuildContext context) {
    final collageItems = items.take(4).toList(growable: false);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 222,
        height: 114,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: _gradientColors,
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.14),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.26),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(17.5),
          child: Stack(
            children: [
              // Right side: 3D tilted 2x2 poster fan collage
              Positioned(
                right: -12,
                top: -10,
                bottom: -14,
                width: 120,
                child: Transform.rotate(
                  angle: 0.24,
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final v in collageItems)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(7),
                          child: SizedBox(
                            width: 52,
                            height: 66,
                            child: PosterImage(
                              url: v.poster,
                              title: v.title,
                              year: v.year,
                              fit: BoxFit.cover,
                              placeholder: Container(
                                color: Colors.white.withValues(alpha: 0.08),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // Smooth left-to-right gradient mask so brand emblem pops crisply
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        _gradientColors.first,
                        _gradientColors.first.withValues(alpha: 0.92),
                        _gradientColors.last.withValues(alpha: 0.22),
                      ],
                      stops: const [0.0, 0.48, 1.0],
                    ),
                  ),
                ),
              ),
              // Left brand identity badge
              Positioned(
                left: 16,
                top: 8,
                bottom: 8,
                width: 112,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildBrandWordmark(),
                      const SizedBox(height: 5),
                      Text(
                        '${items.length} 部精选',
                        textScaler: TextScaler.noScaling,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.62),
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBrandWordmark() {
    return switch (style) {
      _StudioBrandStyle.disney => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            CustomPaint(
              size: const Size(68, 12),
              painter: _DisneyArcPainter(),
            ),
            const Text(
              'Disney+',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.6,
                height: 1.0,
              ),
            ),
          ],
        ),
      _StudioBrandStyle.marvel => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFFE62429),
            borderRadius: BorderRadius.circular(5),
          ),
          child: const Text(
            'MARVEL',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.0,
              height: 1.05,
            ),
          ),
        ),
      _StudioBrandStyle.dc => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF0476F2),
                border: Border.all(color: Colors.white, width: 2.0),
              ),
              alignment: Alignment.center,
              child: const Text(
                'DC',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              '宇宙',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
    };
  }
}

class _DisneyArcPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0x3340C8FF), Color(0xFF7CE8FF), Color(0xFFFFFFFF)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    final path = Path()
      ..moveTo(4, size.height)
      ..quadraticBezierTo(size.width * 0.48, -size.height * 0.35, size.width - 2, size.height * 0.85);
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Ref Image 2 Middle: Compact pill with a 3-card fanned mini-poster stack on the
/// left + bold category label on the right (`合家欢`, `热播剧集`, `热门综艺`...).
class _StackedCategoryPill extends StatelessWidget {
  final String label;
  final List<CmsVideo> items;
  final ApplePalette palette;
  final VoidCallback onTap;

  const _StackedCategoryPill({
    required this.label,
    required this.items,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final stack = items.take(3).toList(growable: false);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        constraints: const BoxConstraints(minHeight: 58),
        padding: const EdgeInsets.fromLTRB(12, 6, 16, 6),
        decoration: BoxDecoration(
          color: palette.isDark
              ? const Color(0xFF1C1F28)
              : palette.groupedPrimary,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: palette.isDark
                ? Colors.white.withValues(alpha: 0.11)
                : Colors.black.withValues(alpha: 0.06),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: palette.isDark ? 0.24 : 0.06,
              ),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 44,
              height: 44,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerLeft,
                children: [
                  for (int i = stack.length - 1; i >= 0; i--)
                    Positioned(
                      left: i * 5.0,
                      top: i * 1.5,
                      bottom: i * 1.5,
                      child: Container(
                        width: 30,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.28),
                            width: 0.7,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.25),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(5.5),
                          child: PosterImage(
                            url: stack[i].poster,
                            title: stack[i].title,
                            year: stack[i].year,
                            fit: BoxFit.cover,
                            placeholder: Container(
                              color: palette.groupedTertiary,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                color: palette.labelPrimary,
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ref Image 2 Bottom: Tall card filled with a 3-row staggered poster-wall mosaic
/// + deep bottom gradient + bold editorial title (`豆瓣高分`, `烂番茄口碑`).
class _PosterWallMosaicCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<CmsVideo> items;
  final Color accentColor;
  final ApplePalette palette;
  final VoidCallback onTap;

  const _PosterWallMosaicCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.items,
    required this.accentColor,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pool = items.isEmpty
        ? const <CmsVideo>[]
        : List<CmsVideo>.generate(12, (i) => items[i % items.length]);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 238,
        height: 274,
        decoration: BoxDecoration(
          color: const Color(0xFF15171F),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: palette.isDark
                ? Colors.white.withValues(alpha: 0.12)
                : Colors.black.withValues(alpha: 0.08),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: palette.isDark ? 0.36 : 0.14,
              ),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(21.5),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 3 staggered rows of mini posters
              Column(
                children: [
                  for (int row = 0; row < 3; row++)
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                          top: row == 0 ? 0 : 5,
                          left: row.isOdd ? 12 : 0,
                        ),
                        child: Row(
                          children: [
                            for (int col = 0; col < 4; col++) ...[
                              if (col > 0) const SizedBox(width: 5),
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(7),
                                  child: pool.isEmpty
                                      ? Container(color: const Color(0xFF232630))
                                      : PosterImage(
                                          url: pool[(row * 4 + col) % pool.length].poster,
                                          title: pool[(row * 4 + col) % pool.length].title,
                                          year: pool[(row * 4 + col) % pool.length].year,
                                          fit: BoxFit.cover,
                                          placeholder: Container(
                                            color: const Color(0xFF242731),
                                          ),
                                        ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              // Deep feathered bottom scrim cradling the bold title
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.05),
                        Colors.black.withValues(alpha: 0.18),
                        const Color(0xE611131B),
                        const Color(0xFF101219),
                      ],
                      stops: const [0.0, 0.45, 0.78, 1.0],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 14,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.4,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.68),
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.88),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        CupertinoIcons.chevron_right,
                        size: 14,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _buildFallbackThumb(String title, ApplePalette palette) {
  return Container(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: palette.isDark
            ? const [Color(0xFF23252C), Color(0xFF15161B)]
            : const [Color(0xFFE4E8F0), Color(0xFFD7DCE8)],
      ),
    ),
    alignment: Alignment.center,
    padding: const EdgeInsets.all(10),
    child: Text(
      title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: palette.labelTertiary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _CuratedPosterCard extends StatelessWidget {
  final CmsVideo video;
  final String cardId;
  final Color accentColor;
  final ApplePalette palette;
  final int? rankNumber;
  final void Function(BuildContext cardContext) onTap;

  const _CuratedPosterCard({
    required this.video,
    required this.cardId,
    required this.accentColor,
    required this.palette,
    this.rankNumber,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final badgeText = video.rtScore != null
        ? '🍅 ${video.rtScore}%'
        : (video.doubanScore != null
            ? '豆 ${video.doubanScore!.toStringAsFixed(1)}'
            : video.year);

    final placeholder = _buildFallbackThumb(video.title, palette);

    BuildContext? posterCtx;
    return GestureDetector(
      key: Key('curated-poster-${video.id}'),
      onTap: () => onTap(posterCtx ?? context),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 114,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: PosterExpandSourceCard(
                cardId: cardId,
                child: Builder(
                  builder: (ctx) {
                    posterCtx = ctx;
                    return Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(
                          color: palette.isDark
                              ? Colors.white.withValues(alpha: 0.1)
                              : Colors.black.withValues(alpha: 0.06),
                          width: 0.8,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: palette.isDark ? 0.32 : 0.09,
                            ),
                            blurRadius: 12,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12.5),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            PosterImage(
                              url: video.poster,
                              title: video.title,
                              year: video.year,
                              fit: BoxFit.cover,
                              fadeIn: true,
                              highRes: true,
                              placeholder: placeholder,
                            ),
                            if (rankNumber != null)
                              Positioned(
                                top: 6,
                                left: 6,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5.5,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: rankNumber! <= 3
                                          ? [
                                              accentColor.withValues(alpha: 0.92),
                                              accentColor.withValues(alpha: 0.68),
                                            ]
                                          : [
                                              Colors.black.withValues(alpha: 0.72),
                                              Colors.black.withValues(alpha: 0.56),
                                            ],
                                    ),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    rankNumber!.toString().padLeft(2, '0'),
                                    textScaler: TextScaler.noScaling,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w800,
                                      fontFeatures: [FontFeature.tabularFigures()],
                                    ),
                                  ),
                                ),
                              ),
                            if (badgeText.isNotEmpty)
                              Positioned(
                                top: 6,
                                right: 6,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5.5,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.68),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    badgeText,
                                    style: const TextStyle(
                                      color: Color(0xFFFFD86B),
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              video.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.labelPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (video.year.isNotEmpty)
              Text(
                video.year,
                maxLines: 1,
                style: TextStyle(
                  color: palette.labelTertiary,
                  fontSize: 10.5,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Interactive Poster Wall page supporting 3 distinct physics entrance styles:
/// 1. [CuratedWallEntranceStyle.blackHoleVortex]: Cards float around the edges,
///    spiral inward into a swirling central black hole, then explode outward
///    into the 3-column Poster Wall.
/// 2. [CuratedWallEntranceStyle.tetrisTumble]: Mixed horizontal & vertical
///    poster blocks tumble down like Tetris pieces stacking crookedly atop one
///    another, then scatter smoothly into the Poster Wall.
/// 3. [CuratedWallEntranceStyle.gravityStack]: Posters free-fall under gravity
///    with damped elastic bounce into a fanned deck, then expand into the wall.
///
/// Tapping the top-right sparkle button cycles to the next animation style and
/// replays immediately.
class _CuratedGravityWallPage extends StatefulWidget {
  final String title;
  final String subtitle;
  final Color accentColor;
  final List<CmsVideo> items;
  final bool hasUserSources;
  final CuratedWallEntranceStyle initialEntranceStyle;
  final ValueChanged<CmsVideo> onOpenVideo;
  final CuratedCardOpenCallback? onOpenVideoFromCard;

  const _CuratedGravityWallPage({
    required this.title,
    required this.subtitle,
    required this.accentColor,
    required this.items,
    required this.hasUserSources,
    this.initialEntranceStyle = CuratedWallEntranceStyle.blackHoleVortex,
    required this.onOpenVideo,
    this.onOpenVideoFromCard,
  });

  @override
  State<_CuratedGravityWallPage> createState() =>
      _CuratedGravityWallPageState();
}

class _CuratedGravityWallPageState extends State<_CuratedGravityWallPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  final ScrollController _scrollCtrl = ScrollController();
  late final CuratedWallEntranceStyle _activeStyle;
  bool _playedHaptic1 = false;
  bool _playedHaptic2 = false;
  bool _playedHaptic3 = false;
  bool _initialized = false;

  static const int _maxAnimatedCards = 12;
  static const List<double> _stackAngles = [
    -0.21, 0.16, -0.12, 0.20, -0.08, 0.13,
    -0.17, 0.09, -0.05, 0.14, -0.11, 0.06,
  ];
  static const List<Offset> _stackJitters = [
    Offset(-16, 12), Offset(14, 8), Offset(-10, 4), Offset(12, 0),
    Offset(-14, -4), Offset(8, -7), Offset(-6, -10), Offset(10, -12),
    Offset(-4, -14), Offset(6, -16), Offset(-3, -18), Offset(2, -20),
  ];

  // Crooked Tetris pile slots: (dxFromCenter, heightTier, isHorizontal, tiltRad)
  static const List<(double, int, bool, double)> _tetrisSlots = [
    (-76, 0, true, -0.08),
    (54, 0, false, 0.11),
    (-12, 0, false, -0.06),
    (-62, 1, false, 0.13),
    (18, 1, true, -0.10),
    (-94, 1, false, -0.14),
    (74, 1, true, 0.09),
    (-26, 2, true, 0.07),
    (46, 2, false, -0.12),
    (-72, 2, true, -0.09),
    (8, 3, false, 0.10),
    (-38, 3, true, -0.11),
  ];

  @override
  void initState() {
    super.initState();
    _activeStyle = widget.initialEntranceStyle;
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1320),
    )..addListener(_handleAnimationTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final disableAnim = MediaQuery.disableAnimationsOf(context);
    if (disableAnim || widget.items.isEmpty) {
      _ctrl.value = 1.0;
    } else {
      _ctrl.forward(from: 0.0);
    }
  }

  void _handleAnimationTick() {
    final v = _ctrl.value;
    if (!_playedHaptic1 && v >= 0.24) {
      _playedHaptic1 = true;
      HapticFeedback.lightImpact();
    } else if (!_playedHaptic2 && v >= 0.44) {
      _playedHaptic2 = true;
      HapticFeedback.mediumImpact();
    } else if (!_playedHaptic3 && v >= 0.56) {
      _playedHaptic3 = true;
      HapticFeedback.selectionClick();
    }
  }

  static double _gravityFallWithBounce(double u) {
    final t = u.clamp(0.0, 1.0);
    if (t < 0.72) {
      final f = t / 0.72;
      return f * f;
    }
    final b = (t - 0.72) / 0.28;
    final bounce = math.sin(b * math.pi) * math.exp(-2.2 * b) * 0.085;
    return 1.0 - bounce;
  }

  @override
  void dispose() {
    _ctrl.removeListener(_handleAnimationTick);
    _ctrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    final topSafePad = MediaQuery.paddingOf(context).top;
    final bottomSafePad = MediaQuery.paddingOf(context).bottom;
    final animCount = math.min(widget.items.length, _maxAnimatedCards);
    final hasSubtitle = widget.subtitle.trim().isNotEmpty;
    final headerContentH = hasSubtitle ? 52.0 : 44.0;
    final topPad = topSafePad + headerContentH + 18.0;

    return Scaffold(
      key: const Key('curated-gravity-wall-page'),
      backgroundColor: palette.background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Subtle edge-to-edge ambient accent aura rising behind Dynamic Island
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: topSafePad + 184,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      widget.accentColor.withValues(
                        alpha: palette.isDark ? 0.30 : 0.20,
                      ),
                      widget.accentColor.withValues(
                        alpha: palette.isDark ? 0.12 : 0.08,
                      ),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.52, 1.0],
                  ),
                ),
              ),
            ),
          ),

          // 2. Full-bleed Physics Entrance & Interactive Poster Wall
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final height = constraints.maxHeight;
              const hPad = 16.0;
              const crossSpacing = 12.0;
              const mainSpacing = 14.0;
              final crossCount = width >= 620 ? 4 : 3;
              final cellW =
                  (width - hPad * 2 - crossSpacing * (crossCount - 1)) /
                      crossCount;
              final cellH = cellW / 0.60;
              final posterH = cellH - 36;

              final stackW = math.min(136.0, width * 0.34);
              final stackH = stackW * 1.48;
              final stackCenterX = (width - stackW) * 0.5;
              final stackCenterY = (height - stackH) * 0.46;

              return AnimatedBuilder(
                animation: _ctrl,
                builder: (context, gridChild) {
                  final v = _ctrl.value;
                  final gridOpacity =
                      v >= 0.86 ? ((v - 0.86) / 0.14).clamp(0.0, 1.0) : 0.0;
                  final overlayVisible = v < 0.995;

                  return Stack(
                    key: Key('curated-wall-style-${_activeStyle.name}'),
                    fit: StackFit.expand,
                    children: [
                      IgnorePointer(
                        ignoring: v < 0.92,
                        child: Opacity(
                          opacity: gridOpacity,
                          child: gridChild,
                        ),
                      ),
                      if (overlayVisible)
                        IgnorePointer(
                          child: Opacity(
                            opacity: v > 0.90
                                ? (1.0 - ((v - 0.90) / 0.10)).clamp(0.0, 1.0)
                                : 1.0,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                if (_activeStyle ==
                                    CuratedWallEntranceStyle.blackHoleVortex)
                                  Positioned.fill(
                                    child: CustomPaint(
                                      key: const Key(
                                        'curated-black-hole-vortex',
                                      ),
                                      painter: _BlackHoleVortexPainter(
                                        progress: v,
                                        accentColor: widget.accentColor,
                                        isDark: palette.isDark,
                                      ),
                                    ),
                                  )
                                else if (v < 0.64)
                                  Positioned.fill(
                                    child: Opacity(
                                      opacity:
                                          (1.0 - (v / 0.64)).clamp(0.0, 1.0) *
                                              0.32,
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          gradient: RadialGradient(
                                            center: const Alignment(0, -0.06),
                                            radius: 0.72,
                                            colors: [
                                              widget.accentColor
                                                  .withValues(alpha: 0.40),
                                              Colors.transparent,
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                for (int i = 0; i < animCount; i++)
                                  _buildPhysicsCard(
                                    index: i,
                                    count: animCount,
                                    progress: v,
                                    video: widget.items[i],
                                    viewportW: width,
                                    viewportH: height,
                                    crossCount: crossCount,
                                    hPad: hPad,
                                    topPad: topPad,
                                    crossSpacing: crossSpacing,
                                    mainSpacing: mainSpacing,
                                    cellW: cellW,
                                    cellH: cellH,
                                    posterH: posterH,
                                    stackW: stackW,
                                    stackH: stackH,
                                    stackCenterX: stackCenterX,
                                    stackCenterY: stackCenterY,
                                    palette: palette,
                                  ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  );
                },
                child: GridView.builder(
                  key: const Key('curated-gravity-wall-grid'),
                  controller: _scrollCtrl,
                  padding: EdgeInsets.fromLTRB(
                    hPad,
                    topPad,
                    hPad,
                    math.max(36.0, bottomSafePad + 24.0),
                  ),
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossCount,
                    childAspectRatio: 0.60,
                    crossAxisSpacing: crossSpacing,
                    mainAxisSpacing: mainSpacing,
                  ),
                  itemCount: widget.items.length,
                  itemBuilder: (context, index) {
                    final v = widget.items[index];
                    final cid = 'curated-wall-${widget.title}-${v.id}-$index';
                    return _CuratedPosterCard(
                      video: v,
                      cardId: cid,
                      accentColor: widget.accentColor,
                      palette: palette,
                      onTap: (cardCtx) {
                        HapticFeedback.selectionClick();
                        if (widget.onOpenVideoFromCard != null) {
                          widget.onOpenVideoFromCard!(v, cardCtx, 13.0, cid);
                        } else {
                          widget.onOpenVideo(v);
                        }
                      },
                    );
                  },
                ),
              );
            },
          ),

          // 3. Immersive floating borderless title bar (no top-right animation
          //    button; smooth feathered scroll veil + Liquid Glass back pill).
          Positioned(
            key: const Key('curated-wall-immersive-header'),
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedBuilder(
              animation: _scrollCtrl,
              builder: (context, headerChild) {
                final scrollOffset = _scrollCtrl.positions.length == 1
                    ? _scrollCtrl.offset
                    : 0.0;
                final depth = (scrollOffset / 52.0).clamp(0.0, 1.0);
                final topAlpha = 0.64 + depth * 0.30;
                final midAlpha = 0.34 + depth * 0.38;
                final lowAlpha = 0.08 + depth * 0.16;
                return DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        palette.background.withValues(alpha: topAlpha),
                        palette.background.withValues(alpha: midAlpha),
                        palette.background.withValues(alpha: lowAlpha),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.50, 0.78, 1.0],
                    ),
                  ),
                  child: headerChild,
                );
              },
              child: Padding(
                padding: EdgeInsets.fromLTRB(14, topSafePad + 6, 14, 18),
                child: Row(
                  children: [
                    IosNativeGlassButton(
                      style: 'circle',
                      symbol: 'chevron.left',
                      symbolSize: 16,
                      width: 38,
                      height: 38,
                      accessibilityLabel: '返回',
                      onTap: () => Navigator.of(context).maybePop(),
                      fallback: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => Navigator.of(context).maybePop(),
                        child: LiquidGlass(
                          width: 38,
                          height: 38,
                          borderRadius: 999,
                          tint: palette.isDark
                              ? const Color(0x401E1E24)
                              : const Color(0xCCFFFFFF),
                          child: Icon(
                            CupertinoIcons.chevron_back,
                            size: 18,
                            color: palette.labelPrimary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: palette.labelPrimary,
                              fontSize: 17.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.35,
                            ),
                          ),
                          if (hasSubtitle) ...[
                            const SizedBox(height: 1.5),
                            Text(
                              widget.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: palette.labelSecondary,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhysicsCard({
    required int index,
    required int count,
    required double progress,
    required CmsVideo video,
    required double viewportW,
    required double viewportH,
    required int crossCount,
    required double hPad,
    required double topPad,
    required double crossSpacing,
    required double mainSpacing,
    required double cellW,
    required double cellH,
    required double posterH,
    required double stackW,
    required double stackH,
    required double stackCenterX,
    required double stackCenterY,
    required ApplePalette palette,
  }) {
    final row = index ~/ crossCount;
    final col = index % crossCount;
    final targetLeft = hPad + col * (cellW + crossSpacing);
    final targetTop = topPad + row * (cellH + mainSpacing);

    double left;
    double top;
    double w;
    double h;
    double angle;
    double opacity = 1.0;

    switch (_activeStyle) {
      case CuratedWallEntranceStyle.blackHoleVortex:
        final cx = viewportW * 0.5;
        final cy = viewportH * 0.44;
        final baseTheta = (index / math.max(count, 1)) * math.pi * 2.0;
        final outerR = math.min(viewportW, viewportH) * (0.36 + (index % 3) * 0.055);
        final floatW = cellW * 0.86;
        final floatH = posterH * 0.86;

        if (progress < 0.48) {
          // Orbit then spiral inward into the central black hole singularity
          final pullStart = 0.08 + (index % 4) * 0.025;
          final pullU = ((progress - pullStart) / (0.46 - pullStart)).clamp(0.0, 1.0);
          final pullEase = Curves.easeInCubic.transform(pullU);
          final radius = outerR * (1.0 - pullEase);
          final theta = baseTheta + progress * 2.2 + pullEase * math.pi * 2.4;
          final scale = (1.0 - pullEase * 0.90).clamp(0.08, 1.0);
          w = floatW * scale;
          h = floatH * scale;
          left = cx + math.cos(theta) * radius - w * 0.5;
          top = cy + math.sin(theta) * radius - h * 0.5;
          angle = (theta - baseTheta) * 0.55;
          opacity = progress < 0.06
              ? (progress / 0.06).clamp(0.0, 1.0)
              : (pullU > 0.88 ? (1.0 - (pullU - 0.88) / 0.12).clamp(0.0, 1.0) : 1.0);
        } else if (progress < 0.54) {
          // Compressed inside the event horizon right before supernova burst
          w = floatW * 0.08;
          h = floatH * 0.08;
          left = cx - w * 0.5;
          top = cy - h * 0.5;
          angle = 0.0;
          opacity = 0.0;
        } else {
          // Supernova pop-out radially into exact 3-column Poster Wall grid
          final burstStart = 0.54 + (index / math.max(count, 1)) * 0.08;
          final burstEnd = (burstStart + 0.34).clamp(0.74, 0.95);
          final u = ((progress - burstStart) / (burstEnd - burstStart)).clamp(0.0, 1.0);
          final eased = Curves.easeOutBack.transform(u);
          final startW = cellW * 0.16;
          final startH = posterH * 0.16;
          w = startW + (cellW - startW) * eased;
          h = startH + (posterH - startH) * eased;
          left = (cx - startW * 0.5) + (targetLeft - (cx - startW * 0.5)) * eased;
          top = (cy - startH * 0.5) + (targetTop - (cy - startH * 0.5)) * eased;
          angle = (index.isEven ? 1 : -1) * 0.42 * (1.0 - Curves.easeOutCubic.transform(u));
          opacity = (u * 4.0).clamp(0.0, 1.0);
        }

      case CuratedWallEntranceStyle.tetrisTumble:
        final (dxNorm, tier, isHorizontal, tilt) =
            _tetrisSlots[index % _tetrisSlots.length];
        final blockW = isHorizontal
            ? math.min(118.0, viewportW * 0.30)
            : math.min(76.0, viewportW * 0.20);
        final blockH = isHorizontal ? blockW * 0.62 : blockW * 1.44;
        final floorY = viewportH * 0.72;
        final landedLeft =
            (viewportW * 0.5 + dxNorm * (viewportW / 390.0) - blockW * 0.5)
                .clamp(12.0, viewportW - blockW - 12.0);
        final landedTop =
            (floorY - blockH - tier * 68.0 + (index % 3) * 9.0)
                .clamp(24.0, viewportH - blockH - 20.0);

        if (progress < 0.54) {
          // Staggered Tetris drops: uneven horizontal & vertical blocks stacking crookedly
          final dropStart = (index / math.max(count, 1)) * 0.30;
          final dropEnd = (dropStart + 0.22).clamp(0.22, 0.54);
          if (progress <= dropStart) {
            w = blockW;
            h = blockH;
            left = landedLeft;
            top = -blockH - 40.0;
            angle = tilt * 0.5;
            opacity = 0.0;
          } else {
            final u = ((progress - dropStart) / (dropEnd - dropStart)).clamp(0.0, 1.0);
            final fall = _gravityFallWithBounce(u);
            final startY = -blockH - 36.0;
            w = blockW;
            h = blockH;
            left = landedLeft;
            top = startY + (landedTop - startY) * fall;
            angle = tilt * (0.4 + 0.6 * fall);
            opacity = (u * 4.0).clamp(0.0, 1.0);
          }
        } else {
          // Energetic outward scatter morphing every horizontal/crooked block into the grid
          final scatterStart = 0.54 + (index / math.max(count, 1)) * 0.07;
          final scatterEnd = (scatterStart + 0.34).clamp(0.76, 0.95);
          final u = ((progress - scatterStart) / (scatterEnd - scatterStart)).clamp(0.0, 1.0);
          final eased = Curves.easeOutBack.transform(u);
          // Slight outward burst arc before settling into target cell
          final arcBurst = math.sin(u * math.pi) * 26.0 * (index.isEven ? -1.0 : 1.0);
          left = landedLeft + (targetLeft - landedLeft) * eased + arcBurst * (1.0 - u);
          top = landedTop + (targetTop - landedTop) * eased - math.sin(u * math.pi) * 18.0;
          w = blockW + (cellW - blockW) * eased;
          h = blockH + (posterH - blockH) * eased;
          angle = tilt * (1.0 - Curves.easeOutCubic.transform(u));
        }

      case CuratedWallEntranceStyle.gravityStack:
        final jitter = _stackJitters[index % _stackJitters.length];
        final stackLeft = stackCenterX + jitter.dx;
        final stackTop = stackCenterY + jitter.dy;
        final stackAngle = _stackAngles[index % _stackAngles.length];

        if (progress < 0.46) {
          final startT = (index / math.max(count, 1)) * 0.20;
          final endT = (startT + 0.24).clamp(0.24, 0.46);
          if (progress <= startT) {
            left = stackLeft + jitter.dx * 1.6;
            top = -stackH - 60.0;
            w = stackW;
            h = stackH;
            angle = stackAngle * 1.5;
            opacity = 0.0;
          } else {
            final localU = ((progress - startT) / (endT - startT)).clamp(0.0, 1.0);
            final fall = _gravityFallWithBounce(localU);
            final startY = -stackH - 40.0 - (index % 3) * 26.0;
            left = stackLeft + jitter.dx * 1.4 * (1.0 - fall);
            top = startY + (stackTop - startY) * fall;
            w = stackW;
            h = stackH;
            angle = stackAngle * (1.45 - 0.45 * fall);
            opacity = (localU * 3.0).clamp(0.0, 1.0);
          }
        } else {
          final spreadStart = 0.46 + (index / math.max(count, 1)) * 0.09;
          final spreadEnd = (spreadStart + 0.36).clamp(0.70, 0.94);
          final localU =
              ((progress - spreadStart) / (spreadEnd - spreadStart)).clamp(0.0, 1.0);
          final eased = Curves.easeOutBack.transform(localU);
          left = stackLeft + (targetLeft - stackLeft) * eased;
          top = stackTop + (targetTop - stackTop) * eased;
          w = stackW + (cellW - stackW) * eased;
          h = stackH + (posterH - stackH) * eased;
          angle = stackAngle * (1.0 - Curves.easeOutCubic.transform(localU));
        }
    }

    return Positioned(
      left: left,
      top: top,
      width: math.max(8.0, w),
      height: math.max(8.0, h),
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Transform.rotate(
          angle: angle,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.22),
                width: 0.9,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: progress < 0.54 ? 0.36 : 0.20,
                  ),
                  blurRadius: progress < 0.54 ? 18 : 10,
                  offset: Offset(0, progress < 0.54 ? 10 : 5),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12.5),
              child: PosterImage(
                url: video.poster,
                title: video.title,
                year: video.year,
                fit: BoxFit.cover,
                highRes: true,
                placeholder: _buildFallbackThumb(video.title, palette),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Swirling gravitational event horizon & shockwave burst painter for the
/// [CuratedWallEntranceStyle.blackHoleVortex] collection animation.
class _BlackHoleVortexPainter extends CustomPainter {
  final double progress;
  final Color accentColor;
  final bool isDark;

  const _BlackHoleVortexPainter({
    required this.progress,
    required this.accentColor,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.5, size.height * 0.44);

    // Event horizon visibility: grows 0..0.18, sustains 0.18..0.52, collapses 0.52..0.68
    double holeScale;
    double holeAlpha;
    if (progress < 0.16) {
      final u = Curves.easeOutBack.transform((progress / 0.16).clamp(0.0, 1.0));
      holeScale = u;
      holeAlpha = (progress / 0.12).clamp(0.0, 1.0);
    } else if (progress < 0.50) {
      holeScale = 1.0 + 0.12 * math.sin((progress - 0.16) * 14.0);
      holeAlpha = 1.0;
    } else if (progress < 0.66) {
      final u = ((progress - 0.50) / 0.16).clamp(0.0, 1.0);
      holeScale = 1.15 * (1.0 - Curves.easeInCubic.transform(u));
      holeAlpha = (1.0 - u).clamp(0.0, 1.0);
    } else {
      holeScale = 0.0;
      holeAlpha = 0.0;
    }

    if (holeAlpha > 0.01 && holeScale > 0.02) {
      final coreR = 38.0 * holeScale;
      final auraR = 112.0 * holeScale;

      // Gravitational lensing outer aura
      canvas.drawCircle(
        center,
        auraR,
        Paint()
          ..shader = RadialGradient(
            colors: [
              const Color(0xFF06050B).withValues(alpha: 0.92 * holeAlpha),
              accentColor.withValues(alpha: 0.42 * holeAlpha),
              const Color(0xFF7B61FF).withValues(alpha: 0.18 * holeAlpha),
              Colors.transparent,
            ],
            stops: const [0.30, 0.54, 0.76, 1.0],
          ).createShader(Rect.fromCircle(center: center, radius: auraR)),
      );

      // Rotating glowing accretion spiral arcs
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(progress * math.pi * 6.0);
      for (int i = 0; i < 3; i++) {
        final arcR = coreR + 10.0 + i * 11.0 * holeScale;
        final arcPaint = Paint()
          ..color = (i == 0
                  ? const Color(0xFFA78BFA)
                  : Color.lerp(accentColor, Colors.white, 0.35)!)
              .withValues(alpha: (0.62 - i * 0.16) * holeAlpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (2.4 - i * 0.55) * holeScale
          ..strokeCap = StrokeCap.round;
        canvas.drawArc(
          Rect.fromCircle(center: Offset.zero, radius: arcR),
          i * 2.1,
          math.pi * 1.15,
          false,
          arcPaint,
        );
      }
      canvas.restore();

      // Deep pitch-black singularity core
      canvas.drawCircle(
        center,
        coreR,
        Paint()..color = const Color(0xFF040407).withValues(alpha: holeAlpha),
      );
      canvas.drawCircle(
        center,
        coreR,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.35 * holeAlpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }

    // Supernova shockwave ring right as cards explode outward (0.50 -> 0.78)
    if (progress >= 0.50 && progress <= 0.78) {
      final u = ((progress - 0.50) / 0.28).clamp(0.0, 1.0);
      final ringR = 26.0 + Curves.easeOutCubic.transform(u) * size.width * 0.68;
      final ringAlpha = (1.0 - u).clamp(0.0, 1.0) * (isDark ? 0.55 : 0.42);
      canvas.drawCircle(
        center,
        ringR,
        Paint()
          ..color = Color.lerp(accentColor, Colors.white, 0.45)!
              .withValues(alpha: ringAlpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (4.5 * (1.0 - u)).clamp(0.8, 4.5),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BlackHoleVortexPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.accentColor != accentColor ||
      oldDelegate.isDark != isDark;
}
