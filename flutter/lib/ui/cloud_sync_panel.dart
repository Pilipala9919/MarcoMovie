import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart' show Colors;
import 'package:flutter/services.dart';

import '../core/lan_sync_server.dart';
import '../core/storage_service.dart';
import 'apple_theme.dart';
import 'ios_liquid_glass.dart';
import 'ios_settings.dart';
import 'local_qr_code.dart';
import 'windows_appearance.dart';

typedef CloudSyncAppliedCallback = void Function({
  required bool subscriptionsChanged,
});

/// Opens the Multi-Device Cloud & LAN Sync screen/sheet:
/// - On iOS: pushes a full-screen [IosSettingsScaffold] route.
/// - On iPadOS / macOS / Windows: opens an [showAppleModalSheet].
Future<void> showCloudSyncSheet(
  BuildContext context,
  StorageService storage, {
  CloudSyncAppliedCallback? onSynced,
  void Function(String title, String message)? onNotice,
  String iosBackLabel = '返回',
}) async {
  if (usesWindowsAppearance(context)) {
    await Navigator.of(context).push<void>(buildApplePageRoute<void>(
        builder: (_) => WinSettingsScaffold(
            title: '多端网络同步',
            subtitle: '通过 WebDAV 或局域网同步收藏、观看进度与内容来源。',
            child: CloudSyncSettingsPanel(
                storage: storage, onSynced: onSynced, onNotice: onNotice))));
    return;
  }
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    await Navigator.of(context).push<void>(
      buildApplePageRoute<void>(
        builder: (_) => IosSettingsScaffold(
          title: '多端网络同步',
          backLabel: iosBackLabel,
          body: CloudSyncSettingsPanel(
            storage: storage,
            embeddedInList: false,
            onSynced: onSynced,
            onNotice: onNotice,
          ),
        ),
      ),
    );
    return;
  }
  await showAppleModalSheet<void>(
    context: context,
    title: '多端网络同步 · WebDAV 与局域网',
    maxWidth: 620,
    builder: (_) => CloudSyncSettingsPanel(
      storage: storage,
      embeddedInList: false,
      onSynced: onSynced,
      onNotice: onNotice,
    ),
  );
}

class CloudSyncSettingsPanel extends StatefulWidget {
  final StorageService storage;
  final bool embeddedInList;
  final CloudSyncAppliedCallback? onSynced;
  final void Function(String title, String message)? onNotice;

  const CloudSyncSettingsPanel({
    super.key,
    required this.storage,
    this.embeddedInList = true,
    this.onSynced,
    this.onNotice,
  });

  static bool isCleartextHttpWithPassword(String url, String password) {
    final trimmed = url.trim().toLowerCase();
    return trimmed.startsWith('http://') && password.isNotEmpty;
  }

  static bool shouldPromptCleartextHttpWarning({
    required String url,
    required String password,
    required String savedUrl,
    required String savedPassword,
  }) {
    if (!isCleartextHttpWithPassword(url, password)) {
      return false;
    }
    return url.trim() != savedUrl.trim() || password != savedPassword;
  }

  @override
  State<CloudSyncSettingsPanel> createState() => _CloudSyncSettingsPanelState();
}

