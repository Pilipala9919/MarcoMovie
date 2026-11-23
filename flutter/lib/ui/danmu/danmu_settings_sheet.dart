// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/material.dart';

import '../../core/danmu/block_filter.dart';
import '../../core/danmu/danmu_prefs.dart';
import '../../core/danmu/provider.dart';
import '../../core/ohos_runtime.dart';
import '../apple_theme.dart';
import '../ios_liquid_glass.dart';

/// Standalone danmu settings modal sheet for mobile and desktop Flutter builds.
///
/// Guarded by `!OhosRuntime.isOhos`: returns [SizedBox.shrink] on HarmonyOS NEXT.
class DanmuSettingsSheet extends StatefulWidget {
  static const Color reducedTransparencySurface = Color(0xF51E1E22);

  final DanmuSettings initialSettings;
  final ValueChanged<DanmuSettings> onChanged;
  final bool persistAutomatically;
  final String currentMatchSummary;
  final int episodeOffset;
  final ValueChanged<int>? onEpisodeOffsetChanged;
  final Future<List<DanmuCandidate>> Function(
    String keyword,
    int? episodeNumber,
  )? onSearchCandidates;
  final ValueChanged<DanmuCandidate>? onSelectCandidate;
  final String initialSearchKeyword;
  final int? initialEpisodeNumber;

  const DanmuSettingsSheet({
    super.key,
    required this.initialSettings,
    required this.onChanged,
    this.persistAutomatically = true,
    this.currentMatchSummary = '',
    this.episodeOffset = 0,
    this.onEpisodeOffsetChanged,
    this.onSearchCandidates,
    this.onSelectCandidate,
    this.initialSearchKeyword = '',
    this.initialEpisodeNumber,
  });

  static Color resolveSurfaceColor(BuildContext context) {
    final reduce = GlassworkBackdrop.reduceTransparency.value ||
        GlassworkBackdrop.intensity.value <= 0.02 ||
        MediaQuery.highContrastOf(context);
    return reduce ? reducedTransparencySurface : AppleColors.groupedPrimary;
  }

  static Future<void> show(
    BuildContext context, {
    required DanmuSettings initialSettings,
    required ValueChanged<DanmuSettings> onChanged,
    String currentMatchSummary = '',
    int episodeOffset = 0,
    ValueChanged<int>? onEpisodeOffsetChanged,
    Future<List<DanmuCandidate>> Function(
      String keyword,
      int? episodeNumber,
    )? onSearchCandidates,
    ValueChanged<DanmuCandidate>? onSelectCandidate,
    String initialSearchKeyword = '',
    int? initialEpisodeNumber,
  }) async {
    if (OhosRuntime.isOhos) return;
    await showIos27LiquidSheet<void>(
      context: context,
      title: '弹幕设置',
      maxWidth: 540,
      builder: (ctx) => DanmuSettingsSheet(
        initialSettings: initialSettings,
        onChanged: onChanged,
        currentMatchSummary: currentMatchSummary,
        episodeOffset: episodeOffset,
        onEpisodeOffsetChanged: onEpisodeOffsetChanged,
        onSearchCandidates: onSearchCandidates,
        onSelectCandidate: onSelectCandidate,
        initialSearchKeyword: initialSearchKeyword,
        initialEpisodeNumber: initialEpisodeNumber,
      ),
    );
  }

  @override
  State<DanmuSettingsSheet> createState() => _DanmuSettingsSheetState();
}

