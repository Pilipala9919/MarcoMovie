// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/ui/motion/motion_tokens.dart';

int _parseArgb(String hex) {
  expect(hex.startsWith('#'), isTrue);
  expect(hex.length, 9);
  return int.parse(hex.substring(1), radix: 16);
}

void main() {
  test('MotionTokens matches shared/ui-spec/motion-tokens.json verbatim', () {
    final specFile = File('../shared/ui-spec/motion-tokens.json');
    expect(specFile.existsSync(), isTrue,
        reason: 'shared/ui-spec/motion-tokens.json must exist relative to flutter/');
    final doc = jsonDecode(specFile.readAsStringSync()) as Map<String, dynamic>;

    expect(MotionTokens.schemaVersion, doc['schemaVersion']);

    final dur = doc['durationsMs'] as Map<String, dynamic>;
    expect(MotionTokens.durationInstantMs, dur['instant']);
    expect(MotionTokens.durationMicroMs, dur['micro']);
    expect(MotionTokens.durationReducedHudFadeMs, dur['reducedHudFade']);
    expect(MotionTokens.durationFastMs, dur['fast']);
    expect(MotionTokens.durationWindowsRouteExitMs, dur['windowsRouteExit']);
    expect(MotionTokens.durationTvPageFadeMs, dur['tvPageFade']);
    expect(MotionTokens.durationWindowsRouteEnterMs, dur['windowsRouteEnter']);
    expect(MotionTokens.durationStandardMs, dur['standard']);
    expect(MotionTokens.durationTvPlayExitMs, dur['tvPlayExit']);
    expect(MotionTokens.durationMobileSharedBoundsMs, dur['mobileSharedBounds']);
    expect(MotionTokens.durationTransitionExitMs, dur['transitionExit']);
    expect(MotionTokens.durationEmphasizedMs, dur['emphasized']);
    expect(MotionTokens.durationTransitionEnterMs, dur['transitionEnter']);
    expect(MotionTokens.durationLogoLoopMs, dur['logoLoop']);
    expect(MotionTokens.durationAuroraCycleMs, dur['auroraCycle']);

    final hud = doc['hudTimersMs'] as Map<String, dynamic>;
    expect(MotionTokens.hudStartSpecFadeInMs, hud['startSpecFadeIn']);
    expect(MotionTokens.hudStartSpecDisplayMs, hud['startSpecDisplay']);
    expect(MotionTokens.hudStartSpecFadeOutMs, hud['startSpecFadeOut']);
    expect(MotionTokens.hudDesktopCursorIdleHideMs, hud['desktopCursorIdleHide']);
    expect(MotionTokens.hudTouchControlsIdleHideMs, hud['touchControlsIdleHide']);
    expect(MotionTokens.hudSkipCountdownTotalMs, hud['skipCountdownTotal']);
    expect(
      MotionTokens.hudTouchHoldSpeedBoostThresholdMs,
      hud['touchHoldSpeedBoostThreshold'],
    );
    expect(
      MotionTokens.hudTouchHoldFastForwardThresholdMs,
      hud['touchHoldFastForwardThreshold'],
    );
    expect(
      MotionTokens.hudDesktopHoldFastForwardThresholdMs,
      hud['desktopHoldFastForwardThreshold'],
    );
    expect(
      MotionTokens.hudTvHoldFastForwardThresholdMs,
      hud['tvHoldFastForwardThreshold'],
    );
    expect(MotionTokens.hudDanmuSeekDebounceMs, hud['danmuSeekDebounce']);
    expect(
      MotionTokens.hudTransitionCaptureBudgetMs,
      hud['transitionCaptureBudget'],
    );

    final gest = doc['gestureThresholds'] as Map<String, dynamic>;
    expect(MotionTokens.gestureTouchSlopDp, (gest['touchSlopDp'] as num).toDouble());
    expect(MotionTokens.gestureDoubleTapTimeoutMs, gest['doubleTapTimeoutMs']);
    expect(
      MotionTokens.gestureDoubleTapSlopDp,
      (gest['doubleTapSlopDp'] as num).toDouble(),
    );
    expect(MotionTokens.gestureMultiTapSeekWindowMs, gest['multiTapSeekWindowMs']);
    expect(
      MotionTokens.gestureEdgeBackGuardDp,
      (gest['edgeBackGuardDp'] as num).toDouble(),
    );
    expect(
      MotionTokens.gestureSystemVerticalGuardDp,
      (gest['systemVerticalGuardDp'] as num).toDouble(),
    );
    expect(
      MotionTokens.gestureSpeedSlideStepDp,
      (gest['speedSlideStepDp'] as num).toDouble(),
    );
    expect(
      MotionTokens.gestureTouchSwipeLockThresholdDp,
      (gest['touchSwipeLockThresholdDp'] as num).toDouble(),
    );
    expect(
      MotionTokens.gestureTouchSwipeLockReleaseHysteresisDp,
      (gest['touchSwipeLockReleaseHysteresisDp'] as num).toDouble(),
    );
    expect(
      MotionTokens.gestureSpeedBoostDetents,
      (gest['speedBoostDetents'] as List).map((e) => (e as num).toDouble()).toList(),
    );
    expect(
      MotionTokens.gestureDefaultBoostSpeed,
      (gest['defaultBoostSpeed'] as num).toDouble(),
    );

    final ios = doc['ios26PlayerGlassMetrics'] as Map<String, dynamic>;
    expect(
      MotionTokens.ios26TopCapsuleHeightPt,
      (ios['topCapsuleHeightPt'] as num).toDouble(),
    );
    expect(
      MotionTokens.ios26TopCapsuleRadiusPt,
      (ios['topCapsuleRadiusPt'] as num).toDouble(),
    );
    expect(
      MotionTokens.ios26CenterPrimaryButtonSizePt,
      (ios['centerPrimaryButtonSizePt'] as num).toDouble(),
    );
    expect(
      MotionTokens.ios26CenterSecondaryButtonSizePt,
      (ios['centerSecondaryButtonSizePt'] as num).toDouble(),
    );
    expect(
      MotionTokens.ios26ScrubberTrackIdleHeightPt,
      (ios['scrubberTrackIdleHeightPt'] as num).toDouble(),
    );
    expect(
      MotionTokens.ios26ScrubberTrackExpandedHeightPt,
      (ios['scrubberTrackExpandedHeightPt'] as num).toDouble(),
    );
    expect(
      MotionTokens.ios26DockCapsuleRadiusPt,
      (ios['dockCapsuleRadiusPt'] as num).toDouble(),
    );
    expect(MotionTokens.ios26MaxPrimaryDockActions, ios['maxPrimaryDockActions']);

    final curves = doc['curves'] as Map<String, dynamic>;
    expect(
      MotionTokens.curveStandardPoints,
      ((curves['standard'] as Map)['cubicBezier'] as List)
          .map((e) => (e as num).toDouble())
          .toList(),
    );
    expect(
      MotionTokens.curveDeceleratePoints,
      ((curves['decelerate'] as Map)['cubicBezier'] as List)
          .map((e) => (e as num).toDouble())
          .toList(),
    );
    expect(
      MotionTokens.curveAcceleratePoints,
      ((curves['accelerate'] as Map)['cubicBezier'] as List)
          .map((e) => (e as num).toDouble())
          .toList(),
    );
    expect(
      MotionTokens.curveLinearPoints,
      ((curves['linear'] as Map)['cubicBezier'] as List)
          .map((e) => (e as num).toDouble())
          .toList(),
    );

    final presets = (doc['springs'] as Map)['presets'] as Map<String, dynamic>;
    void expectSpring(String key, MotionSpringToken token) {
      final p = presets[key] as Map<String, dynamic>;
      expect(token.response, closeTo((p['response'] as num).toDouble(), 1e-6));
      expect(token.dampingRatio, closeTo((p['dampingRatio'] as num).toDouble(), 1e-6));
      expect(token.mass, closeTo((p['mass'] as num).toDouble(), 1e-6));
      expect(token.stiffness, closeTo((p['stiffness'] as num).toDouble(), 1e-4));
      expect(
        token.viscousDamping,
        closeTo((p['viscousDamping'] as num).toDouble(), 1e-4),
      );
      expect(
        token.motionSpringFrequency,
        closeTo((p['motionSpringFrequency'] as num).toDouble(), 1e-4),
      );
      final desc = token.toSpringDescription();
      expect(desc.mass, token.mass);
      expect(desc.stiffness, token.stiffness);
      expect(desc.damping, token.viscousDamping);
    }

    expectSpring('tvFocus', MotionTokens.springTvFocus);
    expectSpring('pressFeedback', MotionTokens.springPressFeedback);
    expectSpring('hudPopup', MotionTokens.springHudPopup);
    expectSpring('playerTransition', MotionTokens.springPlayerTransition);
    expectSpring('ios27Snappy', MotionTokens.springIos27Snappy);
    expectSpring('ios27Smooth', MotionTokens.springIos27Smooth);
    expectSpring('ios27Bouncy', MotionTokens.springIos27Bouncy);

    final ios27Geo = doc['ios27ConcentricGeometry'] as Map<String, dynamic>;
    expect(
      MotionTokens.ios27PhoneInsetMarginPt,
      (ios27Geo['phoneInsetMarginPt'] as num).toDouble(),
    );
    expect(
      MotionTokens.ios27SheetOuterRadiusPt,
      (ios27Geo['sheetOuterRadiusPt'] as num).toDouble(),
    );
    expect(
      MotionTokens.ios27MinInnerRadiusPt,
      (ios27Geo['minInnerRadiusPt'] as num).toDouble(),
    );
    expect(
      MotionTokens.ios27PressSwellScale,
      (ios27Geo['pressSwellScale'] as num).toDouble(),
    );
    expect(
      MotionTokens.ios27ReducedMotionTransitionDurationMs,
      ios27Geo['reducedMotionTransitionDurationMs'],
    );

    final a11y = doc['accessibilitySubstitutions'] as Map<String, dynamic>;
    final rm = (a11y['reduceMotion'] as Map)['rules'] as Map<String, dynamic>;
    final rmTrans = rm['pageAndPlayerTransition'] as Map<String, dynamic>;
    expect(MotionTokens.reduceMotionTransitionMode, rmTrans['mode']);
    expect(MotionTokens.reduceMotionTransitionDurationMs, rmTrans['durationMs']);
    expect(MotionTokens.reduceMotionTransitionCurve, rmTrans['curve']);
    expect(MotionTokens.reduceMotionTransitionScale, (rmTrans['scale'] as num).toDouble());
    expect(MotionTokens.reduceMotionTransitionShaderEnabled, rmTrans['shaderEnabled']);

    final rmTv = rm['tvAndCardFocus'] as Map<String, dynamic>;
    expect(MotionTokens.reduceMotionTvFocusMode, rmTv['mode']);
    expect(MotionTokens.reduceMotionTvFocusDurationMs, rmTv['durationMs']);
    expect(MotionTokens.reduceMotionTvFocusScale, (rmTv['focusScale'] as num).toDouble());
    expect(
      MotionTokens.reduceMotionTvFocusKeepStrokeAndFill,
      rmTv['keepFocusStrokeAndFill'],
    );

    final rmHud = rm['hudOverlays'] as Map<String, dynamic>;
    expect(MotionTokens.reduceMotionHudMode, rmHud['mode']);
    expect(MotionTokens.reduceMotionHudDurationMs, rmHud['durationMs']);
    expect(MotionTokens.reduceMotionHudCurve, rmHud['curve']);
    expect(
      MotionTokens.reduceMotionHudTranslateDp,
      (rmHud['translateDp'] as num).toDouble(),
    );

    final rmAurora = rm['auroraBackground'] as Map<String, dynamic>;
    expect(MotionTokens.reduceMotionAuroraMode, rmAurora['mode']);
    expect(
      MotionTokens.reduceMotionAuroraFrozenTimeSec,
      (rmAurora['frozenTimeSec'] as num).toDouble(),
    );
    expect(MotionTokens.reduceMotionAuroraTickerRunning, rmAurora['tickerRunning']);

    final rmLogo = rm['brandLogoLoader'] as Map<String, dynamic>;
    expect(MotionTokens.reduceMotionLogoMode, rmLogo['mode']);
    expect(MotionTokens.reduceMotionLogoCycleMs, rmLogo['cycleMs']);
    expect(
      MotionTokens.reduceMotionLogoMinAlpha,
      (rmLogo['minAlpha'] as num).toDouble(),
    );
    expect(
      MotionTokens.reduceMotionLogoMaxAlpha,
      (rmLogo['maxAlpha'] as num).toDouble(),
    );

    final rt = (a11y['reduceTransparency'] as Map)['rules'] as Map<String, dynamic>;
    expect(
      MotionTokens.reduceTransparencyGlassSurfaceFill.toARGB32(),
      _parseArgb(rt['glassSurfaceFillArgb'] as String),
    );
    expect(
      MotionTokens.reduceTransparencyHudBackdropFill.toARGB32(),
      _parseArgb(rt['hudBackdropFillArgb'] as String),
    );
    expect(MotionTokens.reduceTransparencyUseBadgeSolidFill, rt['useBadgeSolidFill']);
    expect(
      MotionTokens.reduceTransparencyMinBorderAlpha,
      (rt['minBorderAlpha'] as num).toDouble(),
    );
    expect(
      MotionTokens.reduceTransparencyDisableShaderRefraction,
      rt['disableShaderRefraction'],
    );

    final badgeStyles = doc['badgeStyles'] as Map<String, dynamic>;
    var styleCount = 0;
    for (final entry in badgeStyles.entries) {
      final st = entry.value as Map<String, dynamic>;
      if (entry.key == 'liteTextOnly') {
        expect(MotionTokens.liteBadgeSeparator, st['separator']);
        expect(
          MotionTokens.liteBadgeMetaText.toARGB32(),
          _parseArgb(st['metaTextArgb'] as String),
        );
        expect(MotionTokens.liteBadgeMaxInlineBadges, st['maxInlineBadges']);
        continue;
      }
      styleCount++;
      final actual = MotionTokens.badgeStyles[entry.key];
      expect(actual, isNotNull, reason: 'Missing badge style ${entry.key}');
      expect(actual!.fill.toARGB32(), _parseArgb(st['fillArgb'] as String));
      expect(actual.stroke.toARGB32(), _parseArgb(st['strokeArgb'] as String));
      expect(actual.text.toARGB32(), _parseArgb(st['textArgb'] as String));
      expect(actual.solidFill.toARGB32(), _parseArgb(st['solidFillArgb'] as String));
      expect(actual.focusedFill.toARGB32(), _parseArgb(st['focusedFillArgb'] as String));
      expect(
        actual.focusedStroke.toARGB32(),
        _parseArgb(st['focusedStrokeArgb'] as String),
      );
      expect(actual.focusedText.toARGB32(), _parseArgb(st['focusedTextArgb'] as String));
    }
    expect(MotionTokens.badgeStyles.length, styleCount);

    final aurora = doc['auroraPalette'] as Map<String, dynamic>;
    expect(
      MotionTokens.auroraBaseCanvas.toARGB32(),
      _parseArgb(aurora['baseCanvasArgb'] as String),
    );
    expect(
      MotionTokens.auroraWaveBlue.toARGB32(),
      _parseArgb(aurora['waveBlueArgb'] as String),
    );
    expect(
      MotionTokens.auroraWaveTeal.toARGB32(),
      _parseArgb(aurora['waveTealArgb'] as String),
    );
    expect(
      MotionTokens.auroraWaveIndigo.toARGB32(),
      _parseArgb(aurora['waveIndigoArgb'] as String),
    );
    expect(
      MotionTokens.auroraWavePurple.toARGB32(),
      _parseArgb(aurora['wavePurpleArgb'] as String),
    );
    expect(
      MotionTokens.auroraTimeRateRadPerSec,
      closeTo((aurora['timeRateRadPerSec'] as num).toDouble(), 1e-6),
    );
  });

  test('wrapAuroraElapsedSeconds wraps cleanly mod 6283.1853', () {
    expect(MotionTokens.wrapAuroraElapsedSeconds(0.0), 0.0);
    expect(
      MotionTokens.wrapAuroraElapsedSeconds(MotionTokens.auroraWrapPeriodSec),
      closeTo(0.0, 1e-6),
    );
    expect(
      MotionTokens.wrapAuroraElapsedSeconds(
        MotionTokens.auroraWrapPeriodSec * 3 + 42.25,
      ),
      closeTo(42.25, 1e-4),
    );
    expect(MotionTokens.wrapAuroraElapsedSeconds(double.nan), 0.0);
    expect(MotionTokens.wrapAuroraElapsedSeconds(double.infinity), 0.0);
    expect(
      MotionTokens.wrapAuroraElapsedSeconds(-1.0),
      closeTo(MotionTokens.auroraWrapPeriodSec - 1.0, 1e-4),
    );
  });
}
