import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/models.dart';
import '../core/series_scraper.dart';
import '../core/storage_service.dart';
import 'poster_image.dart';

typedef SeriesScrapeSearchFn = Future<List<SeriesScrapeCandidate>> Function(
  String query,
  String formFilter,
);
typedef SeriesScrapeHydrateFn = Future<SeriesScrapeCandidate> Function(
  SeriesScrapeCandidate candidate,
);

/// Opens the in-series metadata & episode scraping modal sheet.
///
/// Users can:
/// 1. Search & bind the exact official Douban / Bangumi / Bilibili work (strictly
///    distinguishing `动漫/剧集` vs `动态漫画` vs `电影`) to fix mismatched posters,
///    backdrops, synopses, ratings, cast, and danmu titles.
/// 2. Inspect, sort, offset, filter specials, and manually correct per-episode
///    numbers scraped from netdisk/CMS filenames so episode navigation and danmu
///    matching stay 100% aligned.
Future<SeriesScrapeOverride?> showSeriesScrapeSheet(
  BuildContext context, {
  required CmsSite site,
  required CmsVideo video,
  required StorageService storage,
  CmsLine? activeLine,
  SeriesScrapeOverride? initialOverride,
  int initialTab = 0,
  SeriesScrapeSearchFn? debugSearchFn,
  SeriesScrapeHydrateFn? debugHydrateFn,
}) {
  return showDialog<SeriesScrapeOverride?>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 680),
        child: SeriesScrapeSheet(
          site: site,
          video: video,
          storage: storage,
          activeLine: activeLine,
          initialOverride: initialOverride,
          initialTab: initialTab,
          debugSearchFn: debugSearchFn,
          debugHydrateFn: debugHydrateFn,
        ),
      ),
    ),
  );
}

class SeriesScrapeSheet extends StatefulWidget {
  final CmsSite site;
  final CmsVideo video;
  final StorageService storage;
  final CmsLine? activeLine;
  final SeriesScrapeOverride? initialOverride;
  final int initialTab;
  final SeriesScrapeSearchFn? debugSearchFn;
  final SeriesScrapeHydrateFn? debugHydrateFn;

  const SeriesScrapeSheet({
    super.key,
    required this.site,
    required this.video,
    required this.storage,
    this.activeLine,
    this.initialOverride,
    this.initialTab = 0,
    this.debugSearchFn,
    this.debugHydrateFn,
  });

  @override
  State<SeriesScrapeSheet> createState() => _SeriesScrapeSheetState();
}

class _SeriesScrapeSheetState extends State<SeriesScrapeSheet> {
  static const Color _bg = Color(0xFF121722);
  static const Color _cardBg = Color(0xFF1A2232);
  static const Color _border = Color(0x26FFFFFF);
  static const Color _accent = Color(0xFF4C9AFF);
  static const Color _mcAmber = Color(0xFFFF9F0A);

  late int _tabIndex;
  late final TextEditingController _searchCtrl;
  late final TextEditingController _danmuTitleCtrl;
  late final TextEditingController _epFilterCtrl;

  String _formFilter = 'all';
  bool _searching = false;
  bool _hydrating = false;
  String? _searchError;
  List<SeriesScrapeCandidate> _candidates = const [];

  late SeriesScrapeOverride _draft;
  bool _hasExistingOverride = false;
  String _epFilterText = '';

