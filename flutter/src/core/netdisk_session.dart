import 'dart:convert';
import 'dart:async' show TimeoutException;
import 'dart:io' show Cookie;
import 'package:http/http.dart' as http;

/// Cookies belong to one QR attempt, never to a global account or another drive.
class BaiduLoginCookies {
  final Map<
      String,
      ({
        Cookie cookie,
        String domain,
        bool hostOnly,
        String path,
        DateTime? expires
      })> _cookies = {};
  final Map<String, ({String value, DateTime? expires})> _accountUpdates = {};
  static final _name = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");

  void receive(http.Response response, Uri endpoint) {
    if (endpoint.scheme != 'https' || endpoint.host != 'passport.baidu.com') {
      throw const FormatException('百度登录响应来源无效');
    }
    final raw = response.headers['set-cookie'] ?? '';
    if (raw.length > 65536) throw const FormatException('百度登录响应过大');
    for (final field
        in raw.split(RegExp(r"\r?\n|,(?=\s*[!#$%&'*+.^_`|~0-9A-Za-z-]+=)"))) {
      if (field.trim().isEmpty) continue;
      Cookie cookie;
      try {
        cookie = Cookie.fromSetCookieValue(field.trim());
      } catch (_) {
        throw const FormatException('百度登录 Cookie 响应无效');
      }
      final domain = (cookie.domain ?? endpoint.host)
          .replaceFirst(RegExp(r'^\.'), '')
          .toLowerCase();
      if (domain != endpoint.host && domain != 'baidu.com') continue;
      if (!_name.hasMatch(cookie.name) ||
          cookie.value.length > 16384 ||
          RegExp(r'[\x00-\x20\x7f;,]').hasMatch(cookie.value)) {
        throw const FormatException('百度登录 Cookie 响应无效');
      }
      final defaultPath =
          endpoint.path.substring(0, endpoint.path.lastIndexOf('/') + 1);
      final path =
          cookie.path?.startsWith('/') == true ? cookie.path! : defaultPath;
      final key = '$domain|$path|${cookie.name}';
      final expires = cookie.maxAge == null
          ? cookie.expires
          : DateTime.now().add(Duration(seconds: cookie.maxAge!));
      final expired = expires != null && !expires.isAfter(DateTime.now());
      // Account cookies must cover pan.baidu.com. Remember explicit deletion
      // too, so an older JSON session cannot resurrect a revoked cookie.
      if (domain == 'baidu.com' &&
          cookie.domain != null &&
          path == '/' &&
          const ['BDUSS', 'STOKEN', 'PTOKEN'].contains(cookie.name)) {
        _accountUpdates[cookie.name] = (value: cookie.value, expires: expires);
      }
      if (expired || cookie.value.isEmpty) {
        _cookies.remove(key);
      } else {
        if (_cookies.length >= 64 && !_cookies.containsKey(key)) {
          throw const FormatException('百度登录 Cookie 响应过多');
        }
        _cookies[key] = (
          cookie: cookie,
          domain: domain,
          hostOnly: cookie.domain == null,
          path: path,
          expires: expires
        );
      }
    }
  }

  String headerFor(Uri endpoint) {
    if (endpoint.scheme != 'https' || endpoint.host != 'passport.baidu.com') {
      return '';
    }
    final matching = _cookies.values
        .where((item) =>
            (item.domain == endpoint.host ||
                (!item.hostOnly &&
                    endpoint.host.endsWith('.${item.domain}'))) &&
            (endpoint.path == item.path ||
                endpoint.path.startsWith(
                    item.path.endsWith('/') ? item.path : '${item.path}/')) &&
            (item.expires == null || item.expires!.isAfter(DateTime.now())))
        .toList()
      ..sort((a, b) => b.path.length.compareTo(a.path.length));
    final values = <String, String>{};
    for (final item in matching) {
      values.putIfAbsent(item.cookie.name, () => item.cookie.value);
    }
    return values.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  Map<String, String> get accountCookies {
    final values = <String, String>{};
    for (final entry in _accountUpdates.entries) {
      final expires = entry.value.expires;
      values[entry.key] = expires != null && !expires.isAfter(DateTime.now())
          ? ''
          : entry.value.value;
    }
    return values;
  }
}

/// Official QR tickets are one-use exchange codes, never account cookies.
class NetdiskSession {
  static const baiduUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15';
  static const ucUserAgent =
      'Mozilla/5.0 (Linux; U; Android 13; zh-CN; V2118A Build/TP1A.220624.014) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/100.0.4896.58 UCBrowser/15.5.8.1238 Mobile Safari/537.36';
  static bool _value(String value) =>
      value.isNotEmpty &&
      value.length <= 16384 &&
      !RegExp(r'[\x00-\x20\x7f;,]').hasMatch(value);

