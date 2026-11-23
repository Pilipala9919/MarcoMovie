import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../core/models.dart';
import '../core/quark_drive.dart';
import '../core/storage_service.dart';
import 'apple_theme.dart';
import 'motion/ios27_springs.dart';
import 'player_screen.dart';

Future<void> showQuarkLibrarySheet(
  BuildContext context,
  StorageService storage, {
  QuarkDriveClient? drive,
}) async {
  final client = drive ?? QuarkDriveClient(accounts: storage.quarkAccounts);
  try {
    await showIos27LiquidSheet<void>(
      context: context,
      title: '夸克网盘 · 我的视频',
      builder: (_) => _QuarkLibrary(storage: storage, drive: client),
    );
  } finally {
    if (drive == null) client.close();
  }
}

class _QuarkLibrary extends StatefulWidget {
  final StorageService storage;
  final QuarkDriveClient drive;
  const _QuarkLibrary({required this.storage, required this.drive});
  @override
  State<_QuarkLibrary> createState() => _QuarkLibraryState();
}

class _QuarkLibraryState extends State<_QuarkLibrary> {
  static const double _windowsAutoLoadThreshold = 280.0;

  final _folders = <(String, String)>[('0', '全部文件')];
  final _scroll = ScrollController();
  List<CmsVideo> _videos = [];
  int _page = 0, _pages = 1, _request = 0;
  bool _loading = false;
  bool _autoPagingScheduled = false;
  String _error = '';

  bool get _canWindowsAutoLoadMore =>
      isWindowsDesktopUi &&
      !_loading &&
      !_autoPagingScheduled &&
      _error.isEmpty &&
      _page > 0 &&
      _page < _pages;

  void _scheduleWindowsAutoLoadMore() {
    if (!_canWindowsAutoLoadMore) return;
    final expectedRequest = _request;
    final expectedFolder = _folders.last.$1;
    _autoPagingScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoPagingScheduled = false;
      if (!mounted ||
          !_canWindowsAutoLoadMore ||
          _request != expectedRequest ||
          _folders.last.$1 != expectedFolder) {
        return;
      }
      unawaited(_load(more: true));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (!isWindowsDesktopUi ||
        notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical) {
      return false;
    }
    final scrollingDown = switch (notification) {
      ScrollUpdateNotification(:final scrollDelta) => (scrollDelta ?? 0) > 0,
      OverscrollNotification(:final overscroll) => overscroll > 0,
      _ => false,
    };
    if (scrollingDown &&
        notification.metrics.extentAfter < _windowsAutoLoadThreshold) {
      _scheduleWindowsAutoLoadMore();
    }
    return false;
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (!isWindowsDesktopUi ||
        event is! PointerScrollEvent ||
        event.scrollDelta.dy <= 0) {
      return;
    }
    if (!_scroll.hasClients || _scroll.positions.length != 1) return;
    if (_scroll.position.extentAfter <= _windowsAutoLoadThreshold) {
      _scheduleWindowsAutoLoadMore();
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _request++;
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final listing = await widget.drive.listOwned(
        folder: _folders.last.$1,
        page: more ? _page + 1 : 1,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _videos = more ? [..._videos, ...listing.videos] : listing.videos;
        _page = listing.page;
        _pages = listing.pageCount;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _error = '无法读取网盘，请重试；若登录已失效，请返回账号页重新扫码';
      });
    }
  }

  void _open(CmsVideo video) {
    if (video.id.startsWith('mmquark://folder?')) {
      _folders.add((video.id, video.title));
      _videos = [];
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _load();
      return;
    }
    if (video.lines.isEmpty) return;
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          site: const CmsSite(
            key: 'local_quark',
            name: '夸克网盘',
            type: 3,
            api: 'csp_MyDriveGuard',
          ),
          video: video,
          initialLineIndex: 0,
          initialEpisodeIndex: 0,
          storage: widget.storage,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * 0.62,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          child: Row(
            children: [
              if (_folders.length > 1) ...[
                AppleCapsuleButton(
                  label: '上一级',
                  compact: true,
                  icon: CupertinoIcons.chevron_left,
                  onPressed: () {
                    _folders.removeLast();
                    _videos = [];
                    if (_scroll.hasClients) _scroll.jumpTo(0);
                    _load();
                  },
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Text(
                  _folders.last.$2,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerSignal: _handlePointerSignal,
            child: NotificationListener<ScrollNotification>(
              onNotification: _handleScrollNotification,
              child: ListView(
                controller: _scroll,
                physics: isWindowsDesktopUi
                    ? const AlwaysScrollableScrollPhysics()
                    : null,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                children: [
                  for (final video in _videos)
                    Ios27Pressable(
                      pressedScale: isWindowsDesktopUi
                          ? 1.0
                          : Ios27Spring.pressSwellScale,
                      borderRadius: Ios27ConcentricGeometry.innerRadius(
                        outerRadius:
                            Ios27ConcentricGeometry.sheetOuterRadiusPt,
                        padding: 16.0,
                      ),
                      enableIllumination: !isWindowsDesktopUi,
                      onTap: () => _open(video),
                      child: ListTile(
                        key: ValueKey(video.id),
                        leading: Icon(
                          video.id.startsWith('mmquark://folder?')
                              ? CupertinoIcons.folder
                              : CupertinoIcons.play_rectangle,
                          color: AppleColors.systemBlue,
                        ),
                        title: Text(
                          video.title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: video.remarks.isEmpty
                            ? null
                            : Text(video.remarks),
                        trailing: const Icon(
                          CupertinoIcons.chevron_right,
                          size: 16,
                        ),
                      ),
                    ),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: CupertinoActivityIndicator(),
                    ),
                  if (_error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          Text(_error, textAlign: TextAlign.center),
                          const SizedBox(height: 14),
                          AppleCapsuleButton(
                            label: '重试',
                            compact: true,
                            onPressed: () =>
                                _load(more: _page > 0 && _videos.isNotEmpty),
                          ),
                        ],
                      ),
                    ),
                  if (!_loading && _error.isEmpty && _videos.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '此文件夹暂无视频或子文件夹',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (!isWindowsDesktopUi &&
                      !_loading &&
                      _error.isEmpty &&
                      _page < _pages)
                    Center(
                      child: AppleCapsuleButton(
                        label: '加载更多',
                        compact: true,
                        onPressed: () => _load(more: true),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