  @override
  void initState() {
    super.initState();
    _tabIndex = widget.initialTab.clamp(0, 1);
    final existing = widget.initialOverride ??
        widget.storage.getSeriesScrapeOverride(
          widget.site.key,
          widget.video.id,
          isPrivate: widget.site.isEffectivelyPrivate,
        );
    _hasExistingOverride = existing != null;
    final defaultTitle = SeriesScraper.cleanSearchTitle(widget.video.title);
    final line = widget.activeLine;
    final autoScrape = line != null
        ? SeriesScraper.scrapeLineEpisodes(
            line.episodes,
            seriesTitle: widget.video.title,
          )
        : null;
    _draft = existing ??
        SeriesScrapeOverride(
          sortByScrapedEpisode:
              autoScrape?.sourceOrderScrambled == true ? true : null,
        );

    final initialQuery = _draft.matchedTitle.isNotEmpty
        ? _draft.matchedTitle
        : (defaultTitle.isNotEmpty ? defaultTitle : widget.video.title);
    _searchCtrl = TextEditingController(text: initialQuery);
    _danmuTitleCtrl = TextEditingController(text: _draft.danmuTitleOverride);
    _epFilterCtrl = TextEditingController();

    if (SeriesScraper.isMotionComicText(
      widget.video.title,
      extraContext: '${widget.video.tag} ${widget.video.remarks}',
    )) {
      _formFilter = 'motion_comic';
    }

    unawaited(_runSearch());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _danmuTitleCtrl.dispose();
    _epFilterCtrl.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final results = widget.debugSearchFn != null
          ? await widget.debugSearchFn!(q, _formFilter)
          : await SeriesScraper.searchCandidates(
              q,
              filter: _formFilter,
            );
      if (!mounted) return;
      setState(() {
        _candidates = results;
        _searching = false;
        if (results.isEmpty) {
          _searchError = '未找到匹配作品，可精简关键词或切换“全部 / 动态漫画 / 动漫剧集”筛选重试';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchError = '搜索失败：$e';
      });
    }
  }

