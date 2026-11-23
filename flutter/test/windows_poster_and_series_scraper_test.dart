import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/curated_discovery.dart';
import 'package:marco_movie/core/danmu/dandanplay_provider.dart';
import 'package:marco_movie/core/danmu/provider.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/series_scraper.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/detail_screen.dart';
import 'package:marco_movie/ui/poster_image.dart';
import 'package:marco_movie/ui/series_scrape_sheet.dart';
import 'package:marco_movie/ui/windows_appearance.dart';

class _StubDetailClient extends CmsClient {
  final CmsVideo detailVideo;
  _StubDetailClient(this.detailVideo);

  @override
  Future<CmsVideo> fetchDetail(CmsSite site, CmsVideo fallback) async {
    return detailVideo;
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PosterLoader.clearCache();
  });

  group('Work-Form Disambiguation (动态漫画 vs 常规动漫/剧集)', () {
    test('detectWorkForm & isCompatibleWorkForm separate motion comics cleanly',
        () {
      expect(
        SeriesScraper.detectWorkForm('斗罗大陆2：绝世唐门2023'),
        MediaWorkForm.standard,
      );
      expect(
        SeriesScraper.detectWorkForm('斗罗大陆2 绝世唐门 荣耀篇[动态漫画]'),
        MediaWorkForm.motionComic,
      );
      expect(
        SeriesScraper.detectWorkForm('武神主宰 动态漫 第2季'),
        MediaWorkForm.motionComic,
      );
      expect(
        SeriesScraper.isCompatibleWorkForm(
          targetIsMotionComic: false,
          candidateTitle: '《斗罗大陆2 绝世唐门》国产动态漫画',
        ),
        isFalse,
      );
      expect(
        SeriesScraper.isCompatibleWorkForm(
          targetIsMotionComic: true,
          candidateTitle: '《斗罗大陆2 绝世唐门》国产动态漫画',
        ),
        isTrue,
      );
      expect(
        SeriesScraper.isCompatibleWorkForm(
          targetIsMotionComic: true,
          candidateTitle: '斗罗大陆Ⅱ绝世唐门 年番1 3D动画',
        ),
        isFalse,
      );
    });

    test(
        'PosterLoader.isSameWorkTitle aligns Roman numerals / 年番 and blocks 动态漫画 cross-match',
        () {
      expect(
        PosterLoader.isSameWorkTitle(
          '斗罗大陆Ⅱ绝世唐门 年番1',
          '斗罗大陆2：绝世唐门2023',
          wantMotionComic: false,
        ),
        isTrue,
      );
      expect(
        PosterLoader.isSameWorkTitle(
          '斗罗大陆2 绝世唐门 荣耀篇[动态漫画]',
          '斗罗大陆2：绝世唐门2023',
          wantMotionComic: false,
        ),
        isFalse,
      );
      expect(
        PosterLoader.isSameWorkTitle(
          '斗罗大陆2 绝世唐门 荣耀篇[动态漫画]',
          '斗罗大陆2：绝世唐门 动态漫画',
          wantMotionComic: true,
        ),
        isTrue,
      );
      expect(
        PosterLoader.isSameWorkTitle(
          '斗罗大陆',
          '斗罗大陆2：绝世唐门2023',
          wantMotionComic: false,
        ),
        isFalse,
      );
    });

    test('parseDoubanRexxarSubject selects 2023 3D anime vs 2018 动态漫画 accurately',
        () {
      final rexxarDecoded = <String, dynamic>{
        'subjects': <String, dynamic>{
          'items': <Map<String, dynamic>>[
            <String, dynamic>{
              'target_type': 'tv',
              'target': <String, dynamic>{
                'id': '34431106',
                'title': '斗罗大陆2 绝世唐门 荣耀篇[动态漫画]',
                'year': '2018',
                'card_subtitle': '2018 / 中国大陆 / 动画 / 动态漫画',
                'cover_url': 'https://img1.doubanio.com/view/photo/s_ratio_poster/public/p111.jpg',
              },
            },
            <String, dynamic>{
              'target_type': 'tv',
              'target': <String, dynamic>{
                'id': '35567787',
                'title': '斗罗大陆Ⅱ绝世唐门 年番1',
                'year': '2023',
                'card_subtitle': '2023 / 中国大陆 / 动画 奇幻 / 唐宏宁',
                'cover_url': 'https://img2.doubanio.com/view/photo/s_ratio_poster/public/p222.jpg',
              },
            },
          ],
        },
      };

      final anime = PosterLoader.parseDoubanRexxarSubject(
        rexxarDecoded,
        '斗罗大陆2：绝世唐门2023',
        year: '2023',
        wantMotionComic: false,
      );
      expect(anime, isNotNull);
      expect(anime!.id, '35567787');
      expect(anime.isTv, isTrue);

      final motionComic = PosterLoader.parseDoubanRexxarSubject(
        rexxarDecoded,
        '斗罗大陆2：绝世唐门 动态漫画',
        year: '2018',
        wantMotionComic: true,
      );
      expect(motionComic, isNotNull);
      expect(motionComic!.id, '34431106');
    });

    test('parseDoubanSuggestSubject treats movie with episode count as TV', () {
      final suggestDecoded = <Map<String, dynamic>>[
        <String, dynamic>{
          'episode': '40',
          'img': 'https://img3.doubanio.com/view/photo/s_ratio_poster/public/p2937601501.jpg',
          'title': '走马上任',
          'type': 'movie',
          'year': '2026',
          'id': '36942992',
        },
      ];
      final hit = PosterLoader.parseDoubanSuggestSubject(
        suggestDecoded,
        '走马上任（臻彩）',
        year: '2026',
      );
      expect(hit, isNotNull);
      expect(hit!.id, '36942992');
      expect(hit.isTv, isTrue);
    });

    test(
        'isFilmOrTvEncyclopediaEntry rejects 2018 动态漫画 Baike lemma for 2023 3D anime',
        () {
      const baikeDesc =
          '《斗罗大陆2 绝世唐门》是由章干岳担任制片人、黎茜执导的国产动态漫画，2018年12月3日在中国大陆首播。';
      expect(
        PosterLoader.isFilmOrTvEncyclopediaEntry(
          abstractText: baikeDesc,
          descText: '2018年国产动态漫画',
          targetYear: 2023,
          wantMotionComic: false,
        ),
        isFalse,
      );
      expect(
        PosterLoader.isFilmOrTvEncyclopediaEntry(
          abstractText: baikeDesc,
          descText: '2018年国产动态漫画',
          targetYear: 2018,
          wantMotionComic: true,
        ),
        isTrue,
      );
    });

    test(
        'CmsParser season discovery & CuratedDiscovery never mix 动态漫画 with regular 动漫',
        () {
      expect(
        CmsParser.isSameFranchiseSeasonCandidate(
          '斗罗大陆2：绝世唐门2023',
          '斗罗大陆2：绝世唐门 动态漫画 第2季',
        ),
        isFalse,
      );
      expect(
        CuratedDiscoveryService.titleMatchScore(
          '斗罗大陆2：绝世唐门',
          '斗罗大陆2 绝世唐门 动态漫画',
        ),
        0,
      );
      expect(
        CuratedDiscoveryService.titleMatchScore(
          '斗罗大陆2：绝世唐门',
          '斗罗大陆Ⅱ绝世唐门',
        ),
        100,
      );
    });
  });

  group('Landscape Backdrop Matching & Tier Ordering (走马上任 Regression)', () {
    test('rejects TVB 溏心风暴3 clip, UGC vpic_cover & idiom news for 走马上任', () {
      expect(
        PosterLoader.matchesBingLandscapeCaption(
          '溏心风暴3：黄围家走马上任，解释他是有权拿这笔奖金',
          '走马上任',
          targetYear: 2026,
          imageUrl: 'https://owned.invalid/vpic_cover/abc123/abc123_hz.jpg',
        ),
        isFalse,
      );
      expect(
        PosterLoader.matchesBingLandscapeCaption(
          '国乒新帅走马上任，正式公布最新集训名单',
          '走马上任',
          targetYear: 2026,
        ),
        isFalse,
      );
      expect(
        PosterLoader.matchesBingLandscapeCaption(
          '走马上任成语解释与造句大全',
          '走马上任',
          targetYear: 2026,
        ),
        isFalse,
      );
      expect(
        PosterLoader.matchesBingLandscapeCaption(
          '电视剧《走马上任》2026 赵本山王小利喜剧官方剧照',
          '走马上任',
          targetYear: 2026,
        ),
        isTrue,
      );
      expect(
        PosterLoader.matchesBingLandscapeCaption(
          '斗罗大陆2 绝世唐门 动态漫画 剧照',
          '斗罗大陆2：绝世唐门',
          targetYear: 2023,
          wantMotionComic: false,
        ),
        isFalse,
      );
    });

    test('mergeTieredLandscapeUrls prioritizes official stills strictly over Bing',
        () {
      final merged = PosterLoader.mergeTieredLandscapeUrls(
        doubanUrls: const [
          'https://img2.doubanio.com/view/photo/l/public/p2913865140.jpg',
        ],
        bilibiliUrls: const [],
        bingPrimaryUrls: const [
          'https://tse1-mm.cn.bing.net/th/id/OIP-C.fake?pid=Api',
        ],
        bingSecondaryUrls: const [],
      );
      expect(
        merged.first,
        'https://img2.doubanio.com/view/photo/l/public/p2913865140.jpg',
      );
      expect(merged.length, 2);
    });
  });

  group('In-Series Episode Scraper Engine', () {
    test('extracts true episode numbers while ignoring sequel, year, 4K/60fps/10bit/H265',
        () {
      final ep180 = SeriesScraper.scrapeEpisodeName(
        '180 4K.mp4',
        seriesTitle: '斗罗大陆2：绝世唐门2023',
      );
      expect(ep180.resolvedEpisodeNumber, 180);
      expect(ep180.qualityTag, '4K');
      expect(ep180.isSpecial, isFalse);

      final ep01 = SeriesScraper.scrapeEpisodeName(
        '斗罗大陆2 01.mp4',
        seriesTitle: '斗罗大陆2：绝世唐门2023',
      );
      expect(ep01.resolvedEpisodeNumber, 1);

      final epTech = SeriesScraper.scrapeEpisodeName(
        '斗罗大陆Ⅱ绝世唐门_180_2160p_60fps_10bit_H265.mkv',
        seriesTitle: '斗罗大陆2：绝世唐门2023',
      );
      expect(epTech.resolvedEpisodeNumber, 180);
      expect(epTech.qualityTag, '4K · 60帧');

      final epSeason = SeriesScraper.scrapeEpisodeName(
        '走马上任.2026.S02E05.4K.HDR.mkv',
        seriesTitle: '走马上任（臻彩）',
      );
      expect(epSeason.seasonNumber, 2);
      expect(epSeason.resolvedEpisodeNumber, 5);
      expect(epSeason.qualityTag, '4K · HDR');

      final trailer = SeriesScraper.scrapeEpisodeName(
        '00 终极预告.mp4',
        seriesTitle: '斗罗大陆2：绝世唐门2023',
      );
      expect(trailer.isSpecial, isTrue);

      final sp = SeriesScraper.scrapeEpisodeName(
        'SP01 番外特别篇.mkv',
        seriesTitle: '斗罗大陆2：绝世唐门2023',
      );
      expect(sp.isSpecial, isTrue);
    });

    test(
        'scrapeLineEpisodes detects lexicographical scramble, applies offset & manual overrides without mutating episodes',
        () {
      final episodes = <CmsEpisode>[
        const CmsEpisode(name: '00 预告.mp4', url: 'u0'),
        const CmsEpisode(name: '1 4K.mp4', url: 'u1'),
        const CmsEpisode(name: '10 4K.mp4', url: 'u10'),
        const CmsEpisode(name: '100 4K.mp4', url: 'u100'),
        const CmsEpisode(name: '2 4K.mp4', url: 'u2'),
      ];
      final res = SeriesScraper.scrapeLineEpisodes(
        episodes,
        seriesTitle: '斗罗大陆2：绝世唐门2023',
      );
      expect(res.sourceOrderScrambled, isTrue);
      expect(res.specialCount, 1);
      expect(res.regularCount, 4);

      final sorted = res.orderedIndices(sortByScraped: true, hideSpecials: false);
      // Main episodes 1, 2, 10, 100 first, then special trailer at the end.
      expect(sorted, <int>[1, 4, 2, 3, 0]);
      // Original list untouched
      expect(episodes[0].name, '00 预告.mp4');

      final hiddenSpecials =
          res.orderedIndices(sortByScraped: true, hideSpecials: true);
      expect(hiddenSpecials, <int>[1, 4, 2, 3]);

      final calibrated = SeriesScraper.scrapeLineEpisodes(
        episodes,
        seriesTitle: '斗罗大陆2：绝世唐门2023',
        episodeOffset: 10,
        manualOverrides: const {'2 4K.mp4': 182},
      );
      expect(calibrated.byOriginalIndex[1].resolvedEpisodeNumber, 11);
      expect(calibrated.byOriginalIndex[4].resolvedEpisodeNumber, 182);
    });
  });

  group('StorageService SeriesScrapeOverride Persistence & Privacy', () {
    test('round-trips override and respects private site isolation', () async {
      final storage = await StorageService.init();
      int revChanges = 0;
      storage.seriesScrapeRevision.addListener(() => revChanges++);

      const override = SeriesScrapeOverride(
        source: 'douban',
        subjectId: '35567787',
        isTv: true,
        matchedTitle: '斗罗大陆Ⅱ绝世唐门 年番1',
        matchedYear: '2023',
        isMotionComic: false,
        backdropUrl: 'https://img2.doubanio.com/view/photo/l/public/p2877604346.jpg',
        synopsis: '这里没有魔法，没有斗气，没有武术，却有武魂。',
        doubanScore: 7.8,
        episodeOffset: -1,
        sortByScrapedEpisode: true,
        hideSpecials: true,
        episodeNumberOverrides: {'180 4K.mp4': 180},
      );

      await storage.saveSeriesScrapeOverride('wogg', 'dl2_2023', override);
      expect(revChanges, 1);

      final loaded = storage.getSeriesScrapeOverride('wogg', 'dl2_2023');
      expect(loaded, isNotNull);
      expect(loaded!.doubanId, '35567787');
      expect(loaded.episodeOffset, -1);
      expect(loaded.sortByScrapedEpisode, isTrue);
      expect(loaded.episodeNumberOverrides['180 4K.mp4'], 180);

      // Private site must never persist or expose scrape overrides
      await storage.saveSeriesScrapeOverride(
        'wogg',
        'dl2_2023',
        override,
        isPrivate: true,
      );
      expect(
        storage.getSeriesScrapeOverride('wogg', 'dl2_2023', isPrivate: true),
        isNull,
      );

      await storage.clearSeriesScrapeOverride('wogg', 'dl2_2023');
      expect(storage.getSeriesScrapeOverride('wogg', 'dl2_2023'), isNull);
    });
  });

  group('Danmu Matching With Scraped Episode & Work-Form', () {
    test('prefers 3D anime & exact episode over 动态漫画 in DandanplayProvider',
        () async {
      String? postedFileName;
      http.Response jsonUtf8(Map<String, dynamic> data) => http.Response.bytes(
            utf8.encode(jsonEncode(data)),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );

      final client = MockClient((req) async {
        if (req.url.path == '/api/v2/match') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          postedFileName = body['fileName']?.toString();
          return jsonUtf8(<String, dynamic>{
            'isMatched': false,
            'matches': <Map<String, dynamic>>[
              <String, dynamic>{
                'episodeId': 8001,
                'animeId': 9001,
                'animeTitle': '斗罗大陆2 绝世唐门 动态漫画',
                'episodeTitle': '第180话',
                'confidence': 0.90,
              },
            ],
          });
        }
        if (req.url.path == '/api/v2/search/episodes') {
          return jsonUtf8(<String, dynamic>{
            'animes': <Map<String, dynamic>>[
              <String, dynamic>{
                'animeId': 9001,
                'animeTitle': '斗罗大陆2 绝世唐门 动态漫画',
                'episodes': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'episodeId': 8001,
                    'episodeTitle': '第180集',
                  },
                ],
              },
              <String, dynamic>{
                'animeId': 9002,
                'animeTitle': '斗罗大陆Ⅱ绝世唐门',
                'episodes': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'episodeId': 8099,
                    'episodeTitle': '第179集',
                  },
                  <String, dynamic>{
                    'episodeId': 8100,
                    'episodeTitle': '第180集',
                  },
                ],
              },
            ],
          });
        }
        if (req.url.path == '/api/v2/bangumi/9002') {
          return jsonUtf8(<String, dynamic>{
            'bangumi': <String, dynamic>{
              'animeTitle': '斗罗大陆Ⅱ绝世唐门',
              'episodes': <Map<String, dynamic>>[
                <String, dynamic>{
                  'episodeId': 8099,
                  'episodeTitle': '第179集',
                },
                <String, dynamic>{
                  'episodeId': 8100,
                  'episodeTitle': '第180集',
                },
              ],
            },
          });
        }
        return http.Response('not found', 404);
      });

      final provider = DandanplayProvider(
        multilineServerUrls: 'https://danmu.example',
        minRequestIntervalMs: 0,
        client: client,
      );
      addTearDown(provider.close);

      final matches = await provider.matchOrSearch(
        const DanmuMatchQuery(
          title: '斗罗大陆2：绝世唐门2023（臻彩）',
          episodeTitle: '180 4K.mp4',
          episodeIndex: 180,
          isMotionComic: false,
          year: '2023',
        ),
      );

      expect(postedFileName, '斗罗大陆2：绝世唐门 E180');
      expect(matches, isNotEmpty);
      // 3D anime Episode 180 MUST win over 动态漫画 Ep 180 AND over 3D anime Ep 179
      expect(matches.first.animeId, '9002');
      expect(matches.first.episodeTitle, '第180集');

      // Explicit animeId override resolves Ep 180 directly from /api/v2/bangumi/9002
      final boundMatches = await provider.matchOrSearch(
        const DanmuMatchQuery(
          title: '斗罗大陆2：绝世唐门',
          episodeIndex: 180,
          animeIdOverride: '9002',
          originOverride: 'https://danmu.example',
        ),
      );
      expect(boundMatches.first.episodeTitle, '第180集');
      expect(boundMatches.first.confidence, greaterThanOrEqualTo(0.95));
    });
  });

  group('Windows Detail Scraping & Episode Locator Widget Tests', () {
    testWidgets(
        'SeriesScrapeSheet binds official work & saves episode offset calibration',
        (tester) async {
      final storage = await StorageService.init();
      const site = CmsSite(
        key: 'wogg',
        name: '玩偶4K',
        type: 1,
        api: 'https://wogg.test',
      );
      final video = CmsVideo(
        id: 'dl2',
        title: '斗罗大陆2：绝世唐门2023',
        year: '2023',
        lines: [
          CmsLine(
            name: '百度网盘 2 · 4K',
            episodes: const [
              CmsEpisode(name: '00 预告.mp4', url: 'u0'),
              CmsEpisode(name: '1 4K.mp4', url: 'u1'),
              CmsEpisode(name: '180 4K.mp4', url: 'u180'),
            ],
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SeriesScrapeSheet(
              site: site,
              video: video,
              storage: storage,
              activeLine: video.lines.first,
              debugSearchFn: (q, filter) async => const [
                SeriesScrapeCandidate(
                  source: 'douban',
                  subjectId: '35567787',
                  title: '斗罗大陆Ⅱ绝世唐门 年番1',
                  year: '2023',
                  isMotionComic: false,
                  mediaBadge: '动漫',
                  isTv: true,
                  rating: 7.8,
                  synopsis: '3D 动画官方简介：这里没有魔法，没有斗气。',
                ),
                SeriesScrapeCandidate(
                  source: 'douban',
                  subjectId: '34431106',
                  title: '斗罗大陆2 绝世唐门 荣耀篇[动态漫画]',
                  year: '2018',
                  isMotionComic: true,
                  mediaBadge: '动态漫画',
                  isTv: true,
                ),
              ],
              debugHydrateFn: (c) async => c,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Both standard anime and motion comic candidates clearly labeled
      expect(find.text('斗罗大陆Ⅱ绝世唐门 年番1'), findsOneWidget);
      expect(find.text('动态漫画'), findsOneWidget);

      // Switch to episode scrape tab and adjust offset +1
      await tester.tap(find.byKey(const ValueKey('scrape-tab-episodes')));
      await tester.pumpAndSettle();
      expect(find.text('第 180 集'), findsOneWidget);

      await tester.tap(find.text('+1'));
      await tester.pumpAndSettle();
      expect(find.text('第 181 集'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('scrape-save-episodes-btn')));
      await tester.pumpAndSettle();

      final saved = storage.getSeriesScrapeOverride('wogg', 'dl2');
      expect(saved, isNotNull);
      expect(saved!.episodeOffset, 1);
    });

    testWidgets(
        'Windows DetailScreen shows 刮削匹配 button, honors bound override, and locates Ep 180',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        tester.view.physicalSize = const Size(1280, 820);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final storage = await StorageService.init();
        const site = CmsSite(
        key: 'wogg',
        name: '玩偶4K',
        type: 1,
        api: 'https://wogg.test',
      );
        final episodes = <CmsEpisode>[
          const CmsEpisode(name: '1 4K.mp4', url: 'https://a.test/1.mp4'),
          const CmsEpisode(name: '180 4K.mp4', url: 'https://a.test/180.mp4'),
          for (int i = 2; i <= 15; i++)
            CmsEpisode(name: '$i 4K.mp4', url: 'https://a.test/$i.mp4'),
        ];
        final video = CmsVideo(
          id: 'dl2',
          title: '斗罗大陆2：绝世唐门2023',
          year: '2023',
          lines: [CmsLine(name: '百度网盘 2 · 4K', episodes: episodes)],
        );

        await storage.saveSeriesScrapeOverride(
          'wogg',
          'dl2',
          const SeriesScrapeOverride(
            source: 'douban',
            subjectId: '35567787',
            matchedTitle: '斗罗大陆Ⅱ绝世唐门 年番1',
            matchedYear: '2023',
            isMotionComic: false,
            doubanScore: 7.8,
            synopsis: '3D正剧官方简介：唐门创立万年之后的斗罗大陆。',
            sortByScrapedEpisode: true,
          ),
        );

        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);

        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) =>
                WindowsAppearanceScope(controller: appearance, child: child!),
            home: DetailScreen(
              site: site,
              initialVideo: video,
              client: _StubDetailClient(video),
              storage: storage,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Bound rating, synopsis & 刮削匹配 button visible
        expect(find.text('豆瓣 ★ 7.8'), findsOneWidget);
        expect(find.textContaining('唐门创立万年之后的斗罗大陆'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('windows-detail-scrape-btn')),
          findsOneWidget,
        );

        // Expand episodes panel and locate episode 180 via inline locator
        await tester.ensureVisible(
          find.byKey(const ValueKey('windows-detail-episode-toggle')),
        );
        await tester.tap(find.byKey(const ValueKey('windows-detail-episode-toggle')));
        await tester.pumpAndSettle();

        final locator = find.byKey(const ValueKey('windows-episode-locator-field'));
        expect(locator, findsOneWidget);
        await tester.ensureVisible(locator);
        await tester.enterText(locator, '180');
        await tester.pumpAndSettle();

        // Ep 180 keeps its original index (1) while displaying clean scraped label
        expect(find.byKey(const ValueKey('ep_card_0_1')), findsOneWidget);
        expect(find.text('第 180 集'), findsOneWidget);
        expect(find.byKey(const ValueKey('ep_card_0_0')), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
