import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show Colors, Theme;
import 'package:flutter/services.dart';

/// Runtime bridge to Apple's true iOS 26+ Liquid Glass UIKit primitives
/// (`UITabBar`, `UIGlassEffect`, `UIButton.Configuration.glass()`,
/// `UIMenu`, `UISegmentedControl`, `UISheetPresentationController`, and native
/// `UIAlertController`).
///
/// On iOS 15–18, macOS, Windows, Android, HarmonyOS, and widget tests,
/// [isAvailable] resolves to `false` and every widget / presenter seamlessly
/// renders its high-fidelity Flutter fallback.
class IosLiquidGlassBridge {
  static const MethodChannel channel = MethodChannel(
    'marco_movie/ios_liquid_glass',
  );

  static final ValueNotifier<bool> available = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> reduceTransparencyNotifier =
      ValueNotifier<bool>(false);
  static final ValueNotifier<bool> sceneActiveNotifier =
      ValueNotifier<bool>(true);
  static bool _initialized = false;
  static bool? _testOverride;
  static bool? _testReduceTransparencyOverride;
  static bool _incomingHandlerInstalled = false;
  static bool _sheetPresentationInFlight = false;
  static final ValueNotifier<bool> activeSheetNotifier =
      ValueNotifier<bool>(false);
  static int _pinSessionCounter = 0;
  static ValueChanged<int>? _onRootTabSelected;
  static VoidCallback? _onRootTabSearch;
  static VoidCallback? _onRootTabScrollToTop;

  static bool get isSceneActive => sceneActiveNotifier.value;

  static void _setSheetPresentationInFlight(bool active) {
    _sheetPresentationInFlight = active;
    if (activeSheetNotifier.value != active) {
      activeSheetNotifier.value = active;
    }
  }

  @visibleForTesting
  static bool get isSheetPresentationInFlight => _sheetPresentationInFlight;
  static final Map<String, Future<Map<String, dynamic>> Function(String pin)>
      _pinCallbacks =
      <String, Future<Map<String, dynamic>> Function(String pin)>{};

  static bool get isAvailable {
    if (_testOverride != null) return _testOverride!;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return false;
    return available.value;
  }

