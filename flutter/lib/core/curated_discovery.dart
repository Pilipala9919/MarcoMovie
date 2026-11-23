import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'models.dart';
import 'series_scraper.dart';

/// Descriptor for a Rex-style self-built curated discovery shelf on the Home
/// screen (近期国内热门、豆瓣高分、烂番茄、迪士尼、漫威、DC).
class CuratedModuleSpec {
  final String id;
  final String title;
  final String subtitle;
  final String badgeText;
  final IconData icon;
  final Color accentColor;
  final Uri? liveUri;
  final String referer;
  final List<CmsVideo> seedItems;

  const CuratedModuleSpec({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.badgeText,
    required this.icon,
    required this.accentColor,
    required this.liveUri,
    required this.referer,
    required this.seedItems,
  });
}

/// Self-built Rex-style discovery catalog service.
///
/// Important architectural boundary:
/// - This service ONLY supplies metadata discovery lists (titles, ratings,
///   years, posters from approved public metadata endpoints + offline seeds).
/// - It NEVER ships or plays built-in stream URLs. Tapping an item opens
///   `DetailScreen` with [curatedSiteSentinel], which searches ONLY the user's
///   own added CMS sources to resolve playable lines; if none of the user's
///   sources carry the title, playback is cleanly blocked with a clear notice.
class CuratedDiscoveryService {
  CuratedDiscoveryService._();

  static const String sentinelSiteKey = '__curated_discovery__';

  /// Marker [CmsSite] passed into `DetailScreen` when a user opens an item from
  /// a curated discovery module.
  static const CmsSite curatedSiteSentinel = CmsSite(
    key: sentinelSiteKey,
    name: '精选发现',
    type: 1,
    api: '',
    searchable: false,
  );

  static bool isCuratedSite(CmsSite site) => site.key == sentinelSiteKey;

