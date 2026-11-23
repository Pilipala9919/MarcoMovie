// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/ohos_runtime.dart';
import '../apple_theme.dart';
import '../ios_liquid_glass.dart';
import '../poster_image.dart';
import 'first_play_gesture_hint.dart';
import 'onboarding_prefs.dart';

/// Manifest model kept backward-compatible with `assets/demo/manifest.json`
/// schema and unit tests.
class DemoPosterItem {
  final String id;
  final String file;
  final String titleZh;
  final String titleEn;
  final String badgeZh;
  final String badgeEn;
  final List<String> specs;
  final double progress;
  final Color accentColor;

  const DemoPosterItem({
    required this.id,
    required this.file,
    required this.titleZh,
    required this.titleEn,
    this.badgeZh = '示例',
    this.badgeEn = 'DEMO',
    required this.specs,
    this.progress = 0.0,
    required this.accentColor,
  });

  String title({required bool zh}) => zh ? titleZh : titleEn;
  String badge({required bool zh}) => zh ? badgeZh : badgeEn;
  String get assetPath => 'assets/demo/$file';

  static List<DemoPosterItem> parseManifest(String rawJson) {
    if (rawJson.trim().isEmpty) return const <DemoPosterItem>[];
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map<String, dynamic>) return const <DemoPosterItem>[];
    final items = decoded['items'];
    if (items is! List) return const <DemoPosterItem>[];
    final result = <DemoPosterItem>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final specsRaw = map['specs'];
      final specs = specsRaw is List
          ? specsRaw
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList()
          : const <String>[];
      result.add(
        DemoPosterItem(
          id: (map['id'] ?? '').toString(),
          file: (map['file'] ?? '').toString(),
          titleZh: (map['titleZh'] ?? '示例').toString(),
          titleEn: (map['titleEn'] ?? 'Sample').toString(),
          badgeZh: (map['badgeZh'] ?? '示例').toString(),
          badgeEn: (map['badgeEn'] ?? 'DEMO').toString(),
          specs: specs,
          progress: ((map['progress'] is num)
                  ? (map['progress'] as num).toDouble()
                  : 0.0)
              .clamp(0.0, 1.0),
          accentColor: _parseHexColor(
            (map['accentHex'] ?? '#0A84FF').toString(),
          ),
        ),
      );
    }
    return result;
  }

  static Color _parseHexColor(String hex) {
    final cleaned = hex.trim().replaceFirst('#', '');
    if (cleaned.length == 6) {
      final parsed = int.tryParse(cleaned, radix: 16);
      if (parsed != null) return Color(0xFF000000 | parsed);
    }
    return const Color(0xFF0A84FF);
  }
}

/// Complete 14-item fallback list matching `assets/demo/manifest.json` for
/// manifest schema compatibility.
const List<DemoPosterItem> kFallbackDemoPosters = <DemoPosterItem>[
  DemoPosterItem(
    id: 'demo_01',
    file: 'demo_01.png',
    titleZh: '示例 · 远航',
    titleEn: 'Sample · Horizon',
    specs: ['4K', 'DV · ATMOS', 'REMUX'],
    progress: 0.68,
    accentColor: Color(0xFF0A84FF),
  ),
  DemoPosterItem(
    id: 'demo_02',
    file: 'demo_02.png',
    titleZh: '示例 · 城市微光',
    titleEn: 'Sample · City Glow',
    specs: ['4K', 'HDR10+', 'DD+ 5.1'],
    progress: 0.34,
    accentColor: Color(0xFFBF5AF2),
  ),
  DemoPosterItem(
    id: 'demo_03',
    file: 'demo_03.png',
    titleZh: '示例 · 深空信标',
    titleEn: 'Sample · Deep Beacon',
    specs: ['4K', 'DV · ATMOS'],
    progress: 0.52,
    accentColor: Color(0xFF5AC8FA),
  ),
  DemoPosterItem(
    id: 'demo_04',
    file: 'demo_04.png',
    titleZh: '示例 · 海岸季风',
    titleEn: 'Sample · Coastal Wind',
    specs: ['4K', 'HLG', 'HEVC'],
    progress: 0.0,
    accentColor: Color(0xFF30D158),
  ),
  DemoPosterItem(
    id: 'demo_05',
    file: 'demo_05.png',
    titleZh: '示例 · 静夜回响',
    titleEn: 'Sample · Night Echo',
    specs: ['1080P', 'REMUX', 'DD+ 5.1'],
    progress: 0.81,
    accentColor: Color(0xFF5E5CE6),
  ),
  DemoPosterItem(
    id: 'demo_06',
    file: 'demo_06.png',
    titleZh: '示例 · 云端走廊',
    titleEn: 'Sample · Cloud Corridor',
    specs: ['4K', 'HDR10'],
    progress: 0.0,
    accentColor: Color(0xFFFF9F0A),
  ),
  DemoPosterItem(
    id: 'demo_07',
    file: 'demo_07.png',
    titleZh: '示例 · 折光之境',
    titleEn: 'Sample · Prism Field',
    specs: ['4K', 'DV · ATMOS'],
    progress: 0.24,
    accentColor: Color(0xFFFF6482),
  ),
  DemoPosterItem(
    id: 'demo_08',
    file: 'demo_08.png',
    titleZh: '示例 · 极昼航线',
    titleEn: 'Sample · Solstice Line',
    specs: ['4K', 'HDR10+', 'REMUX'],
    progress: 0.0,
    accentColor: Color(0xFF64D2FF),
  ),
  DemoPosterItem(
    id: 'demo_09',
    file: 'demo_09.png',
    titleZh: '示例 · 琥珀潮汐',
    titleEn: 'Sample · Amber Tide',
    specs: ['4K', 'HDR10', 'ATMOS'],
    progress: 0.45,
    accentColor: Color(0xFFFFB340),
  ),
  DemoPosterItem(
    id: 'demo_10',
    file: 'demo_10.png',
    titleZh: '示例 · 雾港灯塔',
    titleEn: 'Sample · Mist Harbor',
    specs: ['1080P', 'HEVC'],
    progress: 0.0,
    accentColor: Color(0xFF5AC8FA),
  ),
  DemoPosterItem(
    id: 'demo_11',
    file: 'demo_11.png',
    titleZh: '示例 · 星环纪事',
    titleEn: 'Sample · Orbital Notes',
    specs: ['4K', 'DV · ATMOS'],
    progress: 0.0,
    accentColor: Color(0xFFBF5AF2),
  ),
  DemoPosterItem(
    id: 'demo_12',
    file: 'demo_12.png',
    titleZh: '示例 · 砾石山谷',
    titleEn: 'Sample · Slate Valley',
    specs: ['4K', 'REMUX'],
    progress: 0.0,
    accentColor: Color(0xFF63E682),
  ),
  DemoPosterItem(
    id: 'demo_13',
    file: 'demo_13.png',
    titleZh: '示例 · 晨曦画幅',
    titleEn: 'Sample · Dawn Frame',
    specs: ['4K', 'HDR10+'],
    progress: 0.0,
    accentColor: Color(0xFFFF6482),
  ),
  DemoPosterItem(
    id: 'demo_14',
    file: 'demo_14.png',
    titleZh: '示例 · 漫游声景',
    titleEn: 'Sample · Drift Soundscape',
    specs: ['1080P', 'DD+ 5.1'],
    progress: 0.0,
    accentColor: Color(0xFF0A84FF),
  ),
];

