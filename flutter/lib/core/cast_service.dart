import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../ui/ios_liquid_glass.dart';

/// A discovered DLNA / UPnP MediaRenderer on the local network.
class CastDevice {
  final String id;
  final String name;
  final String model;
  final String host;
  final String location;
  final String avTransportControlUrl;
  final String? renderingControlUrl;

  const CastDevice({
    required this.id,
    required this.name,
    required this.model,
    required this.host,
    required this.location,
    required this.avTransportControlUrl,
    this.renderingControlUrl,
  });

  String get subtitle => model.isNotEmpty ? '$model · $host' : host;
}

enum CastSessionState {
  idle,
  connecting,
  playing,
  paused,
  error,
}

/// Token-scoped, LAN-only on-demand HTTP relay so loopback proxies (`127.0.0.1`
/// netdisk/range/local media proxies) and header-protected streams (Referer /
/// Cookie / User-Agent) can be played seamlessly by any DLNA smart TV or Marco
/// Movie Android TV on the same Wi-Fi without ever exposing loopback proxies
/// permanently on `0.0.0.0`.
class _CastMediaRelay {
  HttpServer? _server;
  String _token = '';
  Uri? _upstreamUri;
  Map<String, String> _upstreamHeaders = const {};
  String _lanHost = '';

  Future<String> expose({
    required Uri upstreamUri,
    required Map<String, String> headers,
    required String lanIp,
    String? preferredExtension,
  }) async {
    await close();
    final rng = Random.secure();
    final tokenBytes = List<int>.generate(16, (_) => rng.nextInt(256));
    _token = tokenBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    _upstreamUri = upstreamUri;
    _upstreamHeaders = Map<String, String>.from(headers);
    _lanHost = lanIp;

    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress(lanIp), 0);
    } catch (_) {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _server = server;
    server.listen(
      _handleRequest,
      onError: (_) {},
      cancelOnError: false,
    );

    final ext = _normalizeExtension(preferredExtension ?? _inferExtension(upstreamUri));
    return Uri(
      scheme: 'http',
      host: _lanHost,
      port: server.port,
      path: '/s/$_token/video$ext',
    ).toString();
  }

  static String _inferExtension(Uri uri) {
    final path = uri.path.toLowerCase();
    for (final ext in const ['.m3u8', '.mp4', '.mkv', '.ts', '.webm', '.flv', '.mov', '.avi']) {
      if (path.endsWith(ext)) return ext;
    }
    final q = uri.query.toLowerCase();
    if (q.contains('.m3u8') || q.contains('m3u8')) return '.m3u8';
    if (q.contains('.mkv')) return '.mkv';
    return '.mp4';
  }

  static String _normalizeExtension(String raw) {
    final clean = raw.trim().toLowerCase();
    if (clean.startsWith('.') && RegExp(r'^\.[a-z0-9]{2,5}$').hasMatch(clean)) {
      return clean;
    }
    return '.mp4';
  }

  Future<void> _handleRequest(HttpRequest req) async {
    final peer = req.connectionInfo?.remoteAddress.address ?? '';
    if (peer.isNotEmpty &&
        peer != '127.0.0.1' &&
        peer != '::1' &&
        !CastController.isPrivateLanIpv4(peer)) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    if (req.method != 'GET' && req.method != 'HEAD') {
      req.response.statusCode = HttpStatus.methodNotAllowed;
      await req.response.close();
      return;
    }

    final upstream = _upstreamUri;
    if (upstream == null || _token.isEmpty) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }

    Uri target;
    final path = req.uri.path;
    final directPrefix = '/s/$_token/';
    final proxyPrefix = '/p/$_token/';
    if (path.startsWith(directPrefix)) {
      target = upstream;
    } else if (path.startsWith(proxyPrefix)) {
      final sub = path.substring(proxyPrefix.length);
      final q = req.uri.hasQuery ? '?${req.uri.query}' : '';
      target = Uri.parse('${upstream.scheme}://${upstream.host}:${upstream.port}/$sub$q');
    } else {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12)
      ..autoUncompress = false;
    final targetHost = target.host.toLowerCase();
    if (targetHost == '127.0.0.1' ||
        targetHost == 'localhost' ||
        CastController.isPrivateLanIpv4(targetHost)) {
      client.findProxy = (_) => 'DIRECT';
    }
    try {
      final outReq = await client.openUrl(req.method, target);
      outReq.followRedirects = true;
      outReq.maxRedirects = 8;

      _upstreamHeaders.forEach((k, v) {
        final lk = k.toLowerCase();
        if (lk == 'host' || lk == 'connection' || lk == 'content-length') return;
        if (v.isNotEmpty) outReq.headers.set(k, v);
      });
      final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
      if (rangeHeader != null && rangeHeader.isNotEmpty) {
        outReq.headers.set(HttpHeaders.rangeHeader, rangeHeader);
      }

      final outResp = await outReq.close();
      req.response.statusCode = outResp.statusCode;

      final contentType = outResp.headers.value(HttpHeaders.contentTypeHeader) ??
          CastController.inferDlnaMimeType(target.toString());
      final isPlaylist = contentType.toLowerCase().contains('mpegurl') ||
          target.path.toLowerCase().endsWith('.m3u8');

      if (isPlaylist && req.method == 'GET') {
        final body = await utf8.decoder.bind(outResp).join();
        final rewritten = _rewriteLoopbackPlaylist(body, upstream);
        final bytes = utf8.encode(rewritten);
        req.response.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/vnd.apple.mpegurl; charset=utf-8',
        );
        req.response.headers.contentLength = bytes.length;
        req.response.add(bytes);
        await req.response.close();
        return;
      }

      req.response.headers.set(HttpHeaders.contentTypeHeader, contentType);
      req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      final contentRange = outResp.headers.value(HttpHeaders.contentRangeHeader);
      if (contentRange != null && contentRange.isNotEmpty) {
        req.response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
      }
      if (outResp.contentLength >= 0) {
        req.response.headers.contentLength = outResp.contentLength;
      }
      if (req.method == 'HEAD') {
        await outResp.drain<void>();
        await req.response.close();
        return;
      }
      await req.response.addStream(outResp);
      await req.response.close();
    } catch (_) {
      try {
        req.response.statusCode = HttpStatus.badGateway;
        await req.response.close();
      } catch (_) {}
    } finally {
      client.close(force: true);
    }
  }

  String _rewriteLoopbackPlaylist(String body, Uri upstream) {
    final server = _server;
    if (server == null) return body;
    final relayBase = Uri(
      scheme: 'http',
      host: _lanHost,
      port: server.port,
      path: '/p/$_token/',
    ).toString();
    final loopbackHost = Uri(
      scheme: upstream.scheme,
      host: upstream.host,
      port: upstream.port,
      path: '/',
    ).toString();
    var out = body.replaceAll(loopbackHost, relayBase);
    if (upstream.host == 'localhost') {
      out = out.replaceAll(
        Uri(
          scheme: upstream.scheme,
          host: '127.0.0.1',
          port: upstream.port,
          path: '/',
        ).toString(),
        relayBase,
      );
    } else if (upstream.host == '127.0.0.1') {
      out = out.replaceAll(
        Uri(
          scheme: upstream.scheme,
          host: 'localhost',
          port: upstream.port,
          path: '/',
        ).toString(),
        relayBase,
      );
    }
    return out;
  }

  Future<void> close() async {
    final s = _server;
    _server = null;
    _token = '';
    _upstreamUri = null;
    _upstreamHeaders = const {};
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
    }
  }
}

