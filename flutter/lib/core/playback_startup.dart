import 'dart:async';

/// Bounds the wait for actual media progress. A decoder's `playing` flag,
/// duration, or single initial decoded frame alone does not mean playback is
/// advancing rather than sitting in `paused-for-cache` at `00:00`.
class PlaybackStartup {
  PlaybackStartup({
    this.timeout = const Duration(seconds: 60),
    this.fallbackTimeout = const Duration(seconds: 15),
    this.bufferingStallTimeout = const Duration(seconds: 12),
    this.minimumProgress = const Duration(milliseconds: 250),
    this.startupWindow = const Duration(seconds: 3),
  });

  final Duration timeout;
  final Duration fallbackTimeout;
  final Duration bufferingStallTimeout;
  final Duration minimumProgress;
  final Duration startupWindow;

  Timer? _timer;
  Timer? _stallTimer;
  void Function()? _onTimeout;
  bool _hasFallback = false;
  Duration? _timeoutOverride;
  bool _progressed = false;
  bool _pastStartupWindow = false;
  bool _buffering = false;
  bool _playing = true;
  Duration _startOffset = Duration.zero;
  Duration? _effectiveStart;
  Duration _lastPosition = Duration.zero;

  bool get isPastStartupWindow => _pastStartupWindow;

  void waitForProgress(
    void Function() onTimeout, {
    bool hasFallback = false,
    Duration startOffset = Duration.zero,
    Duration? timeoutOverride,
  }) {
    cancel();
    _onTimeout = onTimeout;
    _hasFallback = hasFallback;
    _timeoutOverride = timeoutOverride;
    _progressed = false;
    _pastStartupWindow = false;
    _buffering = false;
    _playing = true;
    _startOffset = startOffset > Duration.zero ? startOffset : Duration.zero;
    _effectiveStart = _startOffset > Duration.zero ? null : Duration.zero;
    _lastPosition = _startOffset;
    _armInitialTimer();
  }

  void reanchor(Duration startOffset) {
    if (_pastStartupWindow || _onTimeout == null) return;
    _startOffset = startOffset > Duration.zero ? startOffset : Duration.zero;
    _effectiveStart = _startOffset > Duration.zero ? null : Duration.zero;
    _lastPosition = _startOffset;
  }

  void position(Duration value) {
    if (_onTimeout == null || _pastStartupWindow) return;
    if (_startOffset > Duration.zero) {
      if (value < _startOffset - const Duration(seconds: 10)) return;
      _effectiveStart ??= value;
    }
    final baseline = _effectiveStart ?? Duration.zero;
    final delta = value - baseline;
    if (value > _lastPosition) {
      _lastPosition = value;
      if (_stallTimer != null && _buffering && _playing) {
        _armStallTimer();
      }
    }
    if (delta >= minimumProgress && !_progressed) {
      _progressed = true;
      _timer?.cancel();
      _timer = null;
    }
    if (delta >= startupWindow) {
      _pastStartupWindow = true;
      cancel();
    }
  }

  void updateState({bool? playing, bool? buffering}) {
    if (_onTimeout == null || _pastStartupWindow) return;
    if (playing != null) _playing = playing;
    if (buffering != null) _buffering = buffering;

    if (!_playing) {
      _timer?.cancel();
      _timer = null;
      _stallTimer?.cancel();
      _stallTimer = null;
      return;
    }
    if (!_progressed && _timer == null) {
      _armInitialTimer();
    }
    if (_buffering) {
      if (_stallTimer == null) _armStallTimer();
    } else {
      _stallTimer?.cancel();
      _stallTimer = null;
    }
  }

  void _armInitialTimer() {
    _timer?.cancel();
    final base = _timeoutOverride ?? timeout;
    final dur = _hasFallback && fallbackTimeout < base ? fallbackTimeout : base;
    _timer = Timer(dur, _fireTimeout);
  }

  void _armStallTimer() {
    _stallTimer?.cancel();
    final base = _timeoutOverride ?? timeout;
    final dur = _hasFallback && bufferingStallTimeout < base
        ? bufferingStallTimeout
        : base;
    _stallTimer = Timer(dur, _fireTimeout);
  }

  void _fireTimeout() {
    final callback = _onTimeout;
    cancel();
    callback?.call();
  }

  void reset() {
    _pastStartupWindow = false;
    cancel();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    _onTimeout = null;
  }
}
