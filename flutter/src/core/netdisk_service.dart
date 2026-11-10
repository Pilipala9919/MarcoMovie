import 'netdisk_session.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate, SocketException;
import 'dart:math' show Random;
import 'package:http/http.dart' as http;
import 'quark_account.dart';
import 'storage_service.dart';

/// Descriptor for each of the 4 TV netdisk drives (`我的夸父`, `我的优汐`, `我的嘟嘟`, `我的阿狸`).
class NetdiskDriveInfo {
  final String key;
  final String tvName;
  final String providerName;
  final String appHint;
  final String linePrefix;

  const NetdiskDriveInfo({
    required this.key,
    required this.tvName,
    required this.providerName,
    required this.appHint,
    required this.linePrefix,
  });

  static const List<NetdiskDriveInfo> all = [
    NetdiskDriveInfo(
      key: 'quark',
      tvName: '我的夸父',
      providerName: '夸克网盘',
      appHint: '请使用手机「夸克 App」扫描二维码登录',
      linePrefix: '夸父智1',
    ),
    NetdiskDriveInfo(
      key: 'uc',
      tvName: '我的优汐',
      providerName: 'UC网盘',
      appHint: '请使用手机「UC浏览器 App」扫描二维码登录',
      linePrefix: '优汐智1',
    ),
    NetdiskDriveInfo(
      key: 'baidu',
      tvName: '我的嘟嘟',
      providerName: '百度网盘',
      appHint: '请使用手机「百度网盘 App」扫描二维码登录',
      linePrefix: '嘟嘟无限2',
    ),
    NetdiskDriveInfo(
      key: 'ali',
      tvName: '我的阿狸',
      providerName: '阿里云盘',
      appHint: '请使用手机「阿里云盘 App」扫描二维码登录',
      linePrefix: '阿狸原画',
    ),
  ];

  String get tvAlias => tvName;
  List<String> get lineBadges => [linePrefix];

  static NetdiskDriveInfo byKey(String key) {
    return all.firstWhere(
      (d) => d.key == key,
      orElse: () => all.first,
    );
  }
}

/// Active QR Code login session returned by [NetdiskService.startQrSession].
class NetdiskQrSession {
  final String driveKey;
  final String qrContentUrl;
  final String qrImageUrl;
  final String token;
  final Map<String, String> extra;

  const NetdiskQrSession({
    required this.driveKey,
    required this.qrContentUrl,
    required this.qrImageUrl,
    required this.token,
    this.extra = const {},
  });

  String get qrContent => qrContentUrl;
}

enum NetdiskPollState {
  waiting,
  scanned,
  confirmed,
  expired,
  error,
}

class NetdiskPollResult {
  final NetdiskPollState state;
  final String message;
  final String credential;
  final bool accountVerified;

  const NetdiskPollResult({
    required this.state,
    required this.message,
    this.credential = '',
    this.accountVerified = false,
  });

  String get status => state.name;
}

class _BaiduLoginAttempt {
  final String gid;
  final BaiduLoginCookies cookies;
  final DateTime created = DateTime.now();
  bool scanned = false;
  String? ticket;
  String? credential;
  Future<NetdiskPollResult>? pending;

  _BaiduLoginAttempt(this.gid, this.cookies);
}

/// Handles official QR code generation and login polling for Quark (`我的夸父`),
/// UC (`我的优汐`), Baidu (`我的嘟嘟`), and AliyunDrive (`我的阿狸`), matching the TV
/// `csp_MyDriveGuard` (`🗂我的云盘┃配置`) experience.
class NetdiskService {
  static List<NetdiskDriveInfo> get drives => NetdiskDriveInfo.all;
  final http.Client _http;
  final bool _ownsClient;
  late final QuarkAccountProvider _quarkAccounts;
  final Map<String, String> _cachedCloudTickets = <String, String>{};
  final Map<String, String> _cachedQuarkTickets = <String, String>{};
  final Map<String, _BaiduLoginAttempt> _baiduAttempts = {};
  int _baiduGeneration = 0;
  bool _closed = false;