/// Pure-Dart + native iOS Bonjour multi-layer DLNA/UPnP discovery + SOAP
/// playback controller + on-demand LAN media relay + native AirPlay picker.
///
/// Works reliably under BOTH:
/// - **TrollStore / multicast-entitled builds** (standard SSDP multicast
///   `239.255.255.250:1900` bound to the active Wi-Fi interface)
/// - **Standard sideload / free-certificate signing (全能签 / AltStore /
///   Sideloadly)** where Apple strips `com.apple.developer.networking.multicast`
///   (uses native iOS Bonjour `NetServiceBrowser` + paced unicast `/24` UDP
///   M-SEARCH + direct Marco Movie TV & smart TV HTTP XML probing + manual IP).
class CastController extends ChangeNotifier {
  static const String _ssdpAddress = '239.255.255.250';
  static const int _ssdpPort = 1900;
  static const int marcoTvPreferredPort = 18652;
  static const List<int> marcoTvFallbackPorts = [18652, 18653];
  static const String _recentLocationsPrefsKey = 'marco_cast_recent_locations';

  static const String _avTransportService =
      'urn:schemas-upnp-org:service:AVTransport:1';
  static const String _renderingControlService =
      'urn:schemas-upnp-org:service:RenderingControl:1';

  /// Well-known DLNA MediaRenderer HTTP ports across Marco Movie TV, Lebo 乐播,
  /// Xiaomi, Hisense, TCL, Sony, Dangbei, Huawei, Kodi, and Cling/Platinum DMRs.
  static const List<int> commonDlnaPorts = [
    18652,
    18653,
    49152,
    49153,
    49154,
    49595,
    57645,
    38400,
    52235,
    60606,
    8200,
    9197,
    1990,
    9999,
    56789,
    2870,
    1400,
    8008,
    5000,
    15678,
  ];

  static const List<String> commonDlnaXmlPaths = [
    '/dlna/device.xml',
    '/description.xml',
    '/desc.xml',
    '/dmr/description.xml',
    '/dmr',
    '/upnp/desc.xml',
    '/devicedesc.xml',
    '/MediaRenderer/desc.xml',
    '/xml/device_description.xml',
    '/rootDesc.xml',
    '/',
  ];

  static const List<String> _bonjourServiceTypes = [
    '_marcomovie-cast._tcp.',
    '_airplay._tcp.',
    '_raop._tcp.',
    '_lelink._tcp.',
    '_lebo._tcp.',
    '_googlecast._tcp.',
    '_dlna._tcp.',
    '_upnp._tcp.',
  ];

  final List<CastDevice> _devices = [];
  bool _scanning = false;
  CastDevice? _activeDevice;
  CastSessionState _state = CastSessionState.idle;
  String? _statusMessage;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  int _volume = 60;
  bool _muted = false;
  double _speed = 1.0;
  String _currentMediaUrl = '';
  String _currentTitle = '';
  Timer? _pollTimer;
  bool _disposed = false;
  final _CastMediaRelay _relay = _CastMediaRelay();

  List<CastDevice> get devices => List.unmodifiable(_devices);
  bool get scanning => _scanning;
  CastDevice? get activeDevice => _activeDevice;
  CastSessionState get state => _state;
  String? get statusMessage => _statusMessage;
  Duration get position => _position;
  Duration get duration => _duration;
  int get volume => _volume;
  bool get muted => _muted;
  double get speed => _speed;
  String get currentTitle => _currentTitle;
  bool get isCasting =>
      _activeDevice != null &&
      (_state == CastSessionState.connecting ||
          _state == CastSessionState.playing ||
          _state == CastSessionState.paused);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Returns `true` for RFC1918 / CGNAT private LAN IPv4 addresses.
  static bool isPrivateLanIpv4(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final octets = parts.map(int.tryParse).toList(growable: false);
    if (octets.any((v) => v == null || v < 0 || v > 255)) return false;
    final a = octets[0]!;
    final b = octets[1]!;
    if (a == 10) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    if (a == 100 && b >= 64 && b <= 127) return true;
    return false;
  }

  /// Returns `true` for VPN, cellular, loopback, or virtual tunnel interfaces
  /// that should never be selected as the Wi-Fi LAN interface.
  static bool isSkippedInterfaceName(String name) {
    final lower = name.toLowerCase();
    for (final prefix in const [
      'utun',
      'ipsec',
      'ppp',
      'tun',
      'tap',
      'wg',
      'pdp_ip',
      'rmnet',
      'ccmni',
      'awdl',
      'llw',
      'anpi',
      'bridge',
      'lo',
    ]) {
      if (lower.startsWith(prefix)) return true;
    }
    for (final token in const [
      'clash',
      'mihomo',
      'vethernet',
      'wsl',
      'docker',
      'vmware',
      'virtual',
      'tailscale',
      'zerotier',
      'wireguard',
      'vpn',
      'loopback',
    ]) {
      if (lower.contains(token)) return true;
    }
    return lower == 'meta' || lower.startsWith('meta ');
  }

  static int _interfacePriority(String name) {
    final lower = name.toLowerCase();
    if (lower == 'en0' || lower == 'wlan0' || lower == 'wlan' || lower == 'wi-fi') return 0;
    if (lower.contains('wlan') || lower.contains('wi-fi') || lower.contains('wireless')) return 1;
    if (lower.startsWith('en')) return 2;
    if (lower.startsWith('eth') || lower.contains('以太网') || lower.contains('ethernet')) return 3;
    return 4;
  }

