import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/app_update.dart';
import 'apple_theme.dart';

typedef IosUpdateCheck = Future<AppUpdate> Function(
    UpdateCancellation cancellation, void Function(String) onStage);

/// Owns the entire sheet lifecycle. Closing / retrying invalidates every late
/// platform-channel or network result from the previous attempt.
class IosUpdateSheet extends StatefulWidget {
  final String installedVersion;
  final Future<String> Function()? readVersion;
  final IosUpdateCheck? check;
  final Future<File> Function(
      AppUpdate, UpdateCancellation, void Function(int, int))? download;
  final Future<ShareResult> Function(File, Rect)? shareFile;
  const IosUpdateSheet(
      {super.key,
      this.installedVersion = '',
      this.readVersion,
      this.check,
      this.download,
      this.shareFile});

  @override
  State<IosUpdateSheet> createState() => _IosUpdateSheetState();
}

class _IosUpdateSheetState extends State<IosUpdateSheet> {
  UpdateCancellation? _operation;
  AppUpdate? _release;
  String _version = '';
  String _status = '正在连接镜像更新源…';
  bool _checking = false;
  bool _downloading = false;
  double? _progress;
  bool _saved = false;
  File? _savedFile;
  bool _sharing = false;

  bool _active(UpdateCancellation op) =>
      mounted && identical(_operation, op) && !op.isCancelled;
  static bool _validVersion(String value) =>
      RegExp(r'^\d+\.\d+\.\d+$').hasMatch(value);
  bool get _newer {
    if (!_validVersion(_version)) return false;
    final remote = _release!.version.split('.').map(int.parse).toList();
    final local = _version.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      if (remote[i] != local[i]) return remote[i] > local[i];
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    if (_validVersion(widget.installedVersion)) {
      _version = widget.installedVersion;
    }
    unawaited(_check());
  }

  @override
  void dispose() {
    _operation?.cancel();
    super.dispose();
  }

  Future<void> _loadVersion(UpdateCancellation op) async {
    try {
      final version = await (widget.readVersion?.call() ??
              PackageInfo.fromPlatform().then((info) => info.version))
          .timeout(const Duration(seconds: 3));
      if (_active(op) && _validVersion(version)) {
        setState(() => _version = version);
      }
    } catch (_) {
      /* Metadata checks must never wait on this platform channel. */
    }
  }

  Future<void> _check() async {
    _operation?.cancel();
    final op = _operation = UpdateCancellation();
    setState(() {
      _checking = true;
      _downloading = false;
      _release = null;
      _saved = false;
      _savedFile = null;
      _status = '正在连接镜像更新源…';
    });
    unawaited(_loadVersion(op));
    void stage(String value) {
      if (_active(op)) setState(() => _status = value);
    }

    try {
      final result = await op.bind((widget.check?.call(op, stage) ??
              AppUpdate.check(
                  platform: 'ios', cancellation: op, onStage: stage))
          .timeout(const Duration(seconds: 18)));
      if (!_active(op)) return;
      if (result.iosUrl == null) {
        throw const FormatException('更新清单缺少完整的 iOS 安装包信息');
      }
      setState(() {
        _release = result;
        _checking = false;
      });
    } catch (error) {
      if (!_active(op)) return;
      setState(() {
        _checking = false;
        _status = error is TimeoutException
            ? '检查更新超时，请重试或打开下载站。'
            : '暂时无法取得更新信息，请重试或打开下载站。';
      });
      op.cancel();
    }
  }

  void _cancel() {
    _operation?.cancel();
    setState(() {
      _checking = false;
      _downloading = false;
      _status = '已取消，可重新检查或下载。';
      _progress = null;
    });
  }

  Future<void> _download({bool? trollStore}) async {
    final release = _release;
    if (release == null || _downloading) return;
    _operation?.cancel();
    final op = _operation = UpdateCancellation();
    setState(() {
      _downloading = true;
      _saved = false;
      _progress = null;
      _status = '正在连接已发布的 IPA 下载地址…';
    });
    try {
      op.check();
      var lastPaint = DateTime.fromMillisecondsSinceEpoch(0);
      void progress(int received, int total) {
        if (!_active(op)) return;
        final now = DateTime.now();
        if (received != total &&
            now.difference(lastPaint).inMilliseconds < 150) {
          return;
        }
        lastPaint = now;
        setState(() {
          _progress = received / total;
          _status = received == total
              ? '下载完成，正在校验安装包…'
              : '正在下载 ${(received / 1048576).toStringAsFixed(1)} / ${(total / 1048576).toStringAsFixed(1)} MB';
        });
      }

      Future<File> download() async {
        final directory = await getApplicationDocumentsDirectory()
            .timeout(const Duration(seconds: 3));
        return release.downloadIos(
            directory: directory, cancellation: op, onProgress: progress);
      }

      final file =
          await (widget.download?.call(release, op, progress) ?? download());
      if (!_active(op)) return;
      setState(() {
        _downloading = false;
        _saved = true;
        _savedFile = file;
        _status = 'IPA 已下载并通过 SHA-256 校验，可交给巨魔或通过系统分享导入签名工具。';
      });
      if (trollStore != null) await _share(trollStore: trollStore);
    } catch (error) {
      if (!_active(op)) return;
      setState(() {
        _downloading = false;
        _status = error is FormatException
            ? '安装包校验失败，未保留不完整文件，请重新下载。'
            : error is TimeoutException
                ? '下载连接超时，请重试，或前往下载站使用备用下载。'
                : '下载未完成，请重试，或前往下载站使用备用下载。';
      });
      op.cancel();
    }
  }