/// Real classic cinema titles rendered in the Rex-style onboarding showcase via
/// [PosterImage] (real high-res movie posters resolved on demand, with crisp
/// cinema gradients while loading or offline).
class _ClassicShowcaseFilm {
  final String id;
  final String titleZh;
  final String titleEn;
  final String year;
  final String rating;
  final List<String> specs;
  final double progress;
  final List<Color> gradient;

  const _ClassicShowcaseFilm({
    required this.id,
    required this.titleZh,
    required this.titleEn,
    required this.year,
    required this.rating,
    required this.specs,
    this.progress = 0.0,
    required this.gradient,
  });

  String title({required bool zh}) => zh ? titleZh : titleEn;
}

const List<_ClassicShowcaseFilm> _kClassicShowcaseFilms = <_ClassicShowcaseFilm>[
  _ClassicShowcaseFilm(
    id: 'demo_01',
    titleZh: '肖申克的救赎',
    titleEn: 'The Shawshank Redemption',
    year: '1994',
    rating: '豆 9.7',
    specs: ['4K', 'HDR10+'],
    progress: 0.72,
    gradient: [Color(0xFF3E2918), Color(0xFF1A1412)],
  ),
  _ClassicShowcaseFilm(
    id: 'demo_02',
    titleZh: '星际穿越',
    titleEn: 'Interstellar',
    year: '2014',
    rating: '豆 9.4',
    specs: ['4K', 'DV · ATMOS'],
    progress: 0.64,
    gradient: [Color(0xFF1B3352), Color(0xFF0A111D)],
  ),
  _ClassicShowcaseFilm(
    id: 'demo_03',
    titleZh: '霸王别姬',
    titleEn: 'Farewell My Concubine',
    year: '1993',
    rating: '豆 9.6',
    specs: ['4K', 'REMUX'],
    progress: 0.38,
    gradient: [Color(0xFF4F1D24), Color(0xFF1B0E11)],
  ),
  _ClassicShowcaseFilm(
    id: 'demo_04',
    titleZh: '泰坦尼克号',
    titleEn: 'Titanic',
    year: '1997',
    rating: '豆 9.5',
    specs: ['4K', 'DV · ATMOS'],
    gradient: [Color(0xFF16384B), Color(0xFF0A1720)],
  ),
  _ClassicShowcaseFilm(
    id: 'demo_05',
    titleZh: '盗梦空间',
    titleEn: 'Inception',
    year: '2010',
    rating: '豆 9.4',
    specs: ['4K', 'HDR10+'],
    progress: 0.81,
    gradient: [Color(0xFF21314A), Color(0xFF0E131D)],
  ),
  _ClassicShowcaseFilm(
    id: 'demo_06',
    titleZh: '千与千寻',
    titleEn: 'Spirited Away',
    year: '2001',
    rating: '豆 9.4',
    specs: ['4K', 'HEVC'],
    gradient: [Color(0xFF1C4746), Color(0xFF0D2024)],
  ),
  _ClassicShowcaseFilm(
    id: 'demo_07',
    titleZh: '蝙蝠侠：黑暗骑士',
    titleEn: 'The Dark Knight',
    year: '2008',
    rating: '豆 9.2',
    specs: ['4K', 'DV · ATMOS'],
    progress: 0.45,
    gradient: [Color(0xFF232C3E), Color(0xFF0B0E15)],
  ),
  _ClassicShowcaseFilm(
    id: 'demo_08',
    titleZh: '沙丘2',
    titleEn: 'Dune: Part Two',
    year: '2024',
    rating: 'RT 92%',
    specs: ['4K', 'DV · ATMOS'],
    progress: 0.28,
    gradient: [Color(0xFF6A3D1C), Color(0xFF1E130B)],
  ),
  _ClassicShowcaseFilm(
    id: 'demo_09',
    titleZh: '疯狂动物城',
    titleEn: 'Zootopia',
    year: '2016',
    rating: '豆 9.2',
    specs: ['4K', 'HDR10'],
    gradient: [Color(0xFF1D4F7A), Color(0xFF10253A)],
  ),
  _ClassicShowcaseFilm(
    id: 'demo_10',
    titleZh: '寻梦环游记',
    titleEn: 'Coco',
    year: '2017',
    rating: '豆 9.1',
    specs: ['4K', 'DV · ATMOS'],
    progress: 0.55,
    gradient: [Color(0xFF5D2A73), Color(0xFF1E0F29)],
  ),
  _ClassicShowcaseFilm(
    id: 'demo_11',
    titleZh: '复仇者联盟4：终局之战',
    titleEn: 'Avengers: Endgame',
    year: '2019',
    rating: '豆 8.5',
    specs: ['4K', 'IMAX'],
    gradient: [Color(0xFF392359), Color(0xFF120C1F)],
  ),
  _ClassicShowcaseFilm(
    id: 'demo_12',
    titleZh: '奥本海默',
    titleEn: 'Oppenheimer',
    year: '2023',
    rating: '豆 8.8',
    specs: ['4K', 'REMUX'],
    gradient: [Color(0xFF6B2D14), Color(0xFF1E0E0A)],
  ),
  _ClassicShowcaseFilm(
    id: 'demo_13',
    titleZh: '蜘蛛侠：纵横宇宙',
    titleEn: 'Spider-Man: Across the Spider-Verse',
    year: '2023',
    rating: 'RT 95%',
    specs: ['4K', 'HDR10+'],
    gradient: [Color(0xFF701D3D), Color(0xFF1C0C1A)],
  ),
  _ClassicShowcaseFilm(
    id: 'demo_14',
    titleZh: '楚门的世界',
    titleEn: 'The Truman Show',
    year: '1998',
    rating: '豆 9.4',
    specs: ['4K', 'REMUX'],
    gradient: [Color(0xFF28557E), Color(0xFF112438)],
  ),
];

