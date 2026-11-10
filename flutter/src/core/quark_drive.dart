import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'quark_account.dart';
import 'source_playback.dart';

/// Read-only access to files already in the authenticated Quark account.
/// Share IDs/tokens never enter this client, and it has no save/delete methods.
class QuarkDriveClient {
  QuarkDriveClient({
    required QuarkAccountProvider accounts,
    http.Client? httpClient,
  }) : _accounts = accounts,
       _http = httpClient ?? http.Client(),
       _ownsHttp = httpClient == null;

  final QuarkAccountProvider _accounts;
  final http.Client _http;
  final bool _ownsHttp;
  static const _pageSize = 50;
  static const _timeout = Duration(seconds: 20);
  static const _maxResponseBytes = 4 * 1024 * 1024;
  static const _apiHost = 'drive-pc.quark.cn';
  static const _referer = 'https://pan.quark.cn/';
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 '
      'Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch';
  static final _identifier = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  void close() {
    if (_ownsHttp) _http.close();
  }

  Future<CmsListing> listOwned({String folder = '0', int page = 1}) async {
    if (page < 1 || page > 10000) throw const FormatException('夸克目录页码无效');
    final session = await _accounts.requireSession();
    final generation = _accounts.generation;
    final fid = folder.startsWith('mmquark:')
        ? _ownedReference(folder, session, kind: 'folder')
        : _fid(folder);
    final payload = await _request(
      session,
      generation,
      '/1/clouddrive/file/sort',
      query: {
        'pdir_fid': fid,
        '_page': '$page',
        '_size': '$_pageSize',
        '_fetch_total': '1',
        '_fetch_sub_dirs': '0',
        '_sort': 'file_type:asc,file_name:asc',
      },
    );
    final data = payload['data'];
    if (data is! Map || data['list'] is! List) {
      throw const QuarkDriveException('invalid_response', '夸克未返回有效目录');
    }
    final rows = data['list'] as List;
    final videos = <CmsVideo>[];
    for (final row in rows.whereType<Map>()) {
      final fileId = row['fid'];
      final title = row['file_name'];
      if (fileId is! String ||
          !_identifier.hasMatch(fileId) ||
          title is! String ||
          title.trim().isEmpty)
        continue;
      final directory = row['dir'] == true || _integer(row['file_type']) == 0;
      if (!directory && _integer(row['category']) != 1) continue;
      final id = Uri(
        scheme: 'mmquark',
        host: directory ? 'folder' : 'owned',
        queryParameters: {'account': session.accountId, 'fid': fileId},
      ).toString();
      videos.add(
        CmsVideo(
          id: id,
          title: title,
          poster: directory
              ? ''
              : _httpUrl(row['thumbnail'] ?? row['thumbnail_url']),
          remarks: directory ? '文件夹' : _fileSize(row['size']),
          tag: directory ? 'quark-folder' : 'quark-owned',
          lines: directory
              ? const []
              : [
                  CmsLine(
                    name: '夸克网盘',
                    episodes: [CmsEpisode(name: title, url: id)],
                  ),
                ],
        ),
      );
    }
    final metadata = payload['metadata'];
    final total = metadata is Map ? _integer(metadata['_total']) : null;
    final pageCount = total != null && total >= 0
        ? ((total + _pageSize - 1) ~/ _pageSize).clamp(1, 10000)
        : page + (rows.length >= _pageSize ? 1 : 0);
    await _accounts.assertCurrentSession(session, generation: generation);
    return CmsListing(page: page, pageCount: pageCount, videos: videos);
  }

