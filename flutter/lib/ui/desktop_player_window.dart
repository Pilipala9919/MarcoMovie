import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';
import 'windows_title_bar.dart';

/// Owns native fullscreen for one player route. Native transitions are serialized
/// so a second double click or leaving the route cannot race a macOS animation.
class DesktopPlayerWindow extends ChangeNotifier with WindowListener {
  DesktopPlayerWindow({bool? macOS, bool? immersiveFrame})
      : _macOS = macOS ?? (defaultTargetPlatform == TargetPlatform.macOS),
        _immersiveFrame =
            immersiveFrame ??
                (!(macOS ?? (defaultTargetPlatform == TargetPlatform.macOS)) &&
                    defaultTargetPlatform == TargetPlatform.windows) {
    windowManager.addListener(this);
  }

  final bool _macOS;
  final bool _immersiveFrame;
  Future<void>? _ready;
  Future<void> _queue = Future<void>.value();
  Future<void>? _closed;
  Completer<void>? _transition;
  Timer? _transitionTimer;
  bool? _transitionTarget;
  bool? _initialFullscreen;
  bool _fullscreen = false;
  bool _changing = false;
  bool _closing = false;

  bool get fullscreen => _fullscreen;

  Future<void> initialize() => _ready ??= _capture();

  Future<void> _capture() async {
    _initialFullscreen = await windowManager.isFullScreen();
    _update(_initialFullscreen!);
    if (_fullscreen) await _titleBar(true);
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    // Keep the queue usable after a failed native call; its caller gets the error.
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> toggle() {
    if (_closing) return Future<void>.value();
    return _enqueue(() async {
      await initialize();
      await _setFullscreen(!await windowManager.isFullScreen());
    });
  }

  /// Returns false only when Escape should leave the player route.
  Future<bool> exitFullscreen() {
    if (_closing) return Future<bool>.value(true);
    return _enqueue(() async {
      await initialize();
      if (!await windowManager.isFullScreen()) return false;
      await _setFullscreen(false);
      return true;
    });
  }

  Future<void> _titleBar(bool full) => windowManager.setTitleBarStyle(
    // Mac uses a hidden title bar with native traffic lights in windowed mode;
    // Windows uses a full-time hidden native frame with our Flutter immersive bar.
    full || _macOS || _immersiveFrame
        ? TitleBarStyle.hidden
        : TitleBarStyle.normal,
    windowButtonVisibility: _immersiveFrame ? false : !full,
  );

  Future<bool> _safeIsMaximized() async {
    try {
      return await windowManager.isMaximized();
    } catch (_) {
      return false;
    }
  }

  Future<void> _repairWindowsMaximizedExit() async {
    if (!_immersiveFrame || _macOS) return;
    if (!await _safeIsMaximized()) return;
    // On Windows, window_manager 0.5.1 restores a maximized window from
    // fullscreen with SWP_NOMOVE|SWP_NOSIZE + PostMessage(SC_MAXIMIZE) while
    // IsZoomed() is still true. Win32 ignores SC_MAXIMIZE on an already-zoomed
    // window, leaving bounds misaligned and window_manager's internal state
    // stuck in STATE_FULLSCREEN_ENTERED (never emitting leave-full-screen or
    // subsequent maximize/unmaximize events). Bouncing unmaximize -> maximize
    // forces SIZE_RESTORED -> SIZE_MAXIMIZED and cleanly restores the frame.
    try {
      await windowManager.unmaximize();
      for (var i = 0; i < 12; i++) {
        if (!await _safeIsMaximized()) break;
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      if (!await _safeIsMaximized()) {
        await windowManager.maximize();
        for (var i = 0; i < 12; i++) {
          if (await _safeIsMaximized()) break;
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
      }
    } catch (error) {
      debugPrint(
        'Windows maximized fullscreen restore fallback skipped: $error',
      );
    }
  }

  Future<void> _setFullscreen(bool full) async {
    _changing = true;
    var wasFullscreen = false;
    try {
      wasFullscreen = await windowManager.isFullScreen();
      if (wasFullscreen != full) {
        if (full) await _titleBar(true);
        final completed = Completer<void>();
        _transition = completed;
        _transitionTarget = full;
        await windowManager.setFullScreen(full);
        // AppKit returns from toggleFullScreen before its animation completes.
        // Do not restore the titlebar or issue another toggle during animation.
        if (_macOS) {
          _transitionTimer?.cancel();
          _transitionTimer = Timer(const Duration(seconds: 8), () {
            if (!completed.isCompleted) {
              completed.completeError(
                TimeoutException(
                  'macOS fullscreen transition timed out',
                  const Duration(seconds: 8),
                ),
              );
            }
          });
          await completed.future;
        }
      }
      final actual = await windowManager.isFullScreen();
      if (actual != full) {
        throw StateError('Window fullscreen transition failed');
      }
      if (wasFullscreen && !actual) {
        await _repairWindowsMaximizedExit();
      }
      await _titleBar(actual);
      _update(actual);
    } catch (_) {
      // A failed entry must not strand a normal window without its controls.
      final actual = await windowManager.isFullScreen();
      if (wasFullscreen && !actual) {
        await _repairWindowsMaximizedExit();
      }
      await _titleBar(actual);
      _update(actual);
      rethrow;
    } finally {
      _transitionTimer?.cancel();
      _transitionTimer = null;
      _transition = null;
      _transitionTarget = null;
      _changing = false;
    }
  }

  void _update(bool full) {
    if (_immersiveFrame) {
      WindowsImmersiveFrame.notifyFullScreen(full);
    }
    if (_fullscreen == full) return;
    _fullscreen = full;
    notifyListeners();
  }

  void _nativeFullscreen(bool full) {
    _update(full);
    if (_transitionTarget == full && !(_transition?.isCompleted ?? true)) {
      _transitionTimer?.cancel();
      _transitionTimer = null;
      _transition!.complete();
    }
    if (!_changing && !_closing) {
      // Also handle the Mac green button / system fullscreen shortcut.
      unawaited(
        _enqueue(() async {
          final actual = await windowManager.isFullScreen();
          await _titleBar(actual);
          _update(actual);
        }).catchError((Object error) {
          debugPrint('Window titlebar update failed: $error');
        }),
      );
    }
  }

  @override
  void onWindowEnterFullScreen() => _nativeFullscreen(true);

  @override
  void onWindowLeaveFullScreen() => _nativeFullscreen(false);

  Future<void> close() {
    _closing = true;
    return _closed ??= _enqueue(() async {
      try {
        await initialize();
        await _setFullscreen(_initialFullscreen!);
      } finally {
        if (_immersiveFrame &&
            !_fullscreen &&
            WindowsImmersiveFrame.fullScreen.value) {
          WindowsImmersiveFrame.fullScreen.value = false;
        }
        windowManager.removeListener(this);
        super.dispose();
      }
    });
  }
}