  /// Mirrors iOS `UIAccessibility.isReduceTransparencyEnabled` (kept fresh on
  /// accessibility change & foreground return). Always `false` on non-iOS
  /// unless overridden in tests.
  static bool get reduceTransparency {
    if (_testReduceTransparencyOverride != null) {
      return _testReduceTransparencyOverride!;
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return false;
    return reduceTransparencyNotifier.value;
  }

  static void _ensureIncomingHandler() {
    if (_incomingHandlerInstalled) return;
    _incomingHandlerInstalled = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'reduceTransparencyChanged' &&
          call.arguments is bool) {
        reduceTransparencyNotifier.value = call.arguments as bool;
        return null;
      }
      if (call.method == 'sceneActivationChanged' && call.arguments is bool) {
        sceneActiveNotifier.value = call.arguments as bool;
        return null;
      }
      if (call.method == 'rootTabSelected' && call.arguments is int) {
        _onRootTabSelected?.call(call.arguments as int);
        return null;
      }
      if (call.method == 'rootTabSearchTapped') {
        _onRootTabSearch?.call();
        return null;
      }
      if (call.method == 'rootTabScrollToTop') {
        _onRootTabScrollToTop?.call();
        return null;
      }
      if (call.method == 'privacyPinCallback' && call.arguments is Map) {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final sessionId = args['sessionId'] as String?;
        final pin = args['pin'] as String?;
        if (sessionId == null || pin == null) {
          return <String, dynamic>{'ok': false, 'error': '参数无效'};
        }
        final handler = _pinCallbacks[sessionId];
        if (handler == null) {
          return <String, dynamic>{'ok': false, 'error': '会话已失效'};
        }
        return handler(pin);
      }
      return null;
    });
  }

  static String _registerPinCallback(
    Future<Map<String, dynamic>> Function(String pin) handler,
  ) {
    _ensureIncomingHandler();
    final id = 'pin_${++_pinSessionCounter}';
    _pinCallbacks[id] = handler;
    return id;
  }

  static void _unregisterPinCallback(String id) {
    _pinCallbacks.remove(id);
  }

  static Future<bool> ensureInitialized() async {
    _ensureIncomingHandler();
    if (_testOverride != null) {
      available.value = _testOverride!;
      return _testOverride!;
    }
    if (_initialized) return available.value;
    _initialized = true;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      available.value = false;
      reduceTransparencyNotifier.value = false;
      return false;
    }
    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'capabilities',
      );
      final supported = result?['available'] == true;
      available.value = supported;
      reduceTransparencyNotifier.value = result?['reduceTransparency'] == true;
      if (result?['sceneActive'] is bool) {
        sceneActiveNotifier.value = result?['sceneActive'] as bool;
      }
      return supported;
    } on MissingPluginException {
      available.value = false;
      reduceTransparencyNotifier.value = false;
      return false;
    } catch (_) {
      available.value = false;
      reduceTransparencyNotifier.value = false;
      return false;
    }
  }

  /// Refreshes `UIAccessibility.isReduceTransparencyEnabled` from native iOS.
  static Future<bool> refreshReduceTransparency() async {
    if (_testReduceTransparencyOverride != null) {
      return _testReduceTransparencyOverride!;
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return false;
    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'capabilities',
      );
      final reduced = result?['reduceTransparency'] == true;
      reduceTransparencyNotifier.value = reduced;
      return reduced;
    } on MissingPluginException {
      return reduceTransparencyNotifier.value;
    } catch (_) {
      return reduceTransparencyNotifier.value;
    }
  }

  /// Dismisses any active native iOS modal sheet/alert owned by this bridge
  /// (for example when `PlayerScreen` disposes while a native sheet is open).
  static Future<void> dismissActiveSheets() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    if (!isAvailable && !_sheetPresentationInFlight) return;
    try {
      await channel.invokeMethod<void>('dismissActiveSheets');
    } on MissingPluginException {
      // No native sheet bridge registered.
    } catch (_) {}
  }

  /// Synchronizes light / dark / system interface style to native iOS windows
  /// and iOS 26 Liquid Glass UIKit controls.
  static Future<void> setAppearanceMode(String mode) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await channel.invokeMethod<void>('setAppearanceMode', mode);
    } on MissingPluginException {
      // Host tests may not register native channel.
    } catch (_) {}
  }

  /// Synchronizes the user's Liquid Glass intensity (`0.0..1.0`) to native
  /// iOS 26 `UIVisualEffectView` / `UIGlassEffect` views.
  static Future<void> setGlassIntensity(double intensity) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await channel.invokeMethod<void>(
        'setGlassIntensity',
        intensity.clamp(0.0, 1.0),
      );
    } on MissingPluginException {
      // Host tests may not register native channel.
    } catch (_) {}
  }

  /// Presents Apple's native iOS AirPlay route picker (`AVRoutePickerView`).
  static Future<bool> presentAirPlayPicker() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return false;
    try {
      final res = await channel.invokeMethod<bool>('presentAirPlayPicker');
      return res == true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Fires tactile iOS haptic feedback for the favorite postcard shutter/arrival
  /// phases and returns the hardware Dynamic Island geometry when available.
  static Future<Map<String, dynamic>?> triggerFavoriteDynamicIslandFeedback(
    String phase,
  ) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return null;
    try {
      final res = await channel.invokeMapMethod<String, dynamic>(
        'triggerFavoriteDynamicIslandFeedback',
        phase,
      );
      return res;
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Discovers LAN cast targets via Apple's native Bonjour (`NetServiceBrowser`)
  /// API, which works on both TrollStore and standard free/sideload certificates
  /// without requiring the `com.apple.developer.networking.multicast` entitlement.
  static Future<Map<String, dynamic>?> discoverBonjourDevices({
    List<String>? serviceTypes,
    Duration timeout = const Duration(milliseconds: 2200),
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return null;
    try {
      final res = await channel.invokeMapMethod<String, dynamic>(
        'discoverBonjourDevices',
        <String, dynamic>{
          if (serviceTypes != null) 'serviceTypes': serviceTypes,
          'timeoutMs': timeout.inMilliseconds,
        },
      );
      return res;
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Attaches and configures the root-controller-level iOS 27 native floating
  /// `UITabBar` + `UIGlassContainerEffect` chrome overlay directly above the
  /// `FlutterView` Metal layer (eliminating `UiKitView` route-transition flashes).
  static Future<bool> configureRootTabChrome({
    required List<IosNativeDockItem> items,
    int selectedIndex = 0,
    bool showSearch = true,
    bool visible = true,
    bool minimized = false,
    bool adaptiveTopOnWide = true,
    ValueChanged<int>? onSelect,
    VoidCallback? onSearch,
    VoidCallback? onScrollToTop,
  }) async {
    _ensureIncomingHandler();
    _onRootTabSelected = onSelect;
    _onRootTabSearch = onSearch;
    _onRootTabScrollToTop = onScrollToTop;
    if (!isAvailable) return false;
    try {
      final res = await channel.invokeMethod<bool>(
        'configureRootTabChrome',
        <String, dynamic>{
          'items': [for (final item in items) item.toMap()],
          'selectedIndex': selectedIndex,
          'showSearch': showSearch && onSearch != null,
          'visible': visible,
          'minimized': minimized,
          'adaptiveTopOnWide': adaptiveTopOnWide,
        },
      );
      return res == true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Synchronizes the selected tab index of the native root `UITabBar`.
  static Future<void> setRootTabSelectedIndex(
    int index, {
    bool animated = true,
  }) async {
    if (!isAvailable) return;
    try {
      await channel.invokeMethod<void>(
        'setRootTabSelectedIndex',
        <String, dynamic>{'index': index, 'animated': animated},
      );
    } on MissingPluginException {
      // Host tests may not register native channel.
    } catch (_) {}
  }

  /// Toggles or smoothly drives scroll-minimize morphing on the root native
  /// `UIGlassContainerEffect` tab chrome (merging tabs & search into the
  /// compact glass pill with iOS 27 spring physics).
  static Future<void> setRootTabMinimized(
    bool minimized, {
    bool animated = true,
    double? progress,
  }) async {
    if (!isAvailable) return;
    try {
      await channel.invokeMethod<void>(
        'setRootTabMinimized',
        <String, dynamic>{
          'minimized': minimized,
          'animated': animated,
          if (progress != null) 'progress': progress.clamp(0.0, 1.0),
        },
      );
    } on MissingPluginException {
      // Host tests may not register native channel.
    } catch (_) {}
  }

  /// Shows or hides the root native tab chrome overlay using iOS 27 spring
  /// motion while keeping background touches 100% passthrough when hidden.
  static Future<void> setRootTabVisible(
    bool visible, {
    bool animated = true,
  }) async {
    if (!isAvailable) return;
    try {
      await channel.invokeMethod<void>(
        'setRootTabVisible',
        <String, dynamic>{'visible': visible, 'animated': animated},
      );
    } on MissingPluginException {
      // Host tests may not register native channel.
    } catch (_) {}
  }

  /// Presents a genuine iOS 26/27 Liquid Glass `UIMenu` anchored in-place at
  /// [anchorRect] (eliminating legacy arrow popovers) and returns the selected
  /// item ID, or `null` if dismissed / unavailable.
  static Future<String?> presentNativeContextMenu({
    required Rect anchorRect,
    required List<IosNativeMenuItem> items,
    String title = '',
  }) async {
    if (!isAvailable || items.isEmpty) return null;
    try {
      return await channel.invokeMethod<String>(
        'showMenuAtRect',
        <String, dynamic>{
          if (title.isNotEmpty) 'title': title,
          'anchorRect': <String, double>{
            'x': anchorRect.left,
            'y': anchorRect.top,
            'width': anchorRect.width,
            'height': anchorRect.height,
          },
          'items': [for (final item in items) item.toMap()],
        },
      );
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static void setAvailableForTest(bool? value) {
    _testOverride = value;
    available.value = value ?? false;
    if (value == null) {
      _initialized = false;
      _testReduceTransparencyOverride = null;
      _sheetPresentationInFlight = false;
      activeSheetNotifier.value = false;
      reduceTransparencyNotifier.value = false;
      sceneActiveNotifier.value = true;
      _onRootTabSelected = null;
      _onRootTabSearch = null;
      _onRootTabScrollToTop = null;
      _pinCallbacks.clear();
    }
  }

  @visibleForTesting
  static void setReduceTransparencyForTest(bool? value) {
    _testReduceTransparencyOverride = value;
    reduceTransparencyNotifier.value = value ?? false;
  }
}

/// Gates mounting of iOS `UiKitView` platform views so strictly at most ONE
/// route (`ModalRoute.isCurrent == true`) owns live platform views at any moment.
///
/// Handing off immediately on `route.isCurrent` (rather than delaying until
/// route slide animations complete) both prevents Flutter iOS Impeller
/// cross-route overlay collisions (`x = 0..67%` black occlusion) AND eliminates
/// post-transition dark-to-bright flashes and placeholder-swap jumps.
class IosNativeRouteGate extends StatefulWidget {
  final Widget Function(BuildContext context, bool nativeActive) builder;

  const IosNativeRouteGate({super.key, required this.builder});

  static final ValueNotifier<int> _placeholderDepth = ValueNotifier<int>(0);

  /// `true` while [runWithPlaceholders] is forcing all mounted gates to swap
  /// native `UiKitView`s for exact-size Flutter placeholders (e.g. before
  /// capturing a `RepaintBoundary.toImage()` snapshot).
  static bool get forcePlaceholders => _placeholderDepth.value > 0;

  /// Temporarily swaps every live [IosNativeRouteGate] `UiKitView` to its
  /// exact-geometry Flutter placeholder for the duration of [action], waiting
  /// one rendered frame by default so `RepaintBoundary.toImage()` never
  /// captures black platform-view holes. Guaranteed to restore native views
  /// via `try/finally` even when [action] throws or is cancelled.
  static Future<T> runWithPlaceholders<T>(
    Future<T> Function() action, {
    bool waitForFrame = true,
    Duration frameTimeout = const Duration(milliseconds: 100),
  }) async {
    _placeholderDepth.value = _placeholderDepth.value + 1;
    try {
      if (waitForFrame) {
        final completer = Completer<void>();
        WidgetsBinding.instance.scheduleFrame();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!completer.isCompleted) completer.complete();
        });
        await completer.future.timeout(frameTimeout, onTimeout: () {});
      }
      return await action();
    } finally {
      _placeholderDepth.value = math.max(0, _placeholderDepth.value - 1);
    }
  }

  @override
  State<IosNativeRouteGate> createState() => _IosNativeRouteGateState();
}

class _IosNativeRouteGateState extends State<IosNativeRouteGate> {
  ModalRoute<dynamic>? _route;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    IosLiquidGlassBridge.available.addListener(_recheck);
    IosNativeRouteGate._placeholderDepth.addListener(_recheck);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    _ready = _computeReady();
  }

  bool _computeReady() {
    if (!IosLiquidGlassBridge.isAvailable) return false;
    if (IosNativeRouteGate.forcePlaceholders) return false;
    final route = _route;
    if (route == null) return true;
    return route.isCurrent;
  }

  void _recheck() {
    if (!mounted) return;
    final next = _computeReady();
    if (next != _ready) {
      setState(() => _ready = next);
    }
  }

  @override
  void dispose() {
    IosLiquidGlassBridge.available.removeListener(_recheck);
    IosNativeRouteGate._placeholderDepth.removeListener(_recheck);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _ready);
  }
}

class IosNativeDockItem {
  final String label;
  final String symbol;
  final String? selectedSymbol;
  final String? kind;

  const IosNativeDockItem({
    required this.label,
    required this.symbol,
    this.selectedSymbol,
    this.kind,
  });

  Map<String, dynamic> toMap() => <String, dynamic>{
        'label': label,
        'symbol': symbol,
        'selectedSymbol': selectedSymbol ?? symbol,
        if (kind != null && kind!.isNotEmpty) 'kind': kind,
      };
}

class IosNativeMenuItem {
  final String id;
  final String title;
  final String? subtitle;
  final String? symbol;
  final bool checked;
  final bool destructive;
  final int section;
  final String? sectionTitle;

  const IosNativeMenuItem({
    required this.id,
    required this.title,
    this.subtitle,
    this.symbol,
    this.checked = false,
    this.destructive = false,
    this.section = 0,
    this.sectionTitle,
  });

  Map<String, dynamic> toMap() => <String, dynamic>{
        'id': id,
        'title': title,
        if (subtitle != null && subtitle!.isNotEmpty) 'subtitle': subtitle,
        if (symbol != null && symbol!.isNotEmpty) 'symbol': symbol,
        'checked': checked,
        'destructive': destructive,
        'section': section,
        if (sectionTitle != null && sectionTitle!.isNotEmpty)
          'sectionTitle': sectionTitle,
      };

  @override
  bool operator ==(Object other) =>
      other is IosNativeMenuItem &&
      other.id == id &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.symbol == symbol &&
      other.checked == checked &&
      other.destructive == destructive &&
      other.section == section &&
      other.sectionTitle == sectionTitle;

  @override
  int get hashCode => Object.hash(
        id,
        title,
        subtitle,
        symbol,
        checked,
        destructive,
        section,
        sectionTitle,
      );
}

/// Hosts the native iOS 26 full-height (62pt) floating Liquid Glass 4-tab
/// capsule (`UIGlassEffect`) + height-matched 62pt circular Liquid Glass search
/// button (`UIButton.Configuration.glass()`), and smoothly morphs into a
/// bottom-right 62pt Brand Logo circular Liquid Glass button with native
/// `UIMenu` when [collapsed] is `true`.
class IosNativeDockView extends StatefulWidget {
  final int selectedIndex;
  final List<IosNativeDockItem> items;
  final ValueChanged<int> onSelect;
  final VoidCallback? onSearch;
  final VoidCallback? onScrollToTop;
  final bool showSearch;
  final bool hidden;
  final bool collapsed;
  final double height;

  const IosNativeDockView({
    super.key,
    required this.selectedIndex,
    required this.items,
    required this.onSelect,
    this.onSearch,
    this.onScrollToTop,
    this.showSearch = true,
    this.hidden = false,
    this.collapsed = false,
    this.height = 76,
  });

  @override
  State<IosNativeDockView> createState() => _IosNativeDockViewState();
}

class _IosNativeDockViewState extends State<IosNativeDockView> {
  MethodChannel? _channel;
  Timer? _hitBoxTimer;
  bool _compactHitBox = false;

  @override
  void initState() {
    super.initState();
    _compactHitBox = widget.collapsed;
  }

  Map<String, dynamic> _buildParams({double? initialWidth}) => <String, dynamic>{
        'selectedIndex': widget.selectedIndex,
        'showSearch': widget.showSearch && widget.onSearch != null,
        'hidden': widget.hidden,
        'collapsed': widget.collapsed,
        'items': [for (final item in widget.items) item.toMap()],
        if (initialWidth != null) 'initialWidth': initialWidth,
        'initialHeight': widget.height,
      };

  void _onViewCreated(int id) {
    _channel?.setMethodCallHandler(null);
    final ch = MethodChannel('marco_movie/ios26_dock_$id');
    _channel = ch;
    ch.setMethodCallHandler((call) async {
      if (!mounted) return;
      if (call.method == 'onSelect' && call.arguments is int) {
        widget.onSelect(call.arguments as int);
      } else if (call.method == 'onSearch') {
        widget.onSearch?.call();
      } else if (call.method == 'onScrollToTop') {
        widget.onScrollToTop?.call();
      }
    });
  }

  @override
  void didUpdateWidget(covariant IosNativeDockView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ch = _channel;
    if (oldWidget.collapsed != widget.collapsed) {
      _hitBoxTimer?.cancel();
      if (widget.collapsed) {
        if (ch != null) {
          unawaited(_safeInvoke(ch, 'setCollapsed', true));
        }
        _hitBoxTimer = Timer(const Duration(milliseconds: 280), () {
          if (mounted && widget.collapsed) {
            setState(() => _compactHitBox = true);
          }
        });
      } else {
        if (_compactHitBox) {
          setState(() => _compactHitBox = false);
        }
        if (ch != null) {
          unawaited(_safeInvoke(ch, 'setCollapsed', false));
        }
      }
    }
    if (ch == null) return;
    if (oldWidget.hidden != widget.hidden) {
      unawaited(_safeInvoke(ch, 'setHidden', widget.hidden));
    }
    final itemsChanged = oldWidget.items.length != widget.items.length ||
        oldWidget.showSearch != widget.showSearch ||
        (oldWidget.onSearch == null) != (widget.onSearch == null);
    if (itemsChanged) {
      unawaited(_safeInvoke(ch, 'update', _buildParams()));
    } else if (oldWidget.selectedIndex != widget.selectedIndex) {
      unawaited(_safeInvoke(ch, 'setSelectedIndex', widget.selectedIndex));
    }
  }

  Future<void> _safeInvoke(MethodChannel ch, String method, dynamic arg) async {
    try {
      await ch.invokeMethod<void>(method, arg);
    } catch (_) {}
  }

  @override
  void dispose() {
    _hitBoxTimer?.cancel();
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.sizeOf(context).width;
    return Align(
      alignment: Alignment.centerRight,
      heightFactor: 1,
      child: SizedBox(
        width: _compactHitBox ? 94.0 : double.infinity,
        height: widget.height,
        child: UiKitView(
          viewType: 'marco_movie/ios26_dock',
          creationParams: _buildParams(
            initialWidth: _compactHitBox ? 94.0 : screenW,
          ),
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: _onViewCreated,
        ),
      ),
    );
  }
}

/// Native iOS 26 Liquid Glass circular icon button or capsule button (leading SF
/// Symbol + label + optional trailing SF Symbol + optional native `UIMenu`),
/// with automatic fallback when running on iOS < 26 or non-iOS platforms.
class IosNativeGlassButton extends StatefulWidget {
  final String style;
  final String? symbol;
  final String? trailingSymbol;
  final String label;
  final double symbolSize;
  final Color? foregroundColor;
  final Color? tintColor;
  final bool forceDark;
  final bool prominent;
  final String? accessibilityLabel;
  final double? width;
  final double maxWidth;
  final double height;
  final String menuTitle;
  final List<IosNativeMenuItem>? menuItems;
  final ValueChanged<String>? onMenuSelected;
  final VoidCallback onTap;
  final Widget fallback;

  const IosNativeGlassButton({
    super.key,
    this.style = 'circle',
    this.symbol,
    this.trailingSymbol,
    this.label = '',
    this.symbolSize = 17,
    this.foregroundColor,
    this.tintColor,
    this.forceDark = false,
    this.prominent = false,
    this.accessibilityLabel,
    this.width,
    this.maxWidth = 168,
    this.height = 40,
    this.menuTitle = '',
    this.menuItems,
    this.onMenuSelected,
    required this.onTap,
    required this.fallback,
  });

  @override
  State<IosNativeGlassButton> createState() => _IosNativeGlassButtonState();
}

class _IosNativeGlassButtonState extends State<IosNativeGlassButton> {
  MethodChannel? _channel;
  Brightness? _lastBrightness;

  bool _isDarkSurface(BuildContext ctx) =>
      widget.forceDark || Theme.of(ctx).brightness == Brightness.dark;

  Color _effectiveForegroundColor([BuildContext? ctx]) {
    if (widget.foregroundColor != null) return widget.foregroundColor!;
    if (widget.forceDark || widget.tintColor != null) return Colors.white;
    final dark = _isDarkSurface(ctx ?? context);
    return dark ? Colors.white : const Color(0xFF14171F);
  }

  Map<String, dynamic> _buildParams({double? initialWidth}) => <String, dynamic>{
        'style': widget.style,
        if (widget.symbol != null) 'symbol': widget.symbol,
        if (widget.trailingSymbol != null)
          'trailingSymbol': widget.trailingSymbol,
        'label': widget.label,
        'symbolSize': widget.symbolSize,
        'forceDark': widget.forceDark,
        if (widget.prominent) 'prominent': true,
        if (widget.foregroundColor != null)
          'foregroundColor': widget.foregroundColor!.toARGB32(),
        if (widget.tintColor != null)
          'tintColor': widget.tintColor!.toARGB32(),
        'accessibilityLabel': widget.accessibilityLabel ?? widget.label,
        if (widget.menuTitle.isNotEmpty) 'menuTitle': widget.menuTitle,
        if (widget.menuItems != null && widget.menuItems!.isNotEmpty)
          'menuItems': [for (final item in widget.menuItems!) item.toMap()],
        if (initialWidth != null) 'initialWidth': initialWidth,
        'initialHeight': widget.height,
      };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (_lastBrightness != null &&
        _lastBrightness != brightness &&
        _channel != null) {
      unawaited(_safeUpdate(_channel!));
    }
    _lastBrightness = brightness;
  }

  void _onViewCreated(int id) {
    _channel?.setMethodCallHandler(null);
    final ch = MethodChannel('marco_movie/ios26_glass_button_$id');
    _channel = ch;
    ch.setMethodCallHandler((call) async {
      if (!mounted) return;
      if (call.method == 'onTap') {
        widget.onTap();
      } else if (call.method == 'onMenuSelected' && call.arguments is String) {
        widget.onMenuSelected?.call(call.arguments as String);
      }
    });
  }

  @override
  void didUpdateWidget(covariant IosNativeGlassButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ch = _channel;
    if (ch == null) return;
    if (oldWidget.style != widget.style ||
        oldWidget.symbol != widget.symbol ||
        oldWidget.trailingSymbol != widget.trailingSymbol ||
        oldWidget.label != widget.label ||
        oldWidget.symbolSize != widget.symbolSize ||
        oldWidget.foregroundColor != widget.foregroundColor ||
        oldWidget.tintColor != widget.tintColor ||
        oldWidget.forceDark != widget.forceDark ||
        oldWidget.prominent != widget.prominent ||
        oldWidget.accessibilityLabel != widget.accessibilityLabel ||
        oldWidget.menuTitle != widget.menuTitle ||
        !listEquals(oldWidget.menuItems, widget.menuItems)) {
      unawaited(_safeUpdate(ch));
    }
  }

  Future<void> _safeUpdate(MethodChannel ch) async {
    try {
      await ch.invokeMethod<void>('update', _buildParams());
    } catch (_) {}
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  double _resolvedWidth(BuildContext context) {
    if (widget.width != null) return widget.width!;
    if (widget.style == 'circle') return widget.height;
    final painter = TextPainter(
      text: TextSpan(
        text: widget.label,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: widget.maxWidth);
    double extra = 26.0;
    if (widget.symbol != null && widget.symbol!.isNotEmpty) extra += 22.0;
    if (widget.trailingSymbol != null && widget.trailingSymbol!.isNotEmpty) {
      extra += 18.0;
    }
    return (painter.width + extra).clamp(74.0, widget.maxWidth);
  }

  @override
  Widget build(BuildContext context) {
    return IosNativeRouteGate(
      builder: (context, nativeActive) {
        if (!nativeActive) {
          if (IosLiquidGlassBridge.isAvailable) {
            return _Ios26GlassButtonPlaceholder(
              style: widget.style,
              symbol: widget.symbol,
              trailingSymbol: widget.trailingSymbol,
              label: widget.label,
              symbolSize: widget.symbolSize,
              foregroundColor: _effectiveForegroundColor(context),
              tintColor: widget.tintColor,
              forceDark: widget.forceDark,
              width: _resolvedWidth(context),
              height: widget.height,
              onTap: widget.onTap,
            );
          }
          return widget.fallback;
        }
        final resolvedW = _resolvedWidth(context);
        return RepaintBoundary(
          child: SizedBox(
            width: resolvedW,
            height: widget.height,
            child: UiKitView(
              viewType: 'marco_movie/ios26_glass_button',
              creationParams: _buildParams(initialWidth: resolvedW),
              creationParamsCodec: const StandardMessageCodec(),
              onPlatformViewCreated: _onViewCreated,
            ),
          ),
        );
      },
    );
  }
}

class IosNativeGlassPillAction {
  final String symbol;
  final Color? color;
  final String accessibilityLabel;
  final VoidCallback onTap;

  const IosNativeGlassPillAction({
    required this.symbol,
    this.color,
    required this.accessibilityLabel,
    required this.onTap,
  });

  Map<String, dynamic> toMap() => <String, dynamic>{
        'symbol': symbol,
        if (color != null) 'color': color!.toARGB32(),
        'accessibilityLabel': accessibilityLabel,
      };
}

/// Native iOS 26 multi-action Liquid Glass capsule pill (e.g. Detail screen
/// top-right `[Netdisk | Download | Favorite]` capsule).
class IosNativeGlassPill extends StatefulWidget {
  final List<IosNativeGlassPillAction> actions;
  final double height;
  final bool forceDark;
  final Widget fallback;

  const IosNativeGlassPill({
    super.key,
    required this.actions,
    this.height = 40,
    this.forceDark = false,
    required this.fallback,
  });

  @override
  State<IosNativeGlassPill> createState() => _IosNativeGlassPillState();
}

class _IosNativeGlassPillState extends State<IosNativeGlassPill> {
  MethodChannel? _channel;
  Brightness? _lastBrightness;

  Map<String, dynamic> _buildParams({double? initialWidth}) => <String, dynamic>{
        'items': [for (final a in widget.actions) a.toMap()],
        'forceDark': widget.forceDark,
        if (initialWidth != null) 'initialWidth': initialWidth,
        'initialHeight': widget.height,
      };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (_lastBrightness != null &&
        _lastBrightness != brightness &&
        _channel != null) {
      unawaited(_safeUpdate(_channel!));
    }
    _lastBrightness = brightness;
  }

  void _onViewCreated(int id) {
    _channel?.setMethodCallHandler(null);
    final ch = MethodChannel('marco_movie/ios26_glass_pill_$id');
    _channel = ch;
    ch.setMethodCallHandler((call) async {
      if (!mounted) return;
      if (call.method == 'onAction' && call.arguments is int) {
        final idx = call.arguments as int;
        if (idx >= 0 && idx < widget.actions.length) {
          widget.actions[idx].onTap();
        }
      }
    });
  }

  bool _actionsChanged(List<IosNativeGlassPillAction> oldList) {
    if (oldList.length != widget.actions.length) return true;
    for (var i = 0; i < oldList.length; i++) {
      if (oldList[i].symbol != widget.actions[i].symbol ||
          oldList[i].color != widget.actions[i].color ||
          oldList[i].accessibilityLabel !=
              widget.actions[i].accessibilityLabel) {
        return true;
      }
    }
    return false;
  }

  @override
  void didUpdateWidget(covariant IosNativeGlassPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ch = _channel;
    if (ch == null) return;
    if (oldWidget.forceDark != widget.forceDark ||
        _actionsChanged(oldWidget.actions)) {
      unawaited(_safeUpdate(ch));
    }
  }

  Future<void> _safeUpdate(MethodChannel ch) async {
    try {
      await ch.invokeMethod<void>('update', _buildParams());
    } catch (_) {}
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IosNativeRouteGate(
      builder: (context, nativeActive) {
        final count = widget.actions.length;
        final width = 12.0 + count * 38.0 + math.max(0, count - 1) * 0.6;
        if (!nativeActive) {
          if (IosLiquidGlassBridge.isAvailable) {
            return _Ios26GlassPillPlaceholder(
              actions: widget.actions,
              forceDark: widget.forceDark,
              width: width,
              height: widget.height,
            );
          }
          return widget.fallback;
        }
        return RepaintBoundary(
          child: SizedBox(
            width: width,
            height: widget.height,
            child: UiKitView(
              viewType: 'marco_movie/ios26_glass_pill',
              creationParams: _buildParams(initialWidth: width),
              creationParamsCodec: const StandardMessageCodec(),
              onPlatformViewCreated: _onViewCreated,
            ),
          ),
        );
      },
    );
  }
}

/// Native iOS 26 `UISegmentedControl` with authentic Liquid Glass translucent
/// pill track & interactive sliding thumb, falling back to Flutter widgets on
/// older iOS / non-iOS.
class IosNativeSegmentedControl extends StatefulWidget {
  final List<String> segments;
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final double height;
  final Widget fallback;

  const IosNativeSegmentedControl({
    super.key,
    required this.segments,
    required this.selectedIndex,
    required this.onChanged,
    this.height = 36,
    required this.fallback,
  });

  @override
  State<IosNativeSegmentedControl> createState() =>
      _IosNativeSegmentedControlState();
}

class _IosNativeSegmentedControlState extends State<IosNativeSegmentedControl> {
  MethodChannel? _channel;

  Map<String, dynamic> _buildParams({double? initialWidth}) => <String, dynamic>{
        'segments': widget.segments,
        'selectedIndex': widget.selectedIndex,
        if (initialWidth != null) 'initialWidth': initialWidth,
        'initialHeight': widget.height,
      };

  void _onViewCreated(int id) {
    _channel?.setMethodCallHandler(null);
    final ch = MethodChannel('marco_movie/ios26_segmented_control_$id');
    _channel = ch;
    ch.setMethodCallHandler((call) async {
      if (!mounted) return;
      if (call.method == 'onChanged' && call.arguments is int) {
        widget.onChanged(call.arguments as int);
      }
    });
  }

  @override
  void didUpdateWidget(covariant IosNativeSegmentedControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ch = _channel;
    if (ch == null) return;
    if (!listEquals(oldWidget.segments, widget.segments)) {
      unawaited(_safeInvoke(ch, 'update', _buildParams()));
    } else if (oldWidget.selectedIndex != widget.selectedIndex) {
      unawaited(_safeInvoke(ch, 'setSelectedIndex', widget.selectedIndex));
    }
  }

  Future<void> _safeInvoke(MethodChannel ch, String method, dynamic arg) async {
    try {
      await ch.invokeMethod<void>(method, arg);
    } catch (_) {}
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IosNativeRouteGate(
      builder: (context, nativeActive) {
        if (!nativeActive) {
          if (IosLiquidGlassBridge.isAvailable) {
            return _Ios26SegmentedPlaceholder(
              segments: widget.segments,
              selectedIndex: widget.selectedIndex,
              height: widget.height,
              onChanged: widget.onChanged,
            );
          }
          return widget.fallback;
        }
        return RepaintBoundary(
          child: SizedBox(
            width: double.infinity,
            height: widget.height,
            child: UiKitView(
              viewType: 'marco_movie/ios26_segmented_control',
              creationParams: _buildParams(),
              creationParamsCodec: const StandardMessageCodec(),
              onPlatformViewCreated: _onViewCreated,
            ),
          ),
        );
      },
    );
  }
}

/// Native iOS 26 UIKit `UISwitch` (with authentic Liquid Glass expanding crystal
/// thumb on press/drag), seamlessly falling back to `CupertinoSwitch` on older
/// iOS, non-iOS platforms, and during route transitions.
class IosNativeSwitch extends StatefulWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color activeColor;
  final String? accessibilityLabel;

  const IosNativeSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor = CupertinoColors.activeGreen,
    this.accessibilityLabel,
  });

  @override
  State<IosNativeSwitch> createState() => _IosNativeSwitchState();
}