  static const String _mobileUa =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4)
    ..idleTimeout = const Duration(seconds: 20)
    ..autoUncompress = true;

  static final Map<String, ({DateTime fetchedAt, List<CmsVideo> items})> _cache =
      {};
  static final Map<String, Future<List<CmsVideo>>> _inflight = {};
  static final Map<String, String> _backdropById = {};
  static final Map<String, String> _genreById = {};
  static const Duration _cacheTtl = Duration(minutes: 30);

  /// Returns a dedicated 16:9 landscape still URL for [video] when available
  /// from Douban's `photos` array, falling back to [video.poster].
  static String backdropFor(CmsVideo video) {
    final hit = _backdropById[video.id];
    if (hit != null && hit.isNotEmpty) return hit;
    return video.poster;
  }

  /// Returns parsed genre subtitle (e.g. `剧情 / 古装`) when available.
  static String genreFor(CmsVideo video) {
    return _genreById[video.id] ?? '';
  }

  /// Rex-style discovery modules displayed across varied Home discovery layouts.
  static final List<CuratedModuleSpec> modules = [
    CuratedModuleSpec(
      id: 'cn_hot',
      title: '近期国内热门',
      subtitle: '近一月 · 热播剧集与华语口碑新作',
      badgeText: '热播',
      icon: CupertinoIcons.flame_fill,
      accentColor: const Color(0xFFFF5E3A),
      liveUri: Uri.https(
        'm.douban.com',
        '/rexxar/api/v2/subject_collection/tv_hot/items',
        {'start': '0', 'count': '16'},
      ),
      referer: 'https://m.douban.com/tv/chinese',
      seedItems: const [
        CmsVideo(id: 'curated:cn:1', title: '漫长的季节', year: '2023', area: '中国大陆', remarks: '豆瓣 9.4', doubanScore: 9.4, actor: '范伟, 秦昊, 陈明昊'),
        CmsVideo(id: 'curated:cn:2', title: '庆余年 第二季', year: '2024', area: '中国大陆', remarks: '豆瓣 7.3', doubanScore: 7.3, actor: '张若昀, 李沁, 陈道明'),
        CmsVideo(id: 'curated:cn:3', title: '繁花', year: '2023', area: '中国大陆', remarks: '豆瓣 8.7', doubanScore: 8.7, actor: '胡歌, 马伊琍, 唐嫣, 辛芷蕾'),
        CmsVideo(id: 'curated:cn:4', title: '我的阿勒泰', year: '2024', area: '中国大陆', remarks: '豆瓣 8.9', doubanScore: 8.9, actor: '马伊琍, 周依然, 于适'),
        CmsVideo(id: 'curated:cn:5', title: '唐朝诡事录之西行', year: '2024', area: '中国大陆', remarks: '豆瓣 8.6', doubanScore: 8.6, actor: '杨旭文, 杨志刚'),
        CmsVideo(id: 'curated:cn:6', title: '三体', year: '2023', area: '中国大陆', remarks: '豆瓣 8.7', doubanScore: 8.7, actor: '张鲁一, 于和伟, 陈瑾'),
        CmsVideo(id: 'curated:cn:7', title: '狂飙', year: '2023', area: '中国大陆', remarks: '豆瓣 8.5', doubanScore: 8.5, actor: '张译, 张颂文, 李一桐'),
        CmsVideo(id: 'curated:cn:8', title: '山花烂漫时', year: '2024', area: '中国大陆', remarks: '豆瓣 9.6', doubanScore: 9.6, actor: '宋佳, 兰西雅, 都兰'),
      ],
    ),
    CuratedModuleSpec(
      id: 'weekly_trending',
      title: '本周趋势',
      subtitle: '院线热映与近期飙升佳作',
      badgeText: '趋势',
      icon: CupertinoIcons.graph_circle_fill,
      accentColor: const Color(0xFFFF9F0A),
      liveUri: Uri.https(
        'm.douban.com',
        '/rexxar/api/v2/subject_collection/movie_hot_gaia/items',
        {'start': '0', 'count': '16'},
      ),
      referer: 'https://m.douban.com/movie/',
      seedItems: const [
        CmsVideo(id: 'curated:tr:1', title: '沙丘2', year: '2024', area: '美国', remarks: '科幻 / 冒险', doubanScore: 8.2, actor: '提莫西·查拉梅, 赞达亚'),
        CmsVideo(id: 'curated:tr:2', title: '奥本海默', year: '2023', area: '美国', remarks: '剧情 / 传记', doubanScore: 8.8, actor: '基里安·墨菲, 艾米莉·布朗特'),
        CmsVideo(id: 'curated:tr:3', title: '周处除三害', year: '2023', area: '中国台湾', remarks: '动作 / 犯罪', doubanScore: 8.1, actor: '阮经天, 袁富华'),
        CmsVideo(id: 'curated:tr:4', title: '九龙城寨之围城', year: '2024', area: '中国香港', remarks: '动作 / 犯罪', doubanScore: 7.3, actor: '古天乐, 洪金宝, 林峯'),
        CmsVideo(id: 'curated:tr:5', title: '头脑特工队2', year: '2024', area: '美国', remarks: '动画 / 奇幻', doubanScore: 8.4, actor: '艾米·波勒, 玛雅·霍克'),
        CmsVideo(id: 'curated:tr:6', title: '荒野机器人', year: '2024', area: '美国', remarks: '科幻 / 动画', doubanScore: 8.0, actor: '露皮塔·尼永奥, 佩德罗·帕斯卡'),
        CmsVideo(id: 'curated:tr:7', title: '流浪地球2', year: '2023', area: '中国大陆', remarks: '科幻 / 冒险', doubanScore: 8.3, actor: '吴京, 刘德华, 李雪健'),
        CmsVideo(id: 'curated:tr:8', title: '好东西', year: '2024', area: '中国大陆', remarks: '剧情 / 喜剧', doubanScore: 9.1, actor: '宋佳, 钟楚曦, 曾慕梅'),
      ],
    ),
    CuratedModuleSpec(
      id: 'cn_variety',
      title: '近一月 · 热门综艺',
      subtitle: '真人秀与热门口碑综艺合集',
      badgeText: '综艺',
      icon: CupertinoIcons.music_mic,
      accentColor: const Color(0xFFBF5AF2),
      liveUri: Uri.https(
        'm.douban.com',
        '/rexxar/api/v2/subject_collection/show_domestic/items',
        {'start': '0', 'count': '16'},
      ),
      referer: 'https://m.douban.com/tv/variety',
      seedItems: const [
        CmsVideo(id: 'curated:vr:1', title: '现在就出发', year: '2024', area: '中国大陆', remarks: '真人秀', doubanScore: 8.3, actor: '沈腾, 白敬亭, 金晨'),
        CmsVideo(id: 'curated:vr:2', title: '你好，星期六', year: '2022', area: '中国大陆', remarks: '真人秀', doubanScore: 7.4, actor: '何炅, 檀健次, 丁程鑫'),
        CmsVideo(id: 'curated:vr:3', title: '毛雪汪', year: '2021', area: '中国大陆', remarks: '真人秀', doubanScore: 8.6, actor: '毛不易, 李雪琴'),
        CmsVideo(id: 'curated:vr:4', title: '花儿与少年·丝路季', year: '2023', area: '中国大陆', remarks: '旅行 / 真人秀', doubanScore: 9.2, actor: '秦海璐, 秦岚, 辛芷蕾, 迪丽热巴'),
        CmsVideo(id: 'curated:vr:5', title: '喜人奇妙夜', year: '2024', area: '中国大陆', remarks: '喜剧 / 竞演', doubanScore: 8.0, actor: '马东, 黄渤, 秦昊'),
        CmsVideo(id: 'curated:vr:6', title: '种地吧', year: '2023', area: '中国大陆', remarks: '真人秀', doubanScore: 9.0, actor: '蒋敦豪, 鹭卓, 李耕耘'),
        CmsVideo(id: 'curated:vr:7', title: '大侦探', year: '2024', area: '中国大陆', remarks: '悬疑 / 推理', doubanScore: 8.4, actor: '何炅, 张若昀, 大张伟'),
        CmsVideo(id: 'curated:vr:8', title: '歌手2024', year: '2024', area: '中国大陆', remarks: '音乐 / 竞演', doubanScore: 7.2, actor: '那英, 凡希亚, 香缇莫'),
      ],
    ),
    CuratedModuleSpec(
      id: 'douban_top',
      title: '豆瓣高分',
      subtitle: '豆瓣影迷公认必看佳片',
      badgeText: '豆瓣',
      icon: CupertinoIcons.star_circle_fill,
      accentColor: const Color(0xFF00B51D),
      liveUri: Uri.https(
        'm.douban.com',
        '/rexxar/api/v2/subject_collection/movie_top250/items',
        {'start': '0', 'count': '16'},
      ),
      referer: 'https://m.douban.com/movie/top250',
      seedItems: const [
        CmsVideo(id: 'curated:db:1', title: '肖申克的救赎', year: '1994', area: '美国', remarks: '豆瓣 9.7', doubanScore: 9.7, actor: '蒂姆·罗宾斯, 摩根·弗里曼'),
        CmsVideo(id: 'curated:db:2', title: '霸王别姬', year: '1993', area: '中国香港', remarks: '豆瓣 9.6', doubanScore: 9.6, actor: '张国荣, 张丰毅, 巩俐'),
        CmsVideo(id: 'curated:db:3', title: '星际穿越', year: '2014', area: '美国', remarks: '豆瓣 9.4', doubanScore: 9.4, actor: '马修·麦康纳, 安妮·海瑟薇'),
        CmsVideo(id: 'curated:db:4', title: '盗梦空间', year: '2010', area: '美国', remarks: '豆瓣 9.4', doubanScore: 9.4, actor: '莱昂纳多·迪卡普里奥, 约瑟夫·高登-莱维特'),
        CmsVideo(id: 'curated:db:5', title: '千与千寻', year: '2001', area: '日本', remarks: '豆瓣 9.4', doubanScore: 9.4, actor: '柊瑠美, 入野自由'),
        CmsVideo(id: 'curated:db:6', title: '楚门的世界', year: '1998', area: '美国', remarks: '豆瓣 9.4', doubanScore: 9.4, actor: '金·凯瑞, 劳拉·琳妮'),
        CmsVideo(id: 'curated:db:7', title: '海上钢琴师', year: '1998', area: '意大利', remarks: '豆瓣 9.3', doubanScore: 9.3, actor: '蒂姆·罗斯, 普路特·泰勒·文斯'),
        CmsVideo(id: 'curated:db:8', title: '让子弹飞', year: '2010', area: '中国大陆', remarks: '豆瓣 9.0', doubanScore: 9.0, actor: '姜文, 葛优, 周润发'),
      ],
    ),
    CuratedModuleSpec(
      id: 'rotten_tomatoes',
      title: '烂番茄新鲜认证',
      subtitle: '海外影评高分口碑榜单',
      badgeText: 'RT',
      icon: CupertinoIcons.rosette,
      accentColor: const Color(0xFFFA320A),
      liveUri: Uri.https(
        'm.douban.com',
        '/rexxar/api/v2/subject_collection/movie_score/items',
        {'start': '0', 'count': '16'},
      ),
      referer: 'https://m.douban.com/movie/',
      seedItems: const [
        CmsVideo(id: 'curated:rt:1', title: '沙丘2', year: '2024', area: '美国', remarks: '新鲜度 92%', doubanScore: 8.2, rtScore: 92, actor: '提莫西·查拉梅, 赞达亚'),
        CmsVideo(id: 'curated:rt:2', title: '奥本海默', year: '2023', area: '美国', remarks: '新鲜度 93%', doubanScore: 8.8, rtScore: 93, actor: '基里安·墨菲, 艾米莉·布朗特'),
        CmsVideo(id: 'curated:rt:3', title: '蜘蛛侠：纵横宇宙', year: '2023', area: '美国', remarks: '新鲜度 95%', doubanScore: 8.5, rtScore: 95, actor: '沙梅克·摩尔, 海莉·斯坦菲尔德'),
        CmsVideo(id: 'curated:rt:4', title: '瞬息全宇宙', year: '2022', area: '美国', remarks: '新鲜度 94%', doubanScore: 7.7, rtScore: 94, actor: '杨紫琼, 关继威'),
        CmsVideo(id: 'curated:rt:5', title: '寄生虫', year: '2019', area: '韩国', remarks: '新鲜度 99%', doubanScore: 8.8, rtScore: 99, actor: '宋康昊, 李善均'),
        CmsVideo(id: 'curated:rt:6', title: '疯狂的麦克斯4：狂暴之路', year: '2015', area: '澳大利亚', remarks: '新鲜度 97%', doubanScore: 8.7, rtScore: 97, actor: '汤姆·哈迪, 查理兹·塞隆'),
        CmsVideo(id: 'curated:rt:7', title: '荒野机器人', year: '2024', area: '美国', remarks: '新鲜度 98%', doubanScore: 8.0, rtScore: 98, actor: '露皮塔·尼永奥, 佩德罗·帕斯卡'),
        CmsVideo(id: 'curated:rt:8', title: '壮志凌云2：独行侠', year: '2022', area: '美国', remarks: '新鲜度 96%', doubanScore: 8.0, rtScore: 96, actor: '汤姆·克鲁斯, 迈尔斯·特勒'),
      ],
    ),
    CuratedModuleSpec(
      id: 'disney',
      title: '迪士尼 · 皮克斯',
      subtitle: '奇幻动画与合家欢经典',
      badgeText: 'Disney',
      icon: CupertinoIcons.sparkles,
      accentColor: const Color(0xFF1D6BFF),
      liveUri: Uri.https(
        'movie.douban.com',
        '/j/new_search_subjects',
        {'sort': 'U', 'range': '7,10', 'tags': '迪士尼', 'start': '0', 'limit': '16'},
      ),
      referer: 'https://movie.douban.com/',
      seedItems: const [
        CmsVideo(id: 'curated:ds:1', title: '疯狂动物城', year: '2016', area: '美国', remarks: '豆瓣 9.2', doubanScore: 9.2, actor: '金妮弗·古德温, 杰森·贝特曼'),
        CmsVideo(id: 'curated:ds:2', title: '寻梦环游记', year: '2017', area: '美国', remarks: '豆瓣 9.1', doubanScore: 9.1, actor: '安东尼·冈萨雷斯, 盖尔·加西亚·贝纳尔'),
        CmsVideo(id: 'curated:ds:3', title: '头脑特工队2', year: '2024', area: '美国', remarks: '豆瓣 8.4', doubanScore: 8.4, actor: '艾米·波勒, 玛雅·霍克'),
        CmsVideo(id: 'curated:ds:4', title: '机器人总动员', year: '2008', area: '美国', remarks: '豆瓣 9.3', doubanScore: 9.3, actor: '本·贝尔特, 艾丽莎·奈特'),
        CmsVideo(id: 'curated:ds:5', title: '心灵奇旅', year: '2020', area: '美国', remarks: '豆瓣 8.7', doubanScore: 8.7, actor: '杰米·福克斯, 蒂娜·菲'),
        CmsVideo(id: 'curated:ds:6', title: '冰雪奇缘', year: '2013', area: '美国', remarks: '豆瓣 8.5', doubanScore: 8.5, actor: '克里斯汀·贝尔, 伊迪娜·门泽尔'),
        CmsVideo(id: 'curated:ds:7', title: '飞屋环游记', year: '2009', area: '美国', remarks: '豆瓣 9.1', doubanScore: 9.1, actor: '爱德华·阿斯纳, 克里斯托弗·普卢默'),
        CmsVideo(id: 'curated:ds:8', title: '加勒比海盗', year: '2003', area: '美国', remarks: '豆瓣 8.8', doubanScore: 8.8, actor: '约翰尼·德普, 杰弗里·拉什'),
      ],
    ),
    CuratedModuleSpec(
      id: 'marvel',
      title: '漫威宇宙',
      subtitle: 'Marvel 超级英雄电影与剧集',
      badgeText: 'MARVEL',
      icon: CupertinoIcons.shield_lefthalf_fill,
      accentColor: const Color(0xFFE62429),
      liveUri: Uri.https(
        'movie.douban.com',
        '/j/new_search_subjects',
        {'sort': 'U', 'range': '6,10', 'tags': '漫威', 'start': '0', 'limit': '16'},
      ),
      referer: 'https://movie.douban.com/',
      seedItems: const [
        CmsVideo(id: 'curated:mv:1', title: '复仇者联盟4：终局之战', year: '2019', area: '美国', remarks: '豆瓣 8.5', doubanScore: 8.5, actor: '小罗伯特·唐尼, 克里斯·埃文斯'),
        CmsVideo(id: 'curated:mv:2', title: '复仇者联盟3：无限战争', year: '2018', area: '美国', remarks: '豆瓣 8.1', doubanScore: 8.1, actor: '小罗伯特·唐尼, 乔什·布洛林'),
        CmsVideo(id: 'curated:mv:3', title: '钢铁侠', year: '2008', area: '美国', remarks: '豆瓣 8.4', doubanScore: 8.4, actor: '小罗伯特·唐尼, 格温妮斯·帕特洛'),
        CmsVideo(id: 'curated:mv:4', title: '银河护卫队3', year: '2023', area: '美国', remarks: '豆瓣 8.4', doubanScore: 8.4, actor: '克里斯·帕拉特, 佐伊·索尔达娜'),
        CmsVideo(id: 'curated:mv:5', title: '洛基 第一季', year: '2021', area: '美国', remarks: '豆瓣 8.5', doubanScore: 8.5, actor: '汤姆·希德勒斯顿, 欧文·威尔逊'),
        CmsVideo(id: 'curated:mv:6', title: '美国队长2', year: '2014', area: '美国', remarks: '豆瓣 8.0', doubanScore: 8.0, actor: '克里斯·埃文斯, 斯嘉丽·约翰逊'),
        CmsVideo(id: 'curated:mv:7', title: '死侍与金刚狼', year: '2024', area: '美国', remarks: '豆瓣 7.0', doubanScore: 7.0, actor: '瑞安·雷诺兹, 休·杰克曼'),
        CmsVideo(id: 'curated:mv:8', title: '蜘蛛侠：英雄无归', year: '2021', area: '美国', remarks: '豆瓣 6.6', doubanScore: 6.6, actor: '汤姆·赫兰德, 赞达亚'),
      ],
    ),
    CuratedModuleSpec(
      id: 'dc',
      title: 'DC 宇宙',
      subtitle: '哥谭暗黑史诗与正义联盟',
      badgeText: 'DC',
      icon: CupertinoIcons.bolt_fill,
      accentColor: const Color(0xFF0476F2),
      liveUri: Uri.https(
        'movie.douban.com',
        '/j/new_search_subjects',
        {'sort': 'U', 'range': '6,10', 'tags': 'DC', 'start': '0', 'limit': '16'},
      ),
      referer: 'https://movie.douban.com/',
      seedItems: const [
        CmsVideo(id: 'curated:dc:1', title: '蝙蝠侠：黑暗骑士', year: '2008', area: '美国', remarks: '豆瓣 9.2', doubanScore: 9.2, actor: '克里斯蒂安·贝尔, 希斯·莱杰'),
        CmsVideo(id: 'curated:dc:2', title: '小丑', year: '2019', area: '美国', remarks: '豆瓣 8.7', doubanScore: 8.7, actor: '华金·菲尼克斯, 罗伯特·德尼罗'),
        CmsVideo(id: 'curated:dc:3', title: '新蝙蝠侠', year: '2022', area: '美国', remarks: '豆瓣 7.2', doubanScore: 7.2, actor: '罗伯特·帕丁森, 佐伊·克罗维兹'),
        CmsVideo(id: 'curated:dc:4', title: '企鹅人', year: '2024', area: '美国', remarks: '豆瓣 8.7', doubanScore: 8.7, actor: '科林·法瑞尔, 克里斯汀·米利欧缇'),
        CmsVideo(id: 'curated:dc:5', title: '守望者', year: '2009', area: '美国', remarks: '豆瓣 8.6', doubanScore: 8.6, actor: '杰基·厄尔·哈利, 帕特里克·威尔森'),
        CmsVideo(id: 'curated:dc:6', title: '扎克·施奈德版正义联盟', year: '2021', area: '美国', remarks: '豆瓣 8.2', doubanScore: 8.2, actor: '本·阿弗莱克, 亨利·卡维尔'),
        CmsVideo(id: 'curated:dc:7', title: '海王', year: '2018', area: '美国', remarks: '豆瓣 7.6', doubanScore: 7.6, actor: '杰森·莫玛, 艾梅柏·希尔德'),
        CmsVideo(id: 'curated:dc:8', title: 'V字仇杀队', year: '2005', area: '美国', remarks: '豆瓣 8.9', doubanScore: 8.9, actor: '娜塔莉·波特曼, 雨果·维文'),
      ],
    ),
  ];

  /// Immediately returns cached items or curated seed items without blocking UI.
  static List<CmsVideo> peekModule(CuratedModuleSpec spec) {
    final hit = _cache[spec.id];
    if (hit != null && hit.items.isNotEmpty) return hit.items;
    return spec.seedItems;
  }

  /// Fetches fresh items for [spec] from approved public metadata APIs, falling
  /// back to [spec.seedItems] when offline or rate-limited.
  static Future<List<CmsVideo>> fetchModule(
    CuratedModuleSpec spec, {
    bool forceRefresh = false,
  }) async {
    final hit = _cache[spec.id];
    if (!forceRefresh &&
        hit != null &&
        hit.items.isNotEmpty &&
        DateTime.now().difference(hit.fetchedAt) < _cacheTtl) {
      return hit.items;
    }
    final existing = _inflight[spec.id];
    if (existing != null) return existing;

    final future = _fetchLiveModule(spec);
    _inflight[spec.id] = future;
    try {
      final items = await future;
      if (items.isNotEmpty) {
        _cache[spec.id] = (fetchedAt: DateTime.now(), items: items);
        return items;
      }
      return spec.seedItems;
    } finally {
      _inflight.remove(spec.id);
    }
  }

  static Future<List<CmsVideo>> _fetchLiveModule(CuratedModuleSpec spec) async {
    final uri = spec.liveUri;
    if (uri == null) return spec.seedItems;
    try {
      final req = await _client.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, _mobileUa);
      req.headers.set(HttpHeaders.refererHeader, spec.referer);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final resp = await req.close().timeout(const Duration(seconds: 4));
      if (resp.statusCode != 200) return spec.seedItems;
      final body = await utf8.decoder.bind(resp).join();
      final parsed = parseDoubanDiscoveryJson(body, moduleId: spec.id);
      if (parsed.isNotEmpty) return parsed;
    } catch (_) {}
    return spec.seedItems;
  }

  /// Parses both Douban Rexxar `subject_collection_items` and
  /// `new_search_subjects` JSON payloads into [CmsVideo] metadata items.
  static List<CmsVideo> parseDoubanDiscoveryJson(
    String jsonText, {
    required String moduleId,
  }) {
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map) return const [];
    final rawList = (decoded['subject_collection_items'] ?? decoded['data']);
    if (rawList is! List) return const [];

    final out = <CmsVideo>[];
    final seen = <String>{};
    for (final raw in rawList.whereType<Map>()) {
      final title = (raw['title'] ?? '').toString().trim();
      if (title.isEmpty || !seen.add(title)) continue;
      final id = (raw['id'] ?? '').toString().trim();
      String poster = '';
      if (raw['pic'] is Map) {
        poster = ((raw['pic'] as Map)['large'] ??
                (raw['pic'] as Map)['normal'] ??
                '')
            .toString()
            .trim();
      }
      if (poster.isEmpty) {
        final cover = raw['cover'];
        if (cover is Map) {
          poster = (cover['url'] ?? '').toString().trim();
        } else if (cover is String) {
          poster = cover.trim();
        }
      }
      if (poster.contains('/s_ratio_poster/')) {
        poster = poster.replaceFirst('/s_ratio_poster/', '/m_ratio_poster/');
      }
      String backdrop = '';
      final photos = raw['photos'];
      if (photos is List) {
        for (final entry in photos) {
          final url = entry is String
              ? entry.trim()
              : (entry is Map ? (entry['url'] ?? '').toString().trim() : '');
          if (url.isNotEmpty) {
            backdrop = url;
            break;
          }
        }
      }
      double? score;
      final rating = raw['rating'];
      if (rating is Map && rating['value'] is num) {
        final v = (rating['value'] as num).toDouble();
        if (v > 0) score = v;
      } else if (raw['rate'] != null) {
        final v = double.tryParse(raw['rate'].toString());
        if (v != null && v > 0) score = v;
      }
      final year = (raw['year'] ?? '').toString().trim();
      final cardSub = (raw['card_subtitle'] ?? '').toString().trim();
      String parsedArea = '';
      String parsedGenre = '';
      if (cardSub.isNotEmpty) {
        final subParts = cardSub
            .split('/')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
        if (subParts.length >= 2) parsedArea = subParts[1];
        if (subParts.length >= 3) {
          parsedGenre = subParts[2]
              .split(RegExp(r'\s+'))
              .where((e) => e.isNotEmpty)
              .take(2)
              .join(' / ');
        }
      }
      final actorsRaw = raw['actors'] ?? raw['casts'];
      final actor = actorsRaw is List
          ? actorsRaw.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).join(', ')
          : '';
      final remarks = score != null
          ? '豆瓣 ${score.toStringAsFixed(1)}'
          : (parsedGenre.isNotEmpty
              ? parsedGenre
              : (year.isNotEmpty ? year : ''));
      final videoId =
          id.isNotEmpty ? 'curated:$moduleId:$id' : 'curated:$moduleId:${out.length}';
      if (backdrop.isNotEmpty) {
        _backdropById[videoId] = backdrop;
      }
      if (parsedGenre.isNotEmpty) {
        _genreById[videoId] = parsedGenre;
      }
      out.add(
        CmsVideo(
          id: videoId,
          title: title,
          poster: poster,
          remarks: remarks,
          year: year,
          area: parsedArea,
          actor: actor,
          description: cardSub,
          doubanScore: score,
        ),
      );
      if (out.length >= 16) break;
    }
    return out;
  }

  /// Normalizes a title for fuzzy matching against a user's CMS source search
  /// results.
  static String normalizeMatchKey(String title) {
    var s = SeriesScraper.normalizeSequelNumerals(title.trim()).toLowerCase();
    s = s.replaceAll(
      RegExp(
        r'[\(\[（【].*?(?:4k|hdr|臻彩|杜比|蓝光|国语|粤语|中字|未删减|完整版|高清|hd|1080p|2160p|抢先|tc|ts).*?[\)\]）】]',
        caseSensitive: false,
      ),
      '',
    );
    s = s.replaceAll(RegExp(r'[\s:：·\-—_,.，。!！?？《》「」]+'), '');
    return s;
  }

  /// Scores how closely [candidateTitle] matches [targetTitle] so user-source
  /// resolution picks the exact movie/series first.
  static int titleMatchScore(String targetTitle, String candidateTitle) {
    if (SeriesScraper.isMotionComicText(targetTitle) !=
        SeriesScraper.isMotionComicText(candidateTitle)) {
      return 0;
    }
    final a = normalizeMatchKey(targetTitle);
    final b = normalizeMatchKey(candidateTitle);
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 100;
    if (b.startsWith(a) || a.startsWith(b)) return 80;
    if (b.contains(a) || a.contains(b)) return 60;
    return 0;
  }
}
