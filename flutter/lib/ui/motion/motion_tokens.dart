// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:math' as math;

import 'package:flutter/animation.dart';

/// Immutable physical spring token aligned 1:1 with `shared/ui-spec/motion-tokens.json`.
class MotionSpringToken {
  final double response;
  final double dampingRatio;
  final double mass;
  final double stiffness;
  final double viscousDamping;
  final double motionSpringFrequency;

  const MotionSpringToken({
    required this.response,
    required this.dampingRatio,
    required this.mass,
    required this.stiffness,
    required this.viscousDamping,
    required this.motionSpringFrequency,
  });

  SpringDescription toSpringDescription() => SpringDescription(
        mass: mass,
        stiffness: stiffness,
        damping: viscousDamping,
      );
}

/// Text-only media spec badge size metrics from `shared/ui-spec/motion-tokens.json`.
class MotionBadgeMetrics {
  final double height;
  final double paddingHorizontal;
  final double paddingVertical;
  final double cornerRadius;
  final double? iosConcentricRadius;
  final double borderWidth;
  final double fontSize;
  final int fontWeight;
  final double letterSpacing;
  final double gap;

  const MotionBadgeMetrics({
    required this.height,
    required this.paddingHorizontal,
    required this.paddingVertical,
    required this.cornerRadius,
    this.iosConcentricRadius,
    required this.borderWidth,
    required this.fontSize,
    required this.fontWeight,
    required this.letterSpacing,
    required this.gap,
  });
}

/// Text-only media spec badge color palette from `shared/ui-spec/motion-tokens.json`.
class MotionBadgeStyle {
  final Color fill;
  final Color stroke;
  final Color text;
  final Color solidFill;
  final Color focusedFill;
  final Color focusedStroke;
  final Color focusedText;

  const MotionBadgeStyle({
    required this.fill,
    required this.stroke,
    required this.text,
    required this.solidFill,
    required this.focusedFill,
    required this.focusedStroke,
    required this.focusedText,
  });
}

/// Cross-platform motion timings, curves, physical springs, accessibility
/// substitutions, and aurora palette constants mirroring
/// `shared/ui-spec/motion-tokens.json` (schemaVersion 2).
final class MotionTokens {
  MotionTokens._();

  static const int schemaVersion = 2;

  // --- durationsMs ---
  static const int durationInstantMs = 0;
  static const int durationMicroMs = 90;
  static const int durationReducedHudFadeMs = 120;
  static const int durationFastMs = 150;
  static const int durationWindowsRouteExitMs = 150;
  static const int durationTvPageFadeMs = 180;
  static const int durationWindowsRouteEnterMs = 185;
  static const int durationStandardMs = 220;
  static const int durationTvPlayExitMs = 220;
  static const int durationMobileSharedBoundsMs = 280;
  static const int durationTransitionExitMs = 300;
  static const int durationEmphasizedMs = 320;
  static const int durationTransitionEnterMs = 420;
  static const int durationLogoLoopMs = 1600;
  static const int durationAuroraCycleMs = 16000;

  static const Duration durationInstant =
      Duration(milliseconds: durationInstantMs);
  static const Duration durationMicro = Duration(milliseconds: durationMicroMs);
  static const Duration durationReducedHudFade =
      Duration(milliseconds: durationReducedHudFadeMs);
  static const Duration durationFast = Duration(milliseconds: durationFastMs);
  static const Duration durationWindowsRouteExit =
      Duration(milliseconds: durationWindowsRouteExitMs);
  static const Duration durationTvPageFade =
      Duration(milliseconds: durationTvPageFadeMs);
  static const Duration durationWindowsRouteEnter =
      Duration(milliseconds: durationWindowsRouteEnterMs);
  static const Duration durationStandard =
      Duration(milliseconds: durationStandardMs);
  static const Duration durationTvPlayExit =
      Duration(milliseconds: durationTvPlayExitMs);
  static const Duration durationMobileSharedBounds =
      Duration(milliseconds: durationMobileSharedBoundsMs);
  static const Duration durationTransitionExit =
      Duration(milliseconds: durationTransitionExitMs);
  static const Duration durationEmphasized =
      Duration(milliseconds: durationEmphasizedMs);
  static const Duration durationTransitionEnter =
      Duration(milliseconds: durationTransitionEnterMs);
  static const Duration durationLogoLoop =
      Duration(milliseconds: durationLogoLoopMs);
  static const Duration durationAuroraCycle =
      Duration(milliseconds: durationAuroraCycleMs);