class _IosNativeSwitchState extends State<IosNativeSwitch> {
  MethodChannel? _channel;

  Map<String, dynamic> _buildParams() => <String, dynamic>{
        'value': widget.value,
        'onTintColor': widget.activeColor.toARGB32(),
        'enabled': widget.onChanged != null,
        if (widget.accessibilityLabel != null &&
            widget.accessibilityLabel!.isNotEmpty)
          'accessibilityLabel': widget.accessibilityLabel,
      };

  void _onViewCreated(int id) {
    _channel?.setMethodCallHandler(null);
    final ch = MethodChannel('marco_movie/ios26_switch_$id');
    _channel = ch;
    ch.setMethodCallHandler((call) async {
      if (!mounted) return;
      if (call.method == 'onChanged' && call.arguments is bool) {
        widget.onChanged?.call(call.arguments as bool);
      }
    });
  }

  @override
  void didUpdateWidget(covariant IosNativeSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ch = _channel;
    if (ch == null) return;
    if (oldWidget.value != widget.value ||
        oldWidget.activeColor != widget.activeColor ||
        (oldWidget.onChanged == null) != (widget.onChanged == null) ||
        oldWidget.accessibilityLabel != widget.accessibilityLabel) {
      unawaited(_safeUpdate(ch));
    }
  }