class _CloudSyncSettingsPanelState extends State<CloudSyncSettingsPanel> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _passCtrl;
  late final TextEditingController _lanPeerCtrl;

  String _confirmedUrl = '';
  String _confirmedPass = '';

  bool _autoSync = true;
  bool _syncSubs = true;
  bool _syncHistory = true;
  bool _obscurePass = true;
  bool _syncingWebdav = false;
  bool _syncingLan = false;
  bool _startingLanServer = false;
  String? _feedbackMessage;
  bool _feedbackIsError = false;

  LanSyncServer? _lanServer;
  List<String> _lanHosts = const [];
  int _selectedLanHostIndex = 0;

  @override
  void initState() {
    super.initState();
    final initialUrl = widget.storage.webdavUrl;
    final initialPass = widget.storage.webdavPass;
    _urlCtrl = TextEditingController(text: initialUrl);
    _userCtrl = TextEditingController(text: widget.storage.webdavUser);
    _passCtrl = TextEditingController(text: initialPass);
    _lanPeerCtrl = TextEditingController();
    _confirmedUrl = initialUrl.trim();
    _confirmedPass = initialPass;
    _autoSync = widget.storage.webdavAuto;
    _syncSubs = widget.storage.webdavSyncSubs;
    _syncHistory = widget.storage.webdavSyncHistory;
  }

  @override
  void dispose() {
    final server = _lanServer;
    _lanServer = null;
    if (server != null) {
      unawaited(server.close());
    }
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _lanPeerCtrl.dispose();
    super.dispose();
  }

  void _notifyNotice(String title, String message, {bool isError = false}) {
    if (mounted) {
      setState(() {
        _feedbackMessage = message;
        _feedbackIsError = isError;
      });
    }
    if (widget.onNotice != null) {
      widget.onNotice!(title, message);
    }
  }

  Future<void> _saveWebdavFields() async {
    final nextUrl = _urlCtrl.text.trim();
    final nextPass = _passCtrl.text;
    await widget.storage.saveWebdavConfig(
      url: nextUrl,
      user: _userCtrl.text.trim(),
      pass: nextPass,
      auto: _autoSync,
      syncSubs: _syncSubs,
      syncHistory: _syncHistory,
    );
    _confirmedUrl = nextUrl;
    _confirmedPass = nextPass;
  }

  bool get _needsCleartextHttpWarning =>
      CloudSyncSettingsPanel.shouldPromptCleartextHttpWarning(
        url: _urlCtrl.text,
        password: _passCtrl.text,
        savedUrl: _confirmedUrl,
        savedPassword: _confirmedPass,
      );

  Future<bool> _confirmCleartextHttpWarning() async {
    final choice = await showAppleNativeAlert(
      context,
      title: '明文传输风险提示',
      message:
          '您配置的 WebDAV 服务使用未加密的 HTTP 协议（http://），在此模式下账号与应用密码将以明文在网络中传输，可能存在凭据泄露风险。建议使用 HTTPS 协议。\n\n是否确认继续保存？',
      actions: const [
        AppleNativeAlertAction(id: 'cancel', title: '取消', isCancel: true),
        AppleNativeAlertAction(
          id: 'confirm',
          title: '已知晓风险，继续保存',
          isDestructive: true,
        ),
      ],
    );
    return choice == 'confirm';
  }

  Future<void> _handleSaveAndWebdavSync() async {
    if (_syncingWebdav) return;
    final trimmedUrl = _urlCtrl.text.trim();
    if (trimmedUrl.isEmpty) {
      _notifyNotice('请填写地址', '请先填写 WebDAV 服务器目录或文件地址。', isError: true);
      return;
    }
    if (_needsCleartextHttpWarning) {
      final ok = await _confirmCleartextHttpWarning();
      if (!ok) return;
    }
    setState(() {
      _syncingWebdav = true;
      _feedbackMessage = null;
    });
    try {
      await _saveWebdavFields();
      final res = await widget.storage.syncWithWebdav();
      widget.onSynced?.call(subscriptionsChanged: res.subscriptionsChanged);
      final subPart = _syncSubs ? ' · 订阅 ${res.subscriptionCount} 个' : '';
      _notifyNotice(
        'WebDAV 同步完成',
        '已合并观看历史 ${res.historyCount} 条 · 收藏 ${res.favoriteCount} 部$subPart。',
      );
    } catch (e) {
      final msg = e is FormatException ? e.message : e.toString();
      _notifyNotice('WebDAV 同步未完成', msg, isError: true);
    } finally {
      if (mounted) {
        setState(() => _syncingWebdav = false);
      }
    }
  }

  Future<void> _handleSaveOnly() async {
    if (_needsCleartextHttpWarning) {
      final ok = await _confirmCleartextHttpWarning();
      if (!ok) return;
    }
    try {
      await _saveWebdavFields();
      widget.onSynced?.call(subscriptionsChanged: false);
      _notifyNotice('已保存配置', 'WebDAV 同步配置与同步范围已保存。');
    } catch (e) {
      final msg = e is FormatException ? e.message : e.toString();
      _notifyNotice('保存配置失败', msg, isError: true);
    }
  }

  Future<void> _handleClearWebdav() async {
    try {
      await widget.storage.saveWebdavConfig(
        url: '',
        user: '',
        pass: '',
        auto: _autoSync,
        syncSubs: _syncSubs,
      );
      _urlCtrl.clear();
      _userCtrl.clear();
      _passCtrl.clear();
      _confirmedUrl = '';
      _confirmedPass = '';
      widget.onSynced?.call(subscriptionsChanged: false);
      _notifyNotice('已清空配置', '已移除本机保存的 WebDAV 地址与凭据。');
    } catch (e) {
      final msg = e is FormatException ? e.message : e.toString();
      _notifyNotice('清空配置失败', msg, isError: true);
    }
  }

  Future<void> _toggleLanReceiver() async {
    if (_startingLanServer) return;
    final existing = _lanServer;
    if (existing != null && !existing.isExpired) {
      await existing.close();
      if (mounted) {
        setState(() {
          _lanServer = null;
          _lanHosts = const [];
        });
      }
      return;
    }
    setState(() {
      _startingLanServer = true;
      _feedbackMessage = null;
    });
    try {
      await existing?.close();
      final hosts = await LanSyncServer.discoverLanAddresses();
      final server = await LanSyncServer.start(
        widget.storage,
        onSynced: ({
          required historyCount,
          required favoriteCount,
          required subscriptionCount,
          required changed,
          required subscriptionsChanged,
        }) {
          if (!mounted) return;
          widget.onSynced?.call(subscriptionsChanged: subscriptionsChanged);
          final subPart = _syncSubs ? ' · 订阅 $subscriptionCount 个' : '';
          setState(() {
            _feedbackIsError = false;
            _feedbackMessage =
                '局域网设备已完成双向同步（历史 $historyCount · 收藏 $favoriteCount$subPart）';
          });
        },
      );
      if (!mounted) {
        await server.close();
        return;
      }
      setState(() {
        _lanServer = server;
        _lanHosts = hosts.isNotEmpty ? hosts : const ['127.0.0.1'];
        _selectedLanHostIndex = 0;
      });
    } catch (e) {
      _notifyNotice('无法开启接收服务', '本机局域网同步端口启动失败：$e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _startingLanServer = false);
      }
    }
  }

  Future<void> _handleLanPeerSync() async {
    if (_syncingLan) return;
    final peerInput = _lanPeerCtrl.text.trim();
    if (peerInput.isEmpty) {
      _notifyNotice('请填写局域网地址', '请输入或粘贴另一台设备上显示的局域网同步地址。', isError: true);
      return;
    }
    setState(() {
      _syncingLan = true;
      _feedbackMessage = null;
    });
    try {
      final res = await widget.storage.syncWithLanPeer(peerInput);
      widget.onSynced?.call(subscriptionsChanged: res.subscriptionsChanged);
      final subPart = _syncSubs ? ' · 订阅 ${res.subscriptionCount} 个' : '';
      _notifyNotice(
        '局域网同步完成',
        '已双向合并观看历史 ${res.historyCount} 条 · 收藏 ${res.favoriteCount} 部$subPart。',
      );
    } catch (e) {
      final msg = e is FormatException ? e.message : e.toString();
      _notifyNotice('局域网同步未完成', msg, isError: true);
    } finally {
      if (mounted) {
        setState(() => _syncingLan = false);
      }
    }
  }

  Widget _buildFieldRow({
    required String label,
    required Widget field,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: settingsMuted(context),
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          field,
        ],
      ),
    );
  }

  Widget _styledTextField({
    Key? fieldKey,
    required TextEditingController controller,
    required String placeholder,
    bool obscureText = false,
    Widget? suffix,
    TextInputType? keyboardType,
  }) {
    return TextSelectionMouseGuard(
      child: CupertinoTextField(
        key: fieldKey,
        controller: controller,
        placeholder: placeholder,
        obscureText: obscureText,
        keyboardType: keyboardType,
        autocorrect: false,
        enableSuggestions: false,
        smartQuotesType: SmartQuotesType.disabled,
        smartDashesType: SmartDashesType.disabled,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        placeholderStyle: TextStyle(
          color: settingsMuted(context),
          fontSize: 14,
        ),
        style: TextStyle(
          color: settingsInk(context),
          fontSize: 14.5,
        ),
        suffix: suffix,
        decoration: BoxDecoration(
          color: usesWindowsAppearance(context)
              ? winMuted(context).withValues(alpha: .08)
              : (ApplePalette.isDarkOf(context)
                  ? const Color(0xFF2C2C2E)
                  : ApplePalette.of(context).groupedSecondary),
          borderRadius: BorderRadius.circular(10),
          border: ApplePalette.isDarkOf(context)
              ? null
              : Border.all(
                  color: Colors.black.withValues(alpha: 0.08),
                  width: 0.6,
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeServer =
        (_lanServer != null && !_lanServer!.isExpired) ? _lanServer : null;
    final currentHost = _lanHosts.isNotEmpty
        ? _lanHosts[_selectedLanHostIndex.clamp(0, _lanHosts.length - 1)]
        : '127.0.0.1';
    final receiverUrl = activeServer?.addressForHost(currentHost) ?? '';

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IosSettingsGroup(
          header: '当前同步状态',
          footer: '隐私空间中的私密订阅、隐私站点及私密收藏始终仅保存在本机，绝不上传或通过局域网传输。',
          children: [
            IosSettingsRow(
              icon: CupertinoIcons.cloud_fill,
              iconColor: widget.storage.isWebdavConfigured
                  ? AppleColors.systemBlue
                  : AppleColors.systemTeal,
              title: widget.storage.isWebdavConfigured
                  ? 'WebDAV 云同步已配置'
                  : '支持云端与局域网互通',
              subtitle: widget.storage.syncStatusSummary,
            ),
          ],
        ),
        if (_feedbackMessage != null && _feedbackMessage!.isNotEmpty) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: _feedbackIsError
                  ? const Color(0x28FF453A)
                  : const Color(0x2430D158),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _feedbackIsError
                    ? const Color(0x66FF453A)
                    : const Color(0x6630D158),
                width: 0.6,
              ),
            ),
            child: Text(
              _feedbackMessage!,
              style: TextStyle(
                color: _feedbackIsError
                    ? const Color(0xFFFF6961)
                    : const Color(0xFF30D158),
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),
        IosSettingsGroup(
          header: '同步范围与自动化',
          footer:
              '开启「同时同步我的订阅源配置」后，新手机、平板、电脑或电视连上同一账号或局域网即可一步拉取公开订阅源、观看历史与收藏；关闭时也不会覆盖云端已有订阅。',
          children: [
            IosSettingsSwitchRow(
              key: const ValueKey('sync-switch-auto'),
              icon: CupertinoIcons.arrow_2_circlepath,
              iconColor: AppleColors.systemGreen,
              title: '自动云同步',
              subtitle: '启动时静默拉取最新进度，播放进度、收藏与订阅变更自动同步',
              value: _autoSync,
              onChanged: (v) async {
                final prev = _autoSync;
                setState(() => _autoSync = v);
                try {
                  await widget.storage.saveWebdavConfig(
                    url: _urlCtrl.text.trim(),
                    user: _userCtrl.text.trim(),
                    pass: _passCtrl.text,
                    auto: v,
                    syncSubs: _syncSubs,
                    syncHistory: _syncHistory,
                  );
                  widget.onSynced?.call(subscriptionsChanged: false);
                } catch (e) {
                  if (mounted) {
                    setState(() => _autoSync = prev);
                  }
                  final msg = e is FormatException ? e.message : e.toString();
                  _notifyNotice('保存配置失败', msg, isError: true);
                }
              },
            ),
            IosSettingsSwitchRow(
              key: const ValueKey('sync-switch-subs'),
              icon: CupertinoIcons.layers_alt_fill,
              iconColor: AppleColors.systemPurple,
              title: '同时同步我的订阅源配置',
              subtitle: '同步公开点播/直播订阅源（自动排除隐私分组与本机文件包）',
              value: _syncSubs,
              onChanged: (v) async {
                setState(() => _syncSubs = v);
                await widget.storage.setWebdavSyncSubs(v);
                if (!v && !_syncHistory) {
                  setState(() => _syncHistory = true);
                  await widget.storage.setWebdavSyncHistory(true);
                }
                widget.onSynced?.call(subscriptionsChanged: false);
              },
            ),
            IosSettingsSwitchRow(
              key: const ValueKey('sync-switch-history'),
              icon: CupertinoIcons.clock_fill,
              iconColor: AppleColors.systemBlue,
              title: '同时同步观看历史与收藏',
              subtitle: '关闭后仅同步订阅源配置，方便与家人共享片源但隔离各自观看记录',
              value: _syncHistory,
              onChanged: (v) async {
                setState(() => _syncHistory = v);
                await widget.storage.setWebdavSyncHistory(v);
                if (!v && !_syncSubs) {
                  setState(() => _syncSubs = true);
                  await widget.storage.setWebdavSyncSubs(true);
                }
                widget.onSynced?.call(subscriptionsChanged: false);
              },
            ),
          ],
        ),
        const SizedBox(height: 20),
        IosSettingsGroup(
          header: 'WebDAV 私有云同步（坚果云 / NAS / Alist / Nextcloud）',
          footer: '填写目录地址即可自动读写 marco-movie-sync.json；坚果云等服务请使用「应用专用密码」。',
          dividerIndent: 16,
          children: [
            _buildFieldRow(
              label: '服务器目录或文件地址',
              field: _styledTextField(
                fieldKey: const ValueKey('sync-webdav-url'),
                controller: _urlCtrl,
                placeholder: 'https://dav.example/dav/MarcoMovie/',
                keyboardType: TextInputType.url,
              ),
            ),
            _buildFieldRow(
              label: 'WebDAV 账号',
              field: _styledTextField(
                fieldKey: const ValueKey('sync-webdav-user'),
                controller: _userCtrl,
                placeholder: '用户名或注册邮箱',
              ),
            ),
            _buildFieldRow(
              label: '密码 / 应用专用密码',
              field: _styledTextField(
                fieldKey: const ValueKey('sync-webdav-pass'),
                controller: _passCtrl,
                placeholder: '填写 WebDAV 密码',
                obscureText: _obscurePass,
                suffix: CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(32, 32),
                  onPressed: () => setState(() => _obscurePass = !_obscurePass),
                  child: Icon(
                    _obscurePass
                        ? CupertinoIcons.eye_slash_fill
                        : CupertinoIcons.eye_fill,
                    size: 17,
                    color: settingsMuted(context),
                  ),
                ),
              ),
            ),
            IosSettingsRow(
              key: const ValueKey('sync-webdav-run'),
              icon: CupertinoIcons.cloud_upload_fill,
              iconColor: AppleColors.systemBlue,
              title: _syncingWebdav ? '正在与 WebDAV 云端同步…' : '保存并立即 WebDAV 云同步',
              trailing: _syncingWebdav
                  ? const CupertinoActivityIndicator(radius: 9)
                  : null,
              showChevron: !_syncingWebdav,
              onTap: _syncingWebdav ? null : _handleSaveAndWebdavSync,
            ),
            IosSettingsRow(
              key: const ValueKey('sync-webdav-save-only'),
              title: '仅保存配置',
              titleColor: AppleColors.systemBlue,
              onTap: _syncingWebdav ? null : _handleSaveOnly,
            ),
            if (widget.storage.isWebdavConfigured ||
                _urlCtrl.text.trim().isNotEmpty)
              IosSettingsRow(
                key: const ValueKey('sync-webdav-clear'),
                title: '清空本机 WebDAV 配置',
                titleColor: AppleColors.systemRed,
                onTap: _syncingWebdav ? null : _handleClearWebdav,
              ),
          ],
        ),
        const SizedBox(height: 20),
        IosSettingsGroup(
          header: '局域网设备点对点双向同步（无需网盘账号）',
          footer:
              '同一 Wi-Fi / 局域网下，任一设备开启接收码，另一台设备输入或扫码获取该地址即可直接双向合并进度、收藏与公开订阅源（兼容 Android TV、手机、老电视精简版、iPhone、iPad、Windows 与 Mac）。',
          dividerIndent: 16,
          children: [
            IosSettingsRow(
              key: const ValueKey('sync-lan-toggle-receiver'),
              icon: CupertinoIcons.qrcode_viewfinder,
              iconColor: activeServer != null
                  ? AppleColors.systemOrange
                  : AppleColors.systemTeal,
              title: activeServer != null ? '关闭本机局域网接收码' : '开启本机局域网接收码（5 分钟有效）',
              subtitle: activeServer != null
                  ? '接收服务运行中：$receiverUrl'
                  : '生成本机局域网二维码与同步地址供其他设备连接',
              trailing: _startingLanServer
                  ? const CupertinoActivityIndicator(radius: 9)
                  : null,
              showChevron: !_startingLanServer && activeServer == null,
              onTap: _startingLanServer ? null : _toggleLanReceiver,
            ),
            if (activeServer != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: Column(
                  children: [
                    Container(
                      width: 176,
                      height: 176,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: LocalQrCode(data: receiverUrl),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      receiverUrl,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: ApplePalette.isDarkOf(context)
                            ? AppleColors.systemCyan
                            : AppleColors.systemBlue,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (_lanHosts.length > 1) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        alignment: WrapAlignment.center,
                        children: [
                          for (var i = 0; i < _lanHosts.length; i++)
                            CupertinoButton(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              minimumSize: const Size(0, 28),
                              color: i == _selectedLanHostIndex
                                  ? AppleColors.systemBlue
                                  : (ApplePalette.isDarkOf(context)
                                      ? const Color(0xFF2C2C2E)
                                      : ApplePalette.of(context).fill),
                              borderRadius: BorderRadius.circular(999),
                              onPressed: () =>
                                  setState(() => _selectedLanHostIndex = i),
                              child: Text(
                                _lanHosts[i],
                                style: TextStyle(
                                  color: i == _selectedLanHostIndex
                                      ? Colors.white
                                      : ApplePalette.of(context).labelPrimary,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 10),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      minimumSize: const Size(0, 32),
                      color: ApplePalette.isDarkOf(context)
                          ? const Color(0xFF2C2C2E)
                          : ApplePalette.of(context).fill,
                      borderRadius: BorderRadius.circular(999),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: receiverUrl));
                        _notifyNotice('已复制同步地址', '本机局域网同步地址已复制到剪贴板。');
                      },
                      child: Text(
                        '复制本机同步地址',
                        style: TextStyle(
                          color: settingsInk(context),
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            _buildFieldRow(
              label: '连接局域网其他设备地址',
              field: _styledTextField(
                fieldKey: const ValueKey('sync-lan-peer-input'),
                controller: _lanPeerCtrl,
                placeholder: 'http://…/configure/…',
                keyboardType: TextInputType.url,
                suffix: CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(32, 32),
                  onPressed: () async {
                    final clip = await Clipboard.getData(Clipboard.kTextPlain);
                    final text = (clip?.text ?? '').trim();
                    if (text.isNotEmpty && mounted) {
                      setState(() => _lanPeerCtrl.text = text);
                    }
                  },
                  child: Text(
                    '粘贴',
                    style: TextStyle(
                      color: AppleColors.systemBlue,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
            IosSettingsRow(
              key: const ValueKey('sync-lan-run'),
              icon: CupertinoIcons.arrow_right_arrow_left_circle_fill,
              iconColor: AppleColors.systemGreen,
              title: _syncingLan ? '正在双向同步局域网数据…' : '立即局域网双向同步',
              trailing: _syncingLan
                  ? const CupertinoActivityIndicator(radius: 9)
                  : null,
              showChevron: !_syncingLan,
              onTap: _syncingLan ? null : _handleLanPeerSync,
            ),
          ],
        ),
      ],
    );

    if (widget.embeddedInList) {
      return content;
    }
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    return TextSelectionMouseGuard(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, safeBottom + 28),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: content,
          ),
        ),
      ),
    );
  }
}
