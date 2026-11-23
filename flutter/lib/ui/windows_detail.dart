part of 'detail_screen.dart';

extension _WindowsDetail on _DetailScreenState {
  static const Color _cinemaCanvas = Color(0xFF0A0D13);
  static const Color _cinemaBorder = Color(0x1EFFFFFF);
  static const Color _cinemaMuted = Color(0xB3FFFFFF);

  String _cleanWindowsSynopsis(String raw) {
    var text = raw.replaceAll(RegExp('<[^>]+>'), '').trim();
    if (text.isEmpty) return '';
    // Many CMS sources emit "short preview...[展开全部] full synopsis..."
    final expandMatch = RegExp(r'\[展开全部\]|【展开全部】').firstMatch(text);
    if (expandMatch != null) {
      final before = text.substring(0, expandMatch.start).trim();
      final after = text.substring(expandMatch.end).trim();
      if (after.length >= before.length && after.isNotEmpty) {
        text = after;
      } else {
        text = '$before $after'.trim();
      }
    }
    text = text
        .replaceAll(RegExp(r'【(?:玩偶哥哥|木偶|雷鲸|欧歌|闪电|多多|蜡笔)[^】]{0,12}】'), '')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
    return text;
  }

  Widget _buildWindowsDetail(BuildContext context) {
    final saved = _findBookmark();
    final bookmark = _video.lines.isNotEmpty &&
            saved?.line ==
                _video
                    .lines[_selectedLine.clamp(0, _video.lines.length - 1)].name
        ? saved
        : null;
    final hasCastSection =
        _video.actor.trim().isNotEmpty || _publicLookupTitle.trim().isNotEmpty;

    return Scaffold(
      backgroundColor: _cinemaCanvas,
      body: ColoredBox(
        color: _cinemaCanvas,
        child: LayoutBuilder(
          builder: (context, box) {
            final pad = box.maxWidth >= 1100 ? 40.0 : (box.maxWidth >= 820 ? 28.0 : 20.0);
            final compact = box.maxWidth < 820;
            final topInset = MediaQuery.paddingOf(context).top;
            final double maxHeroH = math.max(300.0, box.maxHeight - 88.0);
            final double heroHeight = compact
                ? (box.maxHeight * 0.64).clamp(290.0, maxHeroH).toDouble()
                : (box.maxHeight * 0.75)
                    .clamp(math.min(430.0, maxHeroH), maxHeroH)
                    .toDouble();

            return Stack(
              children: [
                // Full-bleed scrollable cinema detail page starting at y = 0
                ListView(
                  padding: const EdgeInsets.only(bottom: 48),
                  children: [
                    _windowsImmersiveHero(
                      context,
                      box: box,
                      pad: pad,
                      topInset: topInset,
                      heroHeight: heroHeight,
                      compact: compact,
                      bookmark: bookmark,
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(pad, 14, pad, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _windowsCollapsibleControlsPanel(bookmark),
                          if (hasCastSection)
                            CastAvatarSection(
                              title: _effectiveLookupTitle.isNotEmpty
                                  ? _effectiveLookupTitle
                                  : _video.title,
                              actorRaw: _video.actor,
                              year: _effectiveLookupYear,
                              doubanId: _effectiveDoubanId,
                              wantMotionComic: _effectiveWantMotionComic,
                              forceDark: true,
                              allowExternalLookup:
                                  !_activeSite.isEffectivelyPrivate,
                              padding: EdgeInsets.zero,
                              containerMargin: const EdgeInsets.only(top: 28),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                // Floating translucent top navigation overlay over the full-bleed poster
                Positioned(
                  top: topInset + 14,
                  left: pad,
                  right: pad,
                  child: Row(
                    children: [
                      _windowsFloatingGlassButton(
                        label: '返回',
                        icon: CupertinoIcons.back,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const Spacer(),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: box.maxWidth * 0.45,
                        ),
                        child: Tooltip(
                          message: _activeSite.name,
                          child: _windowsFloatingGlassButton(
                            label: _activeSite.name,
                            icon: CupertinoIcons.layers_alt,
                            onPressed: _showSourcePickerSheet,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _windowsFloatingGlassButton({
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: const Color(0x990D1119),
        overlayColor: Colors.white.withValues(alpha: .16),
        side: const BorderSide(color: Color(0x33FFFFFF)),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
        shape: const StadiumBorder(),
        minimumSize: const Size(0, 38),
      ),
      icon: Icon(icon, size: 15),
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _windowsImmersiveHero(
    BuildContext context, {
    required BoxConstraints box,
    required double pad,
    required double topInset,
    required double heroHeight,
    required bool compact,
    required WatchHistoryEntry? bookmark,
  }) {
    final hasLines = _video.lines.isNotEmpty;
    final activeLine = hasLines
        ? _video.lines[_selectedLine.clamp(0, _video.lines.length - 1)]
        : null;
    final douban = _effectiveDoubanScore();
    final rt = _effectiveRtScore();
    final specBadges =
        OhosRuntime.isOhos ? const <MediaBadge>[] : _specBadgesForHero(activeLine);
    final synopsis = _cleanWindowsSynopsis(_effectiveSeriesSynopsis());
    final metaLine = [_effectiveLookupYear, _video.area, _video.remarks]
        .where((s) => s.isNotEmpty)
        .join(' · ');
    final bool hasAnyPosterArt =
        _effectivePosterUrl.trim().isNotEmpty || _loadedPosterBytes != null;
    final bool showFramedPortraitCard =
        !_windowsHeroHasLandscape && hasAnyPosterArt && box.maxWidth >= 660;
    final double framedPosterHeight = showFramedPortraitCard
        ? (heroHeight * (compact ? 0.56 : 0.68))
            .clamp(compact ? 156.0 : 250.0, 456.0)
            .toDouble()
        : 0.0;
    final double framedPosterWidth = framedPosterHeight * (2.0 / 3.0);

    final actionButtons = Wrap(
      spacing: 10,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: const Color(0xFF0E131D),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            shape: const StadiumBorder(),
          ),
          onPressed: hasLines
              ? () => _playPrimaryAction(bookmark)
              : _loading
                  ? null
                  : _searchOtherSources,
          icon: const Icon(CupertinoIcons.play_fill, size: 15),
          label: Text(
            hasLines
                ? (bookmark != null && bookmark.resumePosition > 0
                    ? '继续观看'
                    : '立即播放')
                : (_loading ? '加载片源中…' : '搜索其他片源'),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
        ),
        _windowsHeroPillAction(
          label: _isFavorite ? '已收藏' : '收藏',
          icon: _isFavorite ? CupertinoIcons.heart_fill : CupertinoIcons.heart,
          active: _isFavorite,
          onPressed: () async {
            final value = await widget.storage.toggleFavorite(_activeSite, _video);
            if (mounted) _updateWindowsState(() => _isFavorite = value);
          },
        ),
        _windowsHeroPillAction(
          label: '下载',
          icon: CupertinoIcons.arrow_down_to_line,
          onPressed: _showDownloadSheet,
        ),
        _windowsHeroPillAction(
          label: '网盘账号',
          icon: CupertinoIcons.cloud,
          onPressed: () => showNetdiskAccountSheet(
            context,
            widget.storage,
            onChanged: () {
              if (mounted) _updateWindowsState(() {});
            },
          ),
        ),
      ],
    );

    final editorialInfo = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _video.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white,
            fontSize: compact ? 26 : 38,
            height: 1.15,
            letterSpacing: -0.5,
            fontWeight: FontWeight.w800,
            shadows: const [
              Shadow(
                color: Color(0x99000000),
                blurRadius: 18,
                offset: Offset(0, 3),
              ),
            ],
          ),
        ),
        if (metaLine.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            metaLine,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xE0FFFFFF),
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
              height: 1.4,
            ),
          ),
        ],
        if ((douban != null && douban >= 2 && douban <= 10) ||
            (rt != null && rt >= 1 && rt <= 100) ||
            _effectiveWantMotionComic ||
            (_scrapeOverride != null &&
                (_scrapeOverride!.hasWorkBinding ||
                    _scrapeOverride!.hasEpisodeCalibration)) ||
            specBadges.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_effectiveWantMotionComic)
                Container(
                  key: const ValueKey('detail-motion-comic-badge'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 3.5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x3DFF9F0A),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0x80FF9F0A)),
                  ),
                  child: const Text(
                    '动态漫画',
                    style: TextStyle(
                      color: Color(0xFFFFE0A8),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (douban != null && douban >= 2 && douban <= 10)
                Container(
                  key: const ValueKey('detail-douban-badge'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 3.5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x3630D158),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0x6630D158)),
                  ),
                  child: Text(
                    '豆瓣 ★ ${douban.toStringAsFixed(1)}',
                    style: const TextStyle(
                      color: Color(0xFFE9FBF0),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (rt != null && rt >= 1 && rt <= 100)
                Container(
                  key: const ValueKey('detail-rt-badge'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 3.5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x36FF453A),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0x66FF453A)),
                  ),
                  child: Text(
                    '烂番茄 $rt%',
                    style: const TextStyle(
                      color: Color(0xFFFFECEA),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (specBadges.isNotEmpty)
                MediaBadgeRow(
                  badges: specBadges,
                  maxBadges: 5,
                  windowsSolid: true,
                ),
            ],
          ),
        ],
        if (synopsis.isNotEmpty && !compact) ...[
          const SizedBox(height: 12),
          Text(
            synopsis,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xCCFFFFFF),
              fontSize: 13,
              height: 1.55,
            ),
          ),
        ],
        const SizedBox(height: 18),
        actionButtons,
        if (bookmark != null) ...[
          const SizedBox(height: 10),
          Text(
            '${bookmark.episode} · 已看 ${_formatBookmarkTime(bookmark.position)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xB8FFFFFF),
              fontSize: 12,
            ),
          ),
        ],
      ],
    );

    final double editorialMaxWidth = showFramedPortraitCard
        ? math.max(
            240.0,
            math.min(
              620.0,
              box.maxWidth - pad * 2 - framedPosterWidth - (compact ? 24.0 : 48.0),
            ),
          )
        : (compact
            ? math.max(260.0, box.maxWidth - pad * 2)
            : math.min(640.0, box.maxWidth * 0.62));

    return SizedBox(
      width: double.infinity,
      height: heroHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Orientation-aware full-bleed hero stage:
          // - True HD landscape still -> crisp unobstructed widescreen cinema hero
          // - Portrait-only fallback -> deep poster-matched ambient blur canvas
          //   (paired with an uncropped framed 2:3 key-art card on the right).
          Positioned.fill(
            key: _transitionPosterKey,
            child: LandscapePosterImage(
              key: const ValueKey('windows-detail-poster'),
              url: _effectivePosterUrl,
              title: _effectiveLookupTitle,
              year: _effectiveLookupYear,
              preferredBackdropUrl: _effectiveBackdropUrl,
              preferredDoubanId: _effectiveDoubanId,
              preferredDoubanIsTv: _effectiveDoubanIsTv,
              wantMotionComic: _effectiveWantMotionComic,
              allowExternalLookup: !_activeSite.isEffectivelyPrivate,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              blurPortraitFallback: true,
              onBytesLoaded: (bytes) {
                if (mounted && !identical(_loadedPosterBytes, bytes)) {
                  _updateWindowsState(() {
                    _loadedPosterBytes = bytes;
                    _loadedPosterIdentity = _currentPosterIdentity;
                  });
                }
              },
              onLandscapeStatusChanged: (hasLandscape) {
                if (mounted && _windowsHeroHasLandscape != hasLandscape) {
                  _updateWindowsState(
                    () => _windowsHeroHasLandscape = hasLandscape,
                  );
                }
              },
              placeholder: const ColoredBox(
                color: Color(0xFF141923),
                child: Center(
                  child: Icon(
                    CupertinoIcons.film,
                    color: Color(0x55FFFFFF),
                    size: 56,
                  ),
                ),
              ),
            ),
          ),
          // Feather-light top gradient solely for floating back/source pills
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x5E0A0D13),
                  Color(0x140A0D13),
                  Color(0x000A0D13),
                ],
                stops: [0.0, 0.10, 0.22],
              ),
            ),
          ),
          // Localized lower-zone gradient fade ONLY where title, intro & action
          // buttons sit — keeping the entire upper HD poster bright & intact.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x000A0D13),
                  Color(0x000A0D13),
                  Color(0x6E0A0D13),
                  Color(0xD60A0D13),
                  _cinemaCanvas,
                ],
                stops: [0.0, 0.46, 0.64, 0.84, 1.0],
              ),
            ),
          ),
          // Subtle localized bottom-left radial cushion behind text for legibility
          // without dimming the upper or right portions of the poster.
          if (!compact)
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(-0.85, 0.95),
                  radius: 0.95,
                  colors: [
                    Color(0xA60A0D13),
                    Color(0x400A0D13),
                    Color(0x000A0D13),
                  ],
                  stops: [0.0, 0.48, 1.0],
                ),
              ),
            ),
          // When only a portrait 2:3 poster is available (no authentic landscape
          // still exists), showcase the complete uncropped key-art poster in a
          // crisp museum-framed floating card on the right over the ambient blur.
          if (showFramedPortraitCard)
            Positioned(
              right: pad,
              bottom: compact ? 18 : 28,
              width: framedPosterWidth,
              height: framedPosterHeight,
              child: Container(
                key: const ValueKey('windows-detail-framed-poster'),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x99000000),
                      blurRadius: 38,
                      spreadRadius: 2,
                      offset: Offset(0, 18),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      PosterImage(
                        url: _effectivePosterUrl,
                        title: _effectiveLookupTitle,
                        year: _effectiveLookupYear,
                        fit: BoxFit.cover,
                        highRes: true,
                        placeholder: const ColoredBox(
                          color: Color(0xFF18202D),
                          child: Center(
                            child: Icon(
                              CupertinoIcons.film,
                              color: Color(0x55FFFFFF),
                              size: 36,
                            ),
                          ),
                        ),
                      ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: const Color(0x3DFFFFFF),
                            width: 1,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // Editorial metadata & CTA lowered into the bottom content band
          Padding(
            padding: EdgeInsets.fromLTRB(
              pad,
              topInset + 64,
              pad,
              compact ? 14 : 22,
            ),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: editorialMaxWidth,
                ),
                child: SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: editorialInfo,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _windowsHeroPillAction({
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
    bool active = false,
  }) {
    return TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: active
            ? const Color(0x4A4C9AFF)
            : const Color(0x52121722),
        overlayColor: Colors.white.withValues(alpha: .16),
        side: BorderSide(
          color: active
              ? const Color(0x994C9AFF)
              : Colors.white.withValues(alpha: .22),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: const StadiumBorder(),
        minimumSize: const Size(0, 42),
      ),
      icon: Icon(icon, size: 15),
      label: Text(
        label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _windowsCinemaActionPill(
    String label, {
    Key? key,
    IconData? icon,
    bool selected = false,
    VoidCallback? onPressed,
  }) {
    return TextButton(
      key: key,
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: selected
            ? const Color(0xFF2B6EF2)
            : Colors.white.withValues(alpha: .07),
        overlayColor: Colors.white.withValues(alpha: .12),
        side: BorderSide(
          color: selected ? const Color(0x6680B8FF) : _cinemaBorder,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: const StadiumBorder(),
        minimumSize: const Size(40, 38),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14.5),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _windowsCollapsibleControlsPanel(WatchHistoryEntry? bookmark) {
    final hasLines = _video.lines.isNotEmpty;
    final lineIndex =
        hasLines ? _selectedLine.clamp(0, _video.lines.length - 1) : 0;
    final activeLine = hasLines ? _video.lines[lineIndex] : null;
    final activeIndices =
        activeLine != null ? _activeEpisodeIndicesFor(activeLine) : const <int>[];
    final activeLineSpec = activeLine == null || OhosRuntime.isOhos
        ? ''
        : MediaBadges.formatDotJoined(
            _specBadgesForLineOnly(activeLine),
            maxBadges: 2,
          );
    final lineSummary = activeLine == null
        ? '暂无线路'
        : activeLineSpec.isEmpty
            ? activeLine.name
            : '${activeLine.name} · $activeLineSpec';
    final cleanSynopsis = _cleanWindowsSynopsis(_effectiveSeriesSynopsis());

    return Column(
      key: const ValueKey('windows-detail-controls-bar'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (hasLines) ...[
                _windowsDrawerToggleButton(
                  key: const ValueKey('windows-detail-line-toggle'),
                  icon: CupertinoIcons.layers_alt,
                  label: _video.lines.length > 1
                      ? '线路：$lineSummary（共 ${_video.lines.length} 条）'
                      : '线路：$lineSummary',
                  expanded: _windowsLinesExpanded,
                  onPressed: () => _updateWindowsState(() {
                    _windowsLinesExpanded = !_windowsLinesExpanded;
                  }),
                ),
                _windowsDrawerToggleButton(
                  key: const ValueKey('windows-detail-episode-toggle'),
                  icon: CupertinoIcons.square_grid_2x2,
                  label:
                      '选集：${_currentSeasonLabel(activeLine!)}（共 ${activeIndices.length} 集）',
                  expanded: _windowsEpisodesExpanded,
                  onPressed: () => _updateWindowsState(() {
                    _windowsEpisodesExpanded = !_windowsEpisodesExpanded;
                  }),
                ),
                _windowsCinemaActionPill(
                  _descending ? '倒序' : '正序',
                  icon: CupertinoIcons.sort_down,
                  onPressed: () {
                    _updateWindowsState(() {
                      _descending = !_descending;
                      _selectedPage = 0;
                    });
                    widget.storage.setEpisodesDescending(_descending);
                  },
                ),
                _windowsCinemaActionPill(
                  '全部剧集',
                  icon: CupertinoIcons.list_bullet,
                  onPressed: () => _showAllEpisodesGridSheet(bookmark),
                ),
              ],
              _windowsCinemaActionPill(
                '切换片源',
                icon: CupertinoIcons.arrow_2_squarepath,
                onPressed: _showSourcePickerSheet,
              ),
              if (!_activeSite.isEffectivelyPrivate)
                _windowsCinemaActionPill(
                  (_scrapeOverride != null &&
                          (_scrapeOverride!.hasWorkBinding ||
                              _scrapeOverride!.hasEpisodeCalibration))
                      ? '刮削匹配 · 已校准'
                      : '刮削匹配',
                  key: const ValueKey('windows-detail-scrape-btn'),
                  icon: CupertinoIcons.sparkles,
                  selected: _scrapeOverride != null &&
                      (_scrapeOverride!.hasWorkBinding ||
                          _scrapeOverride!.hasEpisodeCalibration),
                  onPressed: () => _openSeriesScrapeSheet(initialTab: 0),
                ),
              if (cleanSynopsis.isNotEmpty)
                _windowsDrawerToggleButton(
                  key: const ValueKey('windows-detail-synopsis-toggle'),
                  icon: CupertinoIcons.doc_text,
                  label: '剧情简介',
                  expanded: _windowsSynopsisExpanded,
                  onPressed: () => _updateWindowsState(() {
                    _windowsSynopsisExpanded = !_windowsSynopsisExpanded;
                  }),
                ),
            ],
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(top: 14),
              child: LinearProgressIndicator(
                minHeight: 2,
                color: Color(0xFF4C9AFF),
                backgroundColor: Color(0x22FFFFFF),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: WinPanel(dark: true, child: _buildDetailError()),
            ),
          if (_video.sourceWarnings.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: WinPanel(dark: true, child: _buildSourceWarningsSection()),
            ),
          if (hasLines) ...[
            // Collapsible Lines Drawer
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _windowsLinesExpanded
                  ? Padding(
                      key: const ValueKey('windows-detail-lines-panel'),
                      padding: const EdgeInsets.only(top: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Divider(height: 1, color: _cinemaBorder),
                          const SizedBox(height: 14),
                          const Text(
                            '选择播放线路',
                            style: TextStyle(
                              color: _cinemaMuted,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (var i = 0; i < _video.lines.length; i++)
                                Builder(
                                  builder: (_) {
                                    final line = _video.lines[i];
                                    final spec = OhosRuntime.isOhos
                                        ? ''
                                        : MediaBadges.formatDotJoined(
                                            _specBadgesForLineOnly(line),
                                            maxBadges: 3,
                                          );
                                    final label = spec.isEmpty
                                        ? line.name
                                        : '${line.name} · $spec';
                                    return ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 300,
                                      ),
                                      child: Tooltip(
                                        message: label,
                                        child: _windowsCinemaActionPill(
                                          label,
                                          selected: i == lineIndex,
                                          onPressed: () => _updateWindowsState(() {
                                            _selectedLine = i;
                                            _selectedPage = 0;
                                            _selectedInLineSeason = null;
                                          }),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                            ],
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            // Collapsible Episodes Drawer
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _windowsEpisodesExpanded
                  ? Padding(
                      key: const ValueKey('windows-detail-episodes-panel'),
                      padding: const EdgeInsets.only(top: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Divider(height: 1, color: _cinemaBorder),
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 10,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _windowsCinemaActionPill(
                                '季数 · ${_currentSeasonLabel(activeLine!)}',
                                icon: CupertinoIcons.chevron_down,
                                onPressed: _showSeasonPickerSheet,
                              ),
                              if (!_activeSite.isEffectivelyPrivate)
                                _windowsCinemaActionPill(
                                  '集数校准',
                                  key: const ValueKey(
                                    'windows-detail-episode-scrape-btn',
                                  ),
                                  icon: CupertinoIcons.slider_horizontal_3,
                                  selected: _scrapeOverride
                                          ?.hasEpisodeCalibration ??
                                      false,
                                  onPressed: () =>
                                      _openSeriesScrapeSheet(initialTab: 1),
                                ),
                              if (activeIndices.length >= 10)
                                SizedBox(
                                  width: 210,
                                  height: 36,
                                  child: TextField(
                                    key: const ValueKey(
                                      'windows-episode-locator-field',
                                    ),
                                    controller: _windowsEpisodeQueryCtrl,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12.5,
                                    ),
                                    decoration: InputDecoration(
                                      hintText: '输入集数定位，如 180',
                                      hintStyle: const TextStyle(
                                        color: Color(0x70FFFFFF),
                                        fontSize: 12,
                                      ),
                                      prefixIcon: const Icon(
                                        CupertinoIcons.search,
                                        color: Color(0x88FFFFFF),
                                        size: 14,
                                      ),
                                      suffixIcon: _windowsEpisodeQuery.isNotEmpty
                                          ? IconButton(
                                              padding: EdgeInsets.zero,
                                              iconSize: 14,
                                              onPressed: () =>
                                                  _updateWindowsState(() {
                                                _windowsEpisodeQueryCtrl.clear();
                                                _windowsEpisodeQuery = '';
                                                _selectedPage = 0;
                                              }),
                                              icon: const Icon(
                                                CupertinoIcons.xmark_circle_fill,
                                                color: Color(0x88FFFFFF),
                                              ),
                                            )
                                          : null,
                                      filled: true,
                                      fillColor:
                                          Colors.white.withValues(alpha: 0.07),
                                      isDense: true,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 8,
                                      ),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(18),
                                        borderSide: const BorderSide(
                                          color: _cinemaBorder,
                                        ),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(18),
                                        borderSide: const BorderSide(
                                          color: _cinemaBorder,
                                        ),
                                      ),
                                    ),
                                    onChanged: (v) => _updateWindowsState(() {
                                      _windowsEpisodeQuery = v;
                                      _selectedPage = 0;
                                    }),
                                  ),
                                ),
                              Text(
                                '共 ${activeIndices.length} 集',
                                style: const TextStyle(
                                  color: _cinemaMuted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          _windowsEpisodes(bookmark),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ] else if (!_loading) ...[
            const SizedBox(height: 16),
            const Text(
              '这个来源暂未提供可播放剧集',
              style: TextStyle(color: _cinemaMuted),
            ),
            const SizedBox(height: 10),
            _windowsCinemaActionPill(
              '搜索其他来源',
              onPressed: _searchOtherSources,
            ),
          ],
          // Collapsible Full Synopsis Drawer
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _windowsSynopsisExpanded && cleanSynopsis.isNotEmpty
                ? Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Divider(height: 1, color: _cinemaBorder),
                        const SizedBox(height: 14),
                        Text(
                          cleanSynopsis,
                          style: const TextStyle(
                            color: _cinemaMuted,
                            height: 1.8,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      );
  }

  Widget _windowsDrawerToggleButton({
    Key? key,
    required IconData icon,
    required String label,
    required bool expanded,
    required VoidCallback onPressed,
  }) {
    return TextButton(
      key: key,
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: expanded
            ? const Color(0xFF2B6EF2)
            : Colors.white.withValues(alpha: .08),
        overlayColor: Colors.white.withValues(alpha: .14),
        side: BorderSide(
          color: expanded ? const Color(0x8880B8FF) : _cinemaBorder,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
        shape: const StadiumBorder(),
        minimumSize: const Size(40, 38),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: expanded ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Icon(
            expanded ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down,
            size: 13,
          ),
        ],
      ),
    );
  }

  Widget _windowsEpisodes(WatchHistoryEntry? bookmark) {
    final lineIndex = _selectedLine.clamp(0, _video.lines.length - 1);
    final line = _video.lines[lineIndex];
    final scrape = _scrapeResultForLine(line);
    final active = _activeEpisodeIndicesFor(line);
    final ordered = _descending ? active.reversed.toList() : active;
    final filterKw = _windowsEpisodeQuery.trim().toLowerCase();
    final indices = filterKw.isEmpty
        ? ordered
        : ordered.where((idx) {
            final ep = line.episodes[idx];
            final info = scrape.byOriginalIndex[idx];
            final numStr = info.resolvedEpisodeNumber?.toString() ?? '';
            return ep.name.toLowerCase().contains(filterKw) ||
                info.displayLabel.toLowerCase().contains(filterKw) ||
                numStr == filterKw;
          }).toList();
    final pageCount = (indices.length / CmsParser.episodePageSize).ceil();
    final page = _selectedPage.clamp(0, pageCount == 0 ? 0 : pageCount - 1);
    final visible = indices
        .skip(page * CmsParser.episodePageSize)
        .take(CmsParser.episodePageSize);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_lineUnavailableReason(line) case final reason?)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text(reason, style: const TextStyle(color: _cinemaMuted)),
        ),
      if (indices.isEmpty && filterKw.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            children: [
              Text(
                '未找到匹配「$_windowsEpisodeQuery」的剧集',
                style: const TextStyle(color: _cinemaMuted, fontSize: 13),
              ),
              const SizedBox(width: 10),
              _windowsCinemaActionPill(
                '清除筛选',
                onPressed: () => _updateWindowsState(() {
                  _windowsEpisodeQueryCtrl.clear();
                  _windowsEpisodeQuery = '';
                  _selectedPage = 0;
                }),
              ),
            ],
          ),
        ),
      LayoutBuilder(builder: (context, box) {
        final columns = (box.maxWidth / 136).floor().clamp(2, 10);
        return Wrap(spacing: 10, runSpacing: 10, children: [
          for (final index in visible)
            Builder(builder: (_) {
              final ep = line.episodes[index];
              final info = scrape.byOriginalIndex[index];
              final showDualLine = info.resolvedEpisodeNumber != null &&
                  !info.isSpecial &&
                  ep.name.trim() != info.displayLabel &&
                  !ep.name.contains('第${info.resolvedEpisodeNumber}集') &&
                  !ep.name.contains('第 ${info.resolvedEpisodeNumber} 集');
              final isBookmarked =
                  bookmark?.line == line.name && bookmark?.index == index;
              return SizedBox(
                width: (box.maxWidth - (columns - 1) * 10) / columns,
                child: Tooltip(
                  message: [
                    if (showDualLine) info.displayLabel,
                    ep.name,
                    if (info.isSpecial) '特别篇/预告',
                    if (_episodeUnavailableReason(ep) case final reason?)
                      reason,
                  ].join(' · '),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      key: ValueKey('ep_card_${lineIndex}_$index'),
                      onTap: () => _openPlayer(lineIndex, index),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 48),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        alignment: Alignment.centerLeft,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: isBookmarked
                              ? const Color(0x334C9AFF)
                              : Colors.white.withValues(alpha: .06),
                          border: Border.all(
                            color: isBookmarked
                                ? const Color(0xFF4C9AFF)
                                : _cinemaBorder,
                          ),
                        ),
                        child: showDualLine
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          info.displayLabel,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      if (info.qualityTag.isNotEmpty)
                                        Text(
                                          info.qualityTag,
                                          style: const TextStyle(
                                            color: Color(0xFF8AB8FF),
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    ep.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Color(0x99FFFFFF),
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              )
                            : Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      ep.name,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  if (info.isSpecial) ...[
                                    const SizedBox(width: 4),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 5,
                                        vertical: 1.5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0x33FF9F0A),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Text(
                                        '特',
                                        style: TextStyle(
                                          color: Color(0xFFFFD080),
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
              );
            }),
        ]);
      }),
      if (pageCount > 1)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Wrap(spacing: 7, runSpacing: 7, children: [
            for (var i = 0; i < pageCount; i++)
              _windowsCinemaActionPill(
                '${i * CmsParser.episodePageSize + 1}–${math.min((i + 1) * CmsParser.episodePageSize, indices.length)}',
                selected: i == page,
                onPressed: () =>
                    _updateWindowsState(() => _selectedPage = i),
              ),
          ]),
        ),
    ]);
  }
}