  Future<void> _safeUpdate(MethodChannel ch) async {
    try {
      await ch.invokeMethod<void>('update', _buildParams());
    } catch (_) {}
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IosNativeRouteGate(
      builder: (context, nativeActive) {
        if (!nativeActive) {
          return CupertinoSwitch(
            value: widget.value,
            activeTrackColor: widget.activeColor,
            onChanged: widget.onChanged,
          );
        }
        return RepaintBoundary(
          child: SizedBox(
            width: 51,
            height: 31,
            child: UiKitView(
              viewType: 'marco_movie/ios26_switch',
              creationParams: _buildParams(),
              creationParamsCodec: const StandardMessageCodec(),
              onPlatformViewCreated: _onViewCreated,
            ),
          ),
        );
      },
    );
  }
}

/// Native iOS 26 UIKit `UISlider` (with authentic Liquid Glass magnifying pill
/// thumb during scrubbing), falling back cleanly to `CupertinoSlider`.
class IosNativeSlider extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final Color activeColor;
  final String? accessibilityLabel;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  const IosNativeSlider({
    super.key,
    required this.value,
    this.min = 0.0,
    this.max = 1.0,
    this.activeColor = CupertinoColors.activeBlue,
    this.accessibilityLabel,
    required this.onChanged,
    this.onChangeEnd,
  });

  @override
  State<IosNativeSlider> createState() => _IosNativeSliderState();
}