  // --- hudTimersMs ---
  static const int hudStartSpecFadeInMs = 180;
  static const int hudStartSpecDisplayMs = 3000;
  static const int hudStartSpecFadeOutMs = 240;
  static const int hudDesktopCursorIdleHideMs = 2500;
  static const int hudTouchControlsIdleHideMs = 4000;
  static const int hudSkipCountdownTotalMs = 3000;
  static const int hudTouchHoldSpeedBoostThresholdMs = 350;
  static const int hudTouchHoldFastForwardThresholdMs = 350;
  static const int hudDesktopHoldFastForwardThresholdMs = 280;
  static const int hudTvHoldFastForwardThresholdMs = 500;
  static const int hudDanmuSeekDebounceMs = 180;
  static const int hudTransitionCaptureBudgetMs = 16;

  // --- gestureThresholds ---
  static const double gestureTouchSlopDp = 12.0;
  static const int gestureDoubleTapTimeoutMs = 260;
  static const double gestureDoubleTapSlopDp = 42.0;
  static const int gestureMultiTapSeekWindowMs = 650;
  static const double gestureEdgeBackGuardDp = 24.0;
  static const double gestureSystemVerticalGuardDp = 28.0;
  static const double gestureSpeedSlideStepDp = 36.0;
  static const double gestureTouchSwipeLockThresholdDp = 48.0;
  static const double gestureTouchSwipeLockReleaseHysteresisDp = 36.0;
  static const List<double> gestureSpeedBoostDetents = <double>[
    1.25,
    1.5,
    2.0,
    3.0,
  ];
  static const double gestureDefaultBoostSpeed = 2.0;

  // --- ios26PlayerGlassMetrics ---
  static const double ios26TopCapsuleHeightPt = 40.0;
  static const double ios26TopCapsuleRadiusPt = 20.0;
  static const double ios26CenterPrimaryButtonSizePt = 76.0;
  static const double ios26CenterSecondaryButtonSizePt = 56.0;
  static const double ios26ScrubberTrackIdleHeightPt = 5.0;
  static const double ios26ScrubberTrackExpandedHeightPt = 10.0;
  static const double ios26DockCapsuleRadiusPt = 22.0;
  static const int ios26MaxPrimaryDockActions = 7;

  // --- curves ---
  static const List<double> curveStandardPoints = <double>[0.2, 0.0, 0.0, 1.0];
  static const List<double> curveDeceleratePoints = <double>[
    0.05,
    0.7,
    0.1,
    1.0,
  ];
  static const List<double> curveAcceleratePoints = <double>[
    0.3,
    0.0,
    0.8,
    0.15,
  ];
  static const List<double> curveLinearPoints = <double>[0.0, 0.0, 1.0, 1.0];

  static const Curve curveStandard = Cubic(0.2, 0.0, 0.0, 1.0);
  static const Curve curveDecelerate = Cubic(0.05, 0.7, 0.1, 1.0);
  static const Curve curveAccelerate = Cubic(0.3, 0.0, 0.8, 0.15);
  static const Curve curveLinear = Curves.linear;

  // --- springs ---
  static const MotionSpringToken springTvFocus = MotionSpringToken(
    response: 0.21,
    dampingRatio: 1.0,
    mass: 1.0,
    stiffness: 895.2,
    viscousDamping: 59.84,
    motionSpringFrequency: 30.0,
  );

  static const MotionSpringToken springPressFeedback = MotionSpringToken(
    response: 0.16,
    dampingRatio: 1.0,
    mass: 1.0,
    stiffness: 1542.13,
    viscousDamping: 78.54,
    motionSpringFrequency: 40.0,
  );

