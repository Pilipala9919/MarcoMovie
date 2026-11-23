import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors;
import 'package:flutter/services.dart';
import '../core/cms_client.dart';
import '../core/csp_bridge.dart';
import '../core/models.dart';
import '../core/spider_gateway.dart';
import '../core/spider_plugin_registry.dart';
import '../core/storage_service.dart';
import 'apple_theme.dart';
import 'ios_liquid_glass.dart';
import 'ios_settings.dart';

/// iOS 26 / cross-platform Settings panel for:
/// 1. Hot-pluggable Script Adapter Packs (`marco-adapter-pack-v1`, local JS/DRPY/Python/T4)
/// 2. Optional user-owned BYO Spider Gateway (`marco-spider-gateway-v1`, LAN Android / Docker)
class SpiderExtensionsPanel extends StatefulWidget {
  final StorageService storage;
  final CmsClient client;
  final List<CmsSite> sites;
  final VoidCallback onChanged;
  final void Function(String title, String message)? onNotice;

  const SpiderExtensionsPanel({
    super.key,
    required this.storage,
    required this.client,
    required this.sites,
    required this.onChanged,
    this.onNotice,
  });

  @override
  State<SpiderExtensionsPanel> createState() => _SpiderExtensionsPanelState();
}

class _SpiderExtensionsPanelState extends State<SpiderExtensionsPanel> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _tokenCtrl;
  bool _gatewayEnabled = false;
  bool _tokenObscured = true;
  bool _testingGateway = false;
  bool _discoveringLan = false;
  bool _importingPack = false;
  String? _gatewayStatusText;
  bool? _gatewayStatusOk;

  @override
  void initState() {
    super.initState();
    final cfg = widget.storage.spiderGatewayConfig;
    _gatewayEnabled = cfg.enabled;
    _urlCtrl = TextEditingController(text: cfg.baseUrl);
    _tokenCtrl = TextEditingController(text: cfg.token);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  void _notify(String title, String message) {
    final cb = widget.onNotice;
    if (cb != null) {
      cb(title, message);
      return;
    }
    if (!mounted) return;
    unawaited(
      showAppleNativeAlert(
        context,
        title: title,
        message: message,
        actions: const [
          AppleNativeAlertAction(id: 'ok', title: '好的', isDefault: true),
        ],
      ),
    );
  }

  Future<void> _saveGateway({bool? enabledOverride, String? deviceName}) async {
    final nextEnabled = enabledOverride ?? _gatewayEnabled;
    final rawUrl = _urlCtrl.text.trim();
    if (nextEnabled && SpiderGatewayConfig.normalizeBaseUrl(rawUrl).isEmpty) {
      setState(() {
        _gatewayEnabled = false;
        _gatewayStatusOk = false;
        _gatewayStatusText = '请先填写有效的网关地址后再开启（例如局域网 Android 端或自建 Docker 地址）';
      });
      return;
    }
    try {
      await widget.storage.saveSpiderGatewayConfig(
        SpiderGatewayConfig(
          enabled: nextEnabled,
          baseUrl: rawUrl,
          token: _tokenCtrl.text.trim(),
          deviceName: deviceName ?? widget.storage.spiderGatewayConfig.deviceName,
        ),
      );
      if (!mounted) return;
      final saved = widget.storage.spiderGatewayConfig;
      setState(() {
        _gatewayEnabled = saved.enabled;
        _urlCtrl.text = saved.baseUrl;
        _gatewayStatusOk = true;
        _gatewayStatusText = saved.isActive
            ? '已保存并启用自建网关兜底，仅代理未适配 .so 线路元数据'
            : '已保存配置（当前未启用网关）';
      });
      widget.onChanged();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _gatewayStatusOk = false;
        _gatewayStatusText = CmsClient.cleanErrorMessage(e);
      });
    }
  }

  Future<void> _testGatewayConnection() async {
    final normalized = SpiderGatewayConfig.normalizeBaseUrl(_urlCtrl.text);
    if (normalized.isEmpty) {
      setState(() {
        _gatewayStatusOk = false;
        _gatewayStatusText = '请先填写有效的 HTTP(S) 网关地址';
      });
      return;
    }
    setState(() {
      _testingGateway = true;
      _gatewayStatusText = '正在探测网关健康状态…';
      _gatewayStatusOk = null;
    });
    final res = await SpiderGatewayClient.checkHealth(
      SpiderGatewayConfig(
        enabled: true,
        baseUrl: normalized,
        token: _tokenCtrl.text.trim(),
      ),
    );
    if (!mounted) return;
    setState(() {
      _testingGateway = false;
      _gatewayStatusOk = res.ok;
      _gatewayStatusText = res.message;
    });
    if (res.ok && res.deviceName.isNotEmpty) {
      await _saveGateway(
        enabledOverride: _gatewayEnabled,
        deviceName: res.deviceName,
      );
    }
  }

  Future<void> _discoverLanAndroidGateways() async {
    setState(() {
      _discoveringLan = true;
      _gatewayStatusOk = null;
      _gatewayStatusText = '正在搜索同一局域网内开启网关的 Android 设备…';
    });
    final found = await SpiderGatewayClient.discoverLanGateways();
    if (!mounted) return;
    setState(() => _discoveringLan = false);
    if (found.isEmpty) {
      setState(() {
        _gatewayStatusOk = false;
        _gatewayStatusText =
            '未发现局域网网关。请在 Android 端「设置 → 订阅与账号 → 局域网蜘蛛网关」开启服务，或手动填写地址。';
      });
      return;
    }
    final picked = await showAppleNativeActionSheet<DiscoveredSpiderGateway>(
      context,
      title: '发现 ${found.length} 台局域网蜘蛛网关',
      message: '选择后将自动填入地址；出于安全考虑，仍需输入该设备上显示的访问令牌（Token）。',
      options: [
        for (final g in found)
          AppleNativeSheetOption<DiscoveredSpiderGateway>(
            value: g,
            title: '${g.deviceName} · ${g.baseUrl}',
          ),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _urlCtrl.text = picked.baseUrl;
      _gatewayStatusOk = true;
      _gatewayStatusText = '已填入「${picked.deviceName}」，请输入设备令牌后保存或测试连接';
    });
  }

  Future<void> _openImportPackDialog() async {
    final inputCtrl = TextEditingController();
    String? errorMsg;
    var busy = false;
    final imported = await showAppleModalSheet<SpiderAdapterPack>(
      context: context,
      title: '导入脚本扩展包',
      maxWidth: 560,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          Future<void> submit() async {
            final raw = inputCtrl.text.trim();
            if (raw.isEmpty) {
              setSheetState(() => errorMsg = '请粘贴插件包 JSON 内容或 HTTP(S) 链接');
              return;
            }
            setSheetState(() {
              busy = true;
              errorMsg = null;
            });
            try {
              SpiderAdapterPack pack;
              if (raw.startsWith('{')) {
                pack = await widget.storage.importSpiderAdapterPackJson(raw);
              } else {
                final remote = await widget.client.fetchSpiderAdapterPack(raw);
                final current = List<SpiderAdapterPack>.of(
                  widget.storage.spiderAdapterPacks,
                );
                final idx = current.indexWhere((p) => p.id == remote.id);
                if (idx >= 0) {
                  current[idx] = remote;
                } else {
                  current.insert(0, remote);
                }
                await widget.storage.saveSpiderAdapterPacks(current);
                pack = remote;
              }
              if (ctx.mounted) Navigator.of(ctx).pop(pack);
            } catch (e) {
              if (ctx.mounted) {
                setSheetState(() {
                  busy = false;
                  errorMsg = CmsClient.cleanErrorMessage(e);
                });
              }
            }
          }

          final sheetPalette = ApplePalette.of(ctx);
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              18,
              16,
              18,
              22 + MediaQuery.viewInsetsOf(ctx).bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '支持输入社区 / 自建的 marco-adapter-pack-v1 扩展包链接（https://plugins.example/pack.json）或直接粘贴 JSON，所有脚本均在本机运行，无需任何官方服务器。',
                  style: TextStyle(
                    color: sheetPalette.labelSecondary,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 14),
                CupertinoTextField(
                  key: const ValueKey('spider-pack-import-input'),
                  controller: inputCtrl,
                  maxLines: 6,
                  minLines: 3,
                  autocorrect: false,
                  placeholder: '粘贴插件包 JSON 或 https://plugins.example/pack.json',
                  placeholderStyle: TextStyle(
                    color: sheetPalette.labelTertiary,
                    fontSize: 14.5,
                  ),
                  style: TextStyle(
                    color: sheetPalette.labelPrimary,
                    fontSize: 15,
                  ),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: sheetPalette.isDark
                        ? const Color(0xFF1C1C1E)
                        : const Color(0xFFEDF0F5),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: sheetPalette.separator,
                      width: 0.8,
                    ),
                  ),
                ),
                if (errorMsg != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    errorMsg!,
                    style: const TextStyle(
                      color: AppleColors.systemRed,
                      fontSize: 13.5,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                CupertinoButton.filled(
                  key: const ValueKey('spider-pack-import-submit'),
                  onPressed: busy ? null : submit,
                  child: busy
                      ? const CupertinoActivityIndicator(color: Colors.white)
                      : const Text(
                          '验证并导入扩展包',
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
    inputCtrl.dispose();
    if (imported != null && mounted) {
      setState(() {});
      widget.onChanged();
      _notify(
        '已导入扩展包',
        '「${imported.name}」包含 ${imported.rules.length} 条跨平台适配规则，已立即生效。',
      );
    }
  }

  Future<void> _managePack(SpiderAdapterPack pack) async {
    final ruleSummary = pack.rules
        .take(5)
        .map(
          (r) =>
              '• ${r.matchApis.isNotEmpty ? r.matchApis.join(", ") : r.matchNamePattern} → ${r.kind.displayName}',
        )
        .join('\n');
    final extra = pack.rules.length > 5
        ? '\n…等共 ${pack.rules.length} 条规则'
        : '';
    final choice = await showAppleNativeAlert(
      context,
      title: '${pack.name} (${pack.version})',
      message:
          '${pack.description.isNotEmpty ? '${pack.description}\n\n' : ''}$ruleSummary$extra',
      actions: [
        if (pack.sourceUrl.isNotEmpty)
          const AppleNativeAlertAction(id: 'refresh', title: '从链接更新'),
        const AppleNativeAlertAction(
          id: 'delete',
          title: '移除扩展包',
          isDestructive: true,
        ),
        const AppleNativeAlertAction(id: 'ok', title: '关闭', isDefault: true),
      ],
    );
    if (!mounted || choice == null) return;
    if (choice == 'delete') {
      await widget.storage.removeSpiderAdapterPack(pack.id);
      if (mounted) setState(() {});
      widget.onChanged();
    } else if (choice == 'refresh' && pack.sourceUrl.isNotEmpty) {
      setState(() => _importingPack = true);
      try {
        final refreshed = await widget.client.fetchSpiderAdapterPack(
          pack.sourceUrl,
        );
        final updated = widget.storage.spiderAdapterPacks
            .map((p) => p.id == pack.id ? refreshed.copyWith(id: pack.id) : p)
            .toList();
        await widget.storage.saveSpiderAdapterPacks(updated);
        if (mounted) {
          setState(() {});
          widget.onChanged();
          _notify('已更新扩展包', '「${refreshed.name}」已更新至 ${refreshed.version}。');
        }
      } catch (e) {
        if (mounted) {
          _notify('更新失败', CmsClient.cleanErrorMessage(e));
        }
      } finally {
        if (mounted) setState(() => _importingPack = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.sites
        .where((s) => !CspBridge.isPickerHiddenUtilitySite(s))
        .toList();
    var nativeCount = 0;
    var packCount = 0;
    var gatewayCount = 0;
    var unsupportedCount = 0;
    for (final s in visible) {
      if (s.usesAdapterPack) {
        packCount++;
      } else if (s.usesSpiderGateway) {
        gatewayCount++;
      } else if (s.supported) {
        nativeCount++;
      } else {
        unsupportedCount++;
      }
    }
    final packs = widget.storage.spiderAdapterPacks;
    final hasGatewayUrl =
        SpiderGatewayConfig.normalizeBaseUrl(_urlCtrl.text).isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 0. Built-in Beginner Tutorial Entry (always visible at top)
        IosSettingsGroup(
          header: '新手必看',
          footer: '不确定怎么配置？建议先点开上面的图文教程，30 秒就能明白怎么免费解锁更多线路。',
          children: [
            IosSettingsRow(
              key: const ValueKey('spider-open-guide-row'),
              icon: CupertinoIcons.book_fill,
              iconColor: AppleColors.systemOrange,
              title: '使用教程与常见疑问',
              subtitle: '大白话讲清 .so 线路、脚本扩展包导入与自建网关步骤',
              trailingText: '图文指南',
              showChevron: true,
              onTap: () => Navigator.of(context).push<void>(
                buildApplePageRoute<void>(
                  builder: (_) => SpiderExtensionsGuidePage(
                    onNotice: _notify,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),

        // 1. Live Coverage Summary (Local-First priority)
        IosSettingsGroup(
          header: '当前片源可用情况（本机优先）',
          footer:
              '自动优先级：本机内置适配 → 脚本扩展包（本机运行）→ 您自建的网关。本机已能播放的线路绝不经过外部网关。',
          children: [
            IosSettingsRow(
              icon: CupertinoIcons.checkmark_shield_fill,
              iconColor: AppleColors.systemGreen,
              title: '本机原生已适配',
              trailingText: '$nativeCount 条',
            ),
            IosSettingsRow(
              icon: CupertinoIcons.cube_box_fill,
              iconColor: AppleColors.systemPurple,
              title: '扩展插件包接管',
              trailingText: '$packCount 条',
            ),
            IosSettingsRow(
              icon: CupertinoIcons.antenna_radiowaves_left_right,
              iconColor: AppleColors.systemTeal,
              title: '自建网关兜底接管',
              trailingText: '$gatewayCount 条',
            ),
            IosSettingsRow(
              icon: CupertinoIcons.exclamationmark_triangle_fill,
              iconColor: unsupportedCount > 0
                  ? AppleColors.systemOrange
                  : const Color(0xFF636366),
              title: '暂未适配（含 .so 依赖）',
              trailingText: '$unsupportedCount 条',
            ),
          ],
        ),
        const SizedBox(height: 22),

        // 2. Short-Term Solution: Hot-Pluggable Script Adapter Packs
        IosSettingsGroup(
          header: '方案一：脚本扩展包（免更新 · 纯本机免费运行）',
          footer:
              '适合绝大多数用户：把社区或他人分享的扩展包链接（.json）或文本粘贴进来，不用重新安装 App 就能解锁更多线路，无需任何服务器。',
          children: [
            for (final pack in packs)
              IosSettingsRow(
                key: ValueKey('spider-pack-row-${pack.id}'),
                icon: CupertinoIcons.cube_box_fill,
                iconColor: pack.enabled
                    ? AppleColors.systemPurple
                    : const Color(0xFF636366),
                title: pack.name,
                subtitle: '${pack.rules.length} 条规则 · v${pack.version}',
                trailing: IosNativeSwitch(
                  value: pack.enabled,
                  activeColor: AppleColors.systemGreen,
                  accessibilityLabel: '启用 ${pack.name}',
                  onChanged: (v) async {
                    await widget.storage.setSpiderAdapterPackEnabled(
                      pack.id,
                      v,
                    );
                    if (mounted) setState(() {});
                    widget.onChanged();
                  },
                ),
                onTap: () => _managePack(pack),
              ),
            IosSettingsRow(
              key: const ValueKey('spider-import-pack-row'),
              icon: CupertinoIcons.plus_circle_fill,
              iconColor: AppleColors.systemBlue,
              title: _importingPack ? '正在更新扩展包…' : '导入脚本扩展包（粘贴链接或 JSON）',
              showChevron: true,
              onTap: _importingPack ? null : _openImportPackDialog,
            ),
            IosSettingsRow(
              key: const ValueKey('spider-copy-template-row'),
              icon: CupertinoIcons.doc_on_doc_fill,
              iconColor: AppleColors.systemIndigo,
              title: '复制扩展包 JSON 模板',
              trailingText: '进阶自制',
              onTap: () async {
                await Clipboard.setData(
                  ClipboardData(
                    text: SpiderPluginRegistry.samplePackTemplateJson(),
                  ),
                );
                _notify(
                  '已复制模板',
                  '已复制扩展包 JSON 模板到剪贴板；不确定怎么写可点顶部「使用教程与常见疑问」复制 AI 帮写提示词。',
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 22),

        // 3. Mid-Term Solution: Optional BYO Spider Gateway (Zero Author Server)
        IosSettingsGroup(
          header: '方案二：自建蜘蛛网关（进阶可选 · 零官方服务器）',
          footer:
              '默认关闭，普通用户无需开启。家有电脑 / NAS / Docker 时可在自己设备上运行网关来兜底安卓 .so 线路；只传几 KB 目录，视频画面仍由本机直连播放。',
          children: [
            IosSettingsSwitchRow(
              key: const ValueKey('spider-gateway-switch'),
              icon: CupertinoIcons.personalhotspot,
              iconColor: AppleColors.systemTeal,
              title: '启用自建蜘蛛网关兜底',
              subtitle: _gatewayEnabled
                  ? (widget.storage.spiderGatewayConfig.deviceName.isNotEmpty
                      ? '当前连接：${widget.storage.spiderGatewayConfig.deviceName}'
                      : '仅接管本机与扩展包均未适配的 .so 线路')
                  : '关闭状态，所有请求均在本地完成',
              value: _gatewayEnabled,
              onChanged: (v) async {
                setState(() => _gatewayEnabled = v);
                await _saveGateway(enabledOverride: v);
              },
            ),
            Builder(
              builder: (fieldCtx) {
                final fp = ApplePalette.of(fieldCtx);
                final fieldBg = fp.isDark
                    ? const Color(0xFF2C2C2E)
                    : const Color(0xFFEDF0F5);
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '网关地址（局域网 Android 端或自建 Docker）',
                        style: TextStyle(
                          color: fp.labelSecondary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      CupertinoTextField(
                        key: const ValueKey('spider-gateway-url-input'),
                        controller: _urlCtrl,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        placeholder:
                            '例如 http://127.0.0.1:9981 或 https://gateway.example',
                        placeholderStyle: TextStyle(
                          color: fp.labelTertiary,
                          fontSize: 14.5,
                        ),
                        style: TextStyle(
                          color: fp.labelPrimary,
                          fontSize: 15.5,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: fieldBg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: fp.separator,
                            width: 0.8,
                          ),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '访问令牌（Bearer Token，仅保存在本机安全存储）',
                        style: TextStyle(
                          color: fp.labelSecondary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      CupertinoTextField(
                        key: const ValueKey('spider-gateway-token-input'),
                        controller: _tokenCtrl,
                        obscureText: _tokenObscured,
                        autocorrect: false,
                        placeholder: '输入 Android 端或自建服务显示的令牌',
                        placeholderStyle: TextStyle(
                          color: fp.labelTertiary,
                          fontSize: 14.5,
                        ),
                        style: TextStyle(
                          color: fp.labelPrimary,
                          fontSize: 15.5,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        suffix: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () =>
                              setState(() => _tokenObscured = !_tokenObscured),
                          child: Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: Icon(
                              _tokenObscured
                                  ? CupertinoIcons.eye
                                  : CupertinoIcons.eye_slash,
                              size: 19,
                              color: fp.labelSecondary,
                            ),
                          ),
                        ),
                        decoration: BoxDecoration(
                          color: fieldBg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: fp.separator,
                            width: 0.8,
                          ),
                        ),
                      ),
                      if (_gatewayStatusText != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _gatewayStatusText!,
                          style: TextStyle(
                            color: _gatewayStatusOk == true
                                ? AppleColors.systemGreen
                                : (_gatewayStatusOk == false
                                    ? AppleColors.systemOrange
                                    : fp.labelSecondary),
                            fontSize: 13.5,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
            IosSettingsRow(
              key: const ValueKey('spider-gateway-discover-btn'),
              icon: CupertinoIcons.wifi,
              iconColor: AppleColors.systemBlue,
              title: _discoveringLan ? '正在搜索局域网 Android 端…' : '局域网发现 Android 端',
              trailing: _discoveringLan
                  ? const CupertinoActivityIndicator(radius: 9)
                  : null,
              showChevron: !_discoveringLan,
              onTap: _discoveringLan ? null : _discoverLanAndroidGateways,
            ),
            IosSettingsRow(
              key: const ValueKey('spider-gateway-test-btn'),
              icon: CupertinoIcons.bolt_horizontal_circle_fill,
              iconColor: hasGatewayUrl
                  ? AppleColors.systemGreen
                  : const Color(0xFF636366),
              title: _testingGateway ? '正在测试网关连通性…' : '测试网关连接',
              trailing: _testingGateway
                  ? const CupertinoActivityIndicator(radius: 9)
                  : null,
              showChevron: !_testingGateway,
              onTap: _testingGateway ? null : _testGatewayConnection,
            ),
            IosSettingsRow(
              key: const ValueKey('spider-gateway-save-btn'),
              title: '保存网关配置',
              titleColor: AppleColors.systemBlue,
              onTap: () => _saveGateway(),
            ),
          ],
        ),
      ],
    );
  }
}

/// Built-in plain-Chinese interactive guide explaining `.so` routes,
/// hot-pluggable Script Adapter Packs, and optional BYO self-hosted Spider Gateway.
class SpiderExtensionsGuidePage extends StatelessWidget {
  final void Function(String title, String message) onNotice;

  const SpiderExtensionsGuidePage({
    super.key,
    required this.onNotice,
  });

  static const String _aiPromptTemplate =
      '请帮我把下面这个片源接口或脚本改写为 Marco Movie 支持的跨平台热插拔扩展包 JSON（协议版本 marco-adapter-pack-v1）。\n'
      '要求：\n'
      '1. 根节点包含 schema("marco-adapter-pack-v1")、id、name、version、description、rules 数组；\n'
      '2. 每条 rule 包含 id、matchApis（例如 ["csp_目标接口名"]，支持末尾 * 通配）、kind（可选 js / drpy / python / t4）、以及 scriptUrl（https:// 链接）或 inlineScript（纯脚本文本）；\n'
      '3. 只输出合法的纯 JSON，方便我直接复制并粘贴进 Marco Movie 的「设置 → 蜘蛛扩展与网关 → 导入脚本扩展包」。\n\n'
      '我要适配的源信息如下：\n'
      '（把你想适配的 csp_* 名称或脚本/接口粘贴在这里）';

  static const String _pythonStartCommand =
      'cd gateway\n'
      'MARCO_GATEWAY_TOKEN="请替换成你自己的随机密码" python3 spider_gateway_server.py';

  static const String _dockerComposeTemplate =
      'services:\n'
      '  marco-spider-gateway:\n'
      '    build: .\n'
      '    restart: unless-stopped\n'
      '    ports:\n'
      '      - "9981:9981/tcp"\n'
      '      - "41978:41978/udp"\n'
      '    environment:\n'
      '      MARCO_GATEWAY_NAME: "家庭 NAS 蜘蛛网关"\n'
      '      MARCO_GATEWAY_TOKEN: "请替换成你自己的随机密码"\n'
      '      MARCO_GATEWAY_ROUTES: "/config/routes.json"\n'
      '    volumes:\n'
      '      - ./routes.json:/config/routes.json:ro';

  Widget _buildTextBlock(String text) {
    return Builder(
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Text(
          text,
          style: TextStyle(
            color: ApplePalette.of(context).labelPrimary,
            fontSize: 15.5,
            height: 1.6,
          ),
        ),
      ),
    );
  }

  Widget _buildStepRow({
    required String step,
    required Color color,
    required String title,
    required String detail,
  }) {
    return Builder(
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 28,
              height: 28,
              margin: const EdgeInsets.only(top: 1),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(8.5),
              ),
              alignment: Alignment.center,
              child: Text(
                step,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: ApplePalette.of(context).labelPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    detail,
                    style: TextStyle(
                      color: ApplePalette.of(context).labelSecondary,
                      fontSize: 14.5,
                      height: 1.55,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFaqRow({required String question, required String answer}) {
    return Builder(
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Q：$question',
              style: TextStyle(
                color: ApplePalette.of(context).labelPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'A：$answer',
              style: TextStyle(
                color: ApplePalette.of(context).labelSecondary,
                fontSize: 14.5,
                height: 1.55,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copyAndNotify(String text, String title, String msg) async {
    await Clipboard.setData(ClipboardData(text: text));
    onNotice(title, msg);
  }

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final hPad = screenWidth >= 600 ? 24.0 : 16.0;

    return IosSettingsScaffold(
      title: '使用教程与帮助',
      backLabel: '蜘蛛扩展与网关',
      body: ListView(
        key: const ValueKey('spider-extensions-guide-page'),
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        padding: EdgeInsets.fromLTRB(hPad, 18, hPad, safeBottom + 40),
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 740),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 1. Plain-Chinese Overview
                  IosSettingsGroup(
                    header: '一、为什么有些线路显示「.so 暂不支持」？',
                    dividerIndent: 16,
                    children: [
                      _buildTextBlock(
                        '市面上很多安卓影视源把解码/加密代码打包在安卓专用的 .so 二进制文件里。苹果 iOS、macOS、Windows 和鸿蒙系统底层不能直接运行安卓 .so，所以这类线路默认会显示「未适配」。\n\n'
                        '好消息是：绝大部分主流片源和 4K 网盘（夸克/UC/百度/阿里）Marco Movie 已经内置跨平台适配，打开就能直接看；只有少数仍依赖安卓 .so 的小众线路，才需要用到本页功能。',
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),

                  // 2. Which option should I pick?
                  IosSettingsGroup(
                    header: '二、我应该选哪种方式？（三选一速查）',
                    dividerIndent: 54,
                    children: [
                      _buildStepRow(
                        step: '省',
                        color: AppleColors.systemGreen,
                        title: '普通用户最省心（0 配置 · 推荐）',
                        detail:
                            '完全不用管本页任何设置！去「切换片源」打开「仅看可用」或点一次「一键隐藏全部未适配」，本机自带的 100+ 线路已经足够看全网绝大多数影视。',
                      ),
                      _buildStepRow(
                        step: '一',
                        color: AppleColors.systemPurple,
                        title: '方案一：脚本扩展包（免更新 App · 纯本地免费）',
                        detail:
                            '当你拿到别人或社区分享的跨平台脚本包（一个 .json 链接或一段文本）时，直接粘贴导入，无需电脑、无需服务器、不用重装 App 即可解锁对应线路。',
                      ),
                      _buildStepRow(
                        step: '二',
                        color: AppleColors.systemTeal,
                        title: '方案二：自建蜘蛛网关（进阶 · 连你自己的设备）',
                        detail:
                            '如果你家里本来就有电脑、NAS 或 Docker，可以把网关装在自己设备上兜底剩余的 .so 线路。完全不经过作者服务器，视频画面也仍由 iPhone 直接拉取播放。',
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),

                  // 3. Step-by-step: Script Adapter Pack
                  IosSettingsGroup(
                    header: '三、手把手教程 ①：怎么用「脚本扩展包」？',
                    footer:
                        '扩展包本质是一个轻量 JSON 清单，告诉 App：「遇到某个 csp_* 线路时，改用纯本地 JS / DRPY2 / Python / T4 脚本来解析」，全平台通用。',
                    dividerIndent: 54,
                    children: [
                      _buildStepRow(
                        step: '1',
                        color: AppleColors.systemPurple,
                        title: '准备好扩展包链接或 JSON 文本',
                        detail:
                            '可以是社区分享的 https://plugins.example/pack.json 链接，也可以是一段以 { 开头的 JSON 文本。',
                      ),
                      _buildStepRow(
                        step: '2',
                        color: AppleColors.systemPurple,
                        title: '返回上一页并粘贴导入',
                        detail:
                            '点「导入脚本扩展包（粘贴链接或 JSON）」，把内容粘进输入框后点「验证并导入」，App 会自动检查格式安全性并保存。',
                      ),
                      _buildStepRow(
                        step: '3',
                        color: AppleColors.systemPurple,
                        title: '回到首页直接播放',
                        detail:
                            '保持列表中扩展包右侧开关为绿色开启状态；进入「切换片源」后会发现原未适配线路已变成紫色的「扩展插件」标签，直接点击即可正常浏览与播放。',
                      ),
                      IosSettingsRow(
                        key: const ValueKey('spider-guide-copy-ai-prompt'),
                        icon: CupertinoIcons.sparkles,
                        iconColor: AppleColors.systemPurple,
                        title: '复制「让 AI 帮我写扩展包」提示词',
                        subtitle: '不会写代码也能把规则发给 AI 一键生成可导入的 JSON',
                        onTap: () => _copyAndNotify(
                          _aiPromptTemplate,
                          '已复制 AI 提示词',
                          '把剪贴板里的提示词连同目标线路信息发给任意 AI，拿到生成的 JSON 后回到上一页直接粘贴导入即可。',
                        ),
                      ),
                      IosSettingsRow(
                        key: const ValueKey('spider-guide-copy-template'),
                        icon: CupertinoIcons.doc_on_doc_fill,
                        iconColor: AppleColors.systemIndigo,
                        title: '复制标准扩展包 JSON 模板',
                        subtitle: '包含 JS 与 T4 示例规则，适合自行修改测试',
                        onTap: () => _copyAndNotify(
                          SpiderPluginRegistry.samplePackTemplateJson(),
                          '已复制 JSON 模板',
                          '已复制 marco-adapter-pack-v1 标准模板到剪贴板。',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),

                  // 4. Step-by-step: Self-Hosted Spider Gateway
                  IosSettingsGroup(
                    header: '四、手把手教程 ②：怎么用「自建蜘蛛网关」？',
                    footer:
                        '再次提醒：自建网关默认关闭，完全属于进阶可选项；不配置也不会影响本机任何已适配线路的正常使用。',
                    dividerIndent: 54,
                    children: [
                      _buildStepRow(
                        step: '1',
                        color: AppleColors.systemTeal,
                        title: '在自己的电脑 / NAS 上启动网关',
                        detail:
                            '运行仓库 gateway 目录自带的 Python 脚本或 Docker 容器，启动后会显示端口（默认 9981）和访问令牌（Token）。',
                      ),
                      _buildStepRow(
                        step: '2',
                        color: AppleColors.systemTeal,
                        title: '让手机自动发现或手动填地址',
                        detail:
                            '确保手机与电脑/NAS 在同一 Wi-Fi，回到上一页点「局域网发现」自动填入，或手动填写 http://127.0.0.1:9981（把 127.0.0.1 换成你设备的局域网 IP）。',
                      ),
                      _buildStepRow(
                        step: '3',
                        color: AppleColors.systemTeal,
                        title: '填入访问令牌并测试连接',
                        detail:
                            '把第 1 步生成的令牌填入「访问令牌」输入框（会自动加密保存在本机），点击「测试网关连接」看到绿色「已连接」提示。',
                      ),
                      _buildStepRow(
                        step: '4',
                        color: AppleColors.systemTeal,
                        title: '打开「启用自建蜘蛛网关兜底」开关',
                        detail:
                            '开启后回到「切换片源」，原本灰色的 .so 线路会自动显示青色的「网关代理」标签并可直接搜索与播放。',
                      ),
                      IosSettingsRow(
                        key: const ValueKey('spider-guide-copy-py-cmd'),
                        icon: CupertinoIcons.command,
                        iconColor: AppleColors.systemBlue,
                        title: '复制 Python 一键启动命令',
                        subtitle: '零第三方依赖，电脑 / NAS 装有 Python 3 即可运行',
                        onTap: () => _copyAndNotify(
                          _pythonStartCommand,
                          '已复制启动命令',
                          '在你的电脑或 NAS 的项目根目录终端中粘贴执行，并把密码替换成自己的随机令牌。',
                        ),
                      ),
                      IosSettingsRow(
                        key: const ValueKey('spider-guide-copy-docker-cmd'),
                        icon: CupertinoIcons.cube_fill,
                        iconColor: AppleColors.systemTeal,
                        title: '复制 Docker Compose 部署配置',
                        subtitle: '适合群晖 / 飞牛 / 极空间 / Linux 服务器长期后台运行',
                        onTap: () => _copyAndNotify(
                          _dockerComposeTemplate,
                          '已复制 Docker 配置',
                          '已复制 docker-compose.yml 模板到剪贴板，修改令牌后运行 docker compose up -d 即可。',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),

                  // 5. FAQ
                  IosSettingsGroup(
                    header: '五、常见疑问（FAQ）',
                    dividerIndent: 16,
                    children: [
                      _buildFaqRow(
                        question: '这是连作者的服务器吗？多人使用会卡或失效吗？',
                        answer:
                            '不是！Marco Movie 不存在任何官方中转服务器。扩展包完全在你手机本地运行；自建网关则只连你自己家里的设备，没人能蹭用你的带宽，也没有封服风险。',
                      ),
                      _buildFaqRow(
                        question: '打开网关后，本来能直接播的线路会变慢吗？',
                        answer:
                            '不会。系统严格遵循「本机优先」原则：本机已适配的 100+ 线路永远直接走本机，绝不经过网关。',
                      ),
                      _buildFaqRow(
                        question: '通过网关看 4K 电影会很耗家庭上传带宽吗？',
                        answer:
                            '不会。网关只帮手机解析几 KB 的影片目录和播放链接 JSON，真正的 4K 视频流仍由你的 iPhone/iPad 直接从网盘或视频 CDN 拉取播放。',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