class _IosNativeSliderState extends State<IosNativeSlider> {
  MethodChannel? _channel;

  Map<String, dynamic> _buildParams() => <String, dynamic>{
        'value': widget.value.clamp(widget.min, widget.max).toDouble(),
        'min': widget.min,
        'max': widget.max,
        'tintColor': widget.activeColor.toARGB32(),
        if (widget.accessibilityLabel != null &&
            widget.accessibilityLabel!.isNotEmpty)
          'accessibilityLabel': widget.accessibilityLabel,
      };

  void _onViewCreated(int id) {
    _channel?.setMethodCallHandler(null);
    final ch = MethodChannel('marco_movie/ios26_slider_$id');
    _channel = ch;
    ch.setMethodCallHandler((call) async {
      if (!mounted) return;
      final raw = call.arguments;
      if (raw is! num) return;
      final v = raw.toDouble().clamp(widget.min, widget.max).toDouble();
      if (call.method == 'onChanged') {
        widget.onChanged?.call(v);
      } else if (call.method == 'onChangeEnd') {
        widget.onChangeEnd?.call(v);
      }
    });
  }

  @override
  void didUpdateWidget(covariant IosNativeSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ch = _channel;
    if (ch == null) return;
    if ((oldWidget.value - widget.value).abs() > 0.0005 ||
        oldWidget.min != widget.min ||
        oldWidget.max != widget.max ||
        oldWidget.activeColor != widget.activeColor ||
        oldWidget.accessibilityLabel != widget.accessibilityLabel) {
      unawaited(_safeUpdate(ch));
    }
  }