  Future<void> _applyCandidate(SeriesScrapeCandidate cand) async {
    if (_hydrating) return;
    setState(() => _hydrating = true);
    try {
      final hydrated = widget.debugHydrateFn != null
          ? await widget.debugHydrateFn!(cand)
          : await SeriesScraper.hydrateCandidate(cand);
      final updated = _draft.copyWith(
        source: hydrated.source,
        subjectId: hydrated.subjectId,
        isTv: hydrated.isTv,
        matchedTitle: hydrated.title,
        matchedYear: hydrated.year,
        isMotionComic: hydrated.isMotionComic,
        posterUrl: hydrated.posterUrl,
        backdropUrl: hydrated.backdropUrl,
        synopsis: hydrated.synopsis,
        doubanScore: hydrated.rating,
        danmuTitleOverride: _danmuTitleCtrl.text.trim(),
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await widget.storage.saveSeriesScrapeOverride(
        widget.site.key,
        widget.video.id,
        updated,
        isPrivate: widget.site.isEffectivelyPrivate,
      );
      if (!mounted) return;
      Navigator.of(context).pop(updated);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _hydrating = false;
        _searchError = '获取作品详情失败：$e';
      });
    }
  }

  Future<void> _saveEpisodeSettings() async {
    final updated = _draft.copyWith(
      danmuTitleOverride: _danmuTitleCtrl.text.trim(),
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await widget.storage.saveSeriesScrapeOverride(
      widget.site.key,
      widget.video.id,
      updated,
      isPrivate: widget.site.isEffectivelyPrivate,
    );
    if (!mounted) return;
    Navigator.of(context).pop(updated);
  }

  Future<void> _resetToAuto() async {
    await widget.storage.clearSeriesScrapeOverride(
      widget.site.key,
      widget.video.id,
      isPrivate: widget.site.isEffectivelyPrivate,
    );
    if (!mounted) return;
    Navigator.of(context).pop(null);
  }

  Future<void> _editManualEpisodeNumber(
    int originalIndex,
    String rawName,
    ScrapedEpisodeInfo info,
  ) async {
    final ctrl = TextEditingController(
      text: info.resolvedEpisodeNumber?.toString() ?? '',
    );
    final result = await showDialog<int?>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: _cardBg,
        title: const Text(
          '手动校准集数',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              rawName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 12.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: '真实集数（正整数，留空恢复自动识别）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) {
                final v = int.tryParse(ctrl.text.trim());
                Navigator.of(dlgCtx).pop(v ?? -1);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dlgCtx).pop(-1),
            child: const Text('恢复自动'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dlgCtx).pop(null),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final v = int.tryParse(ctrl.text.trim());
              Navigator.of(dlgCtx).pop(v != null && v > 0 ? v : -1);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (result == null || !mounted) return;
    final nextMap = Map<String, int>.from(_draft.episodeNumberOverrides);
    if (result <= 0) {
      nextMap.remove(rawName);
    } else {
      nextMap[rawName] = result;
    }
    setState(() {
      _draft = _draft.copyWith(episodeNumberOverrides: nextMap);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _border),
        boxShadow: const [
          BoxShadow(
            color: Color(0xAA000000),
            blurRadius: 42,
            offset: Offset(0, 18),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildHeader(),
          _buildTabBar(),
          const Divider(height: 1, color: _border),
          Expanded(
            child: _tabIndex == 0
                ? _buildWorkMatchTab()
                : _buildEpisodeScrapeTab(),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 14, 10),
      child: Row(
        children: [
          const Icon(
            CupertinoIcons.sparkles,
            color: _accent,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '剧集刮削与校准',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _draft.hasWorkBinding
                      ? '${widget.video.title}  →  已绑定：${_draft.matchedTitle}${_draft.isMotionComic ? "（动态漫画）" : ""}'
                      : widget.video.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ],
            ),
          ),
          if (_hasExistingOverride)
            TextButton(
              key: const ValueKey('scrape-reset-auto'),
              onPressed: _resetToAuto,
              child: const Text(
                '恢复自动匹配',
                style: TextStyle(color: Color(0xFFFF8A80), fontSize: 12.5),
              ),
            ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(CupertinoIcons.xmark, color: Colors.white70, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    Widget tabBtn(int index, String title, IconData icon, Key key) {
      final active = _tabIndex == index;
      return Expanded(
        child: InkWell(
          key: key,
          onTap: () => setState(() => _tabIndex = index),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: active ? _accent.withValues(alpha: 0.22) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: active ? _accent.withValues(alpha: 0.7) : Colors.transparent,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 15,
                  color: active ? Colors.white : Colors.white60,
                ),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: TextStyle(
                    color: active ? Colors.white : Colors.white60,
                    fontSize: 13.5,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _border),
        ),
        child: Row(
          children: [
            tabBtn(
              0,
              '作品刮削匹配（海报/简介/动态漫画区分）',
              CupertinoIcons.photo_on_rectangle,
              const ValueKey('scrape-tab-work'),
            ),
            const SizedBox(width: 6),
            tabBtn(
              1,
              '剧集集数刮削（选集/弹幕校准）',
              CupertinoIcons.list_number,
              const ValueKey('scrape-tab-episodes'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWorkMatchTab() {
    Widget filterChip(String value, String label, Key key) {
      final selected = _formFilter == value;
      return ChoiceChip(
        key: key,
        label: Text(label),
        selected: selected,
        labelStyle: TextStyle(
          color: selected ? Colors.white : Colors.white70,
          fontSize: 12.5,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
        backgroundColor: Colors.white.withValues(alpha: 0.06),
        selectedColor: value == 'motion_comic'
            ? _mcAmber.withValues(alpha: 0.35)
            : _accent.withValues(alpha: 0.35),
        side: BorderSide(
          color: selected
              ? (value == 'motion_comic' ? _mcAmber : _accent)
              : _border,
        ),
        onSelected: (_) {
          if (_formFilter == value) return;
          setState(() => _formFilter = value);
          unawaited(_runSearch());
        },
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('scrape-work-search-field'),
                      controller: _searchCtrl,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: '输入片名搜索豆瓣 / Bangumi / B站官方条目',
                        hintStyle: const TextStyle(color: Colors.white38),
                        prefixIcon: const Icon(
                          CupertinoIcons.search,
                          color: Colors.white54,
                          size: 17,
                        ),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.06),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 11,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: _border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: _border),
                        ),
                      ),
                      onSubmitted: (_) => _runSearch(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    key: const ValueKey('scrape-work-search-btn'),
                    onPressed: _searching ? null : _runSearch,
                    style: FilledButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 13,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('搜索'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  filterChip('all', '全部', const ValueKey('scrape-filter-all')),
                  filterChip(
                    'standard',
                    '动漫 / 剧集（排除动态漫画）',
                    const ValueKey('scrape-filter-standard'),
                  ),
                  filterChip(
                    'motion_comic',
                    '仅动态漫画',
                    const ValueKey('scrape-filter-motion_comic'),
                  ),
                  filterChip('movie', '电影', const ValueKey('scrape-filter-movie')),
                ],
              ),
            ],
          ),
        ),
        if (_hydrating)
          const LinearProgressIndicator(
            minHeight: 2,
            color: _accent,
            backgroundColor: Color(0x22FFFFFF),
          ),
        Expanded(
          child: _searching
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CupertinoActivityIndicator(color: Colors.white70),
                      SizedBox(height: 10),
                      Text(
                        '正在检索豆瓣、Bangumi 与 B站官方条目…',
                        style: TextStyle(color: Colors.white60, fontSize: 13),
                      ),
                    ],
                  ),
                )
              : _candidates.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _searchError ?? '输入片名开始搜索匹配作品',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 13.5,
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
                      itemCount: _candidates.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (ctx, idx) =>
                          _buildCandidateCard(_candidates[idx]),
                    ),
        ),
      ],
    );
  }

  Widget _buildCandidateCard(SeriesScrapeCandidate cand) {
    final isBound = _draft.hasWorkBinding &&
        _draft.source == cand.source &&
        _draft.subjectId == cand.subjectId;
    final isMc = cand.isMotionComic;
    final sourceLabel = switch (cand.source) {
      'douban' => '豆瓣',
      'bangumi' => 'Bangumi',
      'bilibili' => 'B站',
      _ => cand.source,
    };

    return Container(
      key: ValueKey('scrape-candidate-${cand.source}-${cand.subjectId}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isBound ? _accent.withValues(alpha: 0.14) : _cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isBound ? _accent : _border,
          width: isBound ? 1.2 : 0.8,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 50,
              height: 72,
              child: cand.posterUrl.isNotEmpty
                  ? PosterImage(
                      url: cand.posterUrl,
                      title: '',
                      fit: BoxFit.cover,
                      highRes: false,
                      placeholder: const ColoredBox(
                        color: Color(0xFF232C3F),
                        child: Icon(
                          CupertinoIcons.film,
                          color: Colors.white30,
                          size: 20,
                        ),
                      ),
                    )
                  : const ColoredBox(
                      color: Color(0xFF232C3F),
                      child: Icon(
                        CupertinoIcons.film,
                        color: Colors.white30,
                        size: 20,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        cand.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (cand.year.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Text(
                        cand.year,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _miniTag(
                      cand.mediaBadge,
                      bg: isMc
                          ? _mcAmber.withValues(alpha: 0.24)
                          : _accent.withValues(alpha: 0.22),
                      fg: isMc ? const Color(0xFFFFD080) : const Color(0xFFB5D5FF),
                    ),
                    _miniTag(
                      sourceLabel,
                      bg: Colors.white.withValues(alpha: 0.08),
                      fg: Colors.white70,
                    ),
                    if (cand.rating != null && cand.rating! >= 2.0)
                      _miniTag(
                        '★ ${cand.rating!.toStringAsFixed(1)}',
                        bg: const Color(0x3330D158),
                        fg: const Color(0xFF9DF2B2),
                      ),
                  ],
                ),
                if (cand.subtitle.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    cand.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
                if (cand.synopsis.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    cand.synopsis,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: _hydrating ? null : () => _applyCandidate(cand),
            style: FilledButton.styleFrom(
              backgroundColor: isBound
                  ? const Color(0xFF30D158)
                  : Colors.white.withValues(alpha: 0.14),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              minimumSize: const Size(0, 34),
            ),
            child: Text(
              isBound ? '已绑定' : '应用',
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEpisodeScrapeTab() {
    final line = widget.activeLine;
    if (line == null || line.episodes.isEmpty) {
      return const Center(
        child: Text(
          '当前暂未加载剧集列表，请等待线路加载完成后再刮削集数',
          style: TextStyle(color: Colors.white60, fontSize: 13.5),
        ),
      );
    }

    final effectiveTitle = _draft.matchedTitle.isNotEmpty
        ? _draft.matchedTitle
        : widget.video.title;
    final scrape = SeriesScraper.scrapeLineEpisodes(
      line.episodes,
      seriesTitle: effectiveTitle,
      episodeOffset: _draft.episodeOffset,
      manualOverrides: _draft.episodeNumberOverrides,
    );
    final sortByScraped =
        _draft.sortByScrapedEpisode ?? scrape.sourceOrderScrambled;
    final ordered = scrape.orderedIndices(
      sortByScraped: sortByScraped,
      hideSpecials: _draft.hideSpecials,
    );

    final filterKw = _epFilterText.trim().toLowerCase();
    final visibleIndices = filterKw.isEmpty
        ? ordered
        : ordered.where((idx) {
            final ep = line.episodes[idx];
            final info = scrape.byOriginalIndex[idx];
            final numStr = info.resolvedEpisodeNumber?.toString() ?? '';
            return ep.name.toLowerCase().contains(filterKw) ||
                info.displayLabel.toLowerCase().contains(filterKw) ||
                numStr == filterKw;
          }).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Diagnostic summary card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _cardBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '线路：${line.name} · 共 ${line.episodes.length} 项（识别正片 ${scrape.regularCount} 集'
                      '${scrape.specialCount > 0 ? " · 特别篇/预告 ${scrape.specialCount} 项" : ""}'
                      '${scrape.minEpisodeNumber != null && scrape.maxEpisodeNumber != null ? " · 第 ${scrape.minEpisodeNumber}–${scrape.maxEpisodeNumber} 集" : ""}）',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (scrape.sourceOrderScrambled || scrape.hasMissingNumbers) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          if (scrape.sourceOrderScrambled)
                            _miniTag(
                              '检测到源集数顺序错乱，建议开启智能排序',
                              bg: _mcAmber.withValues(alpha: 0.22),
                              fg: const Color(0xFFFFD080),
                            ),
                          if (scrape.hasMissingNumbers)
                            _miniTag(
                              '检测到缺集/跳集，弹幕将按真实集数匹配',
                              bg: _accent.withValues(alpha: 0.22),
                              fg: const Color(0xFFB5D5FF),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 10),
              // Switches + Offset row
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilterChip(
                    key: const ValueKey('scrape-toggle-smart-sort'),
                    label: const Text('按刮削集数智能排序'),
                    selected: sortByScraped,
                    labelStyle: TextStyle(
                      color: sortByScraped ? Colors.white : Colors.white70,
                      fontSize: 12.5,
                    ),
                    selectedColor: _accent.withValues(alpha: 0.35),
                    backgroundColor: Colors.white.withValues(alpha: 0.06),
                    onSelected: (v) => setState(() {
                      _draft = _draft.copyWith(sortByScrapedEpisode: v);
                    }),
                  ),
                  FilterChip(
                    key: const ValueKey('scrape-toggle-hide-specials'),
                    label: const Text('隐藏预告 / 特别篇'),
                    selected: _draft.hideSpecials,
                    labelStyle: TextStyle(
                      color: _draft.hideSpecials ? Colors.white : Colors.white70,
                      fontSize: 12.5,
                    ),
                    selectedColor: _accent.withValues(alpha: 0.35),
                    backgroundColor: Colors.white.withValues(alpha: 0.06),
                    onSelected: (v) => setState(() {
                      _draft = _draft.copyWith(hideSpecials: v);
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Text(
                    '集数全局偏移：',
                    style: TextStyle(color: Colors.white70, fontSize: 12.5),
                  ),
                  const SizedBox(width: 6),
                  _offsetBtn('-10', () => _changeOffset(_draft.episodeOffset - 10)),
                  const SizedBox(width: 4),
                  _offsetBtn('-1', () => _changeOffset(_draft.episodeOffset - 1)),
                  const SizedBox(width: 8),
                  Text(
                    _draft.episodeOffset == 0
                        ? '0'
                        : (_draft.episodeOffset > 0
                            ? '+${_draft.episodeOffset}'
                            : '${_draft.episodeOffset}'),
                    key: const ValueKey('scrape-offset-value'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _offsetBtn('+1', () => _changeOffset(_draft.episodeOffset + 1)),
                  const SizedBox(width: 4),
                  _offsetBtn('+10', () => _changeOffset(_draft.episodeOffset + 10)),
                  if (_draft.episodeOffset != 0) ...[
                    const SizedBox(width: 6),
                    _offsetBtn('归零', () => _changeOffset(0)),
                  ],
                  const Spacer(),
                  SizedBox(
                    width: 170,
                    child: TextField(
                      controller: _epFilterCtrl,
                      style: const TextStyle(color: Colors.white, fontSize: 12.5),
                      decoration: InputDecoration(
                        hintText: '筛选集数/文件名',
                        hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.06),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: _border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: _border),
                        ),
                      ),
                      onChanged: (v) => setState(() => _epFilterText = v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _danmuTitleCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 12.5),
                decoration: InputDecoration(
                  labelText: '弹幕匹配片名覆写（可选，留空自动使用绑定作品名）',
                  labelStyle: const TextStyle(color: Colors.white54, fontSize: 12),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.05),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: _border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: _border),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: _border),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            itemCount: visibleIndices.length,
            separatorBuilder: (_, __) =>
                const Divider(height: 1, color: Color(0x18FFFFFF)),
            itemBuilder: (ctx, pos) {
              final origIdx = visibleIndices[pos];
              final ep = line.episodes[origIdx];
              final info = scrape.byOriginalIndex[origIdx];
              final isManual = info.hasManualOverride;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(
                  children: [
                    SizedBox(
                      width: 34,
                      child: Text(
                        '#${origIdx + 1}',
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        ep.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(
                        CupertinoIcons.arrow_right,
                        size: 12,
                        color: Colors.white38,
                      ),
                    ),
                    _miniTag(
                      info.displayLabel,
                      bg: info.isSpecial
                          ? _mcAmber.withValues(alpha: 0.22)
                          : (isManual
                              ? const Color(0x3330D158)
                              : _accent.withValues(alpha: 0.22)),
                      fg: info.isSpecial
                          ? const Color(0xFFFFD080)
                          : (isManual
                              ? const Color(0xFF9DF2B2)
                              : const Color(0xFFB5D5FF)),
                    ),
                    if (info.qualityTag.isNotEmpty) ...[
                      const SizedBox(width: 5),
                      _miniTag(
                        info.qualityTag,
                        bg: Colors.white.withValues(alpha: 0.08),
                        fg: Colors.white70,
                      ),
                    ],
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () =>
                          _editManualEpisodeNumber(origIdx, ep.name, info),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white70,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        minimumSize: const Size(0, 28),
                      ),
                      child: const Text(
                        '校准',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const Divider(height: 1, color: _border),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '校准后的集数将同步用于剧集列表定位与弹幕精确匹配',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('scrape-save-episodes-btn'),
                onPressed: _saveEpisodeSettings,
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                ),
                child: const Text('保存集数校准'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _changeOffset(int next) {
    setState(() {
      _draft = _draft.copyWith(episodeOffset: next.clamp(-500, 500));
    });
  }

  Widget _offsetBtn(String label, VoidCallback onPressed) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: const BorderSide(color: _border),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: const Size(0, 30),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _miniTag(
    String text, {
    required Color bg,
    required Color fg,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: fg,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