  Future<CmsEpisode> resolve(CmsEpisode episode) async {
    // Reject share/folder/arbitrary HTTP IDs before issuing any playback API.
    final reference = Uri.tryParse(episode.url);
    if (reference?.scheme != 'mmquark' || reference?.host != 'owned') {
      throw const QuarkDriveException(
        'owned_file_required',
        '请选择当前夸克账号中已有的视频；分享文件需先保存到网盘',
      );
    }
    final session = await _accounts.requireSession();
    final generation = _accounts.generation;
    final fid = _ownedReference(episode.url, session, kind: 'owned');
    final variants = <Map<String, Object>>[];
    try {
      final download = await _request(
        session,
        generation,
        '/1/clouddrive/file/download',
        body: {
          'fids': [fid],
        },
      );
      final files = download['data'];
      if (files is List) {
        for (final file in files.whereType<Map>()) {
          if (file['fid'] != null && file['fid'] != fid) continue;
          final url = _mediaUrl(file['download_url']);
          if (url.isNotEmpty) variants.add({'name': '原画', 'url': url});
        }
      }
    } on QuarkDriveException catch (error) {
      if (error.code != 'unavailable') rethrow;
      // Original download may be unavailable while an actual transcode exists.
    }
    try {
      final play = await _request(
        session,
        generation,
        '/1/clouddrive/file/v2/play',
        body: {
          'fid': fid,
          'resolutions': 'normal,low,high,super,2k,4k',
          'supports': 'fmp4,m3u8',
        },
      );
      final data = play['data'];
      final choices = data is Map ? data['video_list'] : null;
      if (choices is List) {
        const rankMap = <String, int>{
          '4k': 6,
          '2k': 5,
          'super': 4,
          'high': 3,
          'low': 2,
          'normal': 1,
        };
        final rankedChoices = <({int rank, String name, String url})>[];
        for (final choice in choices.whereType<Map>()) {
          final info = choice['video_info'];
          if (info is! Map ||
              choice['available'] == false ||
              info['available'] == false)
            continue;
          final url = _mediaUrl(info['url']);
          if (url.isEmpty) continue;
          final resolution = '${choice['resolution'] ?? ''}'.toLowerCase();
          final height = _integer(info['height']);
          final name =
              const {
                'normal': '流畅',
                'low': '标清',
                'high': '高清',
                'super': '超清',
                '2k': '2K',
                '4k': '4K',
              }[resolution] ??
              (height != null && height > 0 ? '${height}p' : '转码');
          final rank = rankMap[resolution] ?? ((height ?? 0) ~/ 360);
          rankedChoices.add((rank: rank, name: name, url: url));
        }
        rankedChoices.sort((a, b) => b.rank.compareTo(a.rank));
        for (final item in rankedChoices) {
          variants.add({'name': item.name, 'url': item.url});
        }
      }
    } on QuarkDriveException catch (error) {
      if (error.code != 'unavailable') rethrow;
    }
    await _accounts.assertCurrentSession(session, generation: generation);
    if (variants.isEmpty) {
      throw const QuarkDriveException('unavailable', '夸克未返回可用的原画或转码地址');
    }
    // Account cookies belong only to the fixed API origin. Signed media URLs
    // and thumbnails may use a CDN; never hand its player the account cookie.
    final resolved = await SourcePlayback.decode(
      {
        'parse': 0,
        'url': variants,
        'header': {'User-Agent': _userAgent, 'Referer': _referer},
      },
      episode,
      localUrl: (_) async => throw const FormatException('夸克不返回本地代理地址'),
    );
    await _accounts.assertCurrentSession(session, generation: generation);
    return resolved;
  }