  static const MotionSpringToken springHudPopup = MotionSpringToken(
    response: 0.28,
    dampingRatio: 0.86,
    mass: 1.0,
    stiffness: 503.55,
    viscousDamping: 38.6,
    motionSpringFrequency: 22.44,
  );

  static const MotionSpringToken springPlayerTransition = MotionSpringToken(
    response: 0.42,
    dampingRatio: 0.92,
    mass: 1.0,
    stiffness: 223.8,
    viscousDamping: 27.53,
    motionSpringFrequency: 14.96,
  );

  static const MotionSpringToken springIos27Snappy = MotionSpringToken(
    response: 0.28,
    dampingRatio: 0.88,
    mass: 1.0,
    stiffness: 503.5508,
    viscousDamping: 39.4943,
    motionSpringFrequency: 22.4399,
  );

  static const MotionSpringToken springIos27Smooth = MotionSpringToken(
    response: 0.38,
    dampingRatio: 1.0,
    mass: 1.0,
    stiffness: 273.3961,
    viscousDamping: 33.0694,
    motionSpringFrequency: 16.5347,
  );

  static const MotionSpringToken springIos27Bouncy = MotionSpringToken(
    response: 0.44,
    dampingRatio: 0.76,
    mass: 1.0,
    stiffness: 203.9179,
    viscousDamping: 21.7056,
    motionSpringFrequency: 14.28,
  );

  // --- ios27ConcentricGeometry ---
  static const double ios27PhoneInsetMarginPt = 10.0;
  static const double ios27SheetOuterRadiusPt = 32.0;
  static const double ios27MinInnerRadiusPt = 8.0;
  static const double ios27PressSwellScale = 1.035;
  static const int ios27ReducedMotionTransitionDurationMs = 150;

  static double omegaRadPerSec(double response) => (2.0 * math.pi) / response;

  static double computeStiffness(double mass, double response) {
    final omega = omegaRadPerSec(response);
    return mass * omega * omega;
  }

  static double computeViscousDamping(
    double dampingRatio,
    double stiffness,
    double mass,
  ) =>
      2.0 * dampingRatio * math.sqrt(stiffness * mass);

  // --- accessibilitySubstitutions.reduceMotion ---
  static const String reduceMotionTransitionMode = 'crossFade';
  static const int reduceMotionTransitionDurationMs = 150;
  static const String reduceMotionTransitionCurve = 'linear';
  static const double reduceMotionTransitionScale = 1.0;
  static const bool reduceMotionTransitionShaderEnabled = false;

  static const String reduceMotionTvFocusMode = 'snap';
  static const int reduceMotionTvFocusDurationMs = 0;
  static const double reduceMotionTvFocusScale = 1.0;
  static const bool reduceMotionTvFocusKeepStrokeAndFill = true;

  static const String reduceMotionHudMode = 'opacityOnly';
  static const int reduceMotionHudDurationMs = 120;
  static const String reduceMotionHudCurve = 'linear';
  static const double reduceMotionHudTranslateDp = 0.0;

  static const String reduceMotionAuroraMode = 'staticFrame';
  static const double reduceMotionAuroraFrozenTimeSec = 0.0;
  static const bool reduceMotionAuroraTickerRunning = false;

  static const String reduceMotionLogoMode = 'staticBreathingAlpha';
  static const int reduceMotionLogoCycleMs = 1600;
  static const double reduceMotionLogoMinAlpha = 0.72;
  static const double reduceMotionLogoMaxAlpha = 1.0;

  // --- accessibilitySubstitutions.reduceTransparency ---
  static const Color reduceTransparencyGlassSurfaceFill = Color(0xF51E1E22);
  static const Color reduceTransparencyHudBackdropFill = Color(0xEB16161A);
  static const bool reduceTransparencyUseBadgeSolidFill = true;
  static const double reduceTransparencyMinBorderAlpha = 0.45;
  static const bool reduceTransparencyDisableShaderRefraction = true;

