part of 'adaptive_shell.dart';

extension _WindowsShell on _AdaptiveShellState {
  void _windowsNavigate(String page) {
    _updateWindowsState(() => _windowsPage = page);
    if (page == 'live' &&
        _liveGroups.isEmpty &&
        !_liveLoading &&
        _visibleLives.isNotEmpty) {
      _loadLivePlaylist(_selectedLiveSource.clamp(0, _visibleLives.length - 1));
    }
  }

  Widget _buildWindowsShell(BuildContext context) {
    final appearance = WindowsAppearanceScope.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final pad = width > 1100 ? 32.0 : 22.0;
    return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyK, control: true):
              _showGlobalSearchSheet,
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              _showGlobalSearchSheet,
        },
        child: Focus(
            autofocus: true,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: WindowsBackdrop(
                  child: SafeArea(
                      bottom: false,
                      child: Column(children: [
                        Padding(
                            padding: EdgeInsets.fromLTRB(pad, 10, pad, 14),
                            child: LayoutBuilder(builder: (context, navBox) {
                              final showWordmark = navBox.maxWidth >= 860;
                              final brand = GestureDetector(
                                  key: const ValueKey('home-brand-logo'),
                                  onTap: _handleHomeLogoTap,
                                  child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Image.asset('assets/logo_mark.png',
                                            width: 34, height: 34),
                                        if (showWordmark) ...[
                                          const SizedBox(width: 9),
                                          Text('MarcoMovie',
                                              style: TextStyle(
                                                  color: winInk(context),
                                                  fontSize: 17.5,
                                                  letterSpacing: -0.2,
                                                  fontWeight: FontWeight.w600))
                                        ]
                                      ]));
                              final navPill = WinPanel(
                                  key: const ValueKey('windows-top-nav-pill'),
                                  radius: 999,
                                  padding: const EdgeInsets.all(4),
                                  child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        for (final item in [
                                          ('home', '首页'),
                                          ('discover', '发现'),
                                          ('live', '直播'),
                                          ('library', '我的')
                                        ])
                                          WinButton(item.$2,
                                              selected: _windowsPage == item.$1,
                                              onPressed: () =>
                                                  _windowsNavigate(item.$1)),
                                      ]));
                              final actions = Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                        tooltip: '搜索影片 · Ctrl+K',
                                        icon: Icon(CupertinoIcons.search,
                                            color: winInk(context), size: 20),
                                        onPressed: _showGlobalSearchSheet),
                                    const SizedBox(width: 4),
                                    IconButton(
                                        tooltip: '背景与外观 · ${appearance.label}',
                                        icon: Icon(CupertinoIcons.paintbrush,
                                            color: winInk(context), size: 19),
                                        onPressed: () => _updateWindowsState(() {
                                              _windowsSettings = '背景与外观';
                                              _windowsPage = 'settings';
                                            })),
                                    IconButton(
                                        tooltip: '设置',
                                        icon: Icon(CupertinoIcons.gear_alt,
                                            color: winInk(context), size: 20),
                                        onPressed: () =>
                                            _windowsNavigate('settings')),
                                  ]);
                              if (navBox.maxWidth < 620) {
                                return Row(children: [
                                  brand,
                                  const Spacer(),
                                  navPill,
                                  const Spacer(),
                                  actions,
                                ]);
                              }
                              return SizedBox(
                                height: 50,
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: brand,
                                    ),
                                    Align(
                                      alignment: Alignment.center,
                                      child: navPill,
                                    ),
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: actions,
                                    ),
                                  ],
                                ),
                              );
                            })),
                        if (_privateSessionUnlocked)
                          Padding(
                              padding: EdgeInsets.symmetric(horizontal: pad),
                              child: Row(children: [
                                Icon(CupertinoIcons.lock_shield,
                                    color: winMuted(context), size: 17),
                                const SizedBox(width: 8),
                                Text('隐私空间',
                                    style: TextStyle(color: winMuted(context))),
                                const Spacer(),
                                WinButton('退出隐私空间',
                                    onPressed: _exitPrivacySpace)
                              ])),
                        Expanded(
                            child: switch (_windowsPage) {
                          'discover' => _windowsDiscover(pad),
                          'live' => _windowsLive(pad),
                          'search' => _windowsSearch(pad),
                          'library' => _windowsLibrary(pad),
                          'settings' => _windowsSettingsPage(pad),
                          _ => _windowsHome(pad),
                        }),
                      ]))),
            )));
  }

  Widget _windowsHeading(String title, {List<Widget> actions = const []}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: LayoutBuilder(
            builder: (context, constraints) => Row(children: [
                  Expanded(
                      child: Text(title,
                          style: TextStyle(
                              color: winInk(context),
                              fontSize: 30,
                              fontWeight: FontWeight.w600))),
                  ConstrainedBox(
                      constraints:
                          BoxConstraints(maxWidth: constraints.maxWidth * .58),
                      child:
                          Wrap(alignment: WrapAlignment.end, children: actions))
                ])),
      );

  Widget _windowsEmpty(String title, String explanation,
          {VoidCallback? action, String button = '添加内容来源'}) =>
      Center(
          child: SingleChildScrollView(
              child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 630),
            child: WinPanel(
                padding: const EdgeInsets.all(36),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: TextStyle(
                              color: winInk(context),
                              fontSize: 29,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 18),
                      Text(explanation,
                          style:
                              TextStyle(color: winMuted(context), height: 1.8)),
                      if (action != null) ...[
                        const SizedBox(height: 25),
                        WinButton(button, selected: true, onPressed: action)
                      ],
                    ]))),
      )));

  Widget _windowsHome(double pad) {
    if (_homeError != null && _windowsRecommendedVideos.isEmpty)
      return _windowsHomeError();
    if (_config == null && !_privateSessionUnlocked) return _windowsWelcome();
    if (_homeLoading && _windowsRecommendedVideos.isEmpty)
      return const Center(child: CircularProgressIndicator());
    if (_windowsRecommendedVideos.isEmpty)
      return _windowsEmpty(
        _homeError == null ? '从一部影片开始' : '暂时无法加载影片',
        _homeError ?? '选择内容来源，或搜索想看的影片。',
        action: _homeError == null
            ? _showSitePickerDialog
            : _refreshCurrentHomeView,
        button: _homeError == null ? '选择片源' : '重新加载',
      );
    final history =
        _privateSessionUnlocked || !widget.storage.showContinueWatching
            ? <WatchHistoryEntry>[]
            : _cachedWatchHistory.take(3).toList();
    final showHero = widget.storage.showHeroBanner;
    return LayoutBuilder(builder: (context, box) {
      final contentWidth = (box.maxWidth - pad * 2).clamp(320.0, 4096.0);
      final sideHistory =
          contentWidth >= 1020 && showHero && history.isNotEmpty;
      final historyWidth = contentWidth >= 1520 ? 344.0 : 316.0;
      final heroHeight = contentWidth >= 1520
          ? 292.0
          : (contentWidth >= 960 ? 276.0 : 252.0);
      final heroAreaWidth = sideHistory
          ? (contentWidth - historyWidth - 18.0)
          : contentWidth;
      final maxHeroSlots = (heroAreaWidth / 380.0).floor().clamp(1, 4);
      final heroCount = !showHero || _windowsRecommendedVideos.isEmpty
          ? 0
          : _windowsRecommendedVideos.length <= 1
              ? 1
              : math.min(
                  maxHeroSlots,
                  math.max(1, _windowsRecommendedVideos.length - 1),
                );
      final heroVideos = _windowsRecommendedVideos.take(heroCount).toList();
      final gridVideos =
          heroCount > 0 && _windowsRecommendedVideos.length > heroCount
              ? _windowsRecommendedVideos.skip(heroCount).toList()
              : _windowsRecommendedVideos;
      return ListView(padding: EdgeInsets.fromLTRB(pad, 0, pad, 24), children: [
        if (showHero && heroVideos.isNotEmpty)
          SizedBox(
            key: const ValueKey('windows-home-hero-row'),
            height: heroHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < heroVideos.length; i++) ...[
                        if (i > 0) const SizedBox(width: 14),
                        Expanded(
                          child: _windowsHeroCard(
                            heroVideos[i],
                            index: i,
                            primary: i == 0,
                            compact: heroVideos.length >= 3 ||
                                heroAreaWidth / heroVideos.length < 430,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (sideHistory) ...[
                  const SizedBox(width: 18),
                  SizedBox(
                    width: historyWidth,
                    child: _windowsContinueWatching(
                      history,
                      fillHeight: true,
                    ),
                  ),
                ],
              ],
            ),
          ),
        if (history.isNotEmpty && !sideHistory) ...[
          if (showHero) const SizedBox(height: 18),
          _windowsContinueWatching(history),
        ],
        if (showHero || history.isNotEmpty) const SizedBox(height: 22),
        Row(children: [
          Expanded(
              child: Text('为你呈现',
                  style: TextStyle(
                      color: winInk(context),
                      fontSize: 20,
                      fontWeight: FontWeight.w600))),
          WinButton('浏览全部',
              icon: CupertinoIcons.chevron_right,
              onPressed: () => _windowsNavigate('discover')),
        ]),
        const SizedBox(height: 12),
        LayoutBuilder(builder: (context, grid) {
          final targetWidth = switch (widget.storage.gridDensity) {
            'comfortable' => 210.0,
            'compact' => 135.0,
            _ => 170.0,
          };
          final columns = (grid.maxWidth / targetWidth).floor().clamp(3, 12);
          return Wrap(spacing: 18, runSpacing: 20, children: [
            for (final video in gridVideos)
              SizedBox(
                  width: (grid.maxWidth - (columns - 1) * 18) / columns,
                  child: _windowsVideoCard(video, _activeSite!)),
          ]);
        }),
      ]);
    });
  }

  Widget _windowsContinueWatching(
    List<WatchHistoryEntry> history, {
    bool fillHeight = false,
  }) {
    Widget buildRow(WatchHistoryEntry entry) => Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _openSyncedMediaEntry(
              siteKey: entry.site,
              videoId: entry.id,
              title: entry.title,
              poster: _resolveHistoryPoster(entry),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 72,
                    height: 46,
                    child: LandscapePosterImage(
                      url: _resolveHistoryPoster(entry),
                      title: _privateSessionUnlocked ? '' : entry.title,
                      allowExternalLookup: !_privateSessionUnlocked,
                      placeholder: ColoredBox(
                        color: winMuted(context).withValues(alpha: .12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: winInk(context),
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        entry.episode,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: winMuted(context),
                          fontSize: 11,
                        ),
                      ),
                      if (entry.progressFraction > 0.01) ...[
                        const SizedBox(height: 5),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: entry.progressFraction,
                            minHeight: 2.5,
                            color: winAccent(context),
                            backgroundColor:
                                winMuted(context).withValues(alpha: .18),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  CupertinoIcons.play_circle,
                  size: 22,
                  color: winMuted(context),
                ),
              ]),
            ),
          ),
        );

    final items = [for (final entry in history) buildRow(entry)];
    return WinPanel(
      key: const ValueKey('windows-continue-watching-card'),
      padding: const EdgeInsets.fromLTRB(16, 10, 14, 12),
      radius: 22,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(
                '最近在看',
                style: TextStyle(
                  color: winInk(context),
                  fontSize: 15.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            WinButton(
              '记录',
              onPressed: () => _updateWindowsState(() {
                _windowsPage = 'library';
                _librarySegment = 1;
              }),
            ),
          ]),
          const SizedBox(height: 4),
          if (fillHeight)
            Expanded(
              child: Column(
                mainAxisAlignment: items.length >= 3
                    ? MainAxisAlignment.spaceEvenly
                    : MainAxisAlignment.start,
                children: items,
              ),
            )
          else
            ...items,
        ],
      ),
    );
  }

  Widget _windowsHomeError() => Center(
          child: WinPanel(
              child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_homeError ?? '加载失败', style: TextStyle(color: winInk(context))),
          const SizedBox(height: 16),
          Wrap(spacing: 10, children: [
            WinButton('重试', onPressed: _retryHomeError ?? _loadSiteHome),
            if (_activeSite != null &&
                CmsClient.needsSourceVerification(
                    _activeSite!, _homeErrorCause))
              SourceVerificationButton(
                  client: widget.client,
                  site: _activeSite!,
                  onVerified: _retryHomeError ?? _loadSiteHome),
            WinButton('切换片源', onPressed: _showSitePickerDialog),
          ]),
        ],
      )));

  Widget _windowsHeroCard(
    CmsVideo video, {
    required int index,
    required bool primary,
    required bool compact,
  }) {
    final subtitle = [video.year, video.area, video.remarks]
        .where((s) => s.isNotEmpty)
        .join(' · ');
    return ClipRRect(
      key: ValueKey('windows-hero-card-$index'),
      borderRadius: BorderRadius.circular(22),
      child: Material(
        color: const Color(0xFF141821),
        child: InkWell(
          onTap: () => _openVideoDetail(_activeSite!, video),
          child: Stack(
            fit: StackFit.expand,
            children: [
              LandscapePosterImage(
                url: video.poster,
                title: _privateSessionUnlocked ? '' : video.title,
                year: video.year,
                allowExternalLookup: !_privateSessionUnlocked,
                blurPortraitFallback: true,
                showRightFramedPortraitFallback: true,
                placeholder: const ColoredBox(color: Color(0xFF161C27)),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomLeft,
                    end: Alignment.topRight,
                    colors: [
                      Color(0xE80A0D12),
                      Color(0xA80D1118),
                      Color(0x180D1118),
                    ],
                    stops: [0.0, 0.52, 1.0],
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: .10),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.all(compact ? 18 : 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if ((_activeSite?.name ?? '').isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 3.5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .42),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: .14),
                          ),
                        ),
                        child: Text(
                          _activeSite!.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xD8FFFFFF),
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    const SizedBox(height: 10),
                    Text(
                      video.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: compact ? 21 : 26,
                        height: 1.2,
                        letterSpacing: -0.3,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xCCFFFFFF),
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: primary
                            ? Colors.white
                            : Colors.white.withValues(alpha: .18),
                        foregroundColor: primary
                            ? const Color(0xFF141B26)
                            : Colors.white,
                        padding: EdgeInsets.symmetric(
                          horizontal: compact ? 14 : 18,
                          vertical: compact ? 9 : 11,
                        ),
                        minimumSize: const Size(0, 36),
                      ),
                      onPressed: () => _openVideoDetail(_activeSite!, video),
                      icon: const Icon(CupertinoIcons.play_fill, size: 14),
                      label: Text(
                        primary ? '影片详情' : '查看详情',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
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

  Widget _windowsVideoCard(CmsVideo video, CmsSite site,
          {bool landscape = false}) =>
      InkWell(
        onTap: () => _openVideoDetail(site, video),
        borderRadius: BorderRadius.circular(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AspectRatio(
              aspectRatio: landscape ? 16 / 9 : 2 / 3,
              child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: PosterImage(
                      url: video.poster,
                      title: _privateSessionUnlocked ? '' : video.title,
                      year: video.year,
                      placeholder: ColoredBox(
                          color: Colors.white.withValues(alpha: .13),
                          child: Center(
                              child: Icon(CupertinoIcons.film,
                                  color: winMuted(context), size: 35)))))),
          const SizedBox(height: 13),
          Text(video.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: winInk(context),
                  fontWeight: FontWeight.w600,
                  fontSize: 15)),
          const SizedBox(height: 5),
          if (widget.storage.cardSubtitleMode != 'none')
            Text(
                switch (widget.storage.cardSubtitleMode) {
                  'site' => site.name,
                  'year_area' => [video.year, video.area, video.tag]
                      .where((s) => s.isNotEmpty)
                      .join(' · '),
                  _ => video.remarks.isEmpty ? site.name : video.remarks,
                },
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: winMuted(context), fontSize: 11)),
        ]),
      );

  Widget _windowsHistoryCard(WatchHistoryEntry entry) => InkWell(
      onTap: () => _openSyncedMediaEntry(
          siteKey: entry.site,
          videoId: entry.id,
          title: entry.title,
          poster: _resolveHistoryPoster(entry)),
      borderRadius: BorderRadius.circular(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Stack(fit: StackFit.expand, children: [
                  PosterImage(
                      url: _resolveHistoryPoster(entry),
                      title: entry.title,
                      placeholder: ColoredBox(
                          color: Colors.white.withValues(alpha: .12))),
                  const Positioned(
                      right: 14,
                      bottom: 14,
                      child: CircleAvatar(
                          radius: 16,
                          backgroundColor: Color(0xDDEDF3FA),
                          child: Icon(CupertinoIcons.play_fill,
                              size: 13, color: Color(0xFF2B455F))))
                ]))),
        const SizedBox(height: 12),
        Text(entry.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                TextStyle(color: winInk(context), fontWeight: FontWeight.w600)),
        const SizedBox(height: 5),
        Text(
            '${entry.episode} · 已看 ${Duration(milliseconds: entry.position).inMinutes} 分钟',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: winMuted(context), fontSize: 11)),
        const SizedBox(height: 10),
        ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
                value: entry.progressFraction,
                minHeight: 3,
                color: const Color(0xFF6484AC),
                backgroundColor: Colors.white24)),
      ]));

  static const double _windowsDiscoverAutoLoadThreshold = 420.0;

  bool get _canWindowsDiscoverAutoLoadMore =>
      _windowsPage == 'discover' &&
      _activeSite != null &&
      !_homeLoading &&
      !_loadingMore &&
      !_autoPagingScheduled &&
      _homeError == null &&
      _loadMoreError == null &&
      _currentPage < _pageCount;

  void _scheduleWindowsDiscoverAutoLoadMore() {
    if (!_canWindowsDiscoverAutoLoadMore) return;
    final expectedSiteKey = _activeSite?.key;
    final expectedHomeEpoch = _homeEpoch;
    final expectedCategoryEpoch = _categoryEpoch;
    final nextPage = _currentPage + 1;
    _autoPagingScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoPagingScheduled = false;
      if (!mounted ||
          !_canWindowsDiscoverAutoLoadMore ||
          _activeSite?.key != expectedSiteKey ||
          _homeEpoch != expectedHomeEpoch ||
          _categoryEpoch != expectedCategoryEpoch ||
          _currentPage + 1 != nextPage) {
        return;
      }
      unawaited(_reloadFilteredListing(page: nextPage));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _handleWindowsDiscoverScrollNotification(
    ScrollNotification notification,
  ) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical) {
      return false;
    }
    final scrollingDown = switch (notification) {
      ScrollUpdateNotification(:final scrollDelta) => (scrollDelta ?? 0) > 0,
      OverscrollNotification(:final overscroll) => overscroll > 0,
      _ => false,
    };
    if (scrollingDown &&
        notification.metrics.extentAfter < _windowsDiscoverAutoLoadThreshold) {
      _scheduleWindowsDiscoverAutoLoadMore();
    }
    return false;
  }

  void _handleWindowsDiscoverPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || event.scrollDelta.dy <= 0) return;
    if (!_windowsDiscoverScrollController.hasClients ||
        _windowsDiscoverScrollController.positions.length != 1) {
      return;
    }
    final pos = _windowsDiscoverScrollController.position;
    if (pos.extentAfter <= _windowsDiscoverAutoLoadThreshold) {
      _scheduleWindowsDiscoverAutoLoadMore();
    }
  }

  Widget _windowsDiscover(double pad) {
    final activeFilterCount = _currentFilter.activeDimensionCount +
        (_filterSubCategoryId.isNotEmpty ? 1 : 0);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerSignal: _handleWindowsDiscoverPointerSignal,
      child: NotificationListener<ScrollNotification>(
        onNotification: _handleWindowsDiscoverScrollNotification,
        child: CustomScrollView(
          key: const PageStorageKey('windows-discover-list'),
          controller: _windowsDiscoverScrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(pad, 8, pad, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _windowsHeading('发现', actions: [
                      Tooltip(
                          message: _activeSite?.name ?? '选择片源',
                          child: WinButton(_activeSite?.name ?? '选择片源',
                              onPressed: _showSitePickerDialog,
                              icon: CupertinoIcons.chevron_down)),
                      if ((_config?.depots ?? []).isNotEmpty)
                        WinButton('切换仓库', onPressed: _showDepotPickerDialog)
                    ]),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final item in [
                        ('recommend', '全部'),
                        ('movie', '电影'),
                        ('series', '剧集'),
                        ('variety', '综艺'),
                        ('anime', '动漫')
                      ])
                        WinButton(item.$2,
                            selected: _primaryTab == item.$1,
                            onPressed: () => _selectPrimaryTab(item.$1)),
                      WinButton(
                          activeFilterCount > 0
                              ? '筛选 · $activeFilterCount'
                              : '筛选',
                          selected: _filterExpanded || activeFilterCount > 0,
                          icon: CupertinoIcons.slider_horizontal_3,
                          onPressed: () => _updateWindowsState(
                              () => _filterExpanded = !_filterExpanded)),
                      WinButton('刷新',
                          icon: CupertinoIcons.refresh,
                          onPressed: _refreshCurrentHomeView)
                    ]),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topCenter,
                      child: _filterExpanded
                          ? Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: _windowsFilterPanel(),
                            )
                          : const SizedBox.shrink(),
                    ),
                    const SizedBox(height: 22),
                    if (_homeLoading)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: LinearProgressIndicator(
                                minHeight: 2.5,
                                color: winAccent(context),
                                backgroundColor:
                                    winMuted(context).withValues(alpha: .12),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              activeFilterCount > 0
                                  ? '正在按筛选条件加载影片…'
                                  : '正在加载片库…',
                              style: TextStyle(
                                  color: winMuted(context), fontSize: 12.5),
                            ),
                          ],
                        ),
                      ),
                    if (_homeError != null) _windowsHomeError(),
                  ],
                ),
              ),
            ),
            if (_activeSite != null && _homeVideos.isNotEmpty)
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: pad),
                sliver: SliverLayoutBuilder(builder: (_, constraints) {
                  final extent = switch (widget.storage.gridDensity) {
                    'compact' => 150.0,
                    'comfortable' => 245.0,
                    _ => 195.0
                  };
                  final count =
                      (constraints.crossAxisExtent / extent).floor().clamp(2, 9);
                  final cardWidth = math.max(
                    0.0,
                    (constraints.crossAxisExtent - (count - 1) * 23) / count,
                  );
                  final rowCount = (_homeVideos.length + count - 1) ~/ count;
                  return SliverIgnorePointer(
                    ignoring: _homeLoading,
                    sliver: SliverAnimatedOpacity(
                      duration: const Duration(milliseconds: 160),
                      opacity: _homeLoading ? 0.38 : 1.0,
                      sliver: SliverList.builder(
                        itemCount: rowCount,
                        itemBuilder: (_, rowIndex) {
                          final start = rowIndex * count;
                          final end =
                              math.min(start + count, _homeVideos.length);
                          return Padding(
                            padding: EdgeInsets.only(
                                bottom: rowIndex < rowCount - 1 ? 28 : 0),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (var i = start; i < end; i++) ...[
                                  if (i > start) const SizedBox(width: 23),
                                  SizedBox(
                                    width: cardWidth,
                                    child: _windowsVideoCard(
                                        _homeVideos[i], _activeSite!),
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  );
                }),
              ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(pad, 0, pad, 30),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!_homeLoading &&
                        _homeError == null &&
                        _homeVideos.isEmpty &&
                        _config != null)
                      _windowsEmpty(
                          '没有符合筛选条件的影片', '试试调整地区/年份组合，或切换其他分类片源。',
                          button: '清除筛选', action: () {
                        _updateWindowsState(() {
                          _primaryTab = 'recommend';
                          _filterSubCategoryId = '';
                          _filterGenreLabel = '';
                          _filterArea = '';
                          _filterYear = '';
                        });
                        _reloadFilteredListing(page: 1);
                      }),
                    if (_loadingMore)
                      Padding(
                        key: const ValueKey('windows-discover-loading-more'),
                        padding: const EdgeInsets.only(top: 24),
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: winAccent(context),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                '正在加载更多…',
                                style: TextStyle(
                                  color: winMuted(context),
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else if (_loadMoreError != null &&
                        _currentPage < _pageCount)
                      Padding(
                        key: const ValueKey('windows-discover-load-more-error'),
                        padding: const EdgeInsets.only(top: 20),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _loadMoreError!,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: winMuted(context),
                                  fontSize: 12.5,
                                ),
                              ),
                              const SizedBox(height: 10),
                              WinButton(
                                '重试加载更多',
                                icon: CupertinoIcons.refresh,
                                onPressed: () => _reloadFilteredListing(
                                  page: _currentPage + 1,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_config == null) _windowsWelcome(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _windowsFilterPanel() {
    final subCats = CmsParser.subCategoriesForPrimaryTab(
      _categories,
      _primaryTab,
    );
    final selectedSubCatName = subCats
        .where((c) => c.id == _filterSubCategoryId)
        .map((c) => c.name.trim())
        .firstOrNull;
    final activeLabels = <String>[
      if (selectedSubCatName != null && selectedSubCatName.isNotEmpty)
        selectedSubCatName,
      if (_filterGenreLabel.isNotEmpty) _filterGenreLabel,
      if (_filterArea.isNotEmpty) _filterArea,
      if (_filterYear.isNotEmpty) _filterYear,
    ];
    final hasAnyFilter = activeLabels.isNotEmpty;
    final accent = winAccent(context);
    final isDark = winDark(context);

    return WinPanel(
      key: const ValueKey('windows-filter-panel'),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      radius: 18,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                CupertinoIcons.slider_horizontal_3,
                color: accent,
                size: 15,
              ),
              const SizedBox(width: 8),
              Text(
                '片库筛选',
                style: TextStyle(
                  color: winInk(context),
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Expanded(
                child: activeLabels.isEmpty
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(left: 12, right: 12),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 3.5,
                            ),
                            decoration: BoxDecoration(
                              color: accent.withValues(
                                alpha: isDark ? 0.16 : 0.10,
                              ),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: accent.withValues(
                                  alpha: isDark ? 0.36 : 0.25,
                                ),
                              ),
                            ),
                            child: Text(
                              activeLabels.join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: accent,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
              if (hasAnyFilter) ...[
                TextButton(
                  key: const ValueKey('windows-filter-reset'),
                  onPressed: () {
                    _updateWindowsState(() {
                      _filterSubCategoryId = '';
                      _filterGenreLabel = '';
                      _filterArea = '';
                      _filterYear = '';
                    });
                    _reloadFilteredListing(page: 1);
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: accent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    minimumSize: const Size(0, 28),
                    shape: const StadiumBorder(),
                  ),
                  child: const Text(
                    '重置筛选',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 4),
              ],
              TextButton.icon(
                onPressed: () => _updateWindowsState(() {
                  _filterExpanded = false;
                }),
                style: TextButton.styleFrom(
                  foregroundColor: winMuted(context),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  minimumSize: const Size(0, 28),
                  shape: const StadiumBorder(),
                ),
                icon: const Icon(CupertinoIcons.chevron_up, size: 12.5),
                label: const Text('收起', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Divider(
              height: 1,
              color: winSurfaceBorder(context),
            ),
          ),
          if (subCats.isNotEmpty) ...[
            _windowsFilterDimensionRow(
              key: const ValueKey('windows-filter-row-category'),
              label: '分类',
              chips: [
                _windowsFilterChip(
                  label: '全部',
                  selected: _filterSubCategoryId.isEmpty,
                  onTap: () {
                    _updateWindowsState(() => _filterSubCategoryId = '');
                    _reloadFilteredListing(page: 1);
                  },
                ),
                for (final cat in subCats)
                  _windowsFilterChip(
                    label: cat.name,
                    selected: _filterSubCategoryId == cat.id,
                    onTap: () {
                      _updateWindowsState(() => _filterSubCategoryId = cat.id);
                      _reloadFilteredListing(page: 1);
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          _windowsFilterDimensionRow(
            key: const ValueKey('windows-filter-row-genre'),
            label: '类型',
            chips: [
              _windowsFilterChip(
                label: '全部',
                selected: _filterGenreLabel.isEmpty,
                onTap: () {
                  _updateWindowsState(() => _filterGenreLabel = '');
                  _reloadFilteredListing(page: 1);
                },
              ),
              for (final genre in CmsParser.fallbackGenreTags)
                _windowsFilterChip(
                  label: genre,
                  selected: _filterGenreLabel == genre,
                  onTap: () {
                    _updateWindowsState(() => _filterGenreLabel = genre);
                    _reloadFilteredListing(page: 1);
                  },
                ),
            ],
          ),
          const SizedBox(height: 12),
          _windowsFilterDimensionRow(
            key: const ValueKey('windows-filter-row-area'),
            label: '地区',
            chips: [
              for (final area in CmsParser.filterAreas)
                _windowsFilterChip(
                  label: area,
                  selected: (_filterArea.isEmpty && area == '全部') ||
                      _filterArea == area,
                  onTap: () {
                    _updateWindowsState(
                      () => _filterArea = area == '全部' ? '' : area,
                    );
                    _reloadFilteredListing(page: 1);
                  },
                ),
            ],
          ),
          const SizedBox(height: 12),
          _windowsFilterDimensionRow(
            key: const ValueKey('windows-filter-row-year'),
            label: '年份',
            chips: [
              for (final yr in CmsParser.filterYears)
                _windowsFilterChip(
                  label: yr,
                  selected: (_filterYear.isEmpty && yr == '全部') ||
                      _filterYear == yr,
                  onTap: () {
                    _updateWindowsState(
                      () => _filterYear = yr == '全部' ? '' : yr,
                    );
                    _reloadFilteredListing(page: 1);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _windowsFilterDimensionRow({
    Key? key,
    required String label,
    required List<Widget> chips,
  }) {
    return Row(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 52,
          height: 30,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              label,
              style: TextStyle(
                color: winMuted(context),
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        Expanded(
          child: Wrap(
            alignment: WrapAlignment.start,
            spacing: 8,
            runSpacing: 8,
            children: chips,
          ),
        ),
      ],
    );
  }

  Widget _windowsFilterChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final isDark = winDark(context);
    final accent = winAccent(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        hoverColor: selected
            ? accent.withValues(alpha: 0.92)
            : (isDark
                ? Colors.white.withValues(alpha: 0.09)
                : const Color(0x140F172A)),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          constraints: const BoxConstraints(minHeight: 30),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 5.5),
          decoration: BoxDecoration(
            color: selected
                ? accent
                : (isDark
                    ? Colors.white.withValues(alpha: 0.05)
                    : const Color(0x0A0F172A)),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? accent : winSurfaceBorder(context),
              width: 0.9,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : winInk(context),
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }

  Widget _windowsLibrary(double pad) {
    final segment =
        _privateSessionUnlocked && _librarySegment == 2 ? 0 : _librarySegment;
    final history =
        _privateSessionUnlocked ? <WatchHistoryEntry>[] : _cachedWatchHistory;
    final favorites =
        widget.storage.getFavorites(forPrivate: _privateSessionUnlocked);
    return Padding(
        padding: EdgeInsets.fromLTRB(pad, 8, pad, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _windowsHeading('我的', actions: [
            if (!_privateSessionUnlocked)
              WinButton('多端同步',
                  icon: CupertinoIcons.cloud, onPressed: _openCloudSyncCenter)
          ]),
          Wrap(spacing: 7, children: [
            for (final entry in [
              (1, '继续观看'),
              (0, '收藏'),
              if (!_privateSessionUnlocked) (2, '下载')
            ])
              WinButton(entry.$2,
                  selected: segment == entry.$1,
                  onPressed: () =>
                      _updateWindowsState(() => _librarySegment = entry.$1)),
            if (segment == 1 && history.isNotEmpty)
              WinButton('管理记录', onPressed: _showWatchHistorySheet),
            if (segment == 2 && DownloadService.instance.canOpenFolder)
              WinButton('打开文件夹',
                  onPressed: DownloadService.instance.openFolder),
          ]),
          const SizedBox(height: 26),
          Expanded(
              child: segment == 2
                  ? _windowsDownloads()
                  : LayoutBuilder(builder: (_, box) {
                      final count = (box.maxWidth / 330).floor().clamp(2, 5);
                      final cards = segment == 1
                          ? [
                              for (final item in history)
                                _windowsHistoryCard(item)
                            ]
                          : [
                              for (final f in favorites)
                                InkWell(
                                    onTap: () => _openSyncedMediaEntry(
                                        siteKey: f.site,
                                        videoId: f.id,
                                        title: f.title,
                                        poster: f.poster),
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          AspectRatio(
                                              aspectRatio: 16 / 9,
                                              child: ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(20),
                                                  child: PosterImage(
                                                      url: f.poster,
                                                      title:
                                                          _privateSessionUnlocked
                                                              ? ''
                                                              : f.title,
                                                      placeholder:
                                                          const SizedBox
                                                              .shrink()))),
                                          const SizedBox(height: 13),
                                          Text(f.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                  color: winInk(context),
                                                  fontWeight: FontWeight.w600)),
                                          Align(
                                              alignment: Alignment.centerRight,
                                              child: IconButton(
                                                  tooltip: '取消收藏',
                                                  icon: Icon(
                                                      CupertinoIcons.heart_fill,
                                                      color: winMuted(context),
                                                      size: 17),
                                                  onPressed: () async {
                                                    await widget.storage
                                                        .toggleFavorite(
                                                            CmsSite(
                                                                key: f.site,
                                                                name: '',
                                                                type: 0,
                                                                api: '',
                                                                isPrivate:
                                                                    _privateSessionUnlocked),
                                                            CmsVideo(
                                                                id: f.id,
                                                                title: f.title,
                                                                poster:
                                                                    f.poster));
                                                    if (mounted)
                                                      _updateWindowsState(
                                                          () {});
                                                  }))
                                        ]))
                            ];
                      if (cards.isEmpty)
                        return _windowsEmpty(
                            segment == 1 ? '还没有观看记录' : '收藏喜欢的影片',
                            '找到一部喜欢的影片，开始观看或加入收藏。',
                            action: () => _windowsNavigate('discover'),
                            button: '去发现');
                      return SingleChildScrollView(
                          child: Wrap(spacing: 24, runSpacing: 25, children: [
                        for (final card in cards)
                          SizedBox(
                              width: (box.maxWidth - (count - 1) * 24) / count,
                              child: card)
                      ]));
                    })),
        ]));
  }

  Widget _windowsDownloads() => AnimatedBuilder(
      animation: DownloadService.instance,
      builder: (context, _) {
        final service = DownloadService.instance;
        if (!service.isReady)
          return _windowsEmpty('下载暂时不可用', '无法打开下载目录，请检查磁盘权限后重新启动应用。');
        if (service.tasks.isEmpty)
          return _windowsEmpty('还没有下载任务', '在影片详情中选择下载，完成后就可以离线观看。');
        final active = service.activeCount;
        final hasPaused =
            service.tasks.any((t) => t.status == DownloadStatus.paused);
        return Column(children: [
          if (active > 0 || hasPaused)
            Row(children: [
              Expanded(
                  child: Text(active > 0 ? '$active 个任务进行中' : '下载已暂停',
                      style: TextStyle(color: winMuted(context)))),
              WinButton(active > 0 ? '全部暂停' : '全部继续',
                  onPressed: active > 0 ? service.pauseAll : service.resumeAll),
            ]),
          Expanded(
              child: ListView.separated(
                  itemCount: service.tasks.length,
                  separatorBuilder: (_, __) => Divider(
                      color: winMuted(context).withValues(alpha: .13),
                      height: 32),
                  itemBuilder: (context, i) {
                    final t = service.tasks[i];
                    final done = t.status == DownloadStatus.completed;
                    final resume = t.status == DownloadStatus.paused ||
                        t.status == DownloadStatus.failed;
                    return Row(children: [
                      ClipRRect(
                          borderRadius: BorderRadius.circular(15),
                          child: SizedBox(
                              width: 140,
                              height: 85,
                              child: PosterImage(
                                  url: t.poster,
                                  title: t.title,
                                  placeholder: const SizedBox.shrink()))),
                      const SizedBox(width: 24),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(t.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: winInk(context),
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 7),
                            Text(
                                '${t.episodeName} · ${DownloadService.statusLabel(t)}',
                                style: TextStyle(
                                    color: winMuted(context), fontSize: 12)),
                            const SizedBox(height: 16),
                            LinearProgressIndicator(
                                value: t.progress.clamp(0, 1), minHeight: 3)
                          ])),
                      const SizedBox(width: 20),
                      WinButton(
                          done
                              ? '播放'
                              : resume
                                  ? '继续'
                                  : '暂停',
                          onPressed: done
                              ? () => _playDownloaded(t)
                              : resume
                                  ? () => service.resume(t.id)
                                  : () => service.pause(t.id)),
                      IconButton(
                          tooltip: '删除下载',
                          onPressed: () => _confirmDeleteDownload(t),
                          icon: Icon(CupertinoIcons.trash,
                              size: 18, color: winMuted(context)))
                    ]);
                  })),
          if (service.rootPath.isNotEmpty)
            Text('保存位置：${service.rootPath}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: winMuted(context))),
        ]);
      });

  void _windowsPlayChannel(LiveChannel channel, [int line = 0]) {
    if (channel.urls.isEmpty) return;
    _updateWindowsState(() {
      _windowsLiveChannel = channel;
      _windowsLiveLine = line;
      _windowsLiveRevision++;
    });
  }

  Widget _windowsLive(double pad) {
    final sources = _visibleLives;
    if (sources.isEmpty)
      return _windowsEmpty('添加你的直播频道', '支持独立导入 M3U / TXT 直播源，自动归类、测速并匹配台标。',
          action: () => _showStandaloneLiveImportSheet());
    final displayGroups = _displayLiveGroups;
    final query = _liveSearchQuery.trim().toLowerCase();
    final channels = <LiveChannel>[
      for (var i = 0; i < displayGroups.length; i++)
        if (query.isNotEmpty ||
            _selectedLiveGroup < 0 ||
            i == _selectedLiveGroup)
          for (final channel in displayGroups[i].channels)
            if (query.isEmpty ||
                channel.name.toLowerCase().contains(query) ||
                displayGroups[i].name.toLowerCase().contains(query))
              channel,
    ];
    final selected = _windowsLiveChannel;
    final player = ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: ColoredBox(
            color: const Color(0xFF172638),
            child: selected == null
                ? const Center(
                    child: Text('选择右侧频道，开始观看',
                        style: TextStyle(color: Colors.white70)))
                : LayoutBuilder(
                    builder: (context, box) => MediaQuery(
                        data: MediaQuery.of(context).copyWith(
                            size: box.biggest, padding: EdgeInsets.zero),
                        child: PlayerScreen(
                            key: ValueKey('live-$_windowsLiveRevision'),
                            site: sources[_selectedLiveSource.clamp(
                                    0, sources.length - 1)]
                                .playbackSite,
                            video: CmsVideo(
                                id: selected.name,
                                title: selected.name,
                                lines: [
                                  CmsLine(
                                      name: selected.group,
                                      episodes: selected.episodes)
                                ]),
                            initialLineIndex: 0,
                            initialEpisodeIndex: _windowsLiveLine,
                            storage: widget.storage,
                            isLive: true,
                            liveGroups: displayGroups,
                            initialLiveChannel: selected,
                            embedded: true,
                            onEmbeddedClose: () => _updateWindowsState(
                                () => _windowsLiveChannel = null),
                            onEmbeddedExpand: () {
                              _updateWindowsState(
                                  () => _windowsLiveChannel = null);
                              _openLiveChannelStream(
                                  sources, selected, _windowsLiveLine);
                            })))));
    final list = WinPanel(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          TextField(
              controller: _liveSearchController,
              style: TextStyle(color: winInk(context)),
              decoration: const InputDecoration(
                  hintText: '搜索全部频道', prefixIcon: Icon(CupertinoIcons.search)),
              onChanged: (v) {
                if (_liveSearchController.value.isComposingRangeValid) return;
                _updateWindowsState(() => _liveSearchQuery = v);
              },
              onSubmitted: (v) =>
                  _updateWindowsState(() => _liveSearchQuery = v)),
          const SizedBox(height: 12),
          if (_liveLoading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
              child: channels.isEmpty
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_liveError ?? (_liveLoading ? '正在加载频道…' : '没有匹配频道'),
                          style: TextStyle(color: winMuted(context))),
                      WinButton(_liveError == null ? '清除搜索' : '重新加载',
                          onPressed: () {
                        if (_liveError != null) {
                          _loadLivePlaylist(_selectedLiveSource);
                        } else {
                          _updateWindowsState(() {
                            _liveSearchController.clear();
                            _liveSearchQuery = '';
                            _selectedLiveGroup = -1;
                          });
                        }
                      }),
                    ]))
                  : ListView.builder(
                      key: const PageStorageKey('windows-live-channels'),
                      itemCount: channels.length,
                      itemBuilder: (_, i) {
                        final ch = channels[i];
                        final speedBadge = LiveHealthVisual.badgeText(ch);
                        return ListTile(
                            selected: ch == selected,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                            leading: LiveStationBadge(
                              channel: ch,
                              size: 36,
                              radius: 9,
                            ),
                            title: Text(ch.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: winInk(context))),
                            subtitle: Text(
                                '${ch.group} · ${ch.urls.length} 条线路${speedBadge != null ? ' · $speedBadge' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: winMuted(context))),
                            onTap: () => _windowsPlayChannel(ch),
                            trailing: ch.urls.length <= 1
                                ? null
                                : PopupMenuButton<int>(
                                    tooltip: '选择线路',
                                    onSelected: (line) =>
                                        _windowsPlayChannel(ch, line),
                                    itemBuilder: (_) => [
                                          for (var line = 0;
                                              line < ch.urls.length;
                                              line++)
                                            PopupMenuItem(
                                                value: line,
                                                child: Text(
                                                  line < ch.episodes.length &&
                                                          ch.episodes[line].name
                                                              .isNotEmpty
                                                      ? ch.episodes[line].name
                                                      : '线路 ${line + 1}',
                                                ))
                                        ]));
                      })),
        ]));
    return Padding(
        padding: EdgeInsets.fromLTRB(pad, 8, pad, 20),
        child: Column(children: [
          _windowsHeading('直播', actions: [
            WinButton('独立导入', onPressed: () => _showStandaloneLiveImportSheet()),
            if (_liveGroups.isNotEmpty)
              WinButton(_liveProbing ? '停止测速' : '测速归类',
                  selected: _liveProbing,
                  onPressed: _probeCurrentLiveGroups),
            WinButton('管理来源', onPressed: _showLiveSourceManagerSheet),
          ]),
          SizedBox(
              height: 48,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (int i = 0; i < sources.length; i++)
                  SizedBox(
                      width: 180,
                      child: WinButton(sources[i].name,
                          selected: i == _selectedLiveSource,
                          onPressed: () => _loadLivePlaylist(i))),
              ])),
          SizedBox(
              height: 48,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                WinButton('全部',
                    selected: _selectedLiveGroup < 0,
                    onPressed: () =>
                        _updateWindowsState(() => _selectedLiveGroup = -1)),
                for (int i = 0; i < displayGroups.length; i++)
                  WinButton('${displayGroups[i].name} (${displayGroups[i].channels.length})',
                      selected: _selectedLiveGroup == i,
                      onPressed: () =>
                          _updateWindowsState(() => _selectedLiveGroup = i)),
              ])),
          const SizedBox(height: 14),
          Expanded(
              child: LayoutBuilder(
                  builder: (_, box) => box.maxWidth >= 900
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                              Expanded(child: player),
                              const SizedBox(width: 22),
                              SizedBox(width: 300, child: list)
                            ])
                      : SingleChildScrollView(
                          child: Column(children: [
                          SizedBox(
                              height: (box.maxWidth * 9 / 16).clamp(180, 340),
                              child: player),
                          const SizedBox(height: 12),
                          SizedBox(height: 360, child: list)
                        ])))),
        ]));
  }

  Widget _windowsSettingsPage(double pad) {
    const tabs = ['背景与外观', '首页与排版', '播放', '内容来源', '账号', '同步与备份', '更多设置'];
    return Padding(
        padding: EdgeInsets.fromLTRB(pad, 8, pad, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _windowsHeading('设置', actions: [
            WinButton('检查更新',
                icon: CupertinoIcons.arrow_down_circle,
                onPressed: _showUpdateCheckSheet)
          ]),
          Expanded(
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
                width: 160,
                child: ListView(children: [
                  for (final label in tabs)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: WinButton(label,
                            selected: label == _windowsSettings,
                            onPressed: () => _updateWindowsState(
                                () => _windowsSettings = label)))
                ])),
            const SizedBox(width: 30),
            Expanded(
                child: SingleChildScrollView(child: WindowsSettingsRegion(child: _windowsSettingsContent()))),
          ])),
        ]));
  }

  Widget _windowsSettingsContent() {
    if (_windowsSettings == '背景与外观') return const WindowsAppearanceSettings();
    if (_windowsSettings == '首页与排版')
      return _buildLayoutSettingsSection(
          context, () => _updateWindowsState(() {}));
    if (_windowsSettings == '播放')
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _WindowsPlaybackEnhancementGroup(
          storage: widget.storage,
          onChanged: () => _updateWindowsState(() {}),
        ),
        const SizedBox(height: 22),
        _buildPlaybackSettingsSection(
            context, () => _updateWindowsState(() {})),
      ]);
    if (_windowsSettings == '更多设置')
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        WinSettingsGroup(
          header: '窗口与系统托盘',
          footer: '选择点击右上角关闭按钮时的默认行为。最小化到系统托盘后，可在 Windows 任务栏右下角单击图标恢复窗口或右键退出程序。',
          children: [
            WinSettingsRow(
              key: const ValueKey('windows-close-action-tray'),
              title: '关闭按钮默认隐藏到右下角任务栏',
              subtitle: '点击关闭按钮时快速隐藏到系统托盘并暂停播放，避免后台重新启动等待',
              icon: CupertinoIcons.tray_arrow_down,
              trailing: Icon(
                widget.storage.windowsCloseAction == 'tray'
                    ? CupertinoIcons.checkmark_circle_fill
                    : CupertinoIcons.circle,
                size: 20,
                color: widget.storage.windowsCloseAction == 'tray'
                    ? winAccent(context)
                    : winMuted(context),
              ),
              onTap: () async {
                await widget.storage.setWindowsCloseAction('tray');
                if (mounted) _updateWindowsState(() {});
              },
            ),
            WinSettingsRow(
              key: const ValueKey('windows-close-action-exit'),
              title: '点击关闭按钮直接退出应用',
              subtitle: '立即隐藏窗口并在后台快速完成收尾，直接关闭程序不驻留托盘',
              icon: CupertinoIcons.power,
              trailing: Icon(
                widget.storage.windowsCloseAction != 'tray'
                    ? CupertinoIcons.checkmark_circle_fill
                    : CupertinoIcons.circle,
                size: 20,
                color: widget.storage.windowsCloseAction != 'tray'
                    ? winAccent(context)
                    : winMuted(context),
              ),
              onTap: () async {
                await widget.storage.setWindowsCloseAction('exit');
                if (mounted) _updateWindowsState(() {});
              },
            ),
          ],
        ),
        const SizedBox(height: 22),
        _buildAppearanceSettingsSection(
            context, () => _updateWindowsState(() {})),
        const SizedBox(height: 22),
        _buildCloudAndDataSettingsSection(
            context, () => _updateWindowsState(() {})),
        const SizedBox(height: 22),
        _WindowsMediaCacheAndRuntimeSection(
          storage: widget.storage,
          onChanged: () => _updateWindowsState(() {}),
        ),
        const SizedBox(height: 22),
        WinSettingsGroup(header: '版本与诊断', children: [
          WinSettingsRow(
              title: '软件更新与版本',
              value: 'v$_currentAppVersion',
              icon: CupertinoIcons.arrow_down_circle,
              onTap: _showUpdateCheckSheet),
          WinSettingsRow(
              title: '导出诊断日志包',
              subtitle: '导出脱敏环境信息与最近的运行日志',
              icon: CupertinoIcons.doc_plaintext,
              onTap: () => _exportDiagnosticsBundle(context)),
          if (!OhosRuntime.isOhos)
            WinSettingsRow(
                title: '重新查看新手引导',
                subtitle: '回顾配置导入、多端同步与桌面快捷键指南',
                icon: CupertinoIcons.sparkles,
                onTap: () => _openOnboardingRoute(isReplay: true)),
        ]),
      ]);
    if (_windowsSettings == '内容来源')
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _windowsHeading('内容来源'),
        _windowsSettingRow(
            '订阅管理', '导入、切换、排序与移除订阅', _showSubscriptionManagerSheet),
        _windowsSettingRow('片源管理', '管理各个来源的启用状态与显示顺序', _showSitePickerDialog),
        _windowsSettingRow('仓库管理', '切换多仓配置', _showDepotPickerDialog),
        _windowsSettingRow('添加来源', '粘贴地址或导入配置文件', _showImportConfigDialog),
      ]);
    if (_windowsSettings == '账号')
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _windowsHeading('账号'),
        for (final drive in NetdiskService.drives)
          _windowsSettingRow(
              drive.providerName,
              widget.storage.isNetdiskLoggedIn(drive.key) ? '已连接' : '尚未连接',
              () => showNetdiskAccountSheet(context, widget.storage,
                      initialDriveKey: drive.key, onChanged: () {
                    if (mounted) _updateWindowsState(() {});
                  })),
      ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _windowsHeading('同步与备份'),
      _windowsSettingRow('多端网络同步', '同步收藏、观看进度与内容来源', _openCloudSyncCenter),
      _windowsSettingRow('导出与恢复备份', '保存或恢复应用配置', _showBackupRestoreDialog),
      _windowsSettingRow('隐私空间', '访问独立的私密收藏和内容来源', _openPrivateSpaceWithAuth),
    ]);
  }

  Widget _windowsSettingRow(
          String title, String description, VoidCallback action) =>
      Padding(
          padding: const EdgeInsets.only(bottom: 15),
          child: WinPanel(
              child: Row(children: [
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(title,
                      style: TextStyle(
                          color: winInk(context),
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 7),
                  Text(description,
                      style: TextStyle(color: winMuted(context), fontSize: 12))
                ])),
            WinButton('打开',
                icon: CupertinoIcons.chevron_right, onPressed: action)
          ])));

  Widget _windowsWelcome() =>
      _windowsEmpty('从一部影片开始。', '添加内容来源，搜索想看的影片。你的收藏与观看记录会保存在这里。',
          action: _showImportConfigDialog);
  Widget _windowsSearch(double pad) {
    final entries = <String, CmsSite>{
      for (final site in _visibleSupportedSites)
        '${site.subscriptionId}:${site.key}': site,
      for (final row in _searchResults)
        '${row.$1.subscriptionId}:${row.$1.key}': row.$1,
    };
    final results = _searchResults
        .where((r) =>
            _searchSiteFilterKey.isEmpty ||
            '${r.$1.subscriptionId}:${r.$1.key}' == _searchSiteFilterKey)
        .toList();
    final history =
        widget.storage.getSearchHistory(forPrivate: _privateSessionUnlocked);
    final isGridLayout = widget.storage.windowsSearchLayout != 'list';
    final isDark = winDark(context);
    return Padding(
        padding: EdgeInsets.fromLTRB(pad, 8, pad, 20),
        child: Column(children: [
          _windowsHeading(_privateSessionUnlocked ? '隐私空间搜索' : '搜索', actions: [
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: .06)
                    : const Color(0x0D0F172A),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: winSurfaceBorder(context)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _windowsSearchLayoutToggleButton(
                    key: const ValueKey('win-search-view-grid'),
                    icon: CupertinoIcons.square_grid_2x2,
                    label: '海报',
                    selected: isGridLayout,
                    onTap: () async {
                      if (isGridLayout) return;
                      await widget.storage.setWindowsSearchLayout('grid');
                      if (mounted) _updateWindowsState(() {});
                    },
                  ),
                  const SizedBox(width: 2),
                  _windowsSearchLayoutToggleButton(
                    key: const ValueKey('win-search-view-list'),
                    icon: CupertinoIcons.list_bullet,
                    label: '列表',
                    selected: !isGridLayout,
                    onTap: () async {
                      if (!isGridLayout) return;
                      await widget.storage.setWindowsSearchLayout('list');
                      if (mounted) _updateWindowsState(() {});
                    },
                  ),
                ],
              ),
            ),
            WinButton('清空历史', onPressed: () async {
              await widget.storage
                  .clearSearchHistory(forPrivate: _privateSessionUnlocked);
              if (mounted) _updateWindowsState(() {});
            }),
          ]),
          WinPanel(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(children: [
                Expanded(
                    child: TextField(
                        key: const ValueKey('windows-search-input'),
                        controller: _searchController,
                        autofocus: true,
                        textInputAction: TextInputAction.search,
                        style: TextStyle(color: winInk(context)),
                        decoration: const InputDecoration(
                            hintText: '搜索影片、剧集',
                            prefixIcon: Icon(CupertinoIcons.search),
                            border: InputBorder.none),
                        onSubmitted: (kw) {
                          if (_searchController.value.isComposingRangeValid) {
                            return;
                          }
                          _runGlobalSearch(kw);
                        })),
                WinButton('搜索',
                    selected: true,
                    onPressed: () => _runGlobalSearch(_searchController.text)),
              ])),
          const SizedBox(height: 14),
          if (!_searchPerformed && history.isNotEmpty)
            Align(
                alignment: Alignment.centerLeft,
                child: Wrap(spacing: 8, children: [
                  for (final word in history)
                    WinButton(word, onPressed: () {
                      _searchController.text = word;
                      _runGlobalSearch(word);
                    })
                ])),
          SizedBox(
              height: 48,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                WinButton('全部片源',
                    selected: _searchSiteFilterKey.isEmpty,
                    onPressed: () =>
                        _updateWindowsState(() => _searchSiteFilterKey = '')),
                for (final entry in entries.entries)
                  SizedBox(
                      width: 170,
                      child: Tooltip(
                          message: entry.value.name,
                          child: WinButton(entry.value.name,
                              selected: entry.key == _searchSiteFilterKey,
                              onPressed: () => _updateWindowsState(
                                  () => _searchSiteFilterKey = entry.key)))),
              ])),
          if (_searching) const LinearProgressIndicator(minHeight: 2),
          if (_searchNotices.isNotEmpty)
            ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: SingleChildScrollView(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      for (final entry in _searchNotices.entries)
                        Row(children: [
                          Expanded(
                              child: Text(entry.value,
                                  style: TextStyle(color: winMuted(context)))),
                          if (_searchVerificationSites[entry.key]
                              case final site?)
                            SourceVerificationButton(
                                client: widget.client,
                                site: site,
                                onVerified: () => _retryVerifiedSearch(site)),
                        ]),
                    ]))),
          const SizedBox(height: 16),
          Expanded(
              child: results.isEmpty
                  ? Center(
                      child: Text(
                          _searching
                              ? '正在搜索已启用的片源…'
                              : !_searchPerformed
                                  ? '输入片名，开始查找想看的内容。'
                                  : '没有匹配影片，试试其他关键词或片源。',
                          style: TextStyle(color: winMuted(context))))
                  : LayoutBuilder(
                      builder: (context, box) => isGridLayout
                          ? _windowsSearchPosterGrid(results, box.maxWidth)
                          : _windowsSearchAdaptiveList(results, box.maxWidth),
                    )),
        ]));
  }

  Widget _windowsSearchLayoutToggleButton({
    Key? key,
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final accent = winAccent(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6.5),
          decoration: BoxDecoration(
            color: selected ? accent : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 13.5,
                color: selected ? Colors.white : winMuted(context),
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.white : winInk(context),
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _windowsSearchPosterGrid(
    List<(CmsSite, CmsVideo)> results,
    double maxWidth,
  ) {
    final densityScale = switch (widget.storage.gridDensity) {
      'compact' => 0.84,
      'comfortable' => 1.18,
      _ => 1.0,
    };
    final baseTarget = maxWidth >= 1600
        ? 196.0
        : (maxWidth >= 1100 ? 180.0 : 156.0);
    final targetExtent = (baseTarget * densityScale).clamp(132.0, 260.0);
    final gap = maxWidth >= 1100 ? 20.0 : 14.0;
    final columns = ((maxWidth + gap) / (targetExtent + gap)).floor().clamp(2, 9);
    final cardWidth = (maxWidth - (columns - 1) * gap) / columns;
    final posterHeight = cardWidth * 1.46;
    final footerHeight = maxWidth >= 1000 ? 58.0 : 54.0;

    return KeyedSubtree(
      key: const ValueKey('windows-search-grid-view'),
      child: GridView.builder(
        key: const PageStorageKey('windows-search-results'),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: gap,
          mainAxisSpacing: 20,
          mainAxisExtent: posterHeight + footerHeight,
        ),
        itemCount: results.length,
        itemBuilder: (context, i) {
        final (site, video) = results[i];
        final meta = [video.year, video.remarks]
            .where((s) => s.trim().isNotEmpty)
            .join(' · ');
        return Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey(
              'windows-search-${site.subscriptionId}-${site.key}-${video.id}',
            ),
            onTap: () => _openVideoDetail(site, video),
            borderRadius: BorderRadius.circular(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: posterHeight,
                  width: double.infinity,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        PosterImage(
                          url: video.poster,
                          title: site.isEffectivelyPrivate ? '' : video.title,
                          year: video.year,
                          placeholder: const ColoredBox(
                            color: Color(0xFF1A202C),
                            child: Center(
                              child: Icon(
                                CupertinoIcons.film,
                                color: Color(0x44FFFFFF),
                                size: 30,
                              ),
                            ),
                          ),
                        ),
                        // Top-left source badge pill
                        Positioned(
                          top: 8,
                          left: 8,
                          right: 8,
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7.5,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xB80B0F17),
                                borderRadius: BorderRadius.circular(7),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.14),
                                  width: 0.6,
                                ),
                              ),
                              child: Text(
                                site.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 9),
                Text(
                  video.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: winInk(context),
                    fontSize: maxWidth >= 1000 ? 14 : 13,
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  meta.isNotEmpty ? meta : site.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: winMuted(context),
                    fontSize: 11.5,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
        );
      },
      ),
    );
  }

  Widget _windowsSearchAdaptiveList(
    List<(CmsSite, CmsVideo)> results,
    double maxWidth,
  ) {
    final twoColumns = maxWidth >= 1360;
    final compact = maxWidth < 780;
    final thumbWidth = compact ? 124.0 : (twoColumns ? 168.0 : 186.0);
    final thumbHeight = compact ? 74.0 : (twoColumns ? 96.0 : 106.0);
    final titleSize = compact ? 15.0 : (twoColumns ? 16.5 : 18.0);

    Widget buildRow(CmsSite site, CmsVideo video) {
      return WinPanel(
        padding: EdgeInsets.zero,
        radius: 18,
        child: InkWell(
          key: ValueKey(
            'windows-search-${site.subscriptionId}-${site.key}-${video.id}',
          ),
          onTap: () => _openVideoDetail(site, video),
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: EdgeInsets.all(compact ? 10 : 13),
            child: Row(
              children: [
                SizedBox(
                  width: thumbWidth,
                  height: thumbHeight,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: LandscapePosterImage(
                      url: video.poster,
                      title: site.isEffectivelyPrivate ? '' : video.title,
                      year: video.year,
                      allowExternalLookup: !site.isEffectivelyPrivate,
                      placeholder: const ColoredBox(color: Color(0x30273548)),
                    ),
                  ),
                ),
                SizedBox(width: compact ? 14 : 18),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: winInk(context),
                          fontSize: titleSize,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        [video.year, video.remarks, site.name]
                            .where((v) => v.isNotEmpty)
                            .join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: winMuted(context),
                          fontSize: compact ? 12 : 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  CupertinoIcons.chevron_right,
                  color: winMuted(context),
                  size: 16,
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (twoColumns) {
      return KeyedSubtree(
        key: const ValueKey('windows-search-list-view'),
        child: GridView.builder(
          key: const PageStorageKey('windows-search-results'),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 16,
            mainAxisSpacing: 14,
            mainAxisExtent: thumbHeight + 28,
          ),
          itemCount: results.length,
          itemBuilder: (_, i) => buildRow(results[i].$1, results[i].$2),
        ),
      );
    }
    return KeyedSubtree(
      key: const ValueKey('windows-search-list-view'),
      child: ListView.separated(
        key: const PageStorageKey('windows-search-results'),
        itemCount: results.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (_, i) => buildRow(results[i].$1, results[i].$2),
      ),
    );
  }
}

class _WindowsPlaybackEnhancementGroup extends StatefulWidget {
  final StorageService storage;
  final VoidCallback onChanged;

  const _WindowsPlaybackEnhancementGroup({
    required this.storage,
    required this.onChanged,
  });

  @override
  State<_WindowsPlaybackEnhancementGroup> createState() =>
      _WindowsPlaybackEnhancementGroupState();
}

class _WindowsPlaybackEnhancementGroupState
    extends State<_WindowsPlaybackEnhancementGroup> {
  final WindowsVideoQualityController _qualityController =
      WindowsVideoQualityController();
  late WindowsPlaybackEngine _windowsEngine;
  WindowsQualityPreset _qualityPreset = WindowsQualityPreset.balancedHq;
  AudioLoudnessPreset _loudnessPreset = AudioLoudnessPreset.off;

  @override
  void initState() {
    super.initState();
    _windowsEngine = WindowsPlaybackEngine.fromId(
      widget.storage.windowsPlaybackEngine,
    );
    unawaited(_loadPresets());
  }

  Future<void> _loadPresets() async {
    final quality = await WindowsVideoQualityController.readSavedQualityPreset();
    final loudness =
        await WindowsVideoQualityController.readSavedLoudnessPreset();
    if (!mounted) return;
    setState(() {
      _qualityPreset = quality;
      _loudnessPreset = loudness;
    });
  }

  @override
  void dispose() {
    _qualityController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMdk = _windowsEngine == WindowsPlaybackEngine.mdk;
    return WinSettingsGroup(
      header: 'Windows 播放引擎、画质与流媒体净化',
      footer: isMdk
          ? '当前已选用 MDK 核显兼容引擎：采用原生 D3D11 / MFT / DXVA 零拷贝硬解，显著降低 Intel / AMD 核显占用并提升 4K/HDR 流畅度；播放页右下角「更多」可随时热切引擎。'
          : '高画质 HDR 映射档与人声响度增强适用于 MPV 引擎（核显轻薄本推荐切换为 MDK 核显兼容引擎）；切换后下次起播生效，播放中亦可在右下角实时热切。',
      children: [
        Padding(
          key: const ValueKey('windows-settings-playback-engine'),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(CupertinoIcons.desktopcomputer,
                      size: 20, color: winMuted(context)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Windows 播放引擎',
                          style: TextStyle(
                            color: winInk(context),
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _windowsEngine.descriptionZh,
                          style: TextStyle(
                            color: winMuted(context),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final engine in const <WindowsPlaybackEngine>[
                    WindowsPlaybackEngine.mdk,
                    WindowsPlaybackEngine.mpv,
                  ])
                    WinButton(
                      engine.labelZh,
                      key: ValueKey('win-setting-engine-${engine.id}'),
                      selected: _windowsEngine == engine,
                      onPressed: () async {
                        setState(() => _windowsEngine = engine);
                        await widget.storage.setWindowsPlaybackEngine(
                          engine.id,
                        );
                        widget.onChanged();
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
        Padding(
          key: const ValueKey('windows-settings-video-quality'),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(CupertinoIcons.sparkles,
                      size: 20, color: winMuted(context)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Windows 渲染画质预设',
                          style: TextStyle(
                            color: winInk(context),
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _qualityPreset.descriptionZh,
                          style: TextStyle(
                            color: winMuted(context),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final preset in WindowsQualityPreset.values)
                    WinButton(
                      preset == WindowsQualityPreset.balancedHq
                          ? '${preset.labelZh}（推荐）'
                          : preset.labelZh,
                      key: ValueKey('win-setting-quality-${preset.id}'),
                      selected: _qualityPreset == preset,
                      onPressed: () async {
                        setState(() => _qualityPreset = preset);
                        await _qualityController.saveQualityPreset(preset);
                        widget.onChanged();
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
        Padding(
          key: const ValueKey('windows-settings-audio-loudness'),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(CupertinoIcons.waveform,
                      size: 20, color: winMuted(context)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '音频响度与人声对白增强',
                          style: TextStyle(
                            color: winInk(context),
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _loudnessPreset.descriptionZh,
                          style: TextStyle(
                            color: winMuted(context),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final preset in AudioLoudnessPreset.values)
                    WinButton(
                      preset.labelZh,
                      key: ValueKey('win-setting-loudness-${preset.id}'),
                      selected: _loudnessPreset == preset,
                      onPressed: () async {
                        setState(() => _loudnessPreset = preset);
                        await _qualityController.saveLoudnessPreset(preset);
                        widget.onChanged();
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
        WinSettingsRow(
          key: const ValueKey('windows-settings-hls-ad-strip'),
          title: 'HLS 点播切片去广告',
          subtitle: '自动识别点播 M3U8 中插入的异域断层短插播广告并剥离（直播流不触发）',
          icon: CupertinoIcons.shield_lefthalf_fill,
          trailing: CupertinoSwitch(
            value: widget.storage.hlsAdStripEnabled,
            activeTrackColor: AppleColors.systemGreen,
            onChanged: (v) async {
              await widget.storage.setHlsAdStripEnabled(v);
              LocalMediaLease.defaultHlsAdStripEnabled = v;
              widget.onChanged();
            },
          ),
        ),
      ],
    );
  }
}

class _WindowsMediaCacheAndRuntimeSection extends StatefulWidget {
  final StorageService storage;
  final VoidCallback onChanged;

  const _WindowsMediaCacheAndRuntimeSection({
    required this.storage,
    required this.onChanged,
  });

  @override
  State<_WindowsMediaCacheAndRuntimeSection> createState() =>
      _WindowsMediaCacheAndRuntimeSectionState();
}

class _WindowsMediaCacheAndRuntimeSectionState
    extends State<_WindowsMediaCacheAndRuntimeSection> {
  int _cacheBytes = 0;
  bool _clearingCache = false;
  late PythonRuntimeStatus _pythonStatus;
  Map<String, dynamic>? _webview2Status;

  @override
  void initState() {
    super.initState();
    _pythonStatus = PythonSourceHost.desktopRuntimeStatus();
    unawaited(_refreshStatus());
  }

  Future<void> _refreshStatus() async {
    final pyStatus = PythonSourceHost.desktopRuntimeStatus();
    if (mounted) {
      setState(() => _pythonStatus = pyStatus);
    }
    final webviewFuture = DesktopWebViewJsBridge.instance.getStatus().then((wv) {
      if (!mounted) return;
      setState(() => _webview2Status = wv);
    });
    final bytesFuture = DiskBlockCache.instance.currentCacheBytes().then((b) {
      if (!mounted) return;
      setState(() => _cacheBytes = b);
    });
    await Future.wait<void>([webviewFuture, bytesFuture]);
  }

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String _cacheOptionLabel(int mb) {
    if (mb <= 0) return '关闭';
    if (mb == StorageService.defaultDiskCacheMaxMb) return '$mb MB（默认）';
    if (mb >= 1024) return '${mb ~/ 1024} GB';
    return '$mb MB';
  }

  @override
  Widget build(BuildContext context) {
    final wv = _webview2Status;
    final wvReady = wv?['available'] == true;
    final wvVersion = (wv?['version'] ?? '').toString();
    final wvReason = (wv?['reason'] ?? 'checking').toString();
    final pySummary = _pythonStatus.ready
        ? '已就绪 · CPython ${_pythonStatus.version}'
        : '未就绪 (${_pythonStatus.reason})';
    final wvSummary = wv == null
        ? '正在检测…'
        : (wvReady
            ? '已就绪${wvVersion.isNotEmpty ? " · v$wvVersion" : ""}'
            : '不可用 ($wvReason)');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WinSettingsGroup(
          header: '媒体磁盘块缓存',
          footer: '点播直链按 256 KiB 对齐分块落盘缓存，加速拖动回放并降低网盘/直链重复拉流。',
          children: [
            Padding(
              key: const ValueKey('windows-settings-disk-cache'),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(CupertinoIcons.archivebox,
                          size: 20, color: winMuted(context)),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '媒体磁盘块缓存上限',
                              style: TextStyle(
                                color: winInk(context),
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '当前已用空间：${_formatBytes(_cacheBytes)}',
                              key: const ValueKey(
                                  'windows-settings-disk-cache-used'),
                              style: TextStyle(
                                color: winMuted(context),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      WinButton(
                        _clearingCache ? '清理中…' : '一键清理缓存',
                        key: const ValueKey('windows-settings-clear-disk-cache'),
                        onPressed: _clearingCache
                            ? null
                            : () async {
                                setState(() => _clearingCache = true);
                                try {
                                  await DiskBlockCache.instance
                                      .clearDiskCache();
                                  await _refreshStatus();
                                } finally {
                                  if (mounted) {
                                    setState(() => _clearingCache = false);
                                  }
                                }
                              },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final mb
                          in StorageService.allowedDiskCacheMbOptions)
                        WinButton(
                          _cacheOptionLabel(mb),
                          key: ValueKey('win-setting-disk-cache-$mb'),
                          selected: widget.storage.diskCacheMaxMb == mb,
                          onPressed: () async {
                            await widget.storage.setDiskCacheMaxMb(mb);
                            await DiskBlockCache.instance.setMaxMegabytes(mb);
                            await _refreshStatus();
                            widget.onChanged();
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        WinSettingsGroup(
          header: '运行环境状态',
          footer: 'Python 3.11 原生引擎用于本地运行社区 .py 片源；Edge WebView2 引擎负责 Stage-3 动态网页嗅探与异步 JS 源兜底。',
          children: [
            WinSettingsRow(
              key: const ValueKey('windows-runtime-python-status'),
              title: 'Python 3.11 原生引擎',
              subtitle: _pythonStatus.executablePath?.isNotEmpty == true
                  ? _pythonStatus.executablePath
                  : '随包免安装隔离运行时 (requests / lxml / pyquery / pycryptodome)',
              value: pySummary,
              icon: CupertinoIcons.chevron_left_slash_chevron_right,
              trailing: Icon(
                _pythonStatus.ready
                    ? CupertinoIcons.checkmark_circle_fill
                    : CupertinoIcons.exclamationmark_circle,
                size: 18,
                color: _pythonStatus.ready
                    ? AppleColors.systemGreen
                    : winMuted(context),
              ),
              onTap: _refreshStatus,
            ),
            WinSettingsRow(
              key: const ValueKey('windows-runtime-webview2-status'),
              title: 'Edge WebView2 动态嗅探引擎',
              subtitle: wvReady && (wv?['userDataDir'] ?? '').toString().isNotEmpty
                  ? (wv!['userDataDir']).toString()
                  : '系统 Evergreen Runtime 离屏嗅探与异步 DOM/JS 兜底',
              value: wvSummary,
              icon: CupertinoIcons.globe,
              trailing: Icon(
                wvReady
                    ? CupertinoIcons.checkmark_circle_fill
                    : CupertinoIcons.exclamationmark_circle,
                size: 18,
                color: wvReady ? AppleColors.systemGreen : winMuted(context),
              ),
              onTap: _refreshStatus,
            ),
          ],
        ),
      ],
    );
  }
}