  /// Builds the official native App deep-link scheme (`qklink://` / `uclink://`)
  /// so iOS "本机跳转授权" opens the login confirmation page directly inside
  /// the Quark / UC App WebView (`inApp=true`) with `client_id` preserved,
  /// avoiding Safari's redirect to `h5.sm.cn` which drops `client_id=532` and
  /// triggers "登录请求已过期".
  static String? buildNativeAppDeepLink(String driveKey, String qrContent) {
    final trimmed = qrContent.trim();
    if (trimmed.isEmpty) return null;
    final parsed = Uri.tryParse(trimmed);
    final token = parsed?.queryParameters['token'] ?? '';
    final targetUrl = switch (driveKey) {
      'quark' when token.isNotEmpty =>
        'https://su.quark.cn/4_eMHBJ?uc_param_str=dsdnfrpfbivesscpgimibtbmnijblauputogpintnwktprchmt&token=${Uri.encodeQueryComponent(token)}&client_id=532&ssb=weblogin&uc_biz_str=S%3Acustom%7COPT%3ASAREA%400%7COPT%3AIMMERSIVE%401%7COPT%3ABACK_BTN_STYLE%400',
      'uc' when token.isNotEmpty =>
        'https://su.uc.cn/1_n0ZCv?uc_param_str=dsdnfrpfbivesscpgimibtbmnijblauputogpintnwktprchmt&token=${Uri.encodeQueryComponent(token)}&client_id=381&uc_biz_str=S%3Acustom%7CC%3Atitlebar_fix',
      _ => trimmed,
    };
    final encoded = Uri.encodeComponent(targetUrl);
    return switch (driveKey) {
      'quark' =>
        'qklink://www.uc.cn/656bdcddd4758b39206a8181c91a7d14?src_pkg=kuake&src_ch=default&action=open_url&url=$encoded',
      'uc' =>
        'uclink://www.uc.cn/f11f7cb5d16fa0969d670c1eccc6053d?src_pkg=kuake&src_ch=default&action=open_url&url=$encoded',
      _ => null,
    };
  }

  NetdiskService({http.Client? httpClient, QuarkAccountProvider? quarkAccounts})
      : _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null {
    _quarkAccounts = quarkAccounts ??
        QuarkAccountProvider(
            readCredential: () => '',
            writeCredential: (_) {},
            httpClient: _http);
  }

  void close() {
    _closed = true;
    _baiduGeneration++;
    _baiduAttempts.clear();
    _cachedCloudTickets.clear();
    _cachedQuarkTickets.clear();
    if (_ownsClient) _http.close();
  }