  // --- scaleTokens ---
  static const Map<int, double> androidUiScalePercent = <int, double>{
    100: 1.0,
    110: 1.1,
    120: 1.2,
  };
  static const double flutterTextScaleClampMin = 0.85;
  static const double flutterTextScaleClampMax = 1.35;

  static const double tvFocusPosterScale = 1.05;
  static const double tvFocusPillScale = 1.06;
  static const double tvFocusReducedScale = 1.0;
  static const double tvFocusStrokeWidthDp = 2.0;
  static const Color tvFocusStrokeColor = Color(0xFFF5F5F7);

  static const MotionBadgeMetrics badgeMetricsCompact = MotionBadgeMetrics(
    height: 20,
    paddingHorizontal: 6,
    paddingVertical: 2,
    cornerRadius: 5,
    iosConcentricRadius: 999,
    borderWidth: 1.0,
    fontSize: 11,
    fontWeight: 600,
    letterSpacing: 0.3,
    gap: 4,
  );

  static const MotionBadgeMetrics badgeMetricsStartSpec = MotionBadgeMetrics(
    height: 24,
    paddingHorizontal: 8,
    paddingVertical: 3,
    cornerRadius: 6,
    iosConcentricRadius: 999,
    borderWidth: 1.0,
    fontSize: 12,
    fontWeight: 700,
    letterSpacing: 0.35,
    gap: 6,
  );

  static const MotionBadgeMetrics badgeMetricsTv = MotionBadgeMetrics(
    height: 28,
    paddingHorizontal: 10,
    paddingVertical: 4,
    cornerRadius: 7,
    borderWidth: 1.5,
    fontSize: 14,
    fontWeight: 700,
    letterSpacing: 0.4,
    gap: 8,
  );

  // --- badgeStyles ---
  static const Map<String, MotionBadgeStyle> badgeStyles =
      <String, MotionBadgeStyle>{
    'uhdGold': MotionBadgeStyle(
      fill: Color(0x2EFF9F0A),
      stroke: Color(0x66FF9F0A),
      text: Color(0xFFFFB340),
      solidFill: Color(0xEB3A2810),
      focusedFill: Color(0xFFF5F5F7),
      focusedStroke: Color(0xFFF5F5F7),
      focusedText: Color(0xFF101013),
    ),
    'hdCyan': MotionBadgeStyle(
      fill: Color(0x2964D2FF),
      stroke: Color(0x5C64D2FF),
      text: Color(0xFF70D7FF),
      solidFill: Color(0xEB142C38),
      focusedFill: Color(0xFFF5F5F7),
      focusedStroke: Color(0xFFF5F5F7),
      focusedText: Color(0xFF101013),
    ),
    'sdNeutral': MotionBadgeStyle(
      fill: Color(0x33787884),
      stroke: Color(0x4DEBEBF5),
      text: Color(0xFFD1D1DA),
      solidFill: Color(0xEB25252B),
      focusedFill: Color(0xFFF5F5F7),
      focusedStroke: Color(0xFFF5F5F7),
      focusedText: Color(0xFF101013),
    ),
    'premiumCombo': MotionBadgeStyle(
      fill: Color(0x335E5CE6),
      stroke: Color(0x73BF5AF2),
      text: Color(0xFFE5C7FF),
      solidFill: Color(0xEB261F42),
      focusedFill: Color(0xFFF5F5F7),
      focusedStroke: Color(0xFFF5F5F7),
      focusedText: Color(0xFF101013),
    ),
    'visionPurple': MotionBadgeStyle(
      fill: Color(0x2EBF5AF2),
      stroke: Color(0x66BF5AF2),
      text: Color(0xFFDEB0FF),
      solidFill: Color(0xEB2D1B38),
      focusedFill: Color(0xFFF5F5F7),
      focusedStroke: Color(0xFFF5F5F7),
      focusedText: Color(0xFF101013),
    ),
    'hdrBlue': MotionBadgeStyle(
      fill: Color(0x2E0A84FF),
      stroke: Color(0x660A84FF),
      text: Color(0xFF64D2FF),
      solidFill: Color(0xEB122640),
      focusedFill: Color(0xFFF5F5F7),
      focusedStroke: Color(0xFFF5F5F7),
      focusedText: Color(0xFF101013),
    ),
    'discEmerald': MotionBadgeStyle(
      fill: Color(0x2930D158),
      stroke: Color(0x5C30D158),
      text: Color(0xFF63E682),
      solidFill: Color(0xEB142E1C),
      focusedFill: Color(0xFFF5F5F7),
      focusedStroke: Color(0xFFF5F5F7),
      focusedText: Color(0xFF101013),
    ),
    'streamTeal': MotionBadgeStyle(
      fill: Color(0x265AC8FA),
      stroke: Color(0x525AC8FA),
      text: Color(0xFF82D7FF),
      solidFill: Color(0xEB152936),
      focusedFill: Color(0xFFF5F5F7),
      focusedStroke: Color(0xFFF5F5F7),
      focusedText: Color(0xFF101013),
    ),
    'spatialAudio': MotionBadgeStyle(
      fill: Color(0x2E0A84FF),
      stroke: Color(0x665AC8FA),
      text: Color(0xFF8AE0FF),
      solidFill: Color(0xEB13283D),
      focusedFill: Color(0xFFF5F5F7),
      focusedStroke: Color(0xFFF5F5F7),
      focusedText: Color(0xFF101013),
    ),
    'standardAudio': MotionBadgeStyle(
      fill: Color(0x38787884),
      stroke: Color(0x3BFFFFFF),
      text: Color(0xFFF5F5F7),
      solidFill: Color(0xEB28282E),
      focusedFill: Color(0xFFF5F5F7),
      focusedStroke: Color(0xFFF5F5F7),
      focusedText: Color(0xFF101013),
    ),
    'codecSlate': MotionBadgeStyle(
      fill: Color(0x29787884),
      stroke: Color(0x29FFFFFF),
      text: Color(0xFFD1D1DA),
      solidFill: Color(0xEB222228),
      focusedFill: Color(0xFFF5F5F7),
      focusedStroke: Color(0xFFF5F5F7),
      focusedText: Color(0xFF101013),
    ),
    'platformTag': MotionBadgeStyle(
      fill: Color(0x2E36363D),
      stroke: Color(0x45FFFFFF),
      text: Color(0xFFEBEBF5),
      solidFill: Color(0xEB28282E),
      focusedFill: Color(0xFFF5F5F7),
      focusedStroke: Color(0xFFF5F5F7),
      focusedText: Color(0xFF101013),
    ),
  };