  static bool isUsable(String provider, String credential) {
    if (credential.isEmpty ||
        credential.length > 65536 ||
        RegExp(r'[\r\n]').hasMatch(credential) ||
        RegExp(r'(?:qr_auth_|fallback_|uc_4k_|baidu_qr_auth_|dudu_4k_|ali_refresh_token_)')
            .hasMatch(credential)) {
      return false;
    }
    final pairs = <String, String>{};
    for (final part in credential.split(';')) {
      final separator = part.indexOf('=');
      if (separator > 0) {
        pairs[part.substring(0, separator).trim()] =
            part.substring(separator + 1).trim();
      }
    }
    switch (provider) {
      case 'uc':
        return _value(pairs['__pus'] ?? '') || _value(pairs['__puus'] ?? '');
      // Older releases stored the QR exchange ticket as lowercase bduss.
      // Only the actual official cookie written after exchange is accepted.
      case 'baidu':
        return _value(pairs['BDUSS'] ?? '') && _value(pairs['STOKEN'] ?? '');
      case 'ali':
        final token = credential.startsWith('ali_token=')
            ? credential.substring(10)
            : credential;
        // 0.5.14 could persist the entire QR bizExt when it contained no
        // refreshToken. An unpadded base64 wrapper can pass token shape checks.
        try {
          final oldEnvelope =
              jsonDecode(utf8.decode(base64.decode(base64.normalize(token))));
          if (oldEnvelope is Map &&
              oldEnvelope.containsKey('pds_login_result')) {
            return false;
          }
        } catch (_) {
          // Actual opaque refresh tokens need not decode as JSON.
        }
        return _value(token) && token.length >= 16 && !token.contains('=');
      default:
        return false;
    }
  }

  static Future<String> exchangeUc(http.Client client, String ticket) async {
    if (!_value(ticket)) throw const FormatException('UC 扫码授权未完成');
    final map = await _get(
        client,
        Uri.https('drive.uc.cn', '/account/mobileinfo',
            {'pr': 'UCBrowser', 'fr': 'h5', 'st': ticket}),
        {'User-Agent': ucUserAgent, 'Referer': 'https://drive.uc.cn/'});
    final data = map['data'];
    final pus = data is Map ? (data['__pus'] ?? '').toString() : '';
    if (!_value(pus)) throw const FormatException('UC 账号会话交换失败，请重新扫码');
    return '__pus=$pus';
  }

  static Future<String> exchangeBaidu(http.Client client, String ticket,
      {BaiduLoginCookies? cookies}) async {
    if (!_value(ticket)) throw const FormatException('百度扫码授权未完成');
    final jar = cookies ?? BaiduLoginCookies();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final response = await baiduRequest(
        client,
        Uri.https('passport.baidu.com', '/v3/login/main/qrbdusslogin', {
          'v': '$ts',
          'bduss': ticket,
          'u': 'https%3A%2F%2Fpan.baidu.com%2Fdisk%2Fhome',
          'loginVersion': 'v5',
          'qrcode': '1',
          'tpl': 'netdisk',
          'maskId': '',
          'fileId': '',
          'apiver': 'v3',
          'tt': '$ts',
          'traceid': '',
          'time': '${ts ~/ 1000}',
          'alg': 'v3',
          'elapsed': '10',
          'callback': 'bd__cbs__4wi6y6',
        }),
        jar);
    // The web passport primarily issues account cookies in Set-Cookie. Some
    // clients also receive data.session; keep that documented body fallback.
    Map map = const {};
    try {
      map = decodeObject(utf8.decode(response.bodyBytes));
    } catch (_) {}
    final data = map['data'];
    Object? session = data is Map ? data['session'] : null;
    if (session is String) {
      try {
        session = jsonDecode(session);
      } catch (_) {
        session = null;
      }
    }
    final values = <String, String>{};
    if (session is Map) {
      for (final key in const ['bduss', 'stoken', 'ptoken']) {
        final value = session[key];
        if (value is String && _value(value)) values[key.toUpperCase()] = value;
      }
    }
    values.addAll(jar.accountCookies);
    final bduss = values['BDUSS'] ?? '';
    if (!_value(bduss) || bduss == ticket) {
      throw const FormatException('已确认百度授权，但尚未取得有效登录会话，请重试');
    }
    if (!_value(values['STOKEN'] ?? '')) {
      throw const FormatException('已确认百度授权，但网盘登录信息不完整，请重试');
    }
    return [
      for (final key in const ['BDUSS', 'STOKEN', 'PTOKEN'])
        if (_value(values[key] ?? '')) '$key=${values[key]}'
    ].join('; ');
  }

