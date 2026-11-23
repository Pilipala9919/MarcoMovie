// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/danmu/danmu_prefs.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/danmu/danmu_settings_sheet.dart';
import 'package:marco_movie/ui/ios_glass_popover.dart';
import 'package:marco_movie/ui/ios_update_sheet.dart';
import 'package:marco_movie/ui/motion/ios27_springs.dart';
import 'package:marco_movie/ui/poster_expand_route.dart';

void main() {
  group('Ios27Spring physics & Ios27ConcentricGeometry', () {
    test('presets match Apple Spring(duration:bounce:) omega and zeta formulas',
        () {
      expect(Ios27Spring.snappy.duration, 0.28);
      expect(Ios27Spring.snappy.bounce, 0.12);
      expect(Ios27Spring.snappy.dampingRatio, closeTo(0.88, 1e-6));
      expect(
        Ios27Spring.snappy.omega,
        closeTo((2.0 * math.pi) / 0.28, 1e-6),
      );

      expect(Ios27Spring.smooth.duration, 0.38);
      expect(Ios27Spring.smooth.bounce, 0.0);
      expect(Ios27Spring.smooth.dampingRatio, 1.0);

      expect(Ios27Spring.bouncy.duration, 0.44);
      expect(Ios27Spring.bouncy.bounce, 0.24);
      expect(Ios27Spring.bouncy.dampingRatio, closeTo(0.76, 1e-6));
    });

    test('smooth converges monotonically without overshoot while bouncy overshoots and settles',
        () {
      final smoothSim = Ios27Spring.smooth.simulation(start: 0.0, end: 1.0);
      var prev = 0.0;
      for (var t = 0.02; t <= 1.2; t += 0.02) {
        final x = smoothSim.x(t);
        expect(x, greaterThanOrEqualTo(prev - 1e-6));
        expect(x, lessThanOrEqualTo(1.0 + 1e-5));
        prev = x;
      }
      expect(smoothSim.x(1.2), closeTo(1.0, 1e-3));

      final bouncySim = Ios27Spring.bouncy.simulation(start: 0.0, end: 1.0);
      var maxPeak = 0.0;
      for (var t = 0.02; t <= 1.5; t += 0.02) {
        final x = bouncySim.x(t);
        if (x > maxPeak) maxPeak = x;
      }
      expect(maxPeak, greaterThan(1.01));
      expect(bouncySim.x(1.6), closeTo(1.0, 1e-3));
    });

    test('initial gesture velocity inheritance accelerates early trajectory', () {
      final restSim = Ios27Spring.smooth.simulation(
        start: 0.0,
        end: 1.0,
        velocity: 0.0,
      );
      final flungSim = Ios27Spring.smooth.simulation(
        start: 0.0,
        end: 1.0,
        velocity: 6.0,
      );
      expect(flungSim.x(0.05), greaterThan(restSim.x(0.05)));
    });

    testWidgets('mid-flight interruption preserves momentum and settles cleanly',
        (tester) async {
      late AnimationController ctrl;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, _) {
              return _TickerProviderHost(
                onInit: (vsync) {
                  ctrl = AnimationController.unbounded(vsync: vsync, value: 0.0);
                },
              );
            },
          ),
        ),
      );
      addTearDown(() => ctrl.dispose());

      Ios27Spring.animate(ctrl, spring: Ios27Spring.bouncy, target: 1.0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      final midVal = ctrl.value;
      final midVel = ctrl.velocity;
      expect(midVal, greaterThan(0.1));
      expect(midVel, greaterThan(0.0));

      // Interrupt mid-flight back to 0.0 -> inherits live velocity without jump
      Ios27Spring.animate(ctrl, spring: Ios27Spring.snappy, target: 0.0);
      expect(ctrl.value, closeTo(midVal, 1e-6));
      await tester.pumpAndSettle();
      expect(ctrl.value, closeTo(0.0, 1e-3));
    });

    test('Ios27ConcentricGeometry innerRadius and rubber-band damping', () {
      expect(
        Ios27ConcentricGeometry.innerRadius(outerRadius: 32.0, padding: 10.0),
        22.0,
      );
      expect(
        Ios27ConcentricGeometry.innerRadius(outerRadius: 12.0, padding: 10.0),
        8.0,
      );
      expect(Ios27RubberBand.apply(0.0), 0.0);
      final damped = Ios27RubberBand.apply(-100.0, dimension: 200.0);
      expect(damped, lessThan(0.0));
      expect(damped.abs(), lessThan(100.0));
    });

    testWidgets('Ios27Pressable swells to 1.035x on press and disables scale under Reduce Motion',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Ios27Pressable(
                key: const ValueKey('pressable-swell'),
                onTap: () {},
                child: const SizedBox(width: 120, height: 44, child: Text('Go')),
              ),
            ),
          ),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('pressable-swell'))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 140));
      final transforms = tester.widgetList<Transform>(
        find.descendant(
          of: find.byKey(const ValueKey('pressable-swell')),
          matching: find.byType(Transform),
        ),
      );
      expect(transforms, isNotEmpty);
      expect(transforms.first.transform.getMaxScaleOnAxis(), greaterThan(1.01));
      await gesture.up();
      await tester.pumpAndSettle();

      // With disableAnimations = true, scale transform is omitted.
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: Center(
                child: Ios27Pressable(
                  key: const ValueKey('pressable-reduced'),
                  onTap: () {},
                  child: const SizedBox(width: 120, height: 44, child: Text('Go')),
                ),
              ),
            ),
          ),
        ),
      );
      final g2 = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('pressable-reduced'))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('pressable-reduced')),
          matching: find.byType(Transform),
        ),
        findsNothing,
      );
      await g2.up();
      await tester.pumpAndSettle();
    });
  });

  group('Arrowless Fluid Morphing Popover & Floating Inset Liquid Sheet', () {
    testWidgets(
      'showIosGlassPopover renders arrowless fluid morphing glass menu from anchorRect',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final anchorKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.only(top: 60, right: 20),
                  child: ElevatedButton(
                    key: anchorKey,
                    onPressed: () {
                      final ctx = anchorKey.currentContext!;
                      showIosGlassPopover<void>(
                        context: ctx,
                        anchorRect: rectForGlobalKey(anchorKey),
                        title: '画质选项',
                        builder: (_) => const Text('4K HDR'),
                      );
                    },
                    child: const Text('Menu'),
                  ),
                ),
              ),
            ),
          ),
        );

        expect(activeIosGlassPopoverCount.value, 0);
        await tester.tap(find.text('Menu'));
        await tester.pumpAndSettle();

        expect(activeIosGlassPopoverCount.value, 1);
        final bubbleFinder = find.byKey(const Key('ios-glass-popover-bubble'));
        expect(bubbleFinder, findsOneWidget);
        expect(find.text('画质选项'), findsOneWidget);
        expect(find.text('4K HDR'), findsOneWidget);
        // No legacy triangle arrow painter in the overlay.
        final customPaints = tester.widgetList<CustomPaint>(
          find.descendant(of: bubbleFinder, matching: find.byType(CustomPaint)),
        );
        expect(
          customPaints.any((p) => p.painter != null && p.size == const Size(300, 8)),
          isFalse,
        );

        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        expect(activeIosGlassPopoverCount.value, 0);
        expect(bubbleFinder, findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'showIos27LiquidSheet floats inset on phone, centers on iPad, and supports drag rebound & fling dismiss',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(390, 844),
                padding: EdgeInsets.only(top: 44, bottom: 34),
              ),
              child: Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      onPressed: () {
                        showIos27LiquidSheet<void>(
                          context: context,
                          title: '悬浮液态面板',
                          builder: (_) => const SizedBox(
                            height: 220,
                            child: Center(child: Text('Sheet Body')),
                          ),
                        );
                      },
                      child: const Text('Open Sheet'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open Sheet'));
        await tester.pumpAndSettle();

        expect(activeAppleModalSheetCount.value, 1);
        final sheetFinder =
            find.byKey(const ValueKey('ios27-liquid-sheet-container'));
        final grabberFinder =
            find.byKey(const ValueKey('ios27-liquid-sheet-grabber'));
        expect(sheetFinder, findsOneWidget);
        expect(grabberFinder, findsOneWidget);

        final sheetRect = tester.getRect(sheetFinder);
        // 4-side floating inset margin (at least 10pt away from phone edges)
        expect(sheetRect.left, greaterThanOrEqualTo(10.0));
        expect(sheetRect.right, lessThanOrEqualTo(380.0));
        expect(sheetRect.bottom, lessThanOrEqualTo(834.0));

        // Short downward drag rebounds back cleanly instead of dismissing
        await tester.drag(grabberFinder, const Offset(0, 40));
        await tester.pumpAndSettle();
        expect(sheetFinder, findsOneWidget);

        // Downward velocity fling dismisses cleanly with velocity inheritance
        await tester.fling(grabberFinder, const Offset(0, 180), 900.0);
        await tester.pumpAndSettle();
        expect(sheetFinder, findsNothing);
        expect(activeAppleModalSheetCount.value, 0);

        // iPad floating centered panel
        tester.view.physicalSize = const Size(1024, 768);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: MediaQuery(
              data: const MediaQueryData(size: Size(1024, 768)),
              child: Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      onPressed: () {
                        showIos27LiquidSheet<void>(
                          context: context,
                          title: 'iPad 居中面板',
                          builder: (_) => const SizedBox(
                            height: 220,
                            child: Center(child: Text('Centered Body')),
                          ),
                        );
                      },
                      child: const Text('Open iPad Sheet'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open iPad Sheet'));
        await tester.pumpAndSettle();
        final ipadRect = tester.getRect(sheetFinder);
        expect(ipadRect.center.dx, closeTo(512.0, 2.0));
        expect(ipadRect.center.dy, closeTo(384.0, 2.0));
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'DanmuSettingsSheet.show & showIosUpdateLiquidSheet use showIos27LiquidSheet',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Builder(
              builder: (context) => Scaffold(
                body: Column(
                  children: [
                    ElevatedButton(
                      onPressed: () => DanmuSettingsSheet.show(
                        context,
                        initialSettings: const DanmuSettings(),
                        onChanged: (_) {},
                      ),
                      child: const Text('Open Danmu'),
                    ),
                    ElevatedButton(
                      onPressed: () => showIosUpdateLiquidSheet(
                        context,
                        autoCheck: false,
                      ),
                      child: const Text('Open Update'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open Danmu'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('ios27-liquid-sheet-container')),
          findsOneWidget,
        );
        expect(find.text('弹幕设置'), findsWidgets);
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Open Update'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('ios27-liquid-sheet-container')),
          findsOneWidget,
        );
        expect(find.byType(IosUpdateSheet), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });

  group('PosterExpandRoute .zoom pull-down & buildApplePageRoute', () {
    testWidgets(
      'PosterExpandRoute supports interactive pull-down .zoom and SpringSimulation fly-back / re-expansion',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: Builder(
                  builder: (ctx) => GestureDetector(
                    key: const ValueKey('zoom-source-card'),
                    onTap: () {
                      Navigator.of(ctx).push(
                        PosterExpandRoute<void>(
                          initialSourceRect: PosterExpandRoute.captureRect(ctx)!,
                          sourceCardId: 'zoom-card-1',
                          builder: (_) => const Scaffold(
                            key: ValueKey('zoom-detail-page'),
                            body: Center(child: Text('Zoom Detail')),
                          ),
                        ),
                      );
                    },
                    child: const SizedBox(
                      width: 120,
                      height: 180,
                      child: ColoredBox(color: Colors.blue),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const ValueKey('zoom-source-card')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('zoom-detail-page')), findsOneWidget);

        // Gentle pull-down re-expands cleanly via SpringSimulation
        await tester.drag(
          find.byKey(const ValueKey('zoom-detail-page')),
          const Offset(0, 45),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('zoom-detail-page')), findsOneWidget);

        // Downward velocity fling triggers .zoom fly-back to source card
        await tester.fling(
          find.byKey(const ValueKey('zoom-detail-page')),
          const Offset(0, 220),
          1000.0,
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('zoom-detail-page')), findsNothing);
        expect(PosterExpandRegistry.activeCardId.value, isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'buildApplePageRoute returns Ios27PageRoute on iOS and respects disableAnimations',
      (tester) async {
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: ElevatedButton(
                    onPressed: () {
                      final route = buildApplePageRoute<void>(
                        builder: (_) => const Scaffold(
                          body: Center(child: Text('Next Page')),
                        ),
                      );
                      expect(route, isA<Ios27PageRoute<void>>());
                      expect(route, isA<CupertinoPageRoute<void>>());
                      Navigator.of(context).push(route);
                    },
                    child: const Text('Push'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Push'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byType(FadeTransition), findsWidgets);
        await tester.pumpAndSettle();
        expect(find.text('Next Page'), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'Ios27PageRoute left-edge drag from x=6 and x=12 pops cleanly without mid-swipe freeze',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final navKey = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navKey,
            home: const Scaffold(
              body: Center(child: Text('Root Page')),
            ),
          ),
        );

        for (final startX in const [6.0, 12.0]) {
          late Ios27PageRoute<void> pushedRoute;
          pushedRoute = Ios27PageRoute<void>(
            builder: (_) => Scaffold(
              body: Center(child: Text('Pushed @$startX')),
            ),
          );
          navKey.currentState!.push(pushedRoute);
          await tester.pumpAndSettle();
          expect(find.text('Pushed @$startX'), findsOneWidget);
          expect(navKey.currentState!.canPop(), isTrue);

          // Small drag -> release rebounds back cleanly without locking navigator.
          final cancelGesture = await tester.startGesture(Offset(startX, 400));
          await cancelGesture.moveBy(const Offset(40, 0));
          await tester.pump();
          expect(navKey.currentState!.userGestureInProgress, isTrue);
          await cancelGesture.up();
          await tester.pumpAndSettle();
          expect(pushedRoute.animation?.status, AnimationStatus.completed);
          expect(navKey.currentState!.userGestureInProgress, isFalse);
          expect(navKey.currentState!.canPop(), isTrue);

          // Full drag +200px from x=startX -> release pops cleanly.
          final popGesture = await tester.startGesture(Offset(startX, 400));
          for (var i = 0; i < 5; i++) {
            await popGesture.moveBy(const Offset(40, 0));
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(navKey.currentState!.userGestureInProgress, isTrue);
          await popGesture.up();
          await tester.pumpAndSettle();

          expect(pushedRoute.animation?.status, AnimationStatus.dismissed);
          expect(navKey.currentState!.userGestureInProgress, isFalse);
          expect(navKey.currentState!.canPop(), isFalse);
          expect(find.text('Pushed @$startX'), findsNothing);
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'PosterExpandRoute left-edge fling from x=12 dismisses cleanly and clears activeCardId',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final navKey = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navKey,
            home: Scaffold(
              body: Center(
                child: Builder(
                  builder: (ctx) => GestureDetector(
                    key: const ValueKey('edge-zoom-card'),
                    onTap: () {
                      Navigator.of(ctx).push(
                        PosterExpandRoute<void>(
                          initialSourceRect: PosterExpandRoute.captureRect(ctx)!,
                          sourceCardId: 'edge-card-12',
                          builder: (_) => const Scaffold(
                            key: ValueKey('edge-zoom-detail'),
                            body: Center(child: Text('Edge Zoom Detail')),
                          ),
                        ),
                      );
                    },
                    child: const SizedBox(
                      width: 120,
                      height: 180,
                      child: ColoredBox(color: Colors.teal),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const ValueKey('edge-zoom-card')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('edge-zoom-detail')), findsOneWidget);
        expect(PosterExpandRegistry.activeCardId.value, 'edge-card-12');
        expect(navKey.currentState!.canPop(), isTrue);

        // Start horizontal fling inside the 24pt edge strip at x=12pt.
        await tester.flingFrom(
          const Offset(12, 400),
          const Offset(240, 0),
          1200.0,
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('edge-zoom-detail')), findsNothing);
        expect(navKey.currentState!.userGestureInProgress, isFalse);
        expect(navKey.currentState!.canPop(), isFalse);
        expect(PosterExpandRegistry.activeCardId.value, isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });
}

class _TickerProviderHost extends StatefulWidget {
  final void Function(TickerProvider vsync) onInit;
  const _TickerProviderHost({required this.onInit});

  @override
  State<_TickerProviderHost> createState() => _TickerProviderHostState();
}

class _TickerProviderHostState extends State<_TickerProviderHost>
    with SingleTickerProviderStateMixin {
  @override
  void initState() {
    super.initState();
    widget.onInit(this);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