  /// Lists video episodes from a public Quark share URL (`https://pan.quark.cn/s/<pwd_id>`)
  /// for TVBox `玩偶哥哥` / `木偶` 4K Quark lines (`mmwogg://quark?...`).
  static Future<List<CmsEpisode>> listPublicShareEpisodes(
    String shareUrl, {
    http.Client? httpClient,
  }) async {
    final match = RegExp(
      r'pan\.quark\.cn/s/([A-Za-z0-9_-]{6,32})',
      caseSensitive: false,
    ).firstMatch(shareUrl);
    if (match == null) return const [];
    final pwdId = match.group(1)!;
    final passMatch = RegExp(
      r'(?:pwd|passcode|code)[=:：\s]*([A-Za-z0-9]{4})',
      caseSensitive: false,
    ).firstMatch(shareUrl);
    final passcode = passMatch?.group(1) ?? '';

    final client = httpClient ?? http.Client();
    final ownsClient = httpClient == null;
    try {
      final tokenUri = Uri.https(
        _apiHost,
        '/1/clouddrive/share/sharepage/token',
        {'pr': 'ucpro', 'fr': 'pc', 'uc_param_str': ''},
      );
      final tokenRes = await client
          .post(
            tokenUri,
            headers: {
              'User-Agent': _userAgent,
              'Referer': _referer,
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({'pwd_id': pwdId, 'passcode': passcode}),
          )
          .timeout(const Duration(seconds: 8));
      if (tokenRes.statusCode != 200) return const [];
      final tokenJson = jsonDecode(utf8.decode(tokenRes.bodyBytes));
      if (tokenJson is! Map) return const [];
      final stoken = ((tokenJson['data'] as Map?)?['stoken'] ?? '').toString();
      if (stoken.isEmpty) return const [];

      Future<List<Map>> fetchDir(String pdirFid) async {
        final detailUri = Uri.https(
          _apiHost,
          '/1/clouddrive/share/sharepage/detail',
          {
            'pr': 'ucpro',
            'fr': 'pc',
            'uc_param_str': '',
            'pwd_id': pwdId,
            'stoken': stoken,
            'pdir_fid': pdirFid,
            'force': '0',
            '_page': '1',
            '_size': '200',
            '_fetch_banner': '0',
            '_fetch_share': '0',
            '_fetch_total': '1',
            '_sort': 'file_type:asc,file_name:asc',
          },
        );
        final res = await client
            .get(
              detailUri,
              headers: {
                'User-Agent': _userAgent,
                'Referer': _referer,
                'Accept': 'application/json',
              },
            )
            .timeout(const Duration(seconds: 8));
        if (res.statusCode != 200) return const [];
        final decoded = jsonDecode(utf8.decode(res.bodyBytes));
        final list = (decoded is Map ? (decoded['data'] as Map?)?['list'] : null);
        if (list is! List) return const [];
        return list.whereType<Map>().toList(growable: false);
      }

      bool isVideoRow(Map row) {
        if (row['dir'] == true || _integer(row['file_type']) == 0) return false;
        if (_integer(row['category']) == 1) return true;
        final name = (row['file_name'] ?? '').toString().toLowerCase();
        return RegExp(r'\.(?:mp4|mkv|ts|m3u8|mov|avi|flv|wmv|webm)$')
            .hasMatch(name);
      }

      final videoRows = <({String folderName, Map row})>[];
      Future<void> walk(String pdirFid, String folderName, int depth) async {
        if (depth > 3 || videoRows.length >= 400) return;
        final rows = await fetchDir(pdirFid);
        final subDirs = <Map>[];
        for (final row in rows) {
          final isDir = row['dir'] == true || _integer(row['file_type']) == 0;
          if (isDir) {
            subDirs.add(row);
          } else if (isVideoRow(row)) {
            videoRows.add((folderName: folderName, row: row));
          }
        }
        if (subDirs.isNotEmpty && depth < 3) {
          subDirs.sort((a, b) {
            final na = (a['file_name'] ?? '').toString().toUpperCase();
            final nb = (b['file_name'] ?? '').toString().toUpperCase();
            final scoreA = (na.contains('4K') || na.contains('2160')) ? 0 : 1;
            final scoreB = (nb.contains('4K') || nb.contains('2160')) ? 0 : 1;
            if (scoreA != scoreB) return scoreA.compareTo(scoreB);
            return na.compareTo(nb);
          });
          for (final dir in subDirs.take(depth == 0 ? 8 : 4)) {
            final fid = (dir['fid'] ?? '').toString();
            final dName = (dir['file_name'] ?? '').toString().trim();
            if (fid.isEmpty) continue;
            await walk(
              fid,
              folderName.isEmpty ? dName : '$folderName/$dName',
              depth + 1,
            );
          }
        }
      }

      await walk('0', '', 0);
      if (videoRows.isEmpty) return const [];

      final episodes = <CmsEpisode>[];
      for (final entry in videoRows) {
        final row = entry.row;
        final fid = (row['fid'] ?? '').toString().trim();
        final fidToken = (row['share_fid_token'] ?? '').toString().trim();
        final rawName = (row['file_name'] ?? '').toString().trim();
        if (fid.isEmpty || fidToken.isEmpty || rawName.isEmpty) continue;
        final cleanName = rawName.replaceFirst(
          RegExp(r'\.(?:mp4|mkv|ts|m3u8|mov|avi|flv|wmv|webm)$',
              caseSensitive: false),
          '',
        );
        final has4kTag = cleanName.toUpperCase().contains('4K') ||
            cleanName.contains('2160') ||
            entry.folderName.toUpperCase().contains('4K');
        final badge = has4kTag ? '[4K原画] ' : '[原画] ';
        final epUrl = Uri(
          scheme: 'mmwogg',
          host: 'quark',
          queryParameters: {
            'pwd_id': pwdId,
            'stoken': stoken,
            'fid': fid,
            'fid_token': fidToken,
          },
        ).toString();
        episodes.add(
          CmsEpisode(
            name: '$badge$cleanName',
            url: epUrl,
          ),
        );
      }
      return episodes;
    } catch (_) {
      return const [];
    } finally {
      if (ownsClient) client.close();
    }
  }

  /// Resolves a `mmwogg://quark?...` share episode by saving it into the user's
  /// temporary `0000temp` folder on Quark Drive and fetching 4K transcode + raw
  /// 4K original streams, matching TVBox `csp_WoGGGuard` (`Quark.java`).
  Future<CmsEpisode> resolveWoggShare(CmsEpisode episode) async {
    final uri = Uri.tryParse(episode.url);
    if (uri == null || uri.scheme != 'mmwogg' || uri.host != 'quark') {
      throw const QuarkDriveException('invalid_share', '夸克分享播放标识无效');
    }
    final pwdId = (uri.queryParameters['pwd_id'] ?? '').trim();
    final stoken = (uri.queryParameters['stoken'] ?? '').trim();
    final shareFid = (uri.queryParameters['fid'] ?? '').trim();
    final shareFidToken = (uri.queryParameters['fid_token'] ?? '').trim();
    if (pwdId.isEmpty ||
        stoken.isEmpty ||
        shareFid.isEmpty ||
        shareFidToken.isEmpty) {
      throw const QuarkDriveException('invalid_share', '夸克分享参数不完整');
    }

    final session = await _accounts.requireSession();
    final generation = _accounts.generation;

    // 1. Find or create `0000temp` directory in root (`pdir_fid: 0`)
    String tempDirFid = '';
    final rootList = await _request(
      session,
      generation,
      '/1/clouddrive/file/sort',
      query: {
        'pdir_fid': '0',
        '_page': '1',
        '_size': '100',
        '_fetch_total': '1',
        '_fetch_sub_dirs': '0',
        '_sort': 'file_type:asc,updated_at:desc',
      },
    );
    final rootRows = (rootList['data'] as Map?)?['list'];
    if (rootRows is List) {
      for (final row in rootRows.whereType<Map>()) {
        final isDir = row['dir'] == true || _integer(row['file_type']) == 0;
        if (isDir && (row['file_name'] ?? '').toString() == '0000temp') {
          tempDirFid = (row['fid'] ?? '').toString();
          break;
        }
      }
    }
    if (tempDirFid.isEmpty) {
      final created = await _request(
        session,
        generation,
        '/1/clouddrive/file',
        body: {
          'pdir_fid': '0',
          'file_name': '0000temp',
          'dir_path': '',
          'dir_init_lock': false,
        },
      );
      tempDirFid = ((created['data'] as Map?)?['fid'] ?? '').toString();
    } else {
      // Clean up old temp files inside `0000temp` to avoid filling user's quota
      try {
        final tempFiles = await _request(
          session,
          generation,
          '/1/clouddrive/file/sort',
          query: {
            'pdir_fid': tempDirFid,
            '_page': '1',
            '_size': '100',
            '_fetch_total': '1',
            '_fetch_sub_dirs': '0',
            '_sort': 'file_type:asc,updated_at:desc',
          },
        );
        final rows = (tempFiles['data'] as Map?)?['list'];
        if (rows is List && rows.isNotEmpty) {
          final oldFids = rows
              .whereType<Map>()
              .map((r) => (r['fid'] ?? '').toString())
              .where((f) => f.isNotEmpty)
              .toList(growable: false);
          if (oldFids.isNotEmpty) {
            await _request(
              session,
              generation,
              '/1/clouddrive/file/delete',
              body: {
                'action_type': 2,
                'filelist': oldFids,
                'exclude_fids': const <String>[],
              },
            );
          }
        }
      } catch (_) {}
    }

    if (tempDirFid.isEmpty) {
      throw const QuarkDriveException('unavailable', '无法创建夸克网盘临时转存目录');
    }

    // 2. Save shared file into `0000temp`
    final saveRes = await _request(
      session,
      generation,
      '/1/clouddrive/share/sharepage/save',
      body: {
        'fid_list': [shareFid],
        'fid_token_list': [shareFidToken],
        'to_pdir_fid': tempDirFid,
        'pwd_id': pwdId,
        'stoken': stoken,
        'pdir_fid': '0',
        'scene': 'link',
      },
    );
    final taskId = ((saveRes['data'] as Map?)?['task_id'] ?? '').toString();
    String savedFid = '';
    final immediateTop =
        ((saveRes['data'] as Map?)?['save_as'] as Map?)?['save_as_top_fids'];
    if (immediateTop is List && immediateTop.isNotEmpty) {
      savedFid = '${immediateTop.first}'.trim();
    }
    if (savedFid.isEmpty && taskId.isNotEmpty) {
      for (var i = 0; i < 10; i++) {
        final taskRes = await _request(
          session,
          generation,
          '/1/clouddrive/task',
          query: {'task_id': taskId, 'retry_index': '$i'},
        );
        final taskData = taskRes['data'] as Map? ?? const {};
        final topFids = (taskData['save_as'] as Map?)?['save_as_top_fids'];
        if (topFids is List && topFids.isNotEmpty) {
          savedFid = '${topFids.first}'.trim();
          if (savedFid.isNotEmpty) break;
        }
        if (_integer(taskData['status']) != 1) break;
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    if (savedFid.isEmpty) {
      throw const QuarkDriveException('unavailable', '夸克4K资源转存超时，请稍后重试');
    }

    // 3. Fetch both transcode (4K/2K/1080P) and raw original download URL
    String originalDownloadUrl = '';
    try {
      final download = await _request(
        session,
        generation,
        '/1/clouddrive/file/download',
        body: {
          'fids': [savedFid],
        },
      );
      final files = download['data'];
      if (files is List) {
        for (final file in files.whereType<Map>()) {
          final url = _mediaUrl(file['download_url']);
          if (url.isNotEmpty) {
            originalDownloadUrl = url;
            break;
          }
        }
      }
    } catch (_) {}

    final transcodeChoices = <({int rank, String name, String url})>[];
    try {
      final play = await _request(
        session,
        generation,
        '/1/clouddrive/file/v2/play',
        body: {
          'fid': savedFid,
          'resolutions': 'normal,low,high,super,2k,4k',
          'supports': 'fmp4,m3u8',
        },
      );
      final data = play['data'];
      final choices = data is Map ? data['video_list'] : null;
      if (choices is List) {
        const rankMap = <String, int>{
          '4k': 6,
          '2k': 5,
          'super': 4,
          'high': 3,
          'low': 2,
          'normal': 1,
        };
        for (final choice in choices.whereType<Map>()) {
          final info = choice['video_info'];
          if (info is! Map ||
              choice['available'] == false ||
              info['available'] == false) {
            continue;
          }
          final url = _mediaUrl(info['url']);
          if (url.isEmpty) continue;
          final resolution = '${choice['resolution'] ?? ''}'.toLowerCase();
          final height = _integer(info['height']);
          final name =
              const {
                'normal': '流畅',
                'low': '标清',
                'high': '高清',
                'super': '超清',
                '2k': '2K',
                '4k': '4K',
              }[resolution] ??
              (height != null && height > 0 ? '${height}p' : '转码');
          final rank = rankMap[resolution] ?? ((height ?? 0) ~/ 360);
          transcodeChoices.add((rank: rank, name: name, url: url));
        }
        transcodeChoices.sort((a, b) => b.rank.compareTo(a.rank));
      }
    } catch (_) {}

    // Prioritize 4K transcode and 4K raw original stream BEFORE 1080P ('super')
    final variants = <Map<String, Object>>[];
    var insertedOriginal = false;
    for (final item in transcodeChoices) {
      if (!insertedOriginal &&
          originalDownloadUrl.isNotEmpty &&
          item.rank < 6) {
        variants.add({'name': '4K原画', 'url': originalDownloadUrl});
        insertedOriginal = true;
      }
      variants.add({'name': item.name, 'url': item.url});
    }
    if (!insertedOriginal && originalDownloadUrl.isNotEmpty) {
      variants.insert(0, {'name': '4K原画', 'url': originalDownloadUrl});
    }

    if (variants.isEmpty) {
      throw const QuarkDriveException('unavailable', '夸克未返回可用的4K原画或转码地址');
    }

    final resolved = await SourcePlayback.decode(
      {
        'parse': 0,
        'url': variants,
        'header': {
          'Cookie': session.cookie,
          'User-Agent': _userAgent,
          'Referer': _referer,
        },
      },
      episode,
      localUrl: (_) async => throw const FormatException('夸克不返回本地代理地址'),
    );
    await _accounts.assertCurrentSession(session, generation: generation);
    return resolved;
  }

  Future<Map<String, dynamic>> _request(
    QuarkAccountSession session,
    int generation,
    String path, {
    Map<String, String> query = const {},
    Map<String, Object>? body,
  }) async {
    await _accounts.assertCurrentSession(session, generation: generation);
    final uri = Uri.https(_apiHost, path, {
      'pr': 'ucpro',
      'fr': 'pc',
      'uc_param_str': '',
      ...query,
    });
    final request = http.Request(body == null ? 'GET' : 'POST', uri)
      ..followRedirects = false
      ..maxRedirects = 0
      ..headers.addAll({
        'Cookie': session.cookie,
        'User-Agent': _userAgent,
        'Referer': _referer,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      });
    if (body != null) request.body = jsonEncode(body);
    try {
      final response = await _http.send(request).timeout(_timeout);
      try {
        await _accounts.assertCurrentSession(session, generation: generation);
      } catch (_) {
        await response.stream.listen((_) {}).cancel();
        rethrow;
      }
      if (response.statusCode >= 300 && response.statusCode < 400) {
        await response.stream.listen((_) {}).cancel();
        throw const QuarkDriveException(
          'redirect_refused',
          '夸克接口发生重定向，请重新验证账号',
        );
      }
      if (response.statusCode == 401) {
        await response.stream.listen((_) {}).cancel();
        _accounts.invalidate();
        throw const QuarkDriveException(
          'authentication_required',
          '夸克登录已失效，请重新登录',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.listen((_) {}).cancel();
        throw const QuarkDriveException('unavailable', '夸克暂时无法提供此文件');
      }
      final bytes = <int>[];
      await for (final part in response.stream.timeout(_timeout)) {
        if (bytes.length + part.length > _maxResponseBytes) {
          throw const QuarkDriveException('invalid_response', '夸克响应超过大小限制');
        }
        bytes.addAll(part);
      }
      await _accounts.assertCurrentSession(session, generation: generation);
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic>) {
        throw const QuarkDriveException('invalid_response', '夸克接口返回格式无效');
      }
      final status = _integer(value['status']), code = _integer(value['code']);
      if (status == 401) {
        _accounts.invalidate();
        throw const QuarkDriveException(
          'authentication_required',
          '夸克登录已失效，请重新登录',
        );
      }
      if (code != 0 || (status != null && status != 200)) {
        throw const QuarkDriveException('unavailable', '夸克暂时无法提供此文件');
      }
      return value;
    } on TimeoutException {
      throw const QuarkDriveException('unavailable', '夸克请求超时，请稍后重试');
    } on http.ClientException {
      throw const QuarkDriveException('unavailable', '无法连接夸克网盘');
    } on FormatException {
      throw const QuarkDriveException('invalid_response', '夸克接口返回格式无效');
    }
  }

  static String _ownedReference(
    String raw,
    QuarkAccountSession session, {
    required String kind,
  }) {
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'mmquark' ||
        uri.host != kind ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.path.isNotEmpty ||
        uri.hasFragment ||
        uri.queryParametersAll.length != 2 ||
        uri.queryParametersAll['account']?.length != 1 ||
        uri.queryParametersAll['fid']?.length != 1) {
      throw const FormatException('夸克文件标识无效');
    }
    if (uri.queryParameters['account'] != session.accountId) {
      throw const QuarkDriveException(
        'account_mismatch',
        '夸克账号已切换，请重新打开当前账号的文件',
      );
    }
    return _fid(uri.queryParameters['fid'] ?? '');
  }

  static String _fid(String value) {
    if (!_identifier.hasMatch(value))
      throw const FormatException('夸克目录或文件标识无效');
    return value;
  }

  static int? _integer(Object? value) =>
      value is int ? value : int.tryParse('$value');
  static String _httpUrl(Object? value) {
    if (value is! String) return '';
    final uri = Uri.tryParse(value.trim());
    return uri != null &&
            const {'https', 'http'}.contains(uri.scheme) &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? uri.toString()
        : '';
  }

  static String _mediaUrl(Object? value) {
    final url = _httpUrl(value);
    if (url.isEmpty) return '';
    final path = Uri.parse(url).path.toLowerCase();
    return RegExp(r'\.(?:webp|png|jpe?g|gif|svg|html?)$').hasMatch(path)
        ? ''
        : url;
  }

  static String _fileSize(Object? value) {
    final size = _integer(value);
    if (size == null || size < 0) return '';
    if (size >= 1024 * 1024 * 1024)
      return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class QuarkDriveException implements Exception {
  const QuarkDriveException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}