  static Future<http.Response> baiduRequest(
      http.Client client, Uri uri, BaiduLoginCookies cookies,
      {Duration timeout = const Duration(seconds: 8)}) async {
    if (uri.scheme != 'https' ||
        uri.host != 'passport.baidu.com' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        !const {
          '/v2/api/getqrcode',
          '/v2/api/qrcode',
          '/channel/unicast',
          '/v3/login/main/qrbdusslogin',
        }.contains(uri.path)) {
      throw const FormatException('百度登录请求地址无效');
    }
    var acceptsResponse = true;
    final elapsed = Stopwatch()..start();
    bool expired() => !acceptsResponse || elapsed.elapsed >= timeout;
    void checkDeadline() {
      if (expired()) throw TimeoutException('百度登录请求超时，请重试');
    }

    return (() async {
      final request = http.Request('GET', uri)..followRedirects = false;
      final cookie = cookies.headerFor(uri);
      request.headers.addAll({
        'User-Agent': baiduUserAgent,
        'Accept': 'application/json, text/plain, */*',
        'Referer': 'https://pan.baidu.com/',
        if (cookie.isNotEmpty) 'Cookie': cookie
      });
      final streamed = await client.send(request);
      if (expired()) {
        await streamed.stream.listen((_) {}).cancel();
        throw TimeoutException('百度登录请求超时，请重试');
      }
      if (streamed.statusCode != 200) {
        await streamed.stream.listen((_) {}).cancel();
        throw const FormatException('百度登录服务暂时不可用，请重试');
      }
      final bytes = <int>[];
      await for (final chunk in streamed.stream) {
        checkDeadline();
        if (bytes.length + chunk.length > 256 * 1024) {
          throw const FormatException('百度登录响应过大');
        }
        bytes.addAll(chunk);
      }
      final response = http.Response.bytes(bytes, streamed.statusCode,
          headers: streamed.headers, request: request);
      // Future.timeout does not cancel client.send or a pending response body.
      // A late response must never replace cookies from the retry that followed.
      checkDeadline();
      cookies.receive(response, uri);
      return response;
    })()
        .timeout(timeout, onTimeout: () {
      acceptsResponse = false;
      throw TimeoutException('百度登录请求超时，请重试');
    });
  }

  static String aliCredential(Object? bizExt) {
    if (bizExt is! String || bizExt.isEmpty) {
      throw const FormatException('阿里扫码授权未完成');
    }
    final decoded =
        jsonDecode(utf8.decode(base64.decode(base64.normalize(bizExt))));
    final pds = decoded is Map ? decoded['pds_login_result'] : null;
    final token = pds is Map ? (pds['refreshToken'] ?? '').toString() : '';
    final credential = 'ali_token=$token';
    if (!isUsable('ali', credential)) {
      throw const FormatException('阿里账号会话交换失败，请重新扫码');
    }
    return credential;
  }

  static Map decodeObject(String text) {
    var value = text.trim();
    if (!value.startsWith('{')) {
      final match =
          RegExp(r'^(?:[A-Za-z_$][\w$]*\s*)?\((.*)\)\s*;?$', dotAll: true)
              .firstMatch(value);
      if (match == null) throw const FormatException('登录响应无效');
      value = match.group(1)!;
    }
    final decoded = jsonDecode(value);
    if (decoded is! Map) throw const FormatException('登录响应无效');
    return decoded;
  }

  static Future<Map> _get(
      http.Client client, Uri uri, Map<String, String> headers) async {
    return (() async {
      final request = http.Request('GET', uri)..followRedirects = false;
      request.headers.addAll({'Accept': 'application/json', ...headers});
      final response = await client.send(request);
      if (response.statusCode != 200) {
        await response.stream.listen((_) {}).cancel();
        throw const FormatException('网盘账号验证失败');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > 256 * 1024) {
          throw const FormatException('登录响应过大');
        }
        bytes.addAll(chunk);
      }
      return decodeObject(utf8.decode(bytes));
    })()
        .timeout(const Duration(seconds: 8));
  }
}