  Future<void> _safeUpdate(MethodChannel ch) async {
    try {
      await ch.invokeMethod<void>('update', _buildParams());
    } catch (_) {}
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IosNativeRouteGate(
      builder: (context, nativeActive) {
        if (!nativeActive) {
          return SizedBox(
            width: double.infinity,
            height: 44,
            child: LayoutBuilder(
              builder: (ctx, constraints) {
                final maxW = math.max(1.0, constraints.maxWidth);
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: widget.onChanged == null
                      ? null
                      : (details) {
                          final ratio =
                              (details.localPosition.dx / maxW).clamp(0.0, 1.0);
                          final target = widget.min +
                              ratio * (widget.max - widget.min);
                          HapticFeedback.selectionClick();
                          widget.onChanged?.call(target);
                          widget.onChangeEnd?.call(target);
                        },
                  child: CupertinoSlider(
                    value: widget.value.clamp(widget.min, widget.max).toDouble(),
                    min: widget.min,
                    max: widget.max,
                    activeColor: widget.activeColor,
                    onChanged: widget.onChanged,
                    onChangeEnd: widget.onChangeEnd,
                  ),
                );
              },
            ),
          );
        }
        return RepaintBoundary(
          child: SizedBox(
            width: double.infinity,
            height: 48,
            child: UiKitView(
              viewType: 'marco_movie/ios26_slider',
              creationParams: _buildParams(),
              creationParamsCodec: const StandardMessageCodec(),
              gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
                Factory<HorizontalDragGestureRecognizer>(
                  HorizontalDragGestureRecognizer.new,
                ),
                Factory<TapGestureRecognizer>(
                  TapGestureRecognizer.new,
                ),
              },
              onPlatformViewCreated: _onViewCreated,
            ),
          ),
        );
      },
    );
  }
}

IconData _cupertinoIconForSfSymbol(String? symbol) => switch (symbol) {
      'chevron.backward' || 'chevron.left' => CupertinoIcons.back,
      'chevron.down' => CupertinoIcons.chevron_down,
      'archivebox.fill' || 'archivebox' => CupertinoIcons.archivebox_fill,
      'square.3.layers.3d' ||
      'square.stack.3d.up' ||
      'square.stack.3d.up.fill' =>
        CupertinoIcons.layers_alt_fill,
      'lock.shield.fill' => CupertinoIcons.lock_shield_fill,
      'cloud.fill' => CupertinoIcons.cloud_fill,
      'cloud' => CupertinoIcons.cloud,
      'line.3.horizontal.decrease' => CupertinoIcons.slider_horizontal_3,
      'arrow.triangle.2.circlepath' => CupertinoIcons.arrow_2_circlepath,
      'magnifyingglass' => CupertinoIcons.search,
      'qrcode.viewfinder' => CupertinoIcons.qrcode,
      'arrow.down.to.line' => CupertinoIcons.arrow_down_to_line,
      'heart.fill' => CupertinoIcons.heart_fill,
      'heart' => CupertinoIcons.heart,
      'play.rectangle' => CupertinoIcons.play_rectangle,
      'play.rectangle.fill' => CupertinoIcons.play_rectangle_fill,
      'dot.radiowaves.left.and.right' =>
        CupertinoIcons.dot_radiowaves_left_right,
      'gearshape' => CupertinoIcons.gear_alt,
      'gearshape.fill' => CupertinoIcons.gear_alt_fill,
      'xmark' => CupertinoIcons.xmark,
      'plus' => CupertinoIcons.plus,
      'slider.horizontal.3' => CupertinoIcons.slider_horizontal_3,
      _ => CupertinoIcons.circle,
    };

/// Zero-`BackdropFilter`, exact-geometry transition placeholder matching native
/// iOS 26 `MarcoNativeGlassButtonPlatformView` so route push/pop animations
/// never shift size or flash legacy Flutter fallback styling.
class _Ios26GlassButtonPlaceholder extends StatelessWidget {
  final String style;
  final String? symbol;
  final String? trailingSymbol;
  final String label;
  final double symbolSize;
  final Color foregroundColor;
  final Color? tintColor;
  final bool forceDark;
  final double width;
  final double height;
  final VoidCallback onTap;

  const _Ios26GlassButtonPlaceholder({
    required this.style,
    required this.symbol,
    required this.trailingSymbol,
    required this.label,
    required this.symbolSize,
    required this.foregroundColor,
    required this.tintColor,
    this.forceDark = false,
    required this.width,
    required this.height,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final dark = forceDark || Theme.of(context).brightness == Brightness.dark;
    final isCapsule = style == 'capsule' &&
        (label.isNotEmpty ||
            (trailingSymbol != null && trailingSymbol!.isNotEmpty));
    final radius = BorderRadius.circular(height * 0.5);
    final baseBg = tintColor != null
        ? Color.alphaBlend(
            tintColor!.withValues(alpha: 0.78),
            const Color(0xFF28282E),
          )
        : (dark ? const Color(0x8824252C) : const Color(0xE8F6F8FC));
    final topBg = tintColor != null
        ? Color.alphaBlend(
            const Color(0x2EFFFFFF),
            baseBg,
          )
        : (dark ? const Color(0x9C34353E) : const Color(0xF5FFFFFF));

    return GestureDetector(
      key: const ValueKey('ios26-glass-button-transition-placeholder'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: width,
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [topBg, baseBg],
            ),
            border: Border.all(
              color: tintColor != null
                  ? Colors.white.withValues(alpha: 0.28)
                  : (dark
                      ? Colors.white.withValues(alpha: 0.20)
                      : Colors.black.withValues(alpha: 0.10)),
              width: 0.65,
            ),
            boxShadow: [
              BoxShadow(
                color: dark ? const Color(0x38000000) : const Color(0x160F172A),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: isCapsule
              ? Padding(
                  padding: const EdgeInsets.only(left: 12, right: 11),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (symbol != null && symbol!.isNotEmpty) ...[
                        Icon(
                          _cupertinoIconForSfSymbol(symbol),
                          size: symbolSize,
                          color: foregroundColor,
                        ),
                        const SizedBox(width: 5),
                      ],
                      if (label.isNotEmpty)
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: foregroundColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ),
                      if (trailingSymbol != null &&
                          trailingSymbol!.isNotEmpty) ...[
                        const SizedBox(width: 5),
                        Icon(
                          _cupertinoIconForSfSymbol(trailingSymbol),
                          size: math.max(symbolSize - 3.0, 11.0),
                          color: foregroundColor.withValues(alpha: 0.82),
                        ),
                      ],
                    ],
                  ),
                )
              : Center(
                  child: symbol != null && symbol!.isNotEmpty
                      ? Icon(
                          _cupertinoIconForSfSymbol(symbol),
                          size: symbolSize,
                          color: foregroundColor,
                        )
                      : const SizedBox.shrink(),
                ),
        ),
      ),
    );
  }
}

class _Ios26GlassPillPlaceholder extends StatelessWidget {
  final List<IosNativeGlassPillAction> actions;
  final bool forceDark;
  final double width;
  final double height;

