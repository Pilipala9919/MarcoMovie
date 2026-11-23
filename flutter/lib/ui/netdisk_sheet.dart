import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr/qr.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/netdisk_service.dart';
import '../core/netdisk_session.dart';
import '../core/storage_service.dart';
import '../core/quark_account.dart';
import 'apple_theme.dart';
import 'ios_liquid_glass.dart';
import 'ios_settings.dart';
import 'local_qr_code.dart';
import 'motion/ios27_springs.dart';
import 'quark_library_sheet.dart';
import 'windows_appearance.dart';

const MethodChannel netdiskAuthChannel = MethodChannel(
  'marco_movie/netdisk_auth',
);

/// Opens the Apple-styled Netdisk QR Code Login & Account Management sheet
/// matching Android TV's `🗂我的云盘┃配置` (`我的夸父 / 我的优汐 / 我的嘟嘟 / 我的阿狸`).
Future<void> showNetdiskAccountSheet(
  BuildContext context,
  StorageService storage, {
  String? initialDriveKey,
  VoidCallback? onChanged,
  NetdiskService? service,
  String iosBackLabel = '返回',
}) async {
  if (usesWindowsAppearance(context)) {
    await Navigator.of(context).push<void>(buildApplePageRoute<void>(
        builder: (_) => WinSettingsScaffold(
            title: '网盘账号',
            subtitle: '管理影视线路使用的账号与解析顺序。',
            child: _NetdiskAccountSheet(
                storage: storage,
                initialDriveKey: initialDriveKey,
                onChanged: onChanged,
                service: service))));
    return;
  }
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    await Navigator.of(context).push<void>(
      buildApplePageRoute<void>(
        builder: (_) => _NetdiskAccountSheet(
          storage: storage,
          initialDriveKey: initialDriveKey,
          onChanged: onChanged,
          service: service,
          embedInIosScaffold: true,
          iosBackLabel: iosBackLabel,
        ),
      ),
    );
    return;
  }
  await showIos27LiquidSheet<void>(
    context: context,
    title: '我的云盘 · 扫码与账号配置',
    builder: (ctx) => _NetdiskAccountSheet(
      storage: storage,
      initialDriveKey: initialDriveKey,
      onChanged: onChanged,
      service: service,
    ),
  );
}

class _NetdiskAccountSheet extends StatefulWidget {
  final StorageService storage;
  final String? initialDriveKey;
  final VoidCallback? onChanged;
  final NetdiskService? service;
  final bool embedInIosScaffold;
  final String iosBackLabel;

  const _NetdiskAccountSheet({
    required this.storage,
    this.initialDriveKey,
    this.onChanged,
    this.service,
    this.embedInIosScaffold = false,
    this.iosBackLabel = '返回',
  });

  @override
  State<_NetdiskAccountSheet> createState() => _NetdiskAccountSheetState();
}