  static const Map<String, String> _commonHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15',
    'Accept': 'application/json, text/plain, */*',
  };

  static bool isLoggedIn(StorageService storage, String driveKey) {
    return storage.isNetdiskLoggedIn(driveKey);
  }

  static String statusLabel(StorageService storage, String driveKey) {
    return isLoggedIn(storage, driveKey) ? '已登录+启用中' : '未登录 · 点击扫码';
  }

  /// Retained for API compatibility. The UI renders qrContent locally; login
  /// tokens must never be sent to a third-party QR image service.
  static String buildQrRenderUrl(String content) => '';

  /// Starts a real QR login session with the official cloud drive passport API.
  Future<NetdiskQrSession> createQrSession(String driveKey) =>
      startQrSession(driveKey);
  Future<NetdiskPollResult> pollQrStatus(NetdiskQrSession session) =>
      pollQrSession(session);

  Future<NetdiskQrSession> startQrSession(String driveKey) async {
    if (_closed) throw const FormatException('网盘登录已关闭，请重新打开');
    final baiduGeneration = driveKey == 'baidu' ? ++_baiduGeneration : null;
    final ts = DateTime.now().millisecondsSinceEpoch;
    try {
      if (driveKey == 'quark') {
        final map = await _quarkPassport('/cas/ajax/getTokenForQrcodeLogin',
            {'client_id': '532', 'v': '1.2', 'request_id': '$ts'});
        if (map['status'] != 2000000) throw const FormatException('夸克二维码创建失败');
        final data = map['data'] as Map? ?? const {};
        final members = data['members'] as Map? ?? const {};
        final token = members['token'];
        if (token is String && _validQuarkToken(token)) {
          _cachedQuarkTickets.remove(token);
          final qrContent =
              'https://su.quark.cn/4_eMHBJ?uc_param_str=dsdnfrpfbivesscpgimibtbmnijblauputogpintnwktprchmt&token=${Uri.encodeQueryComponent(token)}&client_id=532&ssb=weblogin&uc_biz_str=S%3Acustom%7COPT%3ASAREA%400%7COPT%3AIMMERSIVE%401%7COPT%3ABACK_BTN_STYLE%400';
          return NetdiskQrSession(
            driveKey: driveKey,
            qrContentUrl: qrContent,
            qrImageUrl: buildQrRenderUrl(qrContent),
            token: token,
          );
        }
        throw const FormatException('夸克二维码创建失败，请稍后重试');
      } else if (driveKey == 'uc') {
        final uri = Uri.parse(
          'https://api.open.uc.cn/cas/ajax/getTokenForQrcodeLogin?client_id=381&v=1.2&request_id=$ts',
        );
        final res = await _http
            .get(uri, headers: _commonHeaders)
            .timeout(const Duration(seconds: 8));
        final map = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
        final data = map['data'] as Map? ?? const {};
        final members = data['members'] as Map? ?? const {};
        final token = (members['token'] ?? '').toString();
        if (token.isNotEmpty) {
          final qrContent =
              'https://su.uc.cn/1_n0ZCv?uc_param_str=dsdnfrpfbivesscpgimibtbmnijblauputogpintnwktprchmt&token=${Uri.encodeQueryComponent(token)}&client_id=381&uc_biz_str=S%3Acustom%7CC%3Atitlebar_fix';
          return NetdiskQrSession(
            driveKey: driveKey,
            qrContentUrl: qrContent,
            qrImageUrl: buildQrRenderUrl(qrContent),
            token: token,
          );
        }
      } else if (driveKey == 'baidu') {
        final attempt = _BaiduLoginAttempt(_baiduGid(), BaiduLoginCookies());
        final res = await NetdiskSession.baiduRequest(
            _http,
            Uri.https('passport.baidu.com', '/v2/api/getqrcode', {
              'lp': 'pc',
              'qrloginfrom': 'pc',
              'gid': attempt.gid,
              'callback': 'tangram_guid_$ts',
              'apiver': 'v3',
              'tt': '$ts',
              'tpl': 'netdisk',
              'logPage': 'traceId:pc_loginv5_$ts,logPage:loginv5',
              '_': '$ts',
            }),
            attempt.cookies);
        final map = NetdiskSession.decodeObject(utf8.decode(res.bodyBytes));
        final sign = map['sign'];
        if (sign is String && _validQuarkToken(sign)) {
          if (_closed || baiduGeneration != _baiduGeneration) {
            throw const FormatException('百度二维码请求已取消');
          }
          int serverSec = ts ~/ 1000;
          try {
            final dateHdr = res.headers['date'];
            if (dateHdr != null && dateHdr.isNotEmpty) {
              serverSec =
                  HttpDate.parse(dateHdr).millisecondsSinceEpoch ~/ 1000;
            }
          } catch (_) {}
          final qrContent =
              'https://wappass.baidu.com/wp/?qrlogin&t=$serverSec&error=0&sign=${Uri.encodeQueryComponent(sign)}&cmd=login&lp=pc&adapter=3&qrloginfrom=pc';
          // Replacing a QR code starts a fresh cookie jar. Only the active QR
          // may finish; never mix browser-session cookies across attempts.
          _baiduAttempts.clear();
          _baiduAttempts[sign] = attempt;
          return NetdiskQrSession(
            driveKey: driveKey,
            qrContentUrl: qrContent,
            qrImageUrl: buildQrRenderUrl(qrContent),
            token: sign,
            extra: {'gid': attempt.gid},
          );
        }
        throw const FormatException('百度二维码创建失败');
      } else if (driveKey == 'ali') {
        final uri = Uri.parse(
          'https://passport.aliyundrive.com/newlogin/qrcode/generate.do?appName=aliyun_drive&fromSite=52&appEntrance=web&_csrf_token=&isMobile=false&lang=zh_CN&returnUrl=&hsbegin=$ts',
        );
        final res = await _http
            .get(uri, headers: _commonHeaders)
            .timeout(const Duration(seconds: 8));
        final map = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
        final content = (map['content'] as Map?)?['data'] as Map? ?? const {};
        final codeContent = (content['codeContent'] ?? '').toString();
        final ck = (content['ck'] ?? '').toString();
        final t = (content['t'] ?? '').toString();
        if (codeContent.isNotEmpty && ck.isNotEmpty) {
          return NetdiskQrSession(
            driveKey: driveKey,
            qrContentUrl: codeContent,
            qrImageUrl: buildQrRenderUrl(codeContent),
            token: ck,
            extra: {'t': t, 'codeContent': codeContent},
          );
        }
      }
    } catch (_) {
      if (driveKey == 'quark') {
        throw const FormatException('暂时无法创建夸克登录二维码，请稍后重试');
      }
      if (driveKey == 'baidu') {
        throw const FormatException('暂时无法创建百度登录二维码，请稍后重试');
      }
      // Fallback below if network or passport endpoint is blocked.
    }

    final fallbackUrl = switch (driveKey) {
      'quark' => 'https://pan.quark.cn/',
      'uc' => 'https://drive.uc.cn/',
      'baidu' => 'https://pan.baidu.com/',
      'ali' => 'https://www.alipan.com/',
      _ => 'https://pan.quark.cn/',
    };
    return NetdiskQrSession(
      driveKey: driveKey,
      qrContentUrl: fallbackUrl,
      qrImageUrl: buildQrRenderUrl(fallbackUrl),
      token: 'fallback_$ts',
    );
  }

  /// Polls the QR login status for [session].
  Future<NetdiskPollResult> pollQrSession(NetdiskQrSession session) async {
    if (session.driveKey == 'quark' && !_validQuarkToken(session.token)) {
      return const NetdiskPollResult(
          state: NetdiskPollState.error, message: '夸克二维码已失效，请刷新后重试');
    }
    if (session.token.startsWith('fallback_')) {
      return const NetdiskPollResult(
        state: NetdiskPollState.error,
        message: '网盘登录暂时不可用，请刷新二维码后重试',
      );
    }
    if (session.driveKey == 'baidu') return _pollBaidu(session);
    final ts = DateTime.now().millisecondsSinceEpoch;
    try {
      final ticketKey = '${session.driveKey}:${session.token}';
      final cachedTicket = _cachedCloudTickets[ticketKey];
      if (cachedTicket != null) {
        final credential = await NetdiskSession.exchangeUc(_http, cachedTicket);
        _cachedCloudTickets.remove(ticketKey);
        return NetdiskPollResult(
            state: NetdiskPollState.confirmed,
            message: '网盘账号登录成功',
            credential: credential);
      }
      if (session.driveKey == 'quark') {
        final cachedTicket = _cachedQuarkTickets[session.token];
        if (cachedTicket != null && cachedTicket.isNotEmpty) {
          final account = await _quarkAccounts.exchangeServiceTicket(
            cachedTicket,
          );
          _cachedQuarkTickets.remove(session.token);
          return NetdiskPollResult(
            state: NetdiskPollState.confirmed,
            message: '夸父（夸克网盘）扫码登录成功！',
            credential: account.toCredential(),
          );
        }
        // Official pan.quark.cn web QR login creates and polls the token with
        // client_id=532 before exchanging the resulting service_ticket.
        final map = await _quarkPassport(
          '/cas/ajax/getServiceTicketByQrcodeToken',
          {
            'client_id': '532',
            'v': '1.2',
            'token': session.token,
            'request_id': '$ts',
          },
        );
        final status = map['status'];
        if (status == 2000000) {
          final st =
              ((map['data'] as Map?)?['members'] as Map?)?['service_ticket'];
          if (st is! String) throw const FormatException('扫码授权凭据无效');
          _cachedQuarkTickets[session.token] = st;
          final account = await _quarkAccounts.exchangeServiceTicket(st);
          _cachedQuarkTickets.remove(session.token);
          return NetdiskPollResult(
            state: NetdiskPollState.confirmed,
            message: '夸父（夸克网盘）扫码登录成功！',
            credential: account.toCredential(),
          );
        } else if (status == 50004002) {
          return const NetdiskPollResult(
            state: NetdiskPollState.expired,
            message: '二维码已过期，请点击刷新二维码',
          );
        }
        if (status != 50004001) {
          return const NetdiskPollResult(
            state: NetdiskPollState.error,
            message: '夸克扫码授权尚未完成，请刷新后重试',
          );
        }
        return const NetdiskPollResult(
          state: NetdiskPollState.waiting,
          message: '等待使用手机「夸克 App」扫码并确认…',
        );
      } else if (session.driveKey == 'uc') {
        final uri = Uri.parse(
          'https://api.open.uc.cn/cas/ajax/getServiceTicketByQrcodeToken?client_id=381&v=1.2&token=${session.token}&request_id=$ts',
        );
        final res = await _http
            .get(uri, headers: _commonHeaders)
            .timeout(const Duration(seconds: 6));
        final map = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
        final status = map['status'];
        if (status == 2000000) {
          final st =
              (((map['data'] as Map?)?['members'] as Map?)?['service_ticket'] ??
                      '')
                  .toString();
          _cachedCloudTickets['uc:${session.token}'] = st;
          final ucCredential = await NetdiskSession.exchangeUc(_http, st);
          _cachedCloudTickets.remove('uc:${session.token}');
          return NetdiskPollResult(
            state: NetdiskPollState.confirmed,
            message: '优汐（UC网盘）扫码登录成功！',
            credential: ucCredential,
          );
        } else if (status == 50004002) {
          return const NetdiskPollResult(
            state: NetdiskPollState.expired,
            message: '二维码已过期，请点击刷新二维码',
          );
        }
        return const NetdiskPollResult(
          state: NetdiskPollState.waiting,
          message: '等待使用手机「UC浏览器 App」扫码并确认…',
        );
      } else if (session.driveKey == 'ali') {
        final uri = Uri.parse(
          'https://passport.aliyundrive.com/newlogin/qrcode/query.do?appName=aliyun_drive&fromSite=52&_bx-v=2.2.3',
        );
        final res = await _http.post(
          uri,
          headers: {
            ..._commonHeaders,
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: {
            'ck': session.token,
            't': session.extra['t'] ?? '',
            'appName': 'aliyun_drive',
            'appEntrance': 'web',
            'fromSite': '52',
            'isMobile': 'false',
            'lang': 'zh_CN',
            'returnUrl': '',
            'navlanguage': 'zh-CN',
          },
        ).timeout(const Duration(seconds: 6));
        final map = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
        final data = (map['content'] as Map?)?['data'] as Map? ?? const {};
        final status = (data['qrCodeStatus'] ?? '').toString();
        if (status == 'CONFIRMED') {
          final credential = NetdiskSession.aliCredential(data['bizExt']);
          return NetdiskPollResult(
            state: NetdiskPollState.confirmed,
            message: '阿狸（阿里云盘）扫码登录成功！',
            credential: credential,
          );
        } else if (status == 'SCANED') {
          return const NetdiskPollResult(
            state: NetdiskPollState.scanned,
            message: '已扫码，请在手机阿里云盘上点击「确认登录」…',
          );
        } else if (status == 'EXPIRED') {
          return const NetdiskPollResult(
            state: NetdiskPollState.expired,
            message: '二维码已过期，请点击刷新二维码',
          );
        }
        return const NetdiskPollResult(
          state: NetdiskPollState.waiting,
          message: '等待使用手机「阿里云盘 App」扫码并确认…',
        );
      }
    } catch (_) {
      if (session.driveKey == 'quark') {
        return const NetdiskPollResult(
            state: NetdiskPollState.error, message: '夸克账号验证失败，请重新扫码');
      }
      return const NetdiskPollResult(
          state: NetdiskPollState.error, message: '网盘账号验证未完成，请重试或刷新二维码');
    }
    return const NetdiskPollResult(
      state: NetdiskPollState.waiting,
      message: '等待手机端扫码授权…',
    );
  }

  static String _baiduGid() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<NetdiskPollResult> _pollBaidu(NetdiskQrSession session) {
    if (_closed) {
      return Future.value(const NetdiskPollResult(
          state: NetdiskPollState.error, message: '百度登录已关闭，请重新打开'));
    }
    if (!_validQuarkToken(session.token)) {
      return Future.value(const NetdiskPollResult(
          state: NetdiskPollState.expired, message: '百度二维码已失效，请刷新后重试'));
    }
    final attempt = _baiduAttempts.putIfAbsent(
        session.token,
        () => _BaiduLoginAttempt(
            session.extra['gid'] ?? _baiduGid(), BaiduLoginCookies()));
    return attempt.pending ??= _runBaiduPoll(session, attempt).whenComplete(() {
      attempt.pending = null;
    });
  }

  static NetdiskPollResult _baiduWaiting(_BaiduLoginAttempt attempt) =>
      NetdiskPollResult(
          state: attempt.scanned
              ? NetdiskPollState.scanned
              : NetdiskPollState.waiting,
          message: attempt.ticket != null
              ? '已确认百度授权，正在完成登录，请稍候…'
              : attempt.scanned
                  ? '已扫码，请在手机百度网盘上点击「确认登录」…'
                  : '等待使用手机「百度网盘 App」扫码并确认…');

  Future<NetdiskPollResult> _runBaiduPoll(
      NetdiskQrSession session, _BaiduLoginAttempt attempt) async {
    if (DateTime.now().difference(attempt.created) >
        const Duration(minutes: 10)) {
      _baiduAttempts.remove(session.token);
      return const NetdiskPollResult(
          state: NetdiskPollState.expired, message: '百度二维码已过期，请刷新后重试');
    }
    try {
      if (attempt.credential == null && attempt.ticket == null) {
        final ts = DateTime.now().millisecondsSinceEpoch;
        final response = await NetdiskSession.baiduRequest(
            _http,
            Uri.https('passport.baidu.com', '/channel/unicast', {
              'channel_id': session.token,
              'gid': attempt.gid,
              'tpl': 'netdisk',
              '_sdkFrom': '1',
              'callback': 'tangram_guid_$ts',
              'apiver': 'v3',
              'tt': '$ts',
              '_': '$ts',
            }),
            attempt.cookies,
            timeout: const Duration(seconds: 45));
        final data =
            NetdiskSession.decodeObject(utf8.decode(response.bodyBytes));
        final errno = _baiduStatus(data['errno']);
        if (errno == 1) return _baiduWaiting(attempt);
        if (errno != 0) throw const FormatException('百度扫码状态无效');
        final raw = data['channel_v'];
        final channel = raw is String ? jsonDecode(raw) : raw;
        if (channel is! Map) throw const FormatException('百度扫码状态无效');
        switch (_baiduStatus(channel['status'])) {
          case 1:
            attempt.scanned = true;
            return _baiduWaiting(attempt);
          case 0:
            attempt.scanned = true;
            final ticket = channel['v'];
            if (ticket is! String || !_validQuarkToken(ticket)) {
              return const NetdiskPollResult(
                  state: NetdiskPollState.error,
                  message: '已确认百度授权，但未取得有效授权凭据，请刷新二维码重试');
            }
            attempt.ticket = ticket;
          case 2:
            _baiduAttempts.remove(session.token);
            return const NetdiskPollResult(
                state: NetdiskPollState.expired, message: '百度二维码已过期，请刷新后重试');
          default:
            throw const FormatException('百度扫码状态无效');
        }
      }
      attempt.credential ??= await NetdiskSession.exchangeBaidu(
          _http, attempt.ticket!,
          cookies: attempt.cookies);
      // Repeated polls after successful exchange must not reuse the one-use
      // authorization ticket or lose a completed login while it is being saved.
      return NetdiskPollResult(
          state: NetdiskPollState.confirmed,
          message: '嘟嘟（百度网盘）扫码登录成功！',
          accountVerified: true,
          credential: attempt.credential!);
    } on TimeoutException {
      return _baiduWaiting(attempt);
    } on SocketException {
      return _baiduWaiting(attempt);
    } on http.ClientException {
      return _baiduWaiting(attempt);
    } catch (_) {
      return NetdiskPollResult(
          state: NetdiskPollState.error,
          message: attempt.ticket != null
              ? '已确认百度授权，但网盘登录信息尚未完整取得，请重试或刷新二维码'
              : '百度扫码状态验证失败，请重试或刷新二维码');
    }
  }

  static int? _baiduStatus(Object? value) => value is int
      ? value
      : value is String && RegExp(r'^-?\d+$').hasMatch(value)
          ? int.tryParse(value)
          : null;

  static bool _validQuarkToken(String value) =>
      value.isNotEmpty &&
      value.length <= 8192 &&
      !RegExp(r'[\x00-\x20\x7f]').hasMatch(value) &&
      !value.startsWith('fallback_');

  Future<Map> _quarkPassport(
      String path, Map<String, String> parameters) async {
    if (!const {
      '/cas/ajax/getTokenForQrcodeLogin',
      '/cas/ajax/getServiceTicketByQrcodeToken'
    }.contains(path)) {
      throw StateError('Unexpected Quark passport endpoint');
    }
    final request =
        http.Request('GET', Uri.https('uop.quark.cn', path, parameters))
          ..followRedirects = false;
    request.headers.addAll({
      ..._commonHeaders,
      'Origin': 'https://pan.quark.cn',
      'Referer': 'https://pan.quark.cn/',
      'Cache-Control': 'no-cache',
      'Pragma': 'no-cache',
    });
    return (() async {
      final response = await _http.send(request);
      if (response.statusCode != 200) {
        await response.stream.listen((_) {}).cancel();
        throw const FormatException('夸克登录服务暂时不可用');
      }
      final bytes = <int>[];
      await for (final part in response.stream) {
        if (bytes.length + part.length > 256 * 1024) {
          throw const FormatException('夸克登录响应无效');
        }
        bytes.addAll(part);
      }
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! Map) throw const FormatException('夸克登录响应无效');
      return data;
    })()
        .timeout(const Duration(seconds: 8));
  }
}