class _DanmuSettingsSheetState extends State<DanmuSettingsSheet> {
  late DanmuSettings _settings;
  late final TextEditingController _serverUrlsCtrl;
  late final TextEditingController _appIdCtrl;
  late final TextEditingController _appSecretCtrl;
  final TextEditingController _blockRuleCtrl = TextEditingController();
  String? _ruleError;
  late int _episodeOffset;
  late String _matchSummary;

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
    _episodeOffset = widget.episodeOffset;
    _matchSummary = widget.currentMatchSummary;
    _serverUrlsCtrl = TextEditingController(text: _settings.serverUrls);
    _appIdCtrl = TextEditingController(text: _settings.appId);
    _appSecretCtrl = TextEditingController(text: _settings.appSecret);
  }

  @override
  void dispose() {
    _serverUrlsCtrl.dispose();
    _appIdCtrl.dispose();
    _appSecretCtrl.dispose();
    _blockRuleCtrl.dispose();
    super.dispose();
  }

  void _update(DanmuSettings next, {bool persist = true}) {
    setState(() => _settings = next);
    widget.onChanged(next);
    if (persist && widget.persistAutomatically && !OhosRuntime.isOhos) {
      DanmuPrefs.save(next);
    }
  }

  void _saveServerFields() {
    _update(
      _settings.copyWith(
        serverUrls: _serverUrlsCtrl.text,
        appId: _appIdCtrl.text,
        appSecret: _appSecretCtrl.text,
      ),
    );
  }

  void _addBlockRule() {
    final candidate = _blockRuleCtrl.text.trim();
    final vr = DanmuBlockFilter.validateRule(candidate);
    if (!vr.valid) {
      setState(() => _ruleError = vr.error);
      return;
    }
    if (_settings.blockRules.length >= DanmuBlockFilter.maxRules) {
      setState(() => _ruleError = '屏蔽规则已达 100 条上限');
      return;
    }
    final nextRules = List<String>.from(_settings.blockRules);
    if (!nextRules.contains(candidate)) {
      nextRules.add(candidate);
    }
    setState(() {
      _ruleError = null;
      _blockRuleCtrl.clear();
    });
    _update(_settings.copyWith(blockRules: nextRules));
  }

  void _removeBlockRule(String rule) {
    final nextRules = List<String>.from(_settings.blockRules)..remove(rule);
    _update(_settings.copyWith(blockRules: nextRules));
  }

  void _setEpisodeOffset(int next) {
    final clamped = next.clamp(-500, 500);
    setState(() {
      _episodeOffset = clamped;
      _matchSummary = '已调整集数偏移（${clamped >= 0 ? '+$clamped' : '$clamped'} 集），正在重新匹配…';
    });
    widget.onEpisodeOffsetChanged?.call(clamped);
  }

  Future<void> _openManualMatchDialog() async {
    final searcher = widget.onSearchCandidates;
    if (searcher == null) return;
    final kwCtrl = TextEditingController(text: widget.initialSearchKeyword);
    final epCtrl = TextEditingController(
      text: widget.initialEpisodeNumber != null && widget.initialEpisodeNumber! > 0
          ? '${widget.initialEpisodeNumber}'
          : '',
    );
    List<DanmuCandidate> results = const [];
    bool loading = false;
    String? errorMsg;

    await showDialog<void>(
      context: context,
      builder: (dlgCtx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          Future<void> runSearch() async {
            final kw = kwCtrl.text.trim();
            if (kw.isEmpty) return;
            final epNum = int.tryParse(epCtrl.text.trim());
            setDlgState(() {
              loading = true;
              errorMsg = null;
            });
            try {
              final list = await searcher(kw, epNum);
              if (!ctx.mounted) return;
              setDlgState(() {
                results = list;
                loading = false;
                if (list.isEmpty) errorMsg = '未找到匹配的弹幕剧集，可尝试调整片名或集数';
              });
            } catch (e) {
              if (!ctx.mounted) return;
              setDlgState(() {
                loading = false;
                errorMsg = '搜索失败：$e';
              });
            }
          }

          return AlertDialog(
            backgroundColor: const Color(0xFF1C1C1E),
            title: const Text(
              '手动匹配弹幕',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: kwCtrl,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            labelText: '剧名 / 番剧名',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onSubmitted: (_) => runSearch(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 1,
                        child: TextField(
                          controller: epCtrl,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            labelText: '集数',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onSubmitted: (_) => runSearch(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: loading ? null : runSearch,
                        child: const Text('搜索'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (errorMsg != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        errorMsg!,
                        style: const TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    )
                  else if (results.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 280),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: results.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, color: Colors.white12),
                        itemBuilder: (_, idx) {
                          final cand = results[idx];
                          return ListTile(
                            dense: true,
                            title: Text(
                              cand.animeTitle.isNotEmpty
                                  ? cand.animeTitle
                                  : '未命名作品',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              cand.episodeTitle.isNotEmpty
                                  ? cand.episodeTitle
                                  : 'ID ${cand.animeId}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                            trailing: Text(
                              '${(cand.confidence * 100).round()}%',
                              style: const TextStyle(
                                color: Color(0xFF64D2FF),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            onTap: () {
                              widget.onSelectCandidate?.call(cand);
                              if (mounted) {
                                setState(() {
                                  _matchSummary =
                                      '${cand.animeTitle} · ${cand.episodeTitle}';
                                });
                              }
                              Navigator.of(dlgCtx).pop();
                            },
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dlgCtx).pop(),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
    kwCtrl.dispose();
    epCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (OhosRuntime.isOhos) {
      return const SizedBox.shrink();
    }

    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        GlassworkBackdrop.reduceTransparency,
        GlassworkBackdrop.intensity,
      ]),
      builder: (ctx, child) => ColoredBox(
        color: DanmuSettingsSheet.resolveSurfaceColor(ctx),
        child: child,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text(
                '弹幕设置',
                style: TextStyle(
                  color: AppleColors.labelPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              IosNativeSwitch(
                value: _settings.enabled,
                accessibilityLabel: '开启弹幕',
                onChanged: (v) => _update(_settings.copyWith(enabled: v)),
              ),
            ],
          ),
          if (_matchSummary.isNotEmpty ||
              widget.onEpisodeOffsetChanged != null ||
              widget.onSearchCandidates != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.10),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '弹幕匹配与集数校准',
                    style: TextStyle(
                      color: AppleColors.labelSecondary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (_matchSummary.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      _matchSummary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (widget.onEpisodeOffsetChanged != null) ...[
                        OutlinedButton(
                          onPressed: () => _setEpisodeOffset(_episodeOffset - 1),
                          child: const Text('集数 -1'),
                        ),
                        OutlinedButton(
                          onPressed: () => _setEpisodeOffset(0),
                          child: Text(
                            _episodeOffset == 0
                                ? '偏移 0'
                                : '归零 (${_episodeOffset > 0 ? '+$_episodeOffset' : '$_episodeOffset'})',
                          ),
                        ),
                        OutlinedButton(
                          onPressed: () => _setEpisodeOffset(_episodeOffset + 1),
                          child: const Text('集数 +1'),
                        ),
                      ],
                      if (widget.onSearchCandidates != null)
                        FilledButton.tonal(
                          onPressed: _openManualMatchDialog,
                          child: const Text('手动匹配弹幕'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          _sectionTitle('不透明度：${(_settings.opacity * 100).round()}%'),
          Slider(
            value: _settings.opacity,
            min: 0.20,
            max: 1.00,
            divisions: 16,
            onChanged: (v) =>
                _update(_settings.copyWith(opacity: v), persist: false),
            onChangeEnd: (v) =>
                _update(_settings.copyWith(opacity: v), persist: true),
          ),
          _sectionTitle('显示区域'),
          Wrap(
            spacing: 8,
            children: DanmuSettings.areaOptions.map((opt) {
              final selected = (_settings.displayArea - opt).abs() < 0.01;
              return ChoiceChip(
                label: Text('${(opt * 100).round()}%'),
                selected: selected,
                onSelected: (_) => _update(_settings.copyWith(displayArea: opt)),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          _sectionTitle('字号：${_settings.fontSize.round()} lp'),
          Slider(
            value: _settings.fontSize,
            min: 14,
            max: 32,
            divisions: 18,
            onChanged: (v) =>
                _update(_settings.copyWith(fontSize: v), persist: false),
            onChangeEnd: (v) =>
                _update(_settings.copyWith(fontSize: v), persist: true),
          ),
          _sectionTitle('滚动速度'),
          Wrap(
            spacing: 8,
            children: DanmuSettings.speedOptions.map((opt) {
              final selected = (_settings.speedMultiplier - opt).abs() < 0.01;
              return ChoiceChip(
                label: Text('${opt}x'),
                selected: selected,
                onSelected: (_) =>
                    _update(_settings.copyWith(speedMultiplier: opt)),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          _sectionTitle(
            '时间轴偏移：${_settings.timeOffsetMs >= 0 ? '+' : ''}${(_settings.timeOffsetMs / 1000).toStringAsFixed(1)}s',
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => _update(
                  _settings.copyWith(timeOffsetMs: _settings.timeOffsetMs - 500),
                ),
                child: const Text('-0.5s'),
              ),
              OutlinedButton(
                onPressed: () => _update(_settings.copyWith(timeOffsetMs: 0)),
                child: const Text('归零'),
              ),
              OutlinedButton(
                onPressed: () => _update(
                  _settings.copyWith(timeOffsetMs: _settings.timeOffsetMs + 500),
                ),
                child: const Text('+0.5s'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _sectionTitle('弹幕类型'),
          Wrap(
            spacing: 8,
            children: [
              FilterChip(
                label: const Text('滚动'),
                selected: _settings.showScroll,
                onSelected: (v) => _update(_settings.copyWith(showScroll: v)),
              ),
              FilterChip(
                label: const Text('顶部'),
                selected: _settings.showTop,
                onSelected: (v) => _update(_settings.copyWith(showTop: v)),
              ),
              FilterChip(
                label: const Text('底部'),
                selected: _settings.showBottom,
                onSelected: (v) => _update(_settings.copyWith(showBottom: v)),
              ),
            ],
          ),
          const Divider(height: 28, color: AppleColors.separator),
          _sectionTitle('兼容弹幕服务地址（每行一个，最多 8 个，默认留空）'),
          const SizedBox(height: 6),
          TextField(
            controller: _serverUrlsCtrl,
            minLines: 2,
            maxLines: 4,
            style: const TextStyle(color: AppleColors.labelPrimary),
            decoration: const InputDecoration(
              hintText: 'https://danmu.example',
              border: OutlineInputBorder(),
            ),
            onEditingComplete: _saveServerFields,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _appIdCtrl,
                  style: const TextStyle(color: AppleColors.labelPrimary),
                  decoration: const InputDecoration(
                    labelText: 'AppId（可选）',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _appSecretCtrl,
                  obscureText: true,
                  style: const TextStyle(color: AppleColors.labelPrimary),
                  decoration: const InputDecoration(
                    labelText: 'AppSecret（可选）',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _saveServerFields,
              child: const Text('保存服务配置'),
            ),
          ),
          const Divider(height: 28, color: AppleColors.separator),
          _sectionTitle(
            '屏蔽词管理（${_settings.blockRules.length} / ${DanmuBlockFilter.maxRules}）',
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _blockRuleCtrl,
                  style: const TextStyle(color: AppleColors.labelPrimary),
                  decoration: InputDecoration(
                    hintText: '输入关键词或 re:剧透|打卡',
                    errorText: _ruleError,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _addBlockRule(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _addBlockRule,
                child: const Text('添加'),
              ),
            ],
          ),
          if (_settings.blockRules.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _settings.blockRules
                  .map(
                    (rule) => InputChip(
                      label: Text(rule),
                      onDeleted: () => _removeBlockRule(rule),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        title,
        style: const TextStyle(
          color: AppleColors.labelSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