class _NetdiskAccountSheetState extends State<_NetdiskAccountSheet>
    with WidgetsBindingObserver {
  late final NetdiskService _service = widget.service ??
      NetdiskService(quarkAccounts: widget.storage.quarkAccounts);
  String? _activeQrDriveKey;
  NetdiskQrSession? _qrSession;
  bool _loadingQr = false;
  String _qrStatusText = '';
  Timer? _pollTimer;
  int _qrAttempt = 0;
  int? _pollingAttempt;
  bool _foreground = true;
  bool _resumedImmediateRetry = false;
  int _selectedDriveFilter = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (widget.initialDriveKey != null && widget.initialDriveKey!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _startQrLogin(widget.initialDriveKey!);
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _resumedImmediateRetry = false;
      _pollTimer?.cancel();
      return;
    }
    final session = _qrSession;
    if (session != null) {
      if (_pollingAttempt == null) {
        _pollQr(_qrAttempt, session);
      } else {
        _resumedImmediateRetry = true;
        _service.abortBaiduLongPoll();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _qrAttempt++;
    _pollTimer?.cancel();
    if (widget.service == null) _service.close();
    super.dispose();
  }

  NetdiskDriveInfo _driveByKey(String key) {
    return NetdiskService.drives.firstWhere(
      (d) => d.key == key,
      orElse: () => NetdiskService.drives.first,
    );
  }

  Future<void> _startQrLogin(String driveKey) async {
    final attempt = ++_qrAttempt;
    _pollTimer?.cancel();
    setState(() {
      _activeQrDriveKey = driveKey;
      _loadingQr = true;
      _qrSession = null;
      _qrStatusText = '正在连接${_driveByKey(driveKey).providerName}生成登录二维码…';
    });
    try {
      final session = await _service.createQrSession(driveKey);
      if (!mounted || attempt != _qrAttempt) return;
      setState(() {
        _loadingQr = false;
        _qrSession = session;
        _qrStatusText = _driveByKey(driveKey).appHint;
      });
      if (_foreground)
        _pollTimer = Timer(
          const Duration(seconds: 3),
          () => _pollQr(attempt, session),
        );
    } catch (_) {
      if (!mounted || attempt != _qrAttempt) return;
      setState(() {
        _loadingQr = false;
        _qrStatusText = '暂时无法获取登录二维码，请稍后刷新';
      });
    }
  }

  void _cancelQr() {
    _qrAttempt++;
    _pollTimer?.cancel();
    _activeQrDriveKey = null;
    _qrSession = null;
  }

  Future<void> _pollQr(int attempt, NetdiskQrSession session) async {
    bool current() =>
        mounted &&
        ModalRoute.of(context)?.isCurrent != false &&
        attempt == _qrAttempt &&
        identical(_qrSession, session);
    if (!current() || !_foreground || _pollingAttempt == attempt) return;
    _pollTimer?.cancel();
    _pollingAttempt = attempt;
    try {
      final res = await _service.pollQrStatus(session);
      if (!current()) return;
      if (res.state == NetdiskPollState.confirmed &&
          res.credential.isNotEmpty) {
        final complete = session.driveKey == 'quark'
            ? QuarkAccountSession.tryParseCredential(res.credential) != null
            : NetdiskSession.isUsable(session.driveKey, res.credential) &&
                (session.driveKey != 'baidu' || res.accountVerified);
        if (!complete) {
          setState(() => _qrStatusText = '账户验证未完成，请刷新二维码重试');
          return;
        }
        await widget.storage.setNetdiskCredential(
          session.driveKey,
          res.credential,
        );
        if (!current()) return;
        widget.onChanged?.call();
        setState(_cancelQr);
      } else {
        setState(() => _qrStatusText = res.message);
        if (res.state == NetdiskPollState.waiting ||
            res.state == NetdiskPollState.scanned) {
          if (_foreground) {
            final immediate = _resumedImmediateRetry;
            _resumedImmediateRetry = false;
            _pollTimer = Timer(
              immediate
                  ? const Duration(milliseconds: 80)
                  : const Duration(seconds: 3),
              () => _pollQr(attempt, session),
            );
          }
        }
      }
    } catch (_) {
      if (current()) {
        setState(() => _qrStatusText = '正在等待手机端确认登录…');
        if (_foreground) {
          final immediate = _resumedImmediateRetry;
          _resumedImmediateRetry = false;
          _pollTimer = Timer(
            immediate
                ? const Duration(milliseconds: 80)
                : const Duration(seconds: 3),
            () => _pollQr(attempt, session),
          );
        }
      }
    } finally {
      if (_pollingAttempt == attempt) _pollingAttempt = null;
    }
  }

  Future<void> _shareQrImage(String qrData, NetdiskDriveInfo drive) async {
    if (qrData.isEmpty) return;
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null && box.hasSize
        ? Rect.fromCenter(
            center: box.localToGlobal(box.size.center(Offset.zero)),
            width: 1,
            height: 1,
          )
        : const Rect.fromLTWH(0, 0, 1, 1);
    try {
      final matrix = QrImage(
        QrCode.fromData(data: qrData, errorCorrectLevel: QrErrorCorrectLevel.M),
      );
      const quietZone = 4;
      final modules = matrix.moduleCount + quietZone * 2;
      const imageSize = 512.0;
      final cell = imageSize / modules;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, imageSize, imageSize),
        Paint()..color = const Color(0xFFFFFFFF),
      );
      final darkPaint = Paint()
        ..color = const Color(0xFF000000)
        ..isAntiAlias = false;
      for (var r = 0; r < matrix.moduleCount; r++) {
        for (var c = 0; c < matrix.moduleCount; c++) {
          if (matrix.isDark(r, c)) {
            canvas.drawRect(
              Rect.fromLTRB(
                ((c + quietZone) * cell).floorToDouble(),
                ((r + quietZone) * cell).floorToDouble(),
                ((c + quietZone + 1) * cell).floorToDouble(),
                ((r + quietZone + 1) * cell).floorToDouble(),
              ),
              darkPaint,
            );
          }
        }
      }
      final picture = recorder.endRecording();
      final img = await picture.toImage(imageSize.toInt(), imageSize.toInt());
      final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      if (byteData == null) return;
      final tmpFile = File(
        '${Directory.systemTemp.path}/marco-${drive.key}-qr.png',
      );
      await tmpFile.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      await Share.shareXFiles(
        [XFile(tmpFile.path, mimeType: 'image/png')],
        sharePositionOrigin: origin,
      );
      if (mounted) {
        setState(() {
          _qrStatusText =
              '可存储二维码到相册后，打开${drive.providerName} App「扫一扫 → 相册」确认登录';
        });
      }
    } catch (_) {}
    _ensurePollingActive();
  }

  void _ensurePollingActive({bool immediate = false}) {
    final session = _qrSession;
    if (!mounted ||
        !_foreground ||
        session == null ||
        _pollingAttempt != null) {
      return;
    }
    if (immediate || _pollTimer == null || !_pollTimer!.isActive) {
      _pollTimer?.cancel();
      _pollTimer = Timer(
        immediate
            ? const Duration(milliseconds: 120)
            : const Duration(seconds: 3),
        () => _pollQr(_qrAttempt, session),
      );
    }
  }

  Future<void> _shareQrAndOpenAliApp(
    String qrData,
    NetdiskDriveInfo drive,
  ) async {
    if (qrData.isEmpty) return;
    await _shareQrImage(qrData, drive);
    for (final scheme in const ['smartdrive://', 'alipan://']) {
      final uri = Uri.tryParse(scheme);
      if (uri == null) continue;
      try {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          break;
        }
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _qrStatusText = '已准备二维码：打开阿里云盘右上角「+ → 扫一扫 → 相册」选码即可确认登录';
      });
    }
    _ensurePollingActive();
  }

  Future<bool> _startNativeWebAuth(
    NetdiskDriveInfo drive,
    String qrData,
  ) async {
    Map<String, dynamic>? result;
    try {
      result = await netdiskAuthChannel.invokeMapMethod<String, dynamic>(
        'startWebAuth',
        <String, dynamic>{
          'drive': drive.key,
          'url': NetdiskService.buildNativeWebAuthUrl(
            drive.key,
            qrContent: qrData,
          ),
          'qrUrl': qrData,
        },
      );
    } on MissingPluginException {
      return false;
    } on PlatformException {
      _ensurePollingActive();
      return true;
    }
    if (!mounted) return true;
    if (result == null) {
      _ensurePollingActive(immediate: true);
      return true;
    }
    final type = (result['type'] ?? '').toString();
    if (type == 'openScanApp') {
      await _shareQrAndOpenAliApp(qrData, drive);
      return true;
    }
    if (type == 'credential' || type == 'bizExt') {
      final attemptAtStart = _qrAttempt;
      setState(() {
        _qrStatusText = '正在验证${drive.providerName}账号会话…';
      });
      try {
        final rawCredential = type == 'bizExt'
            ? NetdiskSession.aliCredential(result['bizExt'])
            : (result['credential'] ?? '').toString();
        final verified = await _service.verifyWebAuthCredential(
          drive.key,
          rawCredential,
        );
        if (!mounted || attemptAtStart != _qrAttempt) return true;
        await widget.storage.setNetdiskCredential(drive.key, verified);
        if (!mounted || attemptAtStart != _qrAttempt) return true;
        widget.onChanged?.call();
        setState(_cancelQr);
      } catch (_) {
        if (mounted && attemptAtStart == _qrAttempt) {
          setState(() {
            _qrStatusText = '${drive.providerName}账号验证未完成，请重试或刷新二维码';
          });
          _ensurePollingActive();
        }
      }
      return true;
    }
    _ensurePollingActive();
    return true;
  }

  Future<void> _openSameDeviceAuth(
    NetdiskDriveInfo drive,
    String qrData,
  ) async {
    if (qrData.isEmpty) return;
    final isTablet = MediaQuery.sizeOf(context).shortestSide >= 600;
    if (drive.key == 'quark' || drive.key == 'uc') {
      final deepLinks = NetdiskService.buildNativeAppDeepLinks(
        drive.key,
        qrData,
        isTablet: isTablet,
      );
      for (final deepLink in deepLinks) {
        final deepUri = Uri.tryParse(deepLink);
        if (deepUri == null) continue;
        try {
          final launched = await launchUrl(
            deepUri,
            mode: LaunchMode.externalApplication,
          );
          if (launched) {
            if (mounted) {
              setState(() {
                _qrStatusText = '已打开${drive.providerName}，确认登录返回后将自动同步状态';
              });
            }
            _ensurePollingActive();
            return;
          }
        } catch (_) {}
      }
      if (await _startNativeWebAuth(drive, qrData)) return;
      final fallbackUri = Uri.tryParse(qrData);
      if (fallbackUri != null) {
        try {
          await launchUrl(fallbackUri, mode: LaunchMode.externalApplication);
        } catch (_) {}
      }
      _ensurePollingActive();
      return;
    }

    if (await _startNativeWebAuth(drive, qrData)) return;

    for (final deepLink in NetdiskService.buildNativeAppDeepLinks(
      drive.key,
      qrData,
      isTablet: isTablet,
    )) {
      final deepUri = Uri.tryParse(deepLink);
      if (deepUri == null) continue;
      try {
        if (await launchUrl(deepUri, mode: LaunchMode.externalApplication)) {
          _ensurePollingActive();
          return;
        }
      } catch (_) {}
    }
    final webUri = Uri.tryParse(
      NetdiskService.buildNativeWebAuthUrl(drive.key, qrContent: qrData),
    );
    if (webUri != null) {
      try {
        await launchUrl(webUri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
    _ensurePollingActive();
  }

  Future<void> _showManualInputDialog(String driveKey) async {
    setState(_cancelQr);
    final drive = _driveByKey(driveKey);
    final stored = widget.storage.netdiskCredential(driveKey);
    final controller = TextEditingController(
      text: driveKey == 'quark'
          ? QuarkAccountSession.tryParseCredential(stored)?.cookie ?? stored
          : stored,
    );
    var saving = false;
    var error = '';
    Widget buildManualForm(BuildContext ctx, StateSetter update) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
      child: TextSelectionMouseGuard(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (usesWindowsAppearance(ctx)) ...[
                Text(
                  '${drive.providerName} · 账号配置',
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 14),
              ],
              TextSelectionMouseGuard(
                child: TextField(
                  controller: controller,
                  maxLines: 3,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    hintText: '粘贴 Cookie 或 Token…',
                  ),
                ),
              ),
              if (error.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  error,
                  style: const TextStyle(color: AppleColors.systemRed),
                ),
              ],
              const SizedBox(height: 18),
              Wrap(
                spacing: 12,
                runSpacing: 10,
                children: [
                  AppleCapsuleButton(
                    label: '取消',
                    compact: true,
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                  AppleCapsuleButton(
                    label: saving
                        ? '正在验证…'
                        : driveKey == 'quark'
                            ? '验证并保存'
                            : '保存配置',
                    primary: true,
                    compact: true,
                    onPressed: () async {
                      if (saving) return;
                      update(() {
                        saving = true;
                        error = '';
                      });
                      try {
                        var credential = controller.text.trim();
                        if (driveKey == 'quark' && credential.isNotEmpty) {
                          credential = (await widget.storage.quarkAccounts
                                  .validateCredential(credential))
                              .toCredential();
                        }
                        if (!mounted ||
                            !ctx.mounted ||
                            ModalRoute.of(ctx)?.isCurrent == false) return;
                        await widget.storage.setNetdiskCredential(
                          driveKey,
                          credential,
                        );
                        widget.onChanged?.call();
                        if (ctx.mounted) Navigator.of(ctx).pop();
                        if (mounted) setState(() {});
                      } catch (_) {
                        if (ctx.mounted) {
                          update(() {
                            saving = false;
                            error = '账户验证失败，请检查凭据或重新扫码';
                          });
                        }
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (usesWindowsAppearance(context)) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, update) => Dialog(
            backgroundColor: Colors.transparent,
            child: AppleGlassSurface(
              padding: const EdgeInsets.all(2),
              borderRadius: BorderRadius.circular(26),
              child: buildManualForm(ctx, update),
            ),
          ),
        ),
      );
    } else {
      await showIos27LiquidSheet<void>(
        context: context,
        title: '${drive.providerName} · 账号配置',
        maxWidth: 460,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, update) => buildManualForm(ctx, update),
        ),
      );
    }
    // Dialog exit animations may still use its controller on this frame.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
  }

  Future<void> _rotateDriveOrder() async {
    final current = List<String>.from(widget.storage.driveOrder);
    if (current.length > 1) {
      final first = current.removeAt(0);
      current.add(first);
      await widget.storage.setDriveOrder(current);
      widget.onChanged?.call();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final orderLabels = widget.storage.driveOrder.map((k) {
      return switch (k) {
        'quark' => '夸父',
        'uc' => '优汐',
        'baidu' => '嘟嘟',
        'ali' => '阿狸',
        _ => k,
      };
    }).join(' > ');

    if (usesWindowsAppearance(context)) {
      return Column(
          key: const ValueKey('netdisk-account-sheet'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            WinSettingsGroup(children: [
              WinSettingsRow(
                  title: '解析优先顺序',
                  subtitle: orderLabels,
                  icon: CupertinoIcons.arrow_up_arrow_down,
                  trailing: WinButton('切换顺序', onPressed: _rotateDriveOrder))
            ]),
            const SizedBox(height: 18),
            if (_activeQrDriveKey != null) ...[
              _buildQrScannerCard(_driveByKey(_activeQrDriveKey!)),
              const SizedBox(height: 18)
            ],
            for (final drive in NetdiskService.drives) ...[
              WinSettingsGroup(children: [
                WinSettingsRow(
                    title: drive.providerName,
                    subtitle: '对应线路：${drive.lineBadges.join(" / ")}',
                    icon: CupertinoIcons.cloud,
                    value: widget.storage.isNetdiskLoggedIn(drive.key)
                        ? '已连接'
                        : '未连接'),
                Padding(
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
                    child: Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(spacing: 8, runSpacing: 8, children: [
                          WinButton(
                              widget.storage.isNetdiskLoggedIn(drive.key)
                                  ? '重新扫码'
                                  : '扫码登录',
                              key: ValueKey('netdisk-scan-btn-${drive.key}'),
                              selected:
                                  !widget.storage.isNetdiskLoggedIn(drive.key),
                              icon: CupertinoIcons.qrcode,
                              onPressed: () => _startQrLogin(drive.key)),
                          WinButton('手动配置 Token',
                              icon: CupertinoIcons.pencil,
                              onPressed: () =>
                                  _showManualInputDialog(drive.key)),
                          if (drive.key == 'quark' &&
                              widget.storage.getNetdiskCred('quark').isNotEmpty)
                            WinButton('浏览网盘视频',
                                key: const ValueKey('quark-browse-files'),
                                onPressed: () {
                              setState(_cancelQr);
                              showQuarkLibrarySheet(context, widget.storage);
                            }),
                          if (widget.storage.isNetdiskLoggedIn(drive.key))
                            WinButton('退出账号', onPressed: () async {
                              setState(_cancelQr);
                              try {
                                await widget.storage
                                    .setNetdiskCredential(drive.key, '');
                                widget.onChanged?.call();
                                if (mounted) setState(() {});
                              } catch (e) {
                                if (context.mounted)
                                  ScaffoldMessenger.maybeOf(context)
                                      ?.showSnackBar(
                                          SnackBar(content: Text('清除凭据失败：$e')));
                              }
                            }),
                        ]))),
              ]),
              const SizedBox(height: 16),
            ],
          ]);
    }
    final palette = ApplePalette.of(context);
    final useNativeIos26 = IosLiquidGlassBridge.isAvailable;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final bannerCard = AppleSettingsGlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
      borderRadius: BorderRadius.circular(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                CupertinoIcons.arrow_up_arrow_down_circle_fill,
                color: AppleColors.systemBlue,
                size: 19,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '盘序优先：$orderLabels',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.labelPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (!widget.embedInIosScaffold || !useNativeIos26) ...[
                const SizedBox(width: 8),
                AppleCapsuleButton(
                  icon: CupertinoIcons.refresh,
                  label: '切换盘序',
                  compact: true,
                  useBackdrop: false,
                  onPressed: _rotateDriveOrder,
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '与电视端「🗂我的云盘┃配置」保持一致，支持优汐智1 / 夸父智1 / 嘟嘟无限2 / 阿狸原画',
            style: TextStyle(color: palette.labelSecondary, fontSize: 11.5),
          ),
        ],
      ),
    );

    final scrollList = RepaintBoundary(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          useNativeIos26 ? 2 : 12,
          20,
          (widget.embedInIosScaffold ? safeBottom : 0) + 28,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            bannerCard,
            const SizedBox(height: 14),
            // Active QR Code Scanner Box if a drive is selected
            if (_activeQrDriveKey != null) ...[
              _buildQrScannerCard(_driveByKey(_activeQrDriveKey!)),
              const SizedBox(height: 16),
            ],
            // 4 Netdisk Drives List (filtered when a specific drive segment is active on iOS 26+)
            for (var i = 0; i < NetdiskService.drives.length; i++)
              if (_selectedDriveFilter == 0 || _selectedDriveFilter == i + 1) ...[
                _buildDriveTile(NetdiskService.drives[i]),
                const SizedBox(height: 10),
              ],
          ],
        ),
      ),
    );

    final Widget bodyContent = useNativeIos26
        ? Column(
            key: const ValueKey('netdisk-account-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Keep native UISegmentedControl pinned outside the scroll view & away from
              // any BackdropFilter; matching 36pt fallback prevents layout shift during push.
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
                child: IosNativeSegmentedControl(
                  segments: const ['全部', '夸克', 'UC', '百度', '阿狸'],
                  selectedIndex: _selectedDriveFilter,
                  height: 36,
                  onChanged: (idx) => setState(() => _selectedDriveFilter = idx),
                  fallback: _buildFallbackDriveSegments(),
                ),
              ),
              Flexible(child: scrollList),
            ],
          )
        : KeyedSubtree(
            key: const ValueKey('netdisk-account-sheet'),
            child: scrollList,
          );

    if (widget.embedInIosScaffold) {
      return IosSettingsScaffold(
        title: '我的云盘',
        backLabel: widget.iosBackLabel,
        trailing: useNativeIos26
            ? IosNativeGlassButton(
                style: 'capsule',
                symbol: 'arrow.triangle.2.circlepath',
                label: '切换盘序',
                symbolSize: 13,
                height: 36,
                maxWidth: 108,
                accessibilityLabel: '切换盘序',
                onTap: _rotateDriveOrder,
                fallback: AppleCapsuleButton(
                  icon: CupertinoIcons.refresh,
                  label: '切换盘序',
                  compact: true,
                  useBackdrop: false,
                  onPressed: _rotateDriveOrder,
                ),
              )
            : null,
        body: bodyContent,
      );
    }
    return bodyContent;
  }

  Widget _buildFallbackDriveSegments() {
    const labels = ['全部', '夸克', 'UC', '百度', '阿狸'];
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    return Container(
      height: 36,
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C1C22) : const Color(0x14111318),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.06),
          width: 0.6,
        ),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: Ios27Pressable(
                pressedScale: Ios27Spring.pressSwellScale,
                borderRadius: 15.5,
                onTap: () => setState(() => _selectedDriveFilter = i),
                child: AnimatedContainer(
                  duration: Ios27ConcentricGeometry.isReduceMotion(context)
                      ? Ios27ConcentricGeometry.reducedMotionDuration
                      : Ios27Spring.snappy.nominalDuration,
                  curve: Ios27Spring.snappy.curve,
                  alignment: Alignment.center,
                  decoration: i == _selectedDriveFilter
                      ? BoxDecoration(
                          color: isDark
                              ? const Color(0xFF484852)
                              : palette.groupedPrimary,
                          borderRadius: BorderRadius.circular(15.5),
                          boxShadow: isDark
                              ? null
                              : const [
                                  BoxShadow(
                                    color: Color(0x140F172A),
                                    blurRadius: 4,
                                    offset: Offset(0, 1),
                                  ),
                                ],
                        )
                      : null,
                  child: Text(
                    labels[i],
                    maxLines: 1,
                    style: TextStyle(
                      color: i == _selectedDriveFilter
                          ? palette.labelPrimary
                          : palette.labelSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildQrScannerCard(NetdiskDriveInfo drive) {
    final qrData = _qrSession?.qrContent ?? '';
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;

    return Container(
      key: ValueKey('netdisk-qr-card-${drive.key}'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: usesWindowsAppearance(context) ? winMuted(context).withValues(alpha: .06) : null,
        gradient: usesWindowsAppearance(context)
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [
                        const Color(0xFF0A84FF).withValues(alpha: 0.22),
                        const Color(0xFF1C1C1E).withValues(alpha: 0.92),
                      ]
                    : [
                        const Color(0xFFEAF3FF),
                        palette.groupedPrimary,
                      ],
              ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFF0A84FF).withValues(alpha: isDark ? 0.45 : 0.30),
          width: 1,
        ),
        boxShadow: isDark
            ? null
            : const [
                BoxShadow(
                  color: Color(0x100F172A),
                  blurRadius: 14,
                  offset: Offset(0, 4),
                ),
              ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                CupertinoIcons.qrcode_viewfinder,
                color: usesWindowsAppearance(context)
                    ? winInk(context)
                    : (isDark ? const Color(0xFF5AC8FA) : palette.accent),
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${drive.tvAlias}（${drive.providerName}）扫码登录',
                  style: TextStyle(
                    color: settingsInk(context),
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              GestureDetector(
                onTap: () {
                  setState(_cancelQr);
                },
                child: Text(
                  '收起',
                  style: TextStyle(
                    color: usesWindowsAppearance(context)
                        ? winInk(context)
                        : (isDark ? const Color(0xFF5AC8FA) : palette.accent),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 14),
          Container(
            width: 196,
            height: 196,
            padding: EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: Color(0x55000000),
                  blurRadius: 18,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: _loadingQr
                ? Center(child: CupertinoActivityIndicator(radius: 14))
                : qrData.isEmpty
                    ? Center(
                        child: Icon(
                          CupertinoIcons.exclamationmark_circle,
                          color: Colors.black54,
                          size: 36,
                        ),
                      )
                    : LocalQrCode(data: qrData),
          ),
          SizedBox(height: 12),
          Text(
            _qrStatusText,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: settingsMuted(context),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              AppleCapsuleButton(
                key: ValueKey('netdisk-confirm-${drive.key}'),
                icon: CupertinoIcons.checkmark_seal,
                label: '检查登录状态',
                primary: true,
                compact: true,
                onPressed: () {
                  final session = _qrSession;
                  if (session == null) return;
                  if (_pollingAttempt != null) {
                    _resumedImmediateRetry = true;
                    _service.abortBaiduLongPoll();
                  } else {
                    _pollQr(_qrAttempt, session);
                  }
                },
              ),
              AppleCapsuleButton(
                icon: CupertinoIcons.arrow_clockwise,
                label: '刷新二维码',
                compact: true,
                useBackdrop: false,
                onPressed: () => _startQrLogin(drive.key),
              ),
              AppleCapsuleButton(
                key: ValueKey('netdisk-jump-${drive.key}'),
                icon: CupertinoIcons.arrow_up_right_square,
                label: '本机跳转授权',
                compact: true,
                useBackdrop: false,
                onPressed: () => _openSameDeviceAuth(drive, qrData),
              ),
              if (drive.key == 'ali')
                AppleCapsuleButton(
                  key: ValueKey('netdisk-ali-scan-app'),
                  icon: CupertinoIcons.viewfinder,
                  label: 'App相册扫码',
                  compact: true,
                  useBackdrop: false,
                  onPressed: () => _shareQrAndOpenAliApp(qrData, drive),
                ),
              AppleCapsuleButton(
                icon: CupertinoIcons.square_arrow_up,
                label: '保存/分享二维码',
                compact: true,
                useBackdrop: false,
                onPressed: () => _shareQrImage(qrData, drive),
              ),
              AppleCapsuleButton(
                icon: CupertinoIcons.doc_on_clipboard,
                label: '复制授权链接',
                compact: true,
                useBackdrop: false,
                onPressed: () {
                  if (qrData.isEmpty) return;
                  Clipboard.setData(ClipboardData(text: qrData));
                  setState(() {
                    _qrStatusText = '已复制授权链接，可在浏览器或网盘 App 中打开';
                  });
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDriveTile(NetdiskDriveInfo drive) {
    final loggedIn = widget.storage.isNetdiskLoggedIn(drive.key);
    final isScanning = _activeQrDriveKey == drive.key;
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    final statusGreen = isDark ? const Color(0xFF30D158) : const Color(0xFF169641);

    return Container(
      key: ValueKey('netdisk-tile-${drive.key}'),
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
      decoration: BoxDecoration(
        gradient: isDark
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isScanning
                    ? [
                        const Color(0xFF0A84FF).withValues(alpha: 0.22),
                        const Color(0xFF20222C).withValues(alpha: 0.78),
                      ]
                    : [
                        const Color(0xFF2E2E36).withValues(alpha: 0.68),
                        const Color(0xFF1E1E24).withValues(alpha: 0.68),
                      ],
              )
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isScanning
                    ? const [Color(0xFFEAF3FF), Color(0xFFF6F9FF)]
                    : [palette.groupedPrimary, const Color(0xFFF3F5FA)],
              ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: loggedIn
              ? statusGreen.withValues(alpha: isDark ? 0.48 : 0.34)
              : (isDark
                  ? Colors.white.withValues(alpha: 0.14)
                  : Colors.black.withValues(alpha: 0.075)),
          width: isDark ? 0.7 : 0.85,
        ),
        boxShadow: isDark
            ? null
            : const [
                BoxShadow(
                  color: Color(0x0E0F172A),
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: loggedIn
                      ? statusGreen.withValues(alpha: isDark ? 0.18 : 0.13)
                      : palette.accent.withValues(alpha: isDark ? 0.18 : 0.12),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  loggedIn ? CupertinoIcons.cloud_fill : CupertinoIcons.qrcode,
                  color: loggedIn
                      ? statusGreen
                      : (isDark ? const Color(0xFF5AC8FA) : palette.accent),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          drive.tvAlias,
                          style: TextStyle(
                            color: palette.labelPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            drive.providerName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.labelSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '对应线路：${drive.lineBadges.join(" / ")}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.labelSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8.5,
                  vertical: 3.5,
                ),
                decoration: BoxDecoration(
                  color: loggedIn
                      ? statusGreen.withValues(alpha: isDark ? 0.20 : 0.13)
                      : (isDark
                          ? const Color(0xFF3A3A42).withValues(alpha: 0.65)
                          : palette.fill),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: loggedIn
                        ? statusGreen.withValues(alpha: isDark ? 0.45 : 0.35)
                        : (isDark
                            ? Colors.white.withValues(alpha: 0.14)
                            : Colors.black.withValues(alpha: 0.08)),
                    width: 0.6,
                  ),
                ),
                child: Text(
                  loggedIn ? (drive.key == 'quark' ? '已登录' : '已配置') : '未登录',
                  style: TextStyle(
                    color: loggedIn ? statusGreen : palette.labelSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (drive.key == 'quark' &&
              widget.storage.getNetdiskCred('quark').isNotEmpty) ...[
            const SizedBox(height: 12),
            AppleCapsuleButton(
              key: const ValueKey('quark-browse-files'),
              icon: CupertinoIcons.folder,
              label: '浏览网盘视频',
              compact: true,
              useBackdrop: false,
              onPressed: () {
                setState(_cancelQr);
                showQuarkLibrarySheet(context, widget.storage);
              },
            ),
          ],
          const SizedBox(height: 10),
          Container(height: 0.5, color: palette.separator),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: AppleCapsuleButton(
                  key: ValueKey('netdisk-scan-btn-${drive.key}'),
                  icon: CupertinoIcons.qrcode_viewfinder,
                  label: loggedIn ? '重新扫码' : '扫码登录',
                  primary: !loggedIn,
                  compact: true,
                  useBackdrop: false,
                  onPressed: () => _startQrLogin(drive.key),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AppleCapsuleButton(
                  icon: CupertinoIcons.pencil,
                  label: '手动配置 Token',
                  compact: true,
                  useBackdrop: false,
                  onPressed: () => _showManualInputDialog(drive.key),
                ),
              ),
              if (loggedIn) ...[
                const SizedBox(width: 8),
                AppleCapsuleButton(
                  icon: CupertinoIcons.trash,
                  label: '退出',
                  destructive: true,
                  compact: true,
                  useBackdrop: false,
                  onPressed: () async {
                    setState(_cancelQr);
                    try {
                      await widget.storage.setNetdiskCredential(drive.key, '');
                      widget.onChanged?.call();
                      if (mounted) setState(() {});
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          SnackBar(content: Text('清除凭据失败：$e')),
                        );
                      }
                    }
                  },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