/// Rex-inspired silky animated 5-act showcase onboarding for iPhone, iPad,
/// macOS, Windows, and Android Flutter builds.
///
/// Uses real classic cinema posters, continuous smooth motion (honoring
/// Reduce Motion), and adaptive Light/Dark Liquid Glass aesthetics.
/// Automatically bypassed on HarmonyOS NEXT (`OhosRuntime.isOhos`).
class OnboardingScreen extends StatefulWidget {
  static const int actCount = 5;

  final OnboardingPrefs prefs;
  final bool? isChinese;
  final FirstPlayHintPlatform? platformOverride;
  final bool initialReduceMotion;
  final bool initialReduceTransparency;
  final double initialTextScale;
  final WidgetBuilder? backgroundBuilder;
  final ValueChanged<String>? onImportConfig;
  final VoidCallback? onOpenSync;
  final void Function(
    bool reduceMotion,
    bool reduceTransparency,
    double textScale,
  )? onPersonalizationChanged;
  final ValueChanged<bool>? onFinished;

  const OnboardingScreen({
    super.key,
    required this.prefs,
    this.isChinese,
    this.platformOverride,
    this.initialReduceMotion = false,
    this.initialReduceTransparency = false,
    this.initialTextScale = 1.0,
    this.backgroundBuilder,
    this.onImportConfig,
    this.onOpenSync,
    this.onPersonalizationChanged,
    this.onFinished,
  });

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with SingleTickerProviderStateMixin {
  int _act = 0;
  int _hudDemoStep = 0;
  late bool _reduceMotion;
  late bool _reduceTransparency;
  late double _textScale;
  bool _ohosBypassSent = false;
  bool _completing = false;
  late final AnimationController _ambientCtrl;

  bool get _allowContinuousTicker =>
      !_reduceMotion && !Platform.environment.containsKey('FLUTTER_TEST');

  @override
  void initState() {
    super.initState();
    _reduceMotion = widget.initialReduceMotion;
    _reduceTransparency = widget.initialReduceTransparency;
    _textScale = widget.initialTextScale.clamp(0.85, 1.35);
    _ambientCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 22),
    );
    if (OhosRuntime.isOhos) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _ohosBypassSent) return;
        _ohosBypassSent = true;
        widget.onFinished?.call(true);
      });
    } else if (_allowContinuousTicker) {
      _ambientCtrl.repeat();
    }
  }

  @override
  void dispose() {
    _ambientCtrl.dispose();
    super.dispose();
  }

  void _syncAmbientTicker(bool disableAnimations) {
    final shouldRun =
        !disableAnimations && !Platform.environment.containsKey('FLUTTER_TEST');
    if (shouldRun && !_ambientCtrl.isAnimating) {
      _ambientCtrl.repeat();
    } else if (!shouldRun && _ambientCtrl.isAnimating) {
      _ambientCtrl.stop();
    }
  }

  Future<void> _finish({
    required bool skipped,
    bool openImportAfter = false,
  }) async {
    if (_completing) return;
    _completing = true;
    await widget.prefs.markOnboardingCompleted();
    if (!mounted) return;
    widget.onFinished?.call(skipped);
    if (openImportAfter) {
      widget.onImportConfig?.call('');
    }
  }

  void _nextAct() {
    if (_act < OnboardingScreen.actCount - 1) {
      setState(() => _act++);
    } else {
      _finish(skipped: false);
    }
  }

  void _prevAct() {
    if (_act > 0) {
      setState(() => _act--);
    }
  }

  void _handleSystemBack() {
    if (_act > 0) {
      _prevAct();
    } else {
      _finish(skipped: true);
    }
  }

  void _notifyPersonalization() {
    widget.onPersonalizationChanged?.call(
      _reduceMotion,
      _reduceTransparency,
      _textScale,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (OhosRuntime.isOhos) {
      return const SizedBox.shrink();
    }

    final zh = resolveOnboardingChineseLocale(context, widget.isChinese);
    final platform = widget.platformOverride ??
        resolveFirstPlayHintPlatform(platform: Theme.of(context).platform);
    final isIos = Theme.of(context).platform == TargetPlatform.iOS;
    final disableAnimations =
        _reduceMotion || MediaQuery.disableAnimationsOf(context);
    _syncAmbientTicker(disableAnimations);

    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;

    return ValueListenableBuilder<bool>(
      valueListenable: GlassworkBackdrop.reduceTransparency,
      builder: (context, globalReduceTrans, _) {
        final highContrast = _reduceTransparency ||
            globalReduceTrans ||
            MediaQuery.highContrastOf(context);

        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              _handleSystemBack();
            }
          },
          child: Scaffold(
            backgroundColor: isDark ? const Color(0xFF07090F) : palette.canvas,
            body: Stack(
              fit: StackFit.expand,
              children: [
                if (widget.backgroundBuilder != null)
                  widget.backgroundBuilder!(context)
                else
                  _buildCinematicBackdrop(isDark: isDark),
                SafeArea(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth >= 720;
                      return Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: wide ? 40 : 16,
                          vertical: wide ? 22 : 12,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildTopBar(zh, palette),
                            const SizedBox(height: 12),
                            Expanded(
                              child: AnimatedSwitcher(
                                duration: Duration(
                                  milliseconds: disableAnimations ? 100 : 320,
                                ),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                transitionBuilder: (child, anim) {
                                  if (disableAnimations) {
                                    return FadeTransition(
                                      opacity: anim,
                                      child: child,
                                    );
                                  }
                                  return FadeTransition(
                                    opacity: anim,
                                    child: SlideTransition(
                                      position: Tween<Offset>(
                                        begin: const Offset(0.04, 0.0),
                                        end: Offset.zero,
                                      ).animate(anim),
                                      child: child,
                                    ),
                                  );
                                },
                                child: SingleChildScrollView(
                                  key: ValueKey<int>(_act),
                                  physics: const BouncingScrollPhysics(),
                                  child: _buildActContent(
                                    act: _act,
                                    wide: wide,
                                    zh: zh,
                                    platform: platform,
                                    isIos: isIos,
                                    highContrast: highContrast,
                                    disableAnimations: disableAnimations,
                                    palette: palette,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            _buildBottomBar(zh, disableAnimations, palette),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCinematicBackdrop({required bool isDark}) {
    final accentColors = switch (_act) {
      0 => const [Color(0xFF0A84FF), Color(0xFF5E5CE6)],
      1 => const [Color(0xFFFF9F0A), Color(0xFF0A84FF)],
      2 => const [Color(0xFF30D158), Color(0xFF5AC8FA)],
      3 => const [Color(0xFFBF5AF2), Color(0xFF0A84FF)],
      _ => const [Color(0xFF64D2FF), Color(0xFF5E5CE6)],
    };

    return AnimatedBuilder(
      animation: _ambientCtrl,
      builder: (context, _) {
        final angle = _ambientCtrl.value * 2 * math.pi;
        final driftX = 0.25 * math.sin(angle);
        final driftY = 0.16 * math.cos(angle * 0.7);
        return Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isDark
                      ? const [
                          Color(0xFF07090F),
                          Color(0xFF0F172A),
                          Color(0xFF07080E),
                        ]
                      : const [
                          Color(0xFFEDF0F6),
                          Color(0xFFE5EAF4),
                          Color(0xFFDFE5F0),
                        ],
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(-0.3 + driftX, -0.55 + driftY),
                      radius: 1.05,
                      colors: [
                        accentColors[0].withValues(alpha: isDark ? 0.24 : 0.16),
                        accentColors[1].withValues(alpha: isDark ? 0.10 : 0.08),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(0.55 - driftX, 0.68 - driftY),
                      radius: 0.95,
                      colors: [
                        accentColors[1].withValues(alpha: isDark ? 0.18 : 0.11),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTopBar(bool zh, ApplePalette palette) {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.asset(
            'assets/logo_mark.png',
            width: 24,
            height: 24,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Icon(
              CupertinoIcons.film_fill,
              size: 20,
              color: palette.accent,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            zh ? 'Marco Movie' : 'Marco Movie',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.labelPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
        ),
        TextButton(
          key: const Key('onboarding_skip_button'),
          onPressed: () => _finish(skipped: true),
          child: Text(
            zh ? '跳过' : 'Skip',
            style: TextStyle(
              color: palette.labelSecondary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBottomBar(
    bool zh,
    bool disableAnimations,
    ApplePalette palette,
  ) {
    return Row(
      children: [
        if (_act > 0)
          TextButton(
            key: const Key('onboarding_prev_button'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              minimumSize: const Size(48, 36),
            ),
            onPressed: _prevAct,
            child: Text(
              zh ? '上一页' : 'Back',
              style: TextStyle(
                color: palette.labelPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          )
        else
          const SizedBox(width: 8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(OnboardingScreen.actCount, (index) {
                  final active = index == _act;
                  return AnimatedContainer(
                    duration:
                        Duration(milliseconds: disableAnimations ? 0 : 220),
                    curve: Curves.easeOutCubic,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: active ? 24 : 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: active
                          ? palette.accent
                          : (palette.isDark
                              ? const Color(0x4DFFFFFF)
                              : Colors.black.withValues(alpha: 0.16)),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
        Flexible(
          flex: 0,
          child: _buildPrimaryCta(
            key: const Key('onboarding_next_button'),
            label: _act == OnboardingScreen.actCount - 1
                ? (zh ? '开启影院' : 'Enter Home')
                : (zh ? '继续' : 'Next'),
            symbol: _act == OnboardingScreen.actCount - 1
                ? 'checkmark.circle.fill'
                : 'chevron.right',
            onTap: _nextAct,
          ),
        ),
      ],
    );
  }

  /// Primary CTA uses [IosNativeGlassButton] on iOS 26+ with clean Flutter
  /// fallback on iOS 15–18, Android, Windows, macOS, and tests.
  Widget _buildPrimaryCta({
    Key? key,
    required String label,
    required String symbol,
    required VoidCallback onTap,
  }) {
    final fallback = FilledButton(
      onPressed: onTap,
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFF0A84FF),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
    );

    return IosNativeGlassButton(
      key: key,
      style: 'capsule',
      label: label,
      trailingSymbol: symbol,
      tintColor: const Color(0xFF0A84FF),
      foregroundColor: Colors.white,
      maxWidth: 184,
      height: 40,
      onTap: onTap,
      fallback: fallback,
    );
  }

  Widget _buildActContent({
    required int act,
    required bool wide,
    required bool zh,
    required FirstPlayHintPlatform platform,
    required bool isIos,
    required bool highContrast,
    required bool disableAnimations,
    required ApplePalette palette,
  }) {
    switch (act) {
      case 0:
        return _buildAct1RexWelcome(
          wide,
          zh,
          platform,
          highContrast,
          palette,
        );
      case 1:
        return _buildAct2ClassicPosterWall(
          wide,
          zh,
          platform,
          isIos,
          highContrast,
          palette,
        );
      case 2:
        return _buildAct3SyncOrbit(wide, zh, highContrast, palette);
      case 3:
        return _buildAct4CinemaHud(
          wide,
          zh,
          platform,
          isIos,
          highContrast,
          disableAnimations,
          palette,
        );
      default:
        return _buildAct5Personalize(wide, zh, highContrast, palette);
    }
  }

  Widget _buildSplit({
    required bool wide,
    required Widget left,
    required Widget right,
  }) {
    if (wide) {
      return Row(
        key: const Key('onboarding_wide_two_column'),
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(flex: 9, child: left),
          const SizedBox(width: 28),
          Expanded(flex: 11, child: right),
        ],
      );
    }
    return Column(
      key: const Key('onboarding_compact_single_column'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        right,
        const SizedBox(height: 18),
        left,
      ],
    );
  }

  Widget _buildGlassCard({
    required bool highContrast,
    required ApplePalette palette,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
    required Widget child,
  }) {
    final isDark = palette.isDark;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: isDark
            ? (highContrast
                ? const Color(0xF51E1E22)
                : const Color(0xB8151925))
            : (highContrast
                ? const Color(0xFAF8F9FC)
                : const Color(0xDCF8F9FC)),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: highContrast ? 0.38 : 0.16)
              : Colors.white.withValues(alpha: 0.78),
          width: 0.9,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.36 : 0.08),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: child,
      ),
    );
  }

  Widget _buildActCopy({
    required String eyebrow,
    required String headline,
    required String body,
    required ApplePalette palette,
    Widget? action,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: palette.accent.withValues(alpha: palette.isDark ? 0.18 : 0.12),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            eyebrow,
            style: TextStyle(
              color: palette.isDark ? const Color(0xFF64D2FF) : palette.accent,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.1,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          headline,
          style: TextStyle(
            color: palette.labelPrimary,
            fontSize: 25 * _textScale,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            height: 1.18,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          body,
          style: TextStyle(
            color: palette.labelSecondary,
            fontSize: 14 * _textScale,
            height: 1.52,
          ),
        ),
        if (action != null) ...[
          const SizedBox(height: 16),
          action,
        ],
      ],
    );
  }

  /// Act 1: Rex-style 3D tilted dual-track gliding classic cinema poster stage.
  Widget _buildAct1RexWelcome(
    bool wide,
    bool zh,
    FirstPlayHintPlatform platform,
    bool highContrast,
    ApplePalette palette,
  ) {
    final platformTip = switch (platform) {
      FirstPlayHintPlatform.tv => zh
          ? '电视端支持局域网扫码推送与遥控器极速选片'
          : 'TV supports LAN QR push and remote browsing',
      FirstPlayHintPlatform.desktop => zh
          ? '桌面端支持链接粘贴、本地配置与备份一键还原'
          : 'Desktop supports URL paste, local files & backup restore',
      FirstPlayHintPlatform.touch => zh
          ? '支持夸克 / UC / 百度 / 阿里 4K 网盘直连与自有订阅源一键导入'
          : 'Supports 4K cloud drives and one-tap personal source import',
    };

    final topTrack = _kClassicShowcaseFilms.take(7).toList();
    final bottomTrack = _kClassicShowcaseFilms.skip(7).take(7).toList();

    return _buildSplit(
      wide: wide,
      left: _buildActCopy(
        eyebrow: zh ? '私人影院 · 优雅启幕' : 'Your Cinema Universe',
        headline: zh ? '把你的片源，装进一座液态玻璃影院' : 'A Liquid Glass Cinema for Your Sources',
        body: zh
            ? 'Marco Movie 仅作播放与影视管理工具，不内置、不提供、不托管任何影视资源。导入您的自有片源或登录个人网盘，即刻拥有丝滑的 4K 观影体验。'
            : 'Marco Movie is strictly a playback & library tool. It bundles, provides, and hosts zero media content. Connect your own sources or cloud drive to begin.',
        palette: palette,
        action: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildPrimaryCta(
              key: const Key('onboarding_act1_import_button'),
              label: zh ? '立即导入配置' : 'Import Config',
              symbol: 'square.and.arrow.down',
              onTap: () => widget.onImportConfig?.call(''),
            ),
            const SizedBox(height: 10),
            Text(
              platformTip,
              style: TextStyle(
                color: palette.labelTertiary,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
      right: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: Container(
          height: wide ? 340 : 256,
          decoration: BoxDecoration(
            color: palette.isDark
                ? const Color(0xFF0D111B)
                : const Color(0xFF151C2B),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.14),
              width: 0.9,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 28,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Tilted dual-row classic poster marquee (Rex signature hero look)
              AnimatedBuilder(
                animation: _ambientCtrl,
                builder: (context, _) {
                  final phase = _ambientCtrl.value;
                  const cardStride = 94.0;
                  final loopSpan = cardStride * topTrack.length;
                  final offsetA = -(phase * loopSpan) % loopSpan;
                  final offsetB =
                      -((1.0 - phase) * loopSpan) % loopSpan;
                  return Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..rotateZ(-0.11)
                      ..scaleByDouble(1.16, 1.16, 1.0, 1.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildMarqueeRow(topTrack, offsetA),
                        const SizedBox(height: 10),
                        _buildMarqueeRow(bottomTrack, offsetB),
                      ],
                    ),
                  );
                },
              ),
              // Cinema radial vignette so center glass badge shines cleanly
              const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      radius: 0.92,
                      colors: [
                        Color(0x52090D16),
                        Color(0xB8080B12),
                      ],
                    ),
                  ),
                ),
              ),
              // Floating translucent glass brand badge
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xBA121622),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.24),
                        width: 0.9,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF0A84FF).withValues(alpha: 0.30),
                          blurRadius: 26,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(9),
                          child: Image.asset(
                            'assets/logo_mark.png',
                            width: 34,
                            height: 34,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Icon(
                              CupertinoIcons.play_circle_fill,
                              color: Color(0xFF5AC8FA),
                              size: 32,
                            ),
                          ),
                        ),
                        const SizedBox(width: 11),
                        Flexible(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Marco Movie',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.3,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                zh ? 'iOS 26 液态玻璃 · 4K 杜比视界' : 'Liquid Glass · 4K HDR Cinema',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xCC9AD8FF),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMarqueeRow(List<_ClassicShowcaseFilm> films, double dx) {
    final repeated = [...films, ...films];
    return SizedBox(
      height: 116,
      child: OverflowBox(
        maxWidth: double.infinity,
        alignment: Alignment.centerLeft,
        child: Transform.translate(
          offset: Offset(dx, 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final film in repeated)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: SizedBox(
                    width: 84,
                    height: 116,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(11),
                      child: _buildClassicPosterArtwork(film, compact: true),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Act 2: Real classic cinema poster wall with 4K/DV spec badges & resume bars.
  Widget _buildAct2ClassicPosterWall(
    bool wide,
    bool zh,
    FirstPlayHintPlatform platform,
    bool isIos,
    bool highContrast,
    ApplePalette palette,
  ) {
    final columns = wide ? 4 : 3;
    final isDesktop = platform == FirstPlayHintPlatform.desktop;

    return _buildSplit(
      wide: wide,
      left: _buildActCopy(
        eyebrow: zh ? '豆瓣高分 · 专题片单' : 'Curated Discovery & 4K Specs',
        headline: zh ? '高分经典一目了然，4K 规格自动识别' : 'Classic Poster Wall & Live Spec Badges',
        body: zh
            ? '内置近期国内热门、豆瓣高分、烂番茄、迪士尼、漫威与 DC 等发现专题，自动识别 4K、杜比视界与全景声规格，点选后即刻匹配你添加的片源播放。'
            : 'Explore curated collections across Douban Top 250, Rotten Tomatoes, Disney, Marvel, and DC with automatic 4K / Dolby Vision badges and resume progress.',
        palette: palette,
      ),
      right: _buildGlassCard(
        highContrast: highContrast,
        palette: palette,
        padding: const EdgeInsets.all(14),
        child: GridView.builder(
          key: const Key('onboarding_demo_poster_grid'),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _kClassicShowcaseFilms.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 10,
            mainAxisSpacing: 12,
            childAspectRatio: 0.54,
          ),
          itemBuilder: (context, index) => _buildClassicPosterCard(
            _kClassicShowcaseFilms[index],
            zh: zh,
            isDesktop: isDesktop,
            isIos: isIos,
            highContrast: highContrast,
            palette: palette,
          ),
        ),
      ),
    );
  }

  Widget _buildClassicPosterArtwork(
    _ClassicShowcaseFilm film, {
    bool compact = false,
  }) {
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: film.gradient,
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Text(
            film.titleZh,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.82),
              fontSize: compact ? 10.5 : 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
    return PosterImage(
      url: '',
      title: film.titleZh,
      year: film.year,
      fit: BoxFit.cover,
      fadeIn: false,
      placeholder: fallback,
    );
  }

  Widget _buildClassicPosterCard(
    _ClassicShowcaseFilm film, {
    required bool zh,
    required bool isDesktop,
    required bool isIos,
    required bool highContrast,
    required ApplePalette palette,
  }) {
    final card = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildClassicPosterArtwork(film),
                Positioned(
                  top: 5,
                  right: 5,
                  child: Container(
                    key: Key('demo_badge_${film.id}'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5.5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xCC101218),
                      borderRadius: BorderRadius.circular(isIos ? 999 : 6),
                      border: Border.all(
                        color: const Color(0x55FFFFFF),
                        width: 0.7,
                      ),
                    ),
                    child: Text(
                      film.rating,
                      style: const TextStyle(
                        color: Color(0xFFFFD666),
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                if (film.progress > 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      height: 3.5,
                      color: const Color(0x66000000),
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: film.progress,
                        child: Container(color: const Color(0xFF0A84FF)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          film.title(zh: zh),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: palette.labelPrimary,
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (film.specs.isNotEmpty) ...[
          const SizedBox(height: 3.5),
          Wrap(
            spacing: 4,
            runSpacing: 3,
            children: film.specs
                .take(2)
                .map(
                  (spec) => _buildSpecPill(
                    spec,
                    isIos: isIos,
                    highContrast: highContrast,
                    isDark: palette.isDark,
                  ),
                )
                .toList(),
          ),
        ],
      ],
    );

    if (isDesktop) {
      return Tooltip(
        message: '${film.title(zh: zh)} · ${film.specs.join(' · ')}',
        child: card,
      );
    }
    return card;
  }

  Widget _buildSpecPill(
    String spec, {
    required bool isIos,
    required bool highContrast,
    bool isDark = true,
  }) {
    final isGold = spec.contains('4K');
    final isPurple = spec.contains('DV') || spec.contains('ATMOS');
    final fill = isDark
        ? (highContrast
            ? (isGold
                ? const Color(0xEB3A2810)
                : (isPurple
                    ? const Color(0xEB261F42)
                    : const Color(0xEB122640)))
            : (isGold
                ? const Color(0x2EFF9F0A)
                : (isPurple
                    ? const Color(0x335E5CE6)
                    : const Color(0x2E0A84FF))))
        : (isGold
            ? const Color(0x1FD97706)
            : (isPurple
                ? const Color(0x1A6D28D9)
                : const Color(0x18007AFF)));
    final stroke = isGold
        ? const Color(0x66D97706)
        : (isPurple ? const Color(0x667C3AED) : const Color(0x55007AFF));
    final text = isDark
        ? (isGold
            ? const Color(0xFFFFB340)
            : (isPurple ? const Color(0xFFE5C7FF) : const Color(0xFF64D2FF)))
        : (isGold
            ? const Color(0xFFB45309)
            : (isPurple ? const Color(0xFF6D28D9) : const Color(0xFF0066CC)));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(isIos ? 999 : 5),
        border: Border.all(color: stroke, width: 0.8),
      ),
      child: Text(
        spec,
        style: TextStyle(
          color: text,
          fontSize: 9.2,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  /// Act 3: Animated orbital multi-device sync constellation.
  Widget _buildAct3SyncOrbit(
    bool wide,
    bool zh,
    bool highContrast,
    ApplePalette palette,
  ) {
    const devices = [
      (icon: CupertinoIcons.device_phone_portrait, label: 'iPhone', color: Color(0xFF0A84FF)),
      (icon: CupertinoIcons.device_laptop, label: 'Mac / Win', color: Color(0xFFBF5AF2)),
      (icon: CupertinoIcons.tv, label: 'Apple TV', color: Color(0xFF30D158)),
      (icon: CupertinoIcons.cloud_fill, label: 'WebDAV', color: Color(0xFF5AC8FA)),
    ];

    return _buildSplit(
      wide: wide,
      left: _buildActCopy(
        eyebrow: zh ? '跨端同步 · 随处续播' : 'Multi-Device Sync',
        headline: zh ? '进度、收藏与片源，全设备丝滑流转' : 'History, Favorites & Sources in Sync',
        body: zh
            ? '基于 marco-movie-sync v2 协议，支持 WebDAV 云同步与同一局域网免云盘点对点直连。隐私空间与网盘凭据始终仅留在本机。'
            : 'Powered by marco-movie-sync v2 with WebDAV and cloud-free LAN peer-to-peer sync. Privacy space and netdisk credentials stay strictly device-local.',
        palette: palette,
        action: OutlinedButton.icon(
          key: const Key('onboarding_act3_sync_button'),
          onPressed: widget.onOpenSync,
          icon: const Icon(CupertinoIcons.arrow_2_circlepath, size: 16),
          label: Text(zh ? '配置同步' : 'Configure Sync'),
          style: OutlinedButton.styleFrom(
            foregroundColor: palette.labelPrimary,
            side: BorderSide(
              color: palette.isDark
                  ? const Color(0x55FFFFFF)
                  : Colors.black.withValues(alpha: 0.18),
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
      ),
      right: _buildGlassCard(
        highContrast: highContrast,
        palette: palette,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 196,
              child: AnimatedBuilder(
                animation: _ambientCtrl,
                builder: (context, _) {
                  final rot = _ambientCtrl.value * 2 * math.pi;
                  return LayoutBuilder(
                    builder: (ctx, box) {
                      final cx = box.maxWidth / 2;
                      final cy = box.maxHeight / 2;
                      final rx = math.min(box.maxWidth * 0.34, 114.0);
                      const ry = 60.0;
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Center(
                            child: Container(
                              width: rx * 2,
                              height: ry * 2,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: palette.accent.withValues(alpha: 0.24),
                                  width: 1.1,
                                ),
                              ),
                            ),
                          ),
                          Center(
                            child: Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xFF0A84FF),
                                    Color(0xFF5E5CE6),
                                  ],
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF0A84FF)
                                        .withValues(alpha: 0.42),
                                    blurRadius: 20,
                                  ),
                                ],
                              ),
                              child: const Icon(
                                CupertinoIcons.arrow_2_circlepath,
                                color: Colors.white,
                                size: 25,
                              ),
                            ),
                          ),
                          for (var i = 0; i < devices.length; i++)
                            Builder(
                              builder: (_) {
                                final a = rot + (i * math.pi / 2);
                                final x = cx + rx * math.cos(a) - 36;
                                final y = cy + ry * math.sin(a) - 26;
                                final dev = devices[i];
                                return Positioned(
                                  left: x,
                                  top: y,
                                  child: Container(
                                    width: 72,
                                    height: 52,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: palette.isDark
                                          ? const Color(0xE6181C28)
                                          : palette.groupedPrimary,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: dev.color.withValues(alpha: 0.55),
                                        width: 0.9,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: dev.color
                                              .withValues(alpha: 0.18),
                                          blurRadius: 10,
                                        ),
                                      ],
                                    ),
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(dev.icon,
                                            color: dev.color, size: 15),
                                        const SizedBox(height: 2),
                                        Text(
                                          dev.label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: palette.labelPrimary,
                                            fontSize: 9.5,
                                            height: 1.1,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Text(
              zh
                  ? '安全边界：隐私空间与网盘凭据始终留在本机，绝不上传'
                  : 'Privacy boundary: Privacy space & netdisk credentials stay device-local',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: palette.isDark
                    ? const Color(0xFFBF5AF2)
                    : const Color(0xFF7C3AED),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Act 4: Real classic cinema backdrop (`星际穿越`) inside an iOS 26 Liquid Glass HUD.
  Widget _buildAct4CinemaHud(
    bool wide,
    bool zh,
    FirstPlayHintPlatform platform,
    bool isIos,
    bool highContrast,
    bool disableAnimations,
    ApplePalette palette,
  ) {
    final states = switch (platform) {
      FirstPlayHintPlatform.desktop => zh
          ? [
              '状态 1/3：短按 / 长按 ← / → 快进预览',
              '状态 2/3：Space 暂停 · S / [ ] 倍速 · D 弹幕',
              '状态 3/3：滚轮调音量 · 光标静止 2.5s 自动隐去',
            ]
          : [
              'Step 1/3: Short / Hold ← / → scrub preview',
              'Step 2/3: Space · S / [ ] speed · D danmaku',
              'Step 3/3: Scroll volume · Cursor hides after 2.5s',
            ],
      FirstPlayHintPlatform.tv => zh
          ? [
              '状态 1/3：短按 ← / → 快进快退 15 秒',
              '状态 2/3：长按 ← / → 加速预览，松手即播',
              '状态 3/3：按返回键取消预览，恢复原位置',
            ]
          : [
              'Step 1/3: Short Left/Right seeks 15s',
              'Step 2/3: Hold Left/Right scrubs, release to play',
              'Step 3/3: Press Back to cancel & restore',
            ],
      FirstPlayHintPlatform.touch => zh
          ? [
              '状态 1/3：长按 2.0× 倍速 · 左右滑自由调速',
              '状态 2/3：按住上滑锁定 · 🔒 2.0× 持续加速',
              '状态 3/3：双指外一切气泡弹出 · 竖屏伴随选集',
            ]
          : [
              'Step 1/3: Hold 2.0× · Slide horizontally (1.25×–3.0×)',
              'Step 2/3: Swipe up to lock · 🔒 2.0× Locked, tap to reset',
              'Step 3/3: Anchored Liquid Glass popovers · Portrait companion',
            ],
    };

    final stepIndex = _hudDemoStep % states.length;
    final progressValue =
        stepIndex == 0 ? 0.35 : (stepIndex == 1 ? 0.58 : 0.78);
    final heroFilm = _kClassicShowcaseFilms[1]; // 星际穿越

    return _buildSplit(
      wide: wide,
      left: _buildActCopy(
        eyebrow: zh ? 'iOS 26 液态玻璃播放 HUD' : 'Liquid Glass Cinema HUD',
        headline: zh ? '丝滑手势操控，复古明信片收藏' : 'Fluid Gestures & Immersive Playback',
        body: zh
            ? '融合微缩规格徽章、贴底紧凑进度工具栏、按钮弹出液态玻璃气泡、爱优腾式一键投屏与灵动岛明信片收藏动效，每一帧都为大屏观影而生。'
            : 'Compact micro spec badges, fused low bottom deck, anchored glass popovers, one-tap AirPlay/DLNA casting, and vintage postcard favorite animations.',
        palette: palette,
      ),
      right: _buildGlassCard(
        highContrast: highContrast,
        palette: palette,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Container(
                key: const Key('onboarding_act4_hud_preview'),
                height: 192,
                decoration: BoxDecoration(
                  color: const Color(0xFF0C1222),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0x38FFFFFF)),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Real classic movie artwork behind the glass HUD
                    Opacity(
                      opacity: 0.48,
                      child: _buildClassicPosterArtwork(heroFilm),
                    ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x990A0F1A),
                            Color(0x400A0F1A),
                            Color(0xCC06080E),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Stack(
                        children: [
                          Positioned(
                            top: 0,
                            left: 0,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  heroFilm.title(zh: zh),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                _buildSpecPill(
                                  '4K',
                                  isIos: isIos,
                                  highContrast: highContrast,
                                  isDark: true,
                                ),
                                const SizedBox(width: 4),
                                _buildSpecPill(
                                  'DV · ATMOS',
                                  isIos: isIos,
                                  highContrast: highContrast,
                                  isDark: true,
                                ),
                              ],
                            ),
                          ),
                          // Gliding danmaku preview
                          AnimatedBuilder(
                            animation: _ambientCtrl,
                            builder: (context, _) {
                              final slide = 1.0 - ((_ambientCtrl.value * 2.5) % 1.0);
                              return Positioned(
                                top: 28,
                                right: -20 + slide * 64,
                                child: Text(
                                  zh
                                      ? '爱是唯一能够超越时间与空间的事物 ✨'
                                      : 'Love is the one thing that transcends time & space ✨',
                                  style: const TextStyle(
                                    color: Color(0xE6FFFFFF),
                                    fontSize: 11,
                                    shadows: [
                                      Shadow(
                                        color: Colors.black87,
                                        blurRadius: 4,
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                          Center(
                            child: AnimatedSwitcher(
                              duration: Duration(
                                milliseconds: disableAnimations ? 0 : 200,
                              ),
                              child: Container(
                                key: ValueKey<int>(stepIndex),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xD9101626),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: const Color(0xFF0A84FF),
                                  ),
                                ),
                                child: Text(
                                  states[stepIndex],
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Color(0xFFF5F5F7),
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 0,
                            bottom: 12,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xD9241B10),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: const Color(0x88FF9F0A),
                                ),
                              ),
                              child: Text(
                                zh ? '3s 跳过片头' : 'Skip Intro 3s',
                                style: const TextStyle(
                                  color: Color(0xFFFFB340),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: progressValue,
                                minHeight: 4,
                                backgroundColor: const Color(0x38FFFFFF),
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                  Color(0xFF0A84FF),
                                ),
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
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                key: const Key('onboarding_act4_cycle_button'),
                onPressed: () =>
                    setState(() => _hudDemoStep = (_hudDemoStep + 1) % 3),
                style: OutlinedButton.styleFrom(
                  foregroundColor: palette.labelPrimary,
                  side: BorderSide(
                    color: palette.isDark
                        ? const Color(0x55FFFFFF)
                        : Colors.black.withValues(alpha: 0.16),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  zh
                      ? '体验操控演示 (${stepIndex + 1}/3)'
                      : 'Cycle Control Demo (${stepIndex + 1}/3)',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Act 5: Personalization & instant launch.
  Widget _buildAct5Personalize(
    bool wide,
    bool zh,
    bool highContrast,
    ApplePalette palette,
  ) {
    return _buildSplit(
      wide: wide,
      left: _buildActCopy(
        eyebrow: zh ? '个性舒适 · 准备就绪' : 'Personalize & Launch',
        headline: zh ? '按你的习惯，微调观影质感' : 'Tailor Comfort & Visuals',
        body: zh
            ? '主题自动跟随系统在柔和浅色与深色夜间之间切换；也可随时在「设置 -> 关于与更新 -> 重新查看新手引导」再次打开本引导。'
            : 'Appearance follows your system Light/Dark mode automatically. Replay this guide anytime in Settings -> About & Help.',
        palette: palette,
        action: _buildPrimaryCta(
          key: const Key('onboarding_act5_import_button'),
          label: zh ? '立即导入配置' : 'Import Config Now',
          symbol: 'square.and.arrow.down',
          onTap: () => _finish(skipped: false, openImportAfter: true),
        ),
      ),
      right: _buildGlassCard(
        highContrast: highContrast,
        palette: palette,
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile.adaptive(
                key: const Key('onboarding_reduce_motion_switch'),
                contentPadding: EdgeInsets.zero,
                title: Text(
                  zh ? '减少动态效果' : 'Reduce Motion',
                  style: TextStyle(
                    color: palette.labelPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                value: _reduceMotion,
                onChanged: (v) {
                  setState(() => _reduceMotion = v);
                  _notifyPersonalization();
                },
              ),
              SwitchListTile.adaptive(
                key: const Key('onboarding_reduce_transparency_switch'),
                contentPadding: EdgeInsets.zero,
                title: Text(
                  zh ? '降低透明度（高对比纯色）' : 'Reduce Transparency',
                  style: TextStyle(
                    color: palette.labelPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                value: _reduceTransparency,
                onChanged: (v) {
                  setState(() => _reduceTransparency = v);
                  _notifyPersonalization();
                },
              ),
              const SizedBox(height: 8),
              Text(
                zh
                    ? '字号预览：${(_textScale * 100).round()}%'
                    : 'Text Scale: ${(_textScale * 100).round()}%',
                style: TextStyle(color: palette.labelSecondary, fontSize: 13),
              ),
              Slider(
                key: const Key('onboarding_text_scale_slider'),
                min: 0.85,
                max: 1.35,
                divisions: 5,
                value: _textScale,
                onChanged: (v) {
                  setState(() => _textScale = v);
                  _notifyPersonalization();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