  Future<void> _share({required bool trollStore}) async {
    if (_sharing) return;
    final file = _savedFile;
    if (file == null) {
      await _download(trollStore: trollStore);
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final origin = Rect.fromCenter(
        center: box.localToGlobal(box.size.center(Offset.zero)),
        width: 1,
        height: 1);
    setState(() {
      _sharing = true;
      _status = trollStore
          ? '请在系统菜单中选择 TrollStore，使用已下载的 IPA 更新。'
          : '请在系统菜单中选择签名工具，导入 IPA 后使用自己的证书签名安装。';
    });
    try {
      // Share a real file, never a URL string. iPad requires a popover anchor.
      final result = await (widget.shareFile?.call(file, origin) ??
          Share.shareXFiles(
              [XFile(file.path, mimeType: 'application/octet-stream')],
              sharePositionOrigin: origin));
      if (!mounted) return;
      setState(() => _status = result.status == ShareResultStatus.dismissed
          ? '已取消分享，安装包仍已保存，可再次打开。'
          : '已打开系统分享；是否安装成功请在所选工具中确认。');
    } catch (_) {
      if (mounted) {
        setState(() => _status =
            '未能打开系统分享。IPA 已保存，可从「文件 → 我的 iPhone / iPad → Marco Movie」中导入安装工具。');
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _open(Uri uri) async {
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication)
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
    if (!mounted) return;
    if (!opened) {
      await Clipboard.setData(ClipboardData(text: uri.toString()));
      if (mounted) setState(() => _status = '已复制下载地址，请粘贴到浏览器打开。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _checking || _downloading || _sharing;
    final release = _release;
    return SingleChildScrollView(
      key: const ValueKey('ios-update-scroll'),
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(_validVersion(_version) ? '当前版本  $_version' : '当前版本暂无法读取',
            style: const TextStyle(
                color: AppleColors.labelSecondary, fontSize: 13)),
        const SizedBox(height: 12),
        if (release != null) ...[
          Text(
              _validVersion(_version)
                  ? (_newer ? '发现新版本 ${release.version}' : '当前已是最新版本')
                  : '可用版本 ${release.version}',
              style: const TextStyle(
                  color: AppleColors.labelPrimary,
                  fontSize: 23,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
        ],
        if (busy) ...[
          LinearProgressIndicator(
              key: const ValueKey('ios-update-progress'),
              value: _downloading ? _progress : null),
          const SizedBox(height: 12),
        ],
        // Keep status visible even after an error or handoff.
        if (release == null ||
            _downloading ||
            _saved ||
            (!_checking && !_status.startsWith('正在连接'))) ...[
          Text(_status,
              key: const ValueKey('ios-update-status'),
              style: const TextStyle(
                  color: AppleColors.labelSecondary, height: 1.5)),
          const SizedBox(height: 16),
        ],
        Wrap(spacing: 10, runSpacing: 10, children: [
          if (_checking || _downloading)
            AppleCapsuleButton(
                label: '取消', icon: CupertinoIcons.xmark, onPressed: _cancel)
          else if (!_sharing)
            AppleCapsuleButton(
                label: '重新检查', icon: CupertinoIcons.refresh, onPressed: _check),
          AppleCapsuleButton(
              label: '打开下载站',
              icon: CupertinoIcons.globe,
              onPressed: () =>
                  _open(Uri.parse('https://marcotv.wlj9919.top/movie/'))),
          if (release != null && !busy) ...[
            AppleCapsuleButton(
                label: _saved ? '检查已下载 IPA' : '仅下载 IPA',
                icon: CupertinoIcons.arrow_down_to_line,
                primary: true,
                onPressed: _download),
            AppleCapsuleButton(
                label: '浏览器下载',
                icon: CupertinoIcons.arrow_up_right_square,
                onPressed: () => _open(release.iosUrl!)),
            AppleCapsuleButton(
                label: _saved ? '用巨魔更新' : '下载并用巨魔更新',
                icon: CupertinoIcons.bolt,
                onPressed: () => _share(trollStore: true)),
            AppleCapsuleButton(
                label: _saved ? '用其他应用打开' : '下载并自签更新',
                icon: CupertinoIcons.share,
                onPressed: () => _share(trollStore: false)),
          ],
        ]),
        if (release != null && release.notes.isNotEmpty) ...[
          const SizedBox(height: 24),
          const Text('更新内容',
              style: TextStyle(
                  color: AppleColors.labelPrimary,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(release.notes,
              style: const TextStyle(
                  color: AppleColors.labelSecondary,
                  fontSize: 13,
                  height: 1.6)),
        ],
      ]),
    );
  }
}