  const _Ios26GlassPillPlaceholder({
    required this.actions,
    this.forceDark = false,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    final dark = forceDark || Theme.of(context).brightness == Brightness.dark;
    final defaultInk = dark ? Colors.white : const Color(0xFF14171F);
    return SizedBox(
      key: const ValueKey('ios26-glass-pill-transition-placeholder'),
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(height * 0.5),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark
                ? const [Color(0x9C34353E), Color(0x8824252C)]
                : const [Color(0xF5FFFFFF), Color(0xE8F6F8FC)],
          ),
          border: Border.all(
            color: dark
                ? Colors.white.withValues(alpha: 0.24)
                : Colors.black.withValues(alpha: 0.10),
            width: 0.65,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0)
                  Container(
                    width: 0.6,
                    height: 18,
                    color: dark
                        ? Colors.white.withValues(alpha: 0.24)
                        : Colors.black.withValues(alpha: 0.12),
                  ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: actions[i].onTap,
                  child: SizedBox(
                    width: 38,
                    height: 38,
                    child: Center(
                      child: Icon(
                        _cupertinoIconForSfSymbol(actions[i].symbol),
                        size: 17.5,
                        color: actions[i].color ?? defaultInk,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Zero-`BackdropFilter`, exact-geometry transition placeholder matching native
/// iOS 26 `UISegmentedControl` (continuous capsule track + translucent sliding
/// thumb + equal-width segments) so returning to Home/Netdisk/Library never
/// flashes legacy separate pills.
class _Ios26SegmentedPlaceholder extends StatelessWidget {
  final List<String> segments;
  final int selectedIndex;
  final double height;
  final ValueChanged<int> onChanged;

  const _Ios26SegmentedPlaceholder({
    required this.segments,
    required this.selectedIndex,
    required this.height,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final count = segments.length;
    if (count == 0) return SizedBox(width: double.infinity, height: height);
    final safeIdx = selectedIndex.clamp(0, count - 1);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      key: const ValueKey('ios26-segmented-transition-placeholder'),
      width: double.infinity,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(height * 0.5),
          color: dark ? const Color(0x6634343C) : const Color(0x18111318),
          border: Border.all(
            color: dark
                ? Colors.white.withValues(alpha: 0.18)
                : Colors.black.withValues(alpha: 0.08),
            width: 0.6,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(2.5),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final segW = constraints.maxWidth / count;
              final segH = constraints.maxHeight;
              return Stack(
                children: [
                  Positioned(
                    left: segW * safeIdx,
                    top: 0,
                    width: segW,
                    height: segH,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(segH * 0.5),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: dark
                              ? const [Color(0xFF5D5D64), Color(0xFF4A4A50)]
                              : const [Color(0xFFFFFFFF), Color(0xFFF4F6FA)],
                        ),
                        border: Border.all(
                          color: dark
                              ? Colors.white.withValues(alpha: 0.22)
                              : Colors.black.withValues(alpha: 0.08),
                          width: 0.5,
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < count; i++)
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => onChanged(i),
                            child: Center(
                              child: Text(
                                segments[i],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: i == safeIdx
                                      ? (dark
                                          ? Colors.white
                                          : const Color(0xFF14171F))
                                      : (dark
                                          ? Colors.white.withValues(alpha: 0.76)
                                          : const Color(0xB814171F)),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class IosNativeFilterCategory {
  final String id;
  final String label;
  final String kind; // 'all' | 'cat' | 'genre'

  const IosNativeFilterCategory({
    required this.id,
    required this.label,
    required this.kind,
  });

  Map<String, dynamic> toMap() => <String, dynamic>{
        'id': id,
        'label': label,
        'kind': kind,
      };
}

class IosNativeFilterResult {
  final String categoryId;
  final String genreLabel;
  final String area;
  final String year;

  const IosNativeFilterResult({
    required this.categoryId,
    required this.genreLabel,
    required this.area,
    required this.year,
  });
}

/// Presents a native iOS 26 `UISheetPresentationController` Liquid Glass filter
/// sheet (`类别 / 地区 / 年份`), returning the chosen filter values or `null`
/// when unavailable.
Future<IosNativeFilterResult?> showAppleNativeFilterSheet({
  String title = '多维片库筛选',
  required List<IosNativeFilterCategory> categories,
  required String selectedCategoryId,
  required String selectedGenreLabel,
  required List<String> areas,
  required String selectedArea,
  required List<String> years,
  required String selectedYear,
}) async {
  if (!IosLiquidGlassBridge.isAvailable) return null;
  if (IosLiquidGlassBridge._sheetPresentationInFlight) return null;
  IosLiquidGlassBridge._setSheetPresentationInFlight(true);
  try {
    final result = await IosLiquidGlassBridge.channel
        .invokeMapMethod<String, dynamic>(
      'showFilterSheet',
      <String, dynamic>{
        'title': title,
        'categories': [for (final c in categories) c.toMap()],
        'selectedCategoryId': selectedCategoryId,
        'selectedGenreLabel': selectedGenreLabel,
        'areas': areas,
        'selectedArea': selectedArea,
        'years': years,
        'selectedYear': selectedYear,
      },
    );
    if (result == null) return null;
    return IosNativeFilterResult(
      categoryId: (result['categoryId'] as String?) ?? '',
      genreLabel: (result['genreLabel'] as String?) ?? '',
      area: (result['area'] as String?) ?? '',
      year: (result['year'] as String?) ?? '',
    );
  } on MissingPluginException {
    return null;
  } catch (_) {
    return null;
  } finally {
    IosLiquidGlassBridge._setSheetPresentationInFlight(false);
  }
}

/// Presents a genuine iOS 26 Liquid Glass `UISheetPresentationController`
/// privacy passcode modal (`verify` or `set` two-step confirmation mode) with
/// native `UIButton.Configuration.glass()` numeric keypad, haptic feedback,
/// spring shake on wrong PIN, and async verification/save callback to Dart.
///
/// Returns:
/// - `true` if PIN was verified or saved successfully
/// - `false` if cancelled / dismissed by the user
/// - `null` if native iOS 26 Liquid Glass bridge is unavailable (caller should
///   fall back to Flutter's `_buildGlassPinPadCard`).
Future<bool?> showAppleNativePrivacyPin({
  required String mode,
  required String title,
  required String subtitle,
  String confirmTitle = '再次输入确认密码',
  String confirmSubtitle = '请再次输入刚才设置的 4 位数字密码',
  int pinLength = 4,
  String? loadingText,
  String mismatchError = '两次输入的密码不一致，请重新设置',
  required Future<({bool ok, String? error})> Function(String pin) onSubmit,
}) async {
  if (!IosLiquidGlassBridge.isAvailable) return null;
  final sessionId = IosLiquidGlassBridge._registerPinCallback((pin) async {
    try {
      final res = await onSubmit(pin);
      return <String, dynamic>{
        'ok': res.ok,
        if (res.error != null && res.error!.isNotEmpty) 'error': res.error,
      };
    } catch (_) {
      return <String, dynamic>{'ok': false, 'error': '操作失败，请重试'};
    }
  });
  try {
    final result = await IosLiquidGlassBridge.channel.invokeMethod<bool>(
      'showPrivacyPin',
      <String, dynamic>{
        'sessionId': sessionId,
        'mode': mode,
        'title': title,
        'subtitle': subtitle,
        'confirmTitle': confirmTitle,
        'confirmSubtitle': confirmSubtitle,
        'pinLength': pinLength,
        if (loadingText != null && loadingText.isNotEmpty)
          'loadingText': loadingText,
        'mismatchError': mismatchError,
      },
    );
    return result;
  } on MissingPluginException {
    return null;
  } catch (_) {
    return null;
  } finally {
    IosLiquidGlassBridge._unregisterPinCallback(sessionId);
  }
}

class AppleNativeAlertAction {
  final Key? key;
  final String id;
  final String title;
  final bool isCancel;
  final bool isDestructive;
  final bool isDefault;

  const AppleNativeAlertAction({
    this.key,
    required this.id,
    required this.title,
    this.isCancel = false,
    this.isDestructive = false,
    this.isDefault = false,
  });

  Map<String, dynamic> toMap() => <String, dynamic>{
        'id': id,
        'title': title,
        'style': isCancel
            ? 'cancel'
            : (isDestructive ? 'destructive' : 'default'),
        'isDefault': isDefault,
      };
}

class AppleNativeSheetOption<T> {
  final T value;
  final String title;
  final bool isDestructive;
  final bool isDefault;

  const AppleNativeSheetOption({
    required this.value,
    required this.title,
    this.isDestructive = false,
    this.isDefault = false,
  });
}

/// Presents a genuine iOS 26 Liquid Glass `UIAlertController(.alert)` on iOS 26+
/// and falls back cleanly to Flutter's `CupertinoAlertDialog` everywhere else.
Future<String?> showAppleNativeAlert(
  BuildContext context, {
  required String title,
  String? message,
  List<AppleNativeAlertAction> actions = const [
    AppleNativeAlertAction(id: 'ok', title: '确定', isDefault: true),
  ],
  bool barrierDismissible = true,
}) async {
  if (IosLiquidGlassBridge.isAvailable) {
    if (IosLiquidGlassBridge._sheetPresentationInFlight) return null;
    IosLiquidGlassBridge._setSheetPresentationInFlight(true);
    try {
      return await IosLiquidGlassBridge.channel.invokeMethod<String>(
        'showAlert',
        <String, dynamic>{
          'title': title,
          if (message != null && message.isNotEmpty) 'message': message,
          'actions': [for (final a in actions) a.toMap()],
        },
      );
    } on MissingPluginException {
      // Fall through to Flutter CupertinoAlertDialog.
    } catch (_) {
      // Fall through to Flutter CupertinoAlertDialog.
    } finally {
      IosLiquidGlassBridge._setSheetPresentationInFlight(false);
    }
  }
  if (!context.mounted) return null;
  return showCupertinoDialog<String>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (ctx) => CupertinoAlertDialog(
      title: Text(title),
      content: message == null || message.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(message),
            ),
      actions: [
        for (final a in actions)
          CupertinoDialogAction(
            key: a.key,
            isDefaultAction: a.isDefault,
            isDestructiveAction: a.isDestructive,
            onPressed: () => Navigator.of(ctx).pop(a.id),
            child: Text(a.title),
          ),
      ],
    ),
  );
}

/// Presents a genuine iOS 26 Liquid Glass `UIAlertController(.actionSheet)` on
/// iOS 26+ (with iPad popover support) and falls back to `CupertinoActionSheet`
/// on iOS < 26 / other platforms.
Future<T?> showAppleNativeActionSheet<T>(
  BuildContext context, {
  String? title,
  String? message,
  required List<AppleNativeSheetOption<T>> options,
  String cancelLabel = '取消',
}) async {
  if (IosLiquidGlassBridge.isAvailable) {
    if (IosLiquidGlassBridge._sheetPresentationInFlight) return null;
    IosLiquidGlassBridge._setSheetPresentationInFlight(true);
    try {
      final pickedId = await IosLiquidGlassBridge.channel.invokeMethod<String>(
        'showActionSheet',
        <String, dynamic>{
          if (title != null && title.isNotEmpty) 'title': title,
          if (message != null && message.isNotEmpty) 'message': message,
          'cancelTitle': cancelLabel,
          'actions': [
            for (var i = 0; i < options.length; i++)
              <String, dynamic>{
                'id': '$i',
                'title': options[i].title,
                'style': options[i].isDestructive ? 'destructive' : 'default',
              },
          ],
        },
      );
      if (pickedId == null) return null;
      final idx = int.tryParse(pickedId);
      if (idx != null && idx >= 0 && idx < options.length) {
        return options[idx].value;
      }
      return null;
    } on MissingPluginException {
      // Fall through to Flutter CupertinoActionSheet.
    } catch (_) {
      // Fall through to Flutter CupertinoActionSheet.
    } finally {
      IosLiquidGlassBridge._setSheetPresentationInFlight(false);
    }
  }
  if (!context.mounted) return null;
  return showCupertinoModalPopup<T>(
    context: context,
    builder: (sheetCtx) => CupertinoActionSheet(
      title: title == null || title.isEmpty ? null : Text(title),
      message: message == null || message.isEmpty ? null : Text(message),
      actions: [
        for (final opt in options)
          CupertinoActionSheetAction(
            isDefaultAction: opt.isDefault,
            isDestructiveAction: opt.isDestructive,
            onPressed: () => Navigator.of(sheetCtx).pop(opt.value),
            child: Text(opt.title),
          ),
      ],
      cancelButton: cancelLabel.isEmpty
          ? null
          : CupertinoActionSheetAction(
              onPressed: () => Navigator.of(sheetCtx).pop(),
              child: Text(cancelLabel),
            ),
    ),
  );
}

class AppleNativePickerOption<T> {
  final T value;
  final String title;
  final String? subtitle;
  final String? symbol;
  final bool checked;
  final bool destructive;
  final int section;
  final String? sectionTitle;

  const AppleNativePickerOption({
    required this.value,
    required this.title,
    this.subtitle,
    this.symbol,
    this.checked = false,
    this.destructive = false,
    this.section = 0,
    this.sectionTitle,
  });
}

/// Presents a native iOS 26 `UISheetPresentationController` Liquid Glass
/// half-sheet option picker (with SF Symbols, subtitles, sections, and native
/// checkmarks). On iOS 26 with `reduceTransparency` or `forceOpaque` enabled,
/// continues presenting the native sheet with opaque dark styling via
/// `forceOpaque: true`. When running on iOS 15–18 or non-iOS platforms,
/// delegates to [fallback] if provided or falls back cleanly to
/// `CupertinoActionSheet`.
Future<T?> showAppleNativeOptionSheet<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<AppleNativePickerOption<T>> options,
  String cancelLabel = '关闭',
  bool forceOpaque = false,
  Rect? anchorRect,
  bool forceDark = false,
  Future<T?> Function()? fallback,
}) async {
  if (IosLiquidGlassBridge.isAvailable) {
    if (IosLiquidGlassBridge._sheetPresentationInFlight) return null;
    IosLiquidGlassBridge._setSheetPresentationInFlight(true);
    final effectiveOpaque =
        forceOpaque || IosLiquidGlassBridge.reduceTransparency;
    try {
      final pickedId = await IosLiquidGlassBridge.channel.invokeMethod<String>(
        'showOptionSheet',
        <String, dynamic>{
          'title': title,
          if (subtitle != null && subtitle.isNotEmpty) 'subtitle': subtitle,
          'cancelTitle': cancelLabel,
          'forceOpaque': effectiveOpaque,
          if (forceDark) 'forceDark': true,
          if (anchorRect != null)
            'anchorRect': <String, double>{
              'x': anchorRect.left,
              'y': anchorRect.top,
              'width': anchorRect.width,
              'height': anchorRect.height,
            },
          'items': [
            for (var i = 0; i < options.length; i++)
              <String, dynamic>{
                'id': '$i',
                'title': options[i].title,
                if (options[i].subtitle != null &&
                    options[i].subtitle!.isNotEmpty)
                  'subtitle': options[i].subtitle,
                if (options[i].symbol != null && options[i].symbol!.isNotEmpty)
                  'symbol': options[i].symbol,
                'checked': options[i].checked,
                'destructive': options[i].destructive,
                'section': options[i].section,
                if (options[i].sectionTitle != null &&
                    options[i].sectionTitle!.isNotEmpty)
                  'sectionTitle': options[i].sectionTitle,
              },
          ],
        },
      );
      if (pickedId == null) return null;
      final idx = int.tryParse(pickedId);
      if (idx != null && idx >= 0 && idx < options.length) {
        return options[idx].value;
      }
      return null;
    } on MissingPluginException {
      // Fall through to Flutter fallback below.
    } catch (_) {
      // Fall through to Flutter fallback below.
    } finally {
      IosLiquidGlassBridge._setSheetPresentationInFlight(false);
    }
  }
  if (fallback != null) {
    return fallback();
  }
  if (!context.mounted) return null;
  return showCupertinoModalPopup<T>(
    context: context,
    builder: (sheetCtx) => CupertinoActionSheet(
      title: Text(title),
      message: subtitle == null || subtitle.isEmpty ? null : Text(subtitle),
      actions: [
        for (final opt in options)
          CupertinoActionSheetAction(
            isDefaultAction: opt.checked,
            isDestructiveAction: opt.destructive,
            onPressed: () => Navigator.of(sheetCtx).pop(opt.value),
            child: Text(opt.checked ? '✓ ${opt.title}' : opt.title),
          ),
      ],
      cancelButton: cancelLabel.isEmpty
          ? null
          : CupertinoActionSheetAction(
              onPressed: () => Navigator.of(sheetCtx).pop(),
              child: Text(cancelLabel),
            ),
    ),
  );
}