  static const String liteBadgeSeparator = ' · ';
  static const Color liteBadgeMetaText = Color(0xFF64D2FF);
  static const Color liteBadgeChipIdleText = Color(0xFFEEEEF2);
  static const Color liteBadgeChipSelectedFill = Color(0xFF0A84FF);
  static const Color liteBadgeChipFocusedFill = Color(0xFFF5F5F7);
  static const Color liteBadgeChipFocusedText = Color(0xFF101013);
  static const int liteBadgeMaxInlineBadges = 4;

  // --- auroraPalette ---
  static const Color auroraBaseCanvas = Color(0xFF09090C);
  static const Color auroraWaveBlue = Color(0xFF0A84FF);
  static const Color auroraWaveTeal = Color(0xFF5AC8FA);
  static const Color auroraWaveIndigo = Color(0xFF5E5CE6);
  static const Color auroraWavePurple = Color(0xFFBF5AF2);
  static const double auroraTimeRateRadPerSec = 0.38;
  static const double auroraDefaultStrength = 0.62;

  /// Exact wrap period (`2000 * pi`) specified by `transitions-spec.md` §2.2
  /// so sub-harmonic multipliers `{0.45, 0.55, 0.65, 0.70, 0.85}` wrap seamlessly
  /// without mobile `mediump` float precision degradation.
  static const double auroraWrapPeriodSec = 6283.1853;

  static double wrapAuroraElapsedSeconds(double rawSec) {
    if (!rawSec.isFinite) return 0.0;
    final mod = rawSec % auroraWrapPeriodSec;
    return mod < 0.0 ? mod + auroraWrapPeriodSec : mod;
  }
}