  static String? _prefix24(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return null;
    return '${parts[0]}.${parts[1]}.${parts[2]}';
  }

  static String? _prefix16(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return null;
    return '${parts[0]}.${parts[1]}';
  }

  /// Resolves the device's primary Wi-Fi / Ethernet private LAN IPv4 address,
  /// explicitly skipping VPN tunnels (`utun*`, Clash/Meta/Tailscale) and
  /// cellular interfaces (`pdp_ip*`). When [peerHost] is supplied, prefers an
  /// interface on the exact same `/24` (then `/16`) subnet as the target TV.
  static Future<String?> resolveLanIpv4({String? peerHost}) async {
    final cleanPeer = peerHost?.trim().toLowerCase() ?? '';
    if (cleanPeer == '127.0.0.1' || cleanPeer == 'localhost') {
      return '127.0.0.1';
    }
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final sorted = List<NetworkInterface>.of(interfaces)
        ..sort((a, b) =>
            _interfacePriority(a.name).compareTo(_interfacePriority(b.name)));
      final privateCandidates = <String>[];
      String? fallbackNonLoopback;
      for (final iface in sorted) {
        if (isSkippedInterfaceName(iface.name)) continue;
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (addr.isLoopback || ip.startsWith('169.254.')) continue;
          if (isPrivateLanIpv4(ip)) {
            privateCandidates.add(ip);
          } else {
            fallbackNonLoopback ??= ip;
          }
        }
      }
      if (cleanPeer.isNotEmpty && privateCandidates.isNotEmpty) {
        final peer24 = _prefix24(cleanPeer);
        if (peer24 != null) {
          for (final ip in privateCandidates) {
            if (_prefix24(ip) == peer24) return ip;
          }
        }
        final peer16 = _prefix16(cleanPeer);
        if (peer16 != null) {
          for (final ip in privateCandidates) {
            if (_prefix16(ip) == peer16) return ip;
          }
        }
      }
      if (privateCandidates.isNotEmpty) return privateCandidates.first;
      return fallbackNonLoopback;
    } catch (_) {}
    return null;
  }

  /// Builds all 253 peer host IPv4 addresses in the same `/24` subnet as [lanIp],
  /// excluding [lanIp] itself.
  static List<String> buildSubnetScanIps(String lanIp) {
    final parts = lanIp.split('.');
    if (parts.length != 4) return const [];
    final selfLast = int.tryParse(parts[3]);
    if (selfLast == null || !isPrivateLanIpv4(lanIp)) return const [];
    final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
    final hosts = <String>[];
    for (int i = 1; i <= 254; i++) {
      if (i == selfLast) continue;
      hosts.add('$prefix.$i');
    }
    return hosts;
  }

  /// Rewrites `127.0.0.1` / `localhost` URLs to the device's LAN IPv4 if
  /// available, leaving remote HTTP(S) stream URLs untouched.
  static Future<String> resolveCastableUrl(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) return rawUrl.trim();
    final host = uri.host.toLowerCase();
    if (host == '127.0.0.1' || host == 'localhost') {
      final lanIp = await resolveLanIpv4();
      if (lanIp != null && lanIp.isNotEmpty) {
        return uri.replace(host: lanIp).toString();
      }
    }
    return rawUrl.trim();
  }

  /// Opens the native iOS AirPlay route picker (`AVRoutePickerView`).
  Future<bool> openAirPlayPicker() async {
    return IosLiquidGlassBridge.presentAirPlayPicker();
  }

  /// Multi-layer LAN discovery combining:
  /// 0. Remembered recent devices (`SharedPreferences`)
  /// 1. Wi-Fi-bound multi-burst SSDP multicast (TrollStore / desktop / Android)
  /// 2. Native iOS Bonjour (`NetServiceBrowser` -> works on 全能签 / free certs!)
  /// 3. Paced unicast `/24` SSDP M-SEARCH + Marco Movie TV port `18652` probe
  ///    (works on 全能签 / free certs even when TV has no Bonjour or UDP 1900 is busy!)
  Future<void> scanDevices({
    Duration timeout = const Duration(milliseconds: 3400),
    bool clearExisting = false,
  }) async {
    if (_scanning) return;
    _scanning = true;
    _statusMessage = null;
    if (clearExisting) {
      _devices.clear();
    }
    _notify();

    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      _scanning = false;
      _notify();
      return;
    }

    final seenLocations = <String>{};
    final discovered = List<CastDevice>.of(_devices);
    bool permissionDenied = false;
    bool multicastFailed = false;

    void registerDevice(CastDevice dev) {
      final already = discovered.any(
        (d) =>
            d.id == dev.id ||
            d.avTransportControlUrl == dev.avTransportControlUrl,
      );
      if (already) return;
      discovered.add(dev);
      _devices
        ..clear()
        ..addAll(discovered);
      _statusMessage = null;
      _notify();
      unawaited(_rememberLocation(dev.location));
    }

    Future<void> probeLocation(String location) async {
      final normalized = location.trim();
      if (normalized.isEmpty || !seenLocations.add(normalized)) return;
      final dev = await _fetchDeviceDescription(normalized);
      if (dev != null) registerDevice(dev);
    }

    try {
      final lanIp = await resolveLanIpv4();
      final tasks = <Future<void>>[];

      // Layer 0: Re-verify previously discovered / manually added devices immediately.
      tasks.add(_probeRememberedLocations(probeLocation));

      // Layer 1: Multi-burst SSDP Multicast bound to Wi-Fi interface (TrollStore / desktop).
      tasks.add(
        _runMulticastSsdpScan(
          lanIp: lanIp,
          timeout: timeout,
          onLocation: probeLocation,
          onMulticastError: () => multicastFailed = true,
        ),
      );

      // Layer 2: Native iOS Bonjour discovery (zero multicast entitlement required!).
      if (Platform.isIOS) {
        tasks.add(
          _runIosBonjourScan(
            lanIp: lanIp,
            timeout: Duration(
              milliseconds: (timeout.inMilliseconds * 0.72).round().clamp(1400, 2600),
            ),
            onLocation: probeLocation,
            onPermissionDenied: () => permissionDenied = true,
          ),
        );
      }

      // Layer 3: Paced unicast `/24` UDP M-SEARCH (port 1900) + Marco Movie TV
      // direct port (`18652`) TCP probe — zero multicast entitlement required!
      if (lanIp != null && isPrivateLanIpv4(lanIp)) {
        final subnetIps = buildSubnetScanIps(lanIp);
        if (subnetIps.isNotEmpty) {
          tasks.add(
            _runUnicastSubnetSsdpScan(
              lanIp: lanIp,
              targetIps: subnetIps,
              timeout: timeout,
              onLocation: probeLocation,
            ),
          );
          tasks.add(
            _runMarcoTvSubnetTcpProbe(
              targetIps: subnetIps,
              onLocation: probeLocation,
            ),
          );
        }
      }

      await Future.wait(tasks).timeout(
        timeout + const Duration(seconds: 2),
        onTimeout: () => const [],
      );

      _devices
        ..clear()
        ..addAll(discovered);

      if (_devices.isEmpty) {
        if (permissionDenied) {
          _statusMessage = '未开启本地网络权限，请前往 iPhone「设置 → 隐私与安全性 → 本地网络」允许 Marco Movie';
        } else if (lanIp == null) {
          _statusMessage = '未检测到 Wi-Fi 局域网连接，请确认手机已连接 Wi-Fi（关闭 VPN/代理后重试）';
        } else if (multicastFailed) {
          _statusMessage = '未自动发现电视（当前签名不支持组播），可点下方「手动输入电视 IP」直接连接';
        }
      }
    } catch (e) {
      if (_devices.isEmpty) {
        _statusMessage = '局域网搜索异常，请确认同一 Wi-Fi 并可尝试手动输入电视 IP';
      }
      debugPrint('DLNA scan error: $e');
    } finally {
      _scanning = false;
      _notify();
    }
  }

  Future<void> _probeRememberedLocations(
    Future<void> Function(String location) probeLocation,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(_recentLocationsPrefsKey) ?? const [];
      if (saved.isEmpty) return;
      await Future.wait(saved.take(8).map(probeLocation));
    } catch (_) {}
  }

  Future<void> _rememberLocation(String location) async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = List<String>.of(
        prefs.getStringList(_recentLocationsPrefsKey) ?? const [],
      );
      existing.remove(location);
      existing.insert(0, location);
      if (existing.length > 8) {
        existing.removeRange(8, existing.length);
      }
      await prefs.setStringList(_recentLocationsPrefsKey, existing);
    } catch (_) {}
  }

  Future<void> _runMulticastSsdpScan({
    required String? lanIp,
    required Duration timeout,
    required Future<void> Function(String location) onLocation,
    required VoidCallback onMulticastError,
  }) async {
    RawDatagramSocket? socket;
    Timer? scanTimer;
    final pending = <Future<void>>[];
    try {
      final bindAddr =
          (lanIp != null && isPrivateLanIpv4(lanIp)) ? InternetAddress(lanIp) : InternetAddress.anyIPv4;
      try {
        socket = await RawDatagramSocket.bind(bindAddr, 0, reuseAddress: true);
      } catch (_) {
        socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0, reuseAddress: true);
      }
      socket.broadcastEnabled = true;

      if (lanIp != null && isPrivateLanIpv4(lanIp) && (Platform.isIOS || Platform.isMacOS)) {
        try {
          socket.setRawOption(
            RawSocketOption(
              RawSocketOption.levelIPv4,
              RawSocketOption.IPv4MulticastInterface,
              InternetAddress(lanIp).rawAddress,
            ),
          );
        } catch (_) {}
      }

      final completer = Completer<void>();
      socket.listen(
        (event) {
          if (event != RawSocketEvent.read) return;
          final dg = socket?.receive();
          if (dg == null) return;
          final text = utf8.decode(dg.data, allowMalformed: true);
          final location = extractSsdpHeader(text, 'location');
          if (location != null) {
            pending.add(onLocation(location));
          }
        },
        onError: (_) {
          onMulticastError();
        },
        cancelOnError: false,
      );

      final target = InternetAddress(_ssdpAddress);
      const targets = [
        'urn:schemas-upnp-org:service:AVTransport:1',
        'urn:schemas-upnp-org:device:MediaRenderer:1',
        'upnp:rootdevice',
        'ssdp:all',
      ];

      bool sendBurst() {
        var sentAny = false;
        for (final st in targets) {
          final bytes = utf8.encode(buildSsdpSearchPayload(st));
          try {
            final n = socket?.send(bytes, target, _ssdpPort) ?? 0;
            if (n > 0) sentAny = true;
          } catch (_) {
            onMulticastError();
          }
        }
        return sentAny;
      }

      if (!sendBurst()) {
        onMulticastError();
      } else {
        Timer(const Duration(milliseconds: 450), () {
          if (!completer.isCompleted) sendBurst();
        });
        Timer(const Duration(milliseconds: 950), () {
          if (!completer.isCompleted) sendBurst();
        });
      }

      scanTimer = Timer(timeout, () {
        if (!completer.isCompleted) completer.complete();
      });
      await completer.future;
      if (pending.isNotEmpty) {
        await Future.wait(pending).timeout(
          const Duration(milliseconds: 1200),
          onTimeout: () => const [],
        );
      }
    } catch (_) {
      onMulticastError();
    } finally {
      scanTimer?.cancel();
      socket?.close();
    }
  }

  Future<void> _runIosBonjourScan({
    required String? lanIp,
    required Duration timeout,
    required Future<void> Function(String location) onLocation,
    required VoidCallback onPermissionDenied,
  }) async {
    try {
      final raw = await IosLiquidGlassBridge.discoverBonjourDevices(
        serviceTypes: _bonjourServiceTypes,
        timeout: timeout,
      );
      if (raw == null) return;
      if (raw['permissionDenied'] == true) {
        onPermissionDenied();
      }
      final rawDevices = raw['devices'];
      if (rawDevices is! List || rawDevices.isEmpty) return;

      final tvHosts = <String>{};
      final directFetches = <Future<void>>[];
      for (final entry in rawDevices) {
        if (entry is! Map) continue;
        final host = (entry['host'] ?? '').toString().trim();
        final type = (entry['type'] ?? '').toString().toLowerCase();
        final port = (entry['port'] is num) ? (entry['port'] as num).toInt() : 0;
        final txt = entry['txt'] is Map ? entry['txt'] as Map : const {};
        if (host.isEmpty || host == lanIp || !isPrivateLanIpv4(host)) continue;

        tvHosts.add(host);
        if (type.contains('_marcomovie-cast')) {
          final dlnaPath = (txt['dlna'] ?? '/dlna/device.xml').toString().trim();
          final safePath = dlnaPath.startsWith('/') ? dlnaPath : '/$dlnaPath';
          final effectivePort = port > 0 ? port : marcoTvPreferredPort;
          directFetches.add(
            onLocation(
              Uri(
                scheme: 'http',
                host: host,
                port: effectivePort,
                path: safePath,
              ).toString(),
            ),
          );
        } else if ((type.contains('_dlna') || type.contains('_upnp')) && port > 0) {
          directFetches.add(_probeHostPortXml(host, port, onLocation));
        }
      }

      if (directFetches.isNotEmpty) {
        await Future.wait(directFetches);
      }
      if (tvHosts.isNotEmpty) {
        // For every TV/box discovered via AirPlay/LeLink/GoogleCast/Bonjour,
        // probe BOTH unicast SSDP 1900 AND common DLNA HTTP ports directly!
        await Future.wait([
          _runUnicastSubnetSsdpScan(
            lanIp: lanIp,
            targetIps: tvHosts.toList(growable: false),
            timeout: const Duration(milliseconds: 1100),
            onLocation: onLocation,
          ),
          ...tvHosts.take(6).map((h) => _probeHostCommonDlnaPorts(h, onLocation)),
        ]);
      }
    } catch (e) {
      debugPrint('Bonjour scan error: $e');
    }
  }

  /// Sends paced unicast UDP SSDP M-SEARCH directly to LAN host IPs on port
  /// 1900. Because destination addresses are unicast RFC1918 IPs, iOS allows
  /// this WITHOUT the `com.apple.developer.networking.multicast` entitlement!
  Future<void> _runUnicastSubnetSsdpScan({
    required String? lanIp,
    required List<String> targetIps,
    required Duration timeout,
    required Future<void> Function(String location) onLocation,
  }) async {
    if (targetIps.isEmpty) return;
    RawDatagramSocket? socket;
    Timer? doneTimer;
    final pending = <Future<void>>[];
    try {
      final bindAddr =
          (lanIp != null && isPrivateLanIpv4(lanIp)) ? InternetAddress(lanIp) : InternetAddress.anyIPv4;
      try {
        socket = await RawDatagramSocket.bind(bindAddr, 0, reuseAddress: true);
      } catch (_) {
        socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0, reuseAddress: true);
      }

      final completer = Completer<void>();
      socket.listen(
        (event) {
          if (event != RawSocketEvent.read) return;
          final dg = socket?.receive();
          if (dg == null) return;
          final text = utf8.decode(dg.data, allowMalformed: true);
          final location = extractSsdpHeader(text, 'location');
          if (location != null) {
            pending.add(onLocation(location));
          }
        },
        onError: (_) {},
        cancelOnError: false,
      );

      final payloads = [
        utf8.encode(buildSsdpSearchPayload('urn:schemas-upnp-org:service:AVTransport:1')),
        utf8.encode(buildSsdpSearchPayload('urn:schemas-upnp-org:device:MediaRenderer:1')),
        utf8.encode(buildSsdpSearchPayload('upnp:rootdevice')),
      ];

      doneTimer = Timer(timeout, () {
        if (!completer.isCompleted) completer.complete();
      });

      // Micro-batch 16 hosts every 16ms so Darwin's UDP send buffer never drops
      // packets with ENOBUFS.
      const batchSize = 16;
      for (int i = 0; i < targetIps.length; i += batchSize) {
        if (completer.isCompleted) break;
        final end = min(i + batchSize, targetIps.length);
        for (int j = i; j < end; j++) {
          final addr = InternetAddress(targetIps[j]);
          for (final payload in payloads) {
            try {
              socket.send(payload, addr, _ssdpPort);
            } catch (_) {}
          }
        }
        if (end < targetIps.length) {
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
      }

      await completer.future;
      if (pending.isNotEmpty) {
        await Future.wait(pending).timeout(
          const Duration(milliseconds: 1200),
          onTimeout: () => const [],
        );
      }
    } catch (_) {
    } finally {
      doneTimer?.cancel();
      socket?.close();
    }
  }

  /// Fast bounded-concurrency TCP sweep for Marco Movie Android TV's preferred
  /// port (`18652`) across the `/24` LAN subnet — finds Marco Movie TV even if
  /// BOTH iOS multicast is blocked AND TV's UDP 1900 was hijacked AND mDNS is
  /// filtered by the router.
  Future<void> _runMarcoTvSubnetTcpProbe({
    required List<String> targetIps,
    required Future<void> Function(String location) onLocation,
  }) async {
    const batchSize = 48;
    for (int i = 0; i < targetIps.length; i += batchSize) {
      final slice = targetIps.sublist(i, min(i + batchSize, targetIps.length));
      await Future.wait(
        slice.map((ip) async {
          Socket? sock;
          try {
            sock = await Socket.connect(
              ip,
              marcoTvPreferredPort,
              timeout: const Duration(milliseconds: 360),
            );
            sock.destroy();
            await onLocation(
              Uri(
                scheme: 'http',
                host: ip,
                port: marcoTvPreferredPort,
                path: '/dlna/device.xml',
              ).toString(),
            );
          } catch (_) {
            sock?.destroy();
          }
        }),
      );
    }
  }

  Future<void> _probeHostCommonDlnaPorts(
    String host,
    Future<void> Function(String location) onLocation,
  ) async {
    await Future.wait(
      commonDlnaPorts.map((port) async {
        Socket? sock;
        try {
          sock = await Socket.connect(
            host,
            port,
            timeout: const Duration(milliseconds: 420),
          );
          sock.destroy();
          await _probeHostPortXml(host, port, onLocation);
        } catch (_) {
          sock?.destroy();
        }
      }),
    );
  }

  Future<void> _probeHostPortXml(
    String host,
    int port,
    Future<void> Function(String location) onLocation,
  ) async {
    for (final path in commonDlnaXmlPaths) {
      final url = Uri(
        scheme: 'http',
        host: host,
        port: port,
        path: path,
      ).toString();
      final dev = await _fetchDeviceDescription(url);
      if (dev != null) {
        await onLocation(url);
        return;
      }
    }
  }

  /// Parses manual TV IP / `IP:Port` / URL user input cleanly.
  static Uri? parseManualTargetInput(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final withScheme = trimmed.contains('://') ? trimmed : 'http://$trimmed';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty) return null;
    return uri;
  }

  /// Probes a user-entered TV IP, `IP:Port`, or full URL via direct HTTP XML,
  /// unicast SSDP port 1900, and common smart TV DLNA ports.
  Future<CastDevice?> probeManualTarget(String rawInput) async {
    final parsed = parseManualTargetInput(rawInput);
    if (parsed == null) {
      _statusMessage = '请输入有效的电视局域网 IP（如 10.0.0.88 或 局域网IP:18652）';
      _notify();
      return null;
    }

    _scanning = true;
    _statusMessage = '正在探测 ${parsed.host}…';
    _notify();

    CastDevice? found;
    final seen = <String>{};

    Future<void> acceptLocation(String location) async {
      final clean = location.trim();
      if (clean.isEmpty || !seen.add(clean)) return;
      final dev = await _fetchDeviceDescription(clean);
      if (dev == null) return;
      found ??= dev;
      final exists = _devices.any(
        (d) => d.id == dev.id || d.avTransportControlUrl == dev.avTransportControlUrl,
      );
      if (!exists) {
        _devices.insert(0, dev);
        _notify();
      }
      unawaited(_rememberLocation(dev.location));
    }

    try {
      final host = parsed.host;
      final hasExplicitPort = parsed.hasPort && parsed.port > 0;
      final hasExplicitPath = parsed.path.isNotEmpty && parsed.path != '/';

      // 1. If user pasted a direct XML URL or Marco Movie TV web-cast URL, check immediately.
      if (hasExplicitPath) {
        await acceptLocation(parsed.toString());
        if (found == null && hasExplicitPort) {
          await acceptLocation(
            Uri(
              scheme: 'http',
              host: host,
              port: parsed.port,
              path: '/dlna/device.xml',
            ).toString(),
          );
        }
      }
      if (found == null && hasExplicitPort) {
        await _probeHostPortXml(host, parsed.port, acceptLocation);
      }

      // 2. Simultaneously run unicast SSDP 1900 + common DLNA port probing on that host.
      if (found == null) {
        final lanIp = await resolveLanIpv4();
        await Future.wait([
          _runUnicastSubnetSsdpScan(
            lanIp: lanIp,
            targetIps: [host],
            timeout: const Duration(milliseconds: 1400),
            onLocation: acceptLocation,
          ),
          _probeHostCommonDlnaPorts(host, acceptLocation),
        ]);
      }

      if (found != null) {
        _statusMessage = '已连接发现 ${found!.name}';
      } else {
        _statusMessage = '未在 $host 发现 DLNA 投屏服务，请确认电视与手机在同一 Wi-Fi 并已开启投屏';
      }
      return found;
    } catch (_) {
      _statusMessage = '探测 ${parsed.host} 失败，请检查 IP 和本地网络权限';
      return null;
    } finally {
      _scanning = false;
      _notify();
    }
  }

  /// Injects mock or manually discovered devices (helpful in tests or manual setup).
  void setDevicesForTest(List<CastDevice> list) {
    _devices
      ..clear()
      ..addAll(list);
    _notify();
  }

  /// Infers a DLNA-friendly MIME type for DIDL-Lite metadata and relay responses.
  static String inferDlnaMimeType(String mediaUrl) {
    final lower = mediaUrl.toLowerCase();
    if (lower.contains('.m3u8') || lower.contains('m3u8')) {
      return 'application/vnd.apple.mpegurl';
    }
    if (lower.contains('.mkv')) return 'video/x-matroska';
    if (lower.contains('.ts')) return 'video/mp2t';
    if (lower.contains('.webm')) return 'video/webm';
    if (lower.contains('.flv')) return 'video/x-flv';
    return 'video/mp4';
  }

  /// Builds a standards-compliant DIDL-Lite XML payload for `SetAVTransportURI`
  /// so strict TV renderers (Xiaomi, Lebo, Dangbei, Sony, Marco Movie TV) display
  /// the title cleanly and pick the proper decoder pipeline.
  static String buildDidlLiteMetadata({
    required String title,
    required String mediaUrl,
    String? mimeType,
  }) {
    final safeTitle = escapeXml(title.trim().isEmpty ? 'Marco Movie' : title.trim());
    final safeUrl = escapeXml(mediaUrl.trim());
    final mime = mimeType ?? inferDlnaMimeType(mediaUrl);
    final dcNamespace = Uri(
      scheme: 'http',
      host: 'purl.org',
      path: '/dc/elements/1.1/',
    ).toString();
    return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="$dcNamespace" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="0" parentID="-1" restricted="1">'
        '<dc:title>$safeTitle</dc:title>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        '<res protocolInfo="http-get:*:$mime:*">$safeUrl</res>'
        '</item>'
        '</DIDL-Lite>';
  }

  Future<String> _prepareCastMediaUrl(
    String rawUrl,
    Map<String, String>? headers, {
    String? peerHost,
  }) async {
    final trimmed = rawUrl.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return trimmed;
    final host = uri.host.toLowerCase();
    final isLoopback = host == '127.0.0.1' || host == 'localhost';
    final hasCustomHeaders = headers != null &&
        headers.entries.any((e) => e.value.trim().isNotEmpty);

    if (isLoopback || hasCustomHeaders) {
      final lanIp = await resolveLanIpv4(peerHost: peerHost);
      if (lanIp != null && lanIp.isNotEmpty) {
        return _relay.expose(
          upstreamUri: uri,
          headers: headers ?? const {},
          lanIp: lanIp,
        );
      }
      return resolveCastableUrl(trimmed);
    }
    await _relay.close();
    return trimmed;
  }

  /// Starts casting [mediaUrl] to [device] using UPnP `SetAVTransportURI` + `Play`.
  Future<bool> castToDevice({
    required CastDevice device,
    required String mediaUrl,
    required String title,
    Map<String, String>? headers,
    Duration initialPosition = Duration.zero,
    Duration totalDuration = Duration.zero,
  }) async {
    _pollTimer?.cancel();
    _activeDevice = device;
    _currentTitle = title;
    _position = initialPosition;
    _duration = totalDuration;
    _state = CastSessionState.connecting;
    _statusMessage = '正在连接 ${device.name}…';
    _notify();

    try {
      final castUrl = await _prepareCastMediaUrl(
        mediaUrl,
        headers,
        peerHost: device.host,
      );
      _currentMediaUrl = castUrl;

      final didl = buildDidlLiteMetadata(title: title, mediaUrl: castUrl);
      final setUriBody = '''
<u:SetAVTransportURI xmlns:u="$_avTransportService">
  <InstanceID>0</InstanceID>
  <CurrentURI>${escapeXml(castUrl)}</CurrentURI>
  <CurrentURIMetaData>${escapeXml(didl)}</CurrentURIMetaData>
</u:SetAVTransportURI>''';

      await _sendSoapAction(
        controlUrl: device.avTransportControlUrl,
        serviceType: _avTransportService,
        action: 'SetAVTransportURI',
        bodyXml: setUriBody,
      );

      const playBody = '''
<u:Play xmlns:u="$_avTransportService">
  <InstanceID>0</InstanceID>
  <Speed>1</Speed>
</u:Play>''';
      await _sendSoapAction(
        controlUrl: device.avTransportControlUrl,
        serviceType: _avTransportService,
        action: 'Play',
        bodyXml: playBody,
      );

      if (initialPosition > const Duration(seconds: 2)) {
        unawaited(seek(initialPosition));
      }

      _state = CastSessionState.playing;
      _statusMessage = '已投屏到 ${device.name}';
      _startPositionPolling();
      _notify();
      return true;
    } catch (e) {
      await _relay.close();
      _state = CastSessionState.error;
      _statusMessage = '投屏失败：请确认设备支持该视频格式且在同一 Wi-Fi';
      debugPrint('DLNA cast error: $e');
      _notify();
      return false;
    }
  }

  /// Switches the currently casting episode/stream without dropping the TV session.
  Future<bool> switchMedia({
    required String mediaUrl,
    required String title,
    Map<String, String>? headers,
    Duration totalDuration = Duration.zero,
  }) async {
    final device = _activeDevice;
    if (device == null) return false;
    return castToDevice(
      device: device,
      mediaUrl: mediaUrl,
      title: title,
      headers: headers,
      initialPosition: Duration.zero,
      totalDuration: totalDuration,
    );
  }

  static String formatDlnaSpeed(double speed) {
    final clamped = speed.clamp(0.5, 3.0);
    if ((clamped - clamped.roundToDouble()).abs() < 0.001) {
      return clamped.round().toString();
    }
    return clamped
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  Future<void> setSpeed(double nextSpeed) async {
    final device = _activeDevice;
    final clamped = nextSpeed.clamp(0.5, 3.0).toDouble();
    _speed = clamped;
    _notify();
    if (device == null) return;
    try {
      await _sendSoapAction(
        controlUrl: device.avTransportControlUrl,
        serviceType: _avTransportService,
        action: 'Play',
        bodyXml:
            '<u:Play xmlns:u="$_avTransportService"><InstanceID>0</InstanceID><Speed>${formatDlnaSpeed(clamped)}</Speed></u:Play>',
      );
      _state = CastSessionState.playing;
      _notify();
    } catch (_) {}
  }

  Future<void> toggleMute() async {
    final device = _activeDevice;
    _muted = !_muted;
    _notify();
    final rcUrl = device?.renderingControlUrl;
    if (rcUrl == null || rcUrl.isEmpty) return;
    try {
      await _sendSoapAction(
        controlUrl: rcUrl,
        serviceType: _renderingControlService,
        action: 'SetMute',
        bodyXml: '''
<u:SetMute xmlns:u="$_renderingControlService">
  <InstanceID>0</InstanceID>
  <Channel>Master</Channel>
  <DesiredMute>${_muted ? 1 : 0}</DesiredMute>
</u:SetMute>''',
      );
    } catch (_) {}
  }

  Future<void> togglePlayPause() async {
    final device = _activeDevice;
    if (device == null) return;
    final nextPlaying = _state != CastSessionState.playing;
    try {
      if (nextPlaying) {
        await _sendSoapAction(
          controlUrl: device.avTransportControlUrl,
          serviceType: _avTransportService,
          action: 'Play',
          bodyXml:
              '<u:Play xmlns:u="$_avTransportService"><InstanceID>0</InstanceID><Speed>${formatDlnaSpeed(_speed)}</Speed></u:Play>',
        );
        _state = CastSessionState.playing;
      } else {
        await _sendSoapAction(
          controlUrl: device.avTransportControlUrl,
          serviceType: _avTransportService,
          action: 'Pause',
          bodyXml:
              '<u:Pause xmlns:u="$_avTransportService"><InstanceID>0</InstanceID></u:Pause>',
        );
        _state = CastSessionState.paused;
      }
      _notify();
    } catch (_) {}
  }

  Future<void> seek(Duration target) async {
    final device = _activeDevice;
    if (device == null) return;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (_duration > Duration.zero && target > _duration ? _duration : target);
    _position = clamped;
    _notify();
    try {
      await _sendSoapAction(
        controlUrl: device.avTransportControlUrl,
        serviceType: _avTransportService,
        action: 'Seek',
        bodyXml: '''
<u:Seek xmlns:u="$_avTransportService">
  <InstanceID>0</InstanceID>
  <Unit>REL_TIME</Unit>
  <Target>${formatDlnaTime(clamped)}</Target>
</u:Seek>''',
      );
    } catch (_) {}
  }

  Future<void> adjustVolume(int delta) async {
    final device = _activeDevice;
    final next = (_volume + delta).clamp(0, 100);
    _volume = next;
    if (next > 0 && _muted) _muted = false;
    _notify();
    final rcUrl = device?.renderingControlUrl;
    if (rcUrl == null || rcUrl.isEmpty) return;
    try {
      await _sendSoapAction(
        controlUrl: rcUrl,
        serviceType: _renderingControlService,
        action: 'SetVolume',
        bodyXml: '''
<u:SetVolume xmlns:u="$_renderingControlService">
  <InstanceID>0</InstanceID>
  <Channel>Master</Channel>
  <DesiredVolume>$next</DesiredVolume>
</u:SetVolume>''',
      );
    } catch (_) {}
  }

  Future<void> stopCasting() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    final device = _activeDevice;
    _activeDevice = null;
    _state = CastSessionState.idle;
    _statusMessage = null;
    _currentMediaUrl = '';
    _speed = 1.0;
    _muted = false;
    _notify();
    if (device != null) {
      try {
        await _sendSoapAction(
          controlUrl: device.avTransportControlUrl,
          serviceType: _avTransportService,
          action: 'Stop',
          bodyXml:
              '<u:Stop xmlns:u="$_avTransportService"><InstanceID>0</InstanceID></u:Stop>',
        );
      } catch (_) {}
    }
    await _relay.close();
  }

  void _startPositionPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final device = _activeDevice;
      if (device == null || _state == CastSessionState.idle) return;
      try {
        final xml = await _sendSoapAction(
          controlUrl: device.avTransportControlUrl,
          serviceType: _avTransportService,
          action: 'GetPositionInfo',
          bodyXml:
              '<u:GetPositionInfo xmlns:u="$_avTransportService"><InstanceID>0</InstanceID></u:GetPositionInfo>',
        );
        final relTime = extractXmlTag(xml, 'RelTime');
        final trackDuration = extractXmlTag(xml, 'TrackDuration');
        final parsedPos = parseDlnaTime(relTime);
        final parsedDur = parseDlnaTime(trackDuration);
        if (parsedPos != null) _position = parsedPos;
        if (parsedDur != null && parsedDur > Duration.zero) {
          _duration = parsedDur;
        }
        _notify();
      } catch (_) {
        if (_state == CastSessionState.playing &&
            _duration > Duration.zero &&
            _position < _duration) {
          _position += const Duration(seconds: 2);
          _notify();
        }
      }
    });
  }

  Future<CastDevice?> _fetchDeviceDescription(String location) async {
    final uri = Uri.tryParse(location);
    if (uri == null || !uri.hasScheme) return null;
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 1400)
      ..findProxy = (_) => 'DIRECT';
    try {
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(milliseconds: 1800));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final body = await utf8.decoder.bind(resp).join();
      return parseDeviceDescriptionXml(body, location);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _sendSoapAction({
    required String controlUrl,
    required String serviceType,
    required String action,
    required String bodyXml,
  }) async {
    final uri = Uri.parse(controlUrl);
    final envelope = buildSoapEnvelope(bodyXml);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4)
      ..findProxy = (_) => 'DIRECT';
    try {
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'text/xml; charset="utf-8"');
      req.headers.set('SOAPACTION', '"$serviceType#$action"');
      final bytes = utf8.encode(envelope);
      req.headers.contentLength = bytes.length;
      req.add(bytes);
      final resp = await req.close().timeout(const Duration(seconds: 5));
      final body = await utf8.decoder.bind(resp).join();
      if (resp.statusCode >= 400) {
        throw HttpException('SOAP $action failed (${resp.statusCode})');
      }
      return body;
    } finally {
      client.close(force: true);
    }
  }

  /// Builds an SSDP M-SEARCH packet for [searchTarget].
  static String buildSsdpSearchPayload(String searchTarget) {
    return 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: $_ssdpAddress:$_ssdpPort\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: $searchTarget\r\n'
        'USER-AGENT: iOS/18 UPnP/1.1 MarcoMovie/1.0\r\n'
        '\r\n';
  }

  /// Extracts a case-insensitive header value from an SSDP response datagram.
  static String? extractSsdpHeader(String raw, String headerName) {
    final target = '${headerName.toLowerCase()}:';
    for (final line in raw.split(RegExp(r'\r?\n'))) {
      if (line.toLowerCase().startsWith(target)) {
        final v = line.substring(target.length).trim();
        if (v.isNotEmpty) return v;
      }
    }
    return null;
  }

  /// Parses a UPnP MediaRenderer description XML document into a [CastDevice].
  static CastDevice? parseDeviceDescriptionXml(String xml, String location) {
    final locUri = Uri.tryParse(location);
    if (locUri == null) return null;
    final urlBaseStr = extractXmlTag(xml, 'URLBase');
    final urlBase = (urlBaseStr != null && urlBaseStr.isNotEmpty)
        ? Uri.tryParse(urlBaseStr)
        : null;
    final baseUri = (urlBase != null && urlBase.hasScheme && urlBase.host.isNotEmpty)
        ? urlBase
        : locUri;

    final friendlyName = extractXmlTag(xml, 'friendlyName') ?? baseUri.host;
    final modelName = extractXmlTag(xml, 'modelName') ?? '';
    final udn = extractXmlTag(xml, 'UDN') ?? location;
    final avPath = _extractServiceControlUrl(xml, 'AVTransport');
    if (avPath == null || avPath.isEmpty) return null;
    final rcPath = _extractServiceControlUrl(xml, 'RenderingControl');
    return CastDevice(
      id: udn,
      name: friendlyName,
      model: modelName,
      host: baseUri.host,
      location: location,
      avTransportControlUrl: baseUri.resolve(avPath).toString(),
      renderingControlUrl:
          rcPath != null && rcPath.isNotEmpty ? baseUri.resolve(rcPath).toString() : null,
    );
  }

  static String? _extractServiceControlUrl(String xml, String serviceKeyword) {
    final serviceRe = RegExp(
      r'<(?:[A-Za-z0-9_-]+:)?service\b[^>]*>([\s\S]*?)</(?:[A-Za-z0-9_-]+:)?service>',
      caseSensitive: false,
    );
    for (final match in serviceRe.allMatches(xml)) {
      final block = match.group(1) ?? '';
      if (!block.toLowerCase().contains(serviceKeyword.toLowerCase())) continue;
      final control = extractXmlTag(block, 'controlURL');
      if (control != null && control.isNotEmpty) return control;
    }
    return null;
  }

  static String? extractXmlTag(String xml, String tag) {
    final re = RegExp(
      '<(?:[A-Za-z0-9_-]+:)?$tag(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[A-Za-z0-9_-]+:)?$tag>',
      caseSensitive: false,
    );
    final m = re.firstMatch(xml);
    return m?.group(1)?.trim();
  }

  static String buildSoapEnvelope(String bodyXml) {
    return '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body>$bodyXml</s:Body>'
        '</s:Envelope>';
  }

  static String escapeXml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static String formatDlnaTime(Duration d) {
    final totalSec = d.inSeconds.clamp(0, 359999);
    final h = (totalSec ~/ 3600).toString().padLeft(2, '0');
    final m = ((totalSec % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (totalSec % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  static Duration? parseDlnaTime(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final clean = raw.split('.').first.trim();
    final parts = clean.split(':');
    if (parts.length != 3) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final s = int.tryParse(parts[2]);
    if (h == null || m == null || s == null) return null;
    return Duration(hours: h, minutes: m, seconds: s);
  }

  String get currentMediaUrl => _currentMediaUrl;

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    unawaited(_relay.close());
    super.dispose();
  }
}
