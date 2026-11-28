// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Descriptor for a curated metadata-only discovery module on the iOS Discover / Home screens.
/// Security & compliance boundary: NEVER embeds playable media stream URLs — only public
/// metadata (titles, ratings, years, posters) resolved against the user's own added sources.
public struct CuratedModuleSpec: Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let badgeText: String
    public let accentHex: UInt32
    public let liveUrlString: String
    public let referer: String
    public let wave: Int
    public let seedItems: [CmsVideo]

    public init(
        id: String,
        title: String,
        subtitle: String,
        badgeText: String,
        accentHex: UInt32,
        liveUrlString: String,
        referer: String,
        wave: Int,
        seedItems: [CmsVideo]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.badgeText = badgeText
        self.accentHex = accentHex
        self.liveUrlString = liveUrlString
        self.referer = referer
        self.wave = wave
        self.seedItems = seedItems
    }
}

private final class CuratedDiscoveryStateBox: @unchecked Sendable {
    struct CachedEntry {
        let fetchedAt: Date
        let items: [CmsVideo]
    }

    let lock = NSLock()
    var cache: [String: CachedEntry] = [:]
    var backdropById: [String: String] = [:]
    var genreById: [String: String] = [:]
    var diskWarmed: Bool = false

    func reset() {
        lock.lock()
        cache.removeAll()
        backdropById.removeAll()
        genreById.removeAll()
        diskWarmed = false
        lock.unlock()
    }
}

/// Composes curated editorial discovery shelves for the iOS Home & Discover screens:
/// 1. Local catalog-derived shelves (`buildModules(from:preferences:nowMs:)`) strictly from the
///    user's loaded public catalog.
/// 2. Full 8-module Douban public metadata fetcher (Wave 1: `weekly_trending`, `cn_hot`,
///    `douban_top`, `rotten_tomatoes`; Wave 2: `cn_variety`, `disney`, `marvel`, `dc`) with
///    30-minute in-memory TTL, `<Application Support>/marco_curated_discovery_v1.json` disk
///    snapshot cache, `/s_ratio_poster/` -> `/m_ratio_poster/` upgrade, and rich metadata-only
///    offline fallback seeds (zero stream URLs).
public enum CuratedDiscoveryService {
    public static let sentinelSiteKey = "__curated_discovery__"
    public static let cacheTtlSeconds: TimeInterval = 30 * 60
    public static let snapshotFileName = "marco_curated_discovery_v1.json"

    private static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private static let state = CuratedDiscoveryStateBox()

    /// Marker `CmsSite` passed to Detail when opening a curated discovery metadata item.
    public static let curatedSiteSentinel = CmsSite(
        key: sentinelSiteKey,
        name: "精选发现",
        type: 1,
        api: "",
        searchable: false
    )

    public static func isCuratedSite(_ site: CmsSite) -> Bool {
        site.key == sentinelSiteKey
    }

    // MARK: - 8 Curated Metadata Modules (Wave 1 + Wave 2)

    public static let modules: [CuratedModuleSpec] = [
        CuratedModuleSpec(
            id: "weekly_trending",
            title: "本周趋势",
            subtitle: "院线热映与近期飙升佳作",
            badgeText: "趋势",
            accentHex: 0xFF9F0A,
            liveUrlString: "https://m.douban.com/rexxar/api/v2/subject_collection/movie_hot_gaia/items?start=0&count=16",
            referer: "https://m.douban.com/movie/",
            wave: 1,
            seedItems: [
                CmsVideo(id: "curated:tr:1", title: "沙丘2", remarks: "科幻 / 冒险", year: "2024", area: "美国", actor: "提莫西·查拉梅, 赞达亚", doubanScore: 8.2),
                CmsVideo(id: "curated:tr:2", title: "奥本海默", remarks: "剧情 / 传记", year: "2023", area: "美国", actor: "基里安·墨菲, 艾米莉·布朗特", doubanScore: 8.8),
                CmsVideo(id: "curated:tr:3", title: "周处除三害", remarks: "动作 / 犯罪", year: "2023", area: "中国台湾", actor: "阮经天, 袁富华", doubanScore: 8.1),
                CmsVideo(id: "curated:tr:4", title: "九龙城寨之围城", remarks: "动作 / 犯罪", year: "2024", area: "中国香港", actor: "古天乐, 洪金宝, 林峯", doubanScore: 7.3),
                CmsVideo(id: "curated:tr:5", title: "头脑特工队2", remarks: "动画 / 奇幻", year: "2024", area: "美国", actor: "艾米·波勒, 玛雅·霍克", doubanScore: 8.4),
                CmsVideo(id: "curated:tr:6", title: "荒野机器人", remarks: "科幻 / 动画", year: "2024", area: "美国", actor: "露皮塔·尼永奥, 佩德罗·帕斯卡", doubanScore: 8.0),
                CmsVideo(id: "curated:tr:7", title: "流浪地球2", remarks: "科幻 / 冒险", year: "2023", area: "中国大陆", actor: "吴京, 刘德华, 李雪健", doubanScore: 8.3),
                CmsVideo(id: "curated:tr:8", title: "好东西", remarks: "剧情 / 喜剧", year: "2024", area: "中国大陆", actor: "宋佳, 钟楚曦, 曾慕梅", doubanScore: 9.1),
            ]
        ),
        CuratedModuleSpec(
            id: "cn_hot",
            title: "近期国内热门",
            subtitle: "近一月 · 热播剧集与华语口碑新作",
            badgeText: "热播",
            accentHex: 0xFF5E3A,
            liveUrlString: "https://m.douban.com/rexxar/api/v2/subject_collection/tv_hot/items?start=0&count=16",
            referer: "https://m.douban.com/tv/chinese",
            wave: 1,
            seedItems: [
                CmsVideo(id: "curated:cn:1", title: "漫长的季节", remarks: "豆瓣 9.4", year: "2023", area: "中国大陆", actor: "范伟, 秦昊, 陈明昊", doubanScore: 9.4),
                CmsVideo(id: "curated:cn:2", title: "庆余年 第二季", remarks: "豆瓣 7.3", year: "2024", area: "中国大陆", actor: "张若昀, 李沁, 陈道明", doubanScore: 7.3),
                CmsVideo(id: "curated:cn:3", title: "繁花", remarks: "豆瓣 8.7", year: "2023", area: "中国大陆", actor: "胡歌, 马伊琍, 唐嫣, 辛芷蕾", doubanScore: 8.7),
                CmsVideo(id: "curated:cn:4", title: "我的阿勒泰", remarks: "豆瓣 8.9", year: "2024", area: "中国大陆", actor: "马伊琍, 周依然, 于适", doubanScore: 8.9),
                CmsVideo(id: "curated:cn:5", title: "唐朝诡事录之西行", remarks: "豆瓣 8.6", year: "2024", area: "中国大陆", actor: "杨旭文, 杨志刚", doubanScore: 8.6),
                CmsVideo(id: "curated:cn:6", title: "三体", remarks: "豆瓣 8.7", year: "2023", area: "中国大陆", actor: "张鲁一, 于和伟, 陈瑾", doubanScore: 8.7),
                CmsVideo(id: "curated:cn:7", title: "狂飙", remarks: "豆瓣 8.5", year: "2023", area: "中国大陆", actor: "张译, 张颂文, 李一桐", doubanScore: 8.5),
                CmsVideo(id: "curated:cn:8", title: "山花烂漫时", remarks: "豆瓣 9.6", year: "2024", area: "中国大陆", actor: "宋佳, 兰西雅, 都兰", doubanScore: 9.6),
            ]
        ),
        CuratedModuleSpec(
            id: "douban_top",
            title: "豆瓣高分",
            subtitle: "豆瓣影迷公认必看佳片",
            badgeText: "豆瓣",
            accentHex: 0x00B51D,
            liveUrlString: "https://m.douban.com/rexxar/api/v2/subject_collection/movie_top250/items?start=0&count=16",
            referer: "https://m.douban.com/movie/top250",
            wave: 1,
            seedItems: [
                CmsVideo(id: "curated:db:1", title: "肖申克的救赎", remarks: "豆瓣 9.7", year: "1994", area: "美国", actor: "蒂姆·罗宾斯, 摩根·弗里曼", doubanScore: 9.7),
                CmsVideo(id: "curated:db:2", title: "霸王别姬", remarks: "豆瓣 9.6", year: "1993", area: "中国香港", actor: "张国荣, 张丰毅, 巩俐", doubanScore: 9.6),
                CmsVideo(id: "curated:db:3", title: "星际穿越", remarks: "豆瓣 9.4", year: "2014", area: "美国", actor: "马修·麦康纳, 安妮·海瑟薇", doubanScore: 9.4),
                CmsVideo(id: "curated:db:4", title: "盗梦空间", remarks: "豆瓣 9.4", year: "2010", area: "美国", actor: "莱昂纳多·迪卡普里奥, 约瑟夫·高登-莱维特", doubanScore: 9.4),
                CmsVideo(id: "curated:db:5", title: "千与千寻", remarks: "豆瓣 9.4", year: "2001", area: "日本", actor: "柊瑠美, 入野自由", doubanScore: 9.4),
                CmsVideo(id: "curated:db:6", title: "楚门的世界", remarks: "豆瓣 9.4", year: "1998", area: "美国", actor: "金·凯瑞, 劳拉·琳妮", doubanScore: 9.4),
                CmsVideo(id: "curated:db:7", title: "海上钢琴师", remarks: "豆瓣 9.3", year: "1998", area: "意大利", actor: "蒂姆·罗斯, 普路特·泰勒·文斯", doubanScore: 9.3),
                CmsVideo(id: "curated:db:8", title: "让子弹飞", remarks: "豆瓣 9.0", year: "2010", area: "中国大陆", actor: "姜文, 葛优, 周润发", doubanScore: 9.0),
            ]
        ),
        CuratedModuleSpec(
            id: "rotten_tomatoes",
            title: "烂番茄新鲜认证",
            subtitle: "海外影评高分口碑榜单",
            badgeText: "RT",
            accentHex: 0xFA320A,
            liveUrlString: "https://m.douban.com/rexxar/api/v2/subject_collection/movie_score/items?start=0&count=16",
            referer: "https://m.douban.com/movie/",
            wave: 1,
            seedItems: [
                CmsVideo(id: "curated:rt:1", title: "沙丘2", remarks: "新鲜度 92%", year: "2024", area: "美国", actor: "提莫西·查拉梅, 赞达亚", doubanScore: 8.2, rtScore: 92),
                CmsVideo(id: "curated:rt:2", title: "奥本海默", remarks: "新鲜度 93%", year: "2023", area: "美国", actor: "基里安·墨菲, 艾米莉·布朗特", doubanScore: 8.8, rtScore: 93),
                CmsVideo(id: "curated:rt:3", title: "蜘蛛侠：纵横宇宙", remarks: "新鲜度 95%", year: "2023", area: "美国", actor: "沙梅克·摩尔, 海莉·斯坦菲尔德", doubanScore: 8.5, rtScore: 95),
                CmsVideo(id: "curated:rt:4", title: "瞬息全宇宙", remarks: "新鲜度 94%", year: "2022", area: "美国", actor: "杨紫琼, 关继威", doubanScore: 7.7, rtScore: 94),
                CmsVideo(id: "curated:rt:5", title: "寄生虫", remarks: "新鲜度 99%", year: "2019", area: "韩国", actor: "宋康昊, 李善均", doubanScore: 8.8, rtScore: 99),
                CmsVideo(id: "curated:rt:6", title: "疯狂的麦克斯4：狂暴之路", remarks: "新鲜度 97%", year: "2015", area: "澳大利亚", actor: "汤姆·哈迪, 查理兹·塞隆", doubanScore: 8.7, rtScore: 97),
                CmsVideo(id: "curated:rt:7", title: "荒野机器人", remarks: "新鲜度 98%", year: "2024", area: "美国", actor: "露皮塔·尼永奥, 佩德罗·帕斯卡", doubanScore: 8.0, rtScore: 98),
                CmsVideo(id: "curated:rt:8", title: "壮志凌云2：独行侠", remarks: "新鲜度 96%", year: "2022", area: "美国", actor: "汤姆·克鲁斯, 迈尔斯·特勒", doubanScore: 8.0, rtScore: 96),
            ]
        ),
        CuratedModuleSpec(
            id: "cn_variety",
            title: "近一月 · 热门综艺",
            subtitle: "真人秀与热门口碑综艺合集",
            badgeText: "综艺",
            accentHex: 0xBF5AF2,
            liveUrlString: "https://m.douban.com/rexxar/api/v2/subject_collection/show_domestic/items?start=0&count=16",
            referer: "https://m.douban.com/tv/variety",
            wave: 2,
            seedItems: [
                CmsVideo(id: "curated:vr:1", title: "现在就出发", remarks: "真人秀", year: "2024", area: "中国大陆", actor: "沈腾, 白敬亭, 金晨", doubanScore: 8.3),
                CmsVideo(id: "curated:vr:2", title: "你好，星期六", remarks: "真人秀", year: "2022", area: "中国大陆", actor: "何炅, 檀健次, 丁程鑫", doubanScore: 7.4),
                CmsVideo(id: "curated:vr:3", title: "毛雪汪", remarks: "真人秀", year: "2021", area: "中国大陆", actor: "毛不易, 李雪琴", doubanScore: 8.6),
                CmsVideo(id: "curated:vr:4", title: "花儿与少年·丝路季", remarks: "旅行 / 真人秀", year: "2023", area: "中国大陆", actor: "秦海璐, 秦岚, 辛芷蕾, 迪丽热巴", doubanScore: 9.2),
                CmsVideo(id: "curated:vr:5", title: "喜人奇妙夜", remarks: "喜剧 / 竞演", year: "2024", area: "中国大陆", actor: "马东, 黄渤, 秦昊", doubanScore: 8.0),
                CmsVideo(id: "curated:vr:6", title: "种地吧", remarks: "真人秀", year: "2023", area: "中国大陆", actor: "蒋敦豪, 鹭卓, 李耕耘", doubanScore: 9.0),
                CmsVideo(id: "curated:vr:7", title: "大侦探", remarks: "悬疑 / 推理", year: "2024", area: "中国大陆", actor: "何炅, 张若昀, 大张伟", doubanScore: 8.4),
                CmsVideo(id: "curated:vr:8", title: "歌手2024", remarks: "音乐 / 竞演", year: "2024", area: "中国大陆", actor: "那英, 凡希亚, 香缇莫", doubanScore: 7.2),
            ]
        ),
        CuratedModuleSpec(
            id: "disney",
            title: "迪士尼 · 皮克斯",
            subtitle: "奇幻动画与合家欢经典",
            badgeText: "Disney",
            accentHex: 0x1D6BFF,
            liveUrlString: "https://movie.douban.com/j/new_search_subjects?sort=U&range=7,10&tags=%E8%BF%AA%E5%A3%AB%E5%B0%BC&start=0&limit=16",
            referer: "https://movie.douban.com/",
            wave: 2,
            seedItems: [
                CmsVideo(id: "curated:ds:1", title: "疯狂动物城", remarks: "豆瓣 9.2", year: "2016", area: "美国", actor: "金妮弗·古德温, 杰森·贝特曼", doubanScore: 9.2),
                CmsVideo(id: "curated:ds:2", title: "寻梦环游记", remarks: "豆瓣 9.1", year: "2017", area: "美国", actor: "安东尼·冈萨雷斯, 盖尔·加西亚·贝纳尔", doubanScore: 9.1),
                CmsVideo(id: "curated:ds:3", title: "头脑特工队2", remarks: "豆瓣 8.4", year: "2024", area: "美国", actor: "艾米·波勒, 玛雅·霍克", doubanScore: 8.4),
                CmsVideo(id: "curated:ds:4", title: "机器人总动员", remarks: "豆瓣 9.3", year: "2008", area: "美国", actor: "本·贝尔特, 艾丽莎·奈特", doubanScore: 9.3),
                CmsVideo(id: "curated:ds:5", title: "心灵奇旅", remarks: "豆瓣 8.7", year: "2020", area: "美国", actor: "杰米·福克斯, 蒂娜·菲", doubanScore: 8.7),
                CmsVideo(id: "curated:ds:6", title: "冰雪奇缘", remarks: "豆瓣 8.5", year: "2013", area: "美国", actor: "克里斯汀·贝尔, 伊迪娜·门泽尔", doubanScore: 8.5),
                CmsVideo(id: "curated:ds:7", title: "飞屋环游记", remarks: "豆瓣 9.1", year: "2009", area: "美国", actor: "爱德华·阿斯纳, 克里斯托弗·普卢默", doubanScore: 9.1),
                CmsVideo(id: "curated:ds:8", title: "加勒比海盗", remarks: "豆瓣 8.8", year: "2003", area: "美国", actor: "约翰尼·德普, 杰弗里·拉什", doubanScore: 8.8),
            ]
        ),
        CuratedModuleSpec(
            id: "marvel",
            title: "漫威宇宙",
            subtitle: "Marvel 超级英雄电影与剧集",
            badgeText: "MARVEL",
            accentHex: 0xE62429,
            liveUrlString: "https://movie.douban.com/j/new_search_subjects?sort=U&range=6,10&tags=%E6%BC%AB%E5%A8%81&start=0&limit=16",
            referer: "https://movie.douban.com/",
            wave: 2,
            seedItems: [
                CmsVideo(id: "curated:mv:1", title: "复仇者联盟4：终局之战", remarks: "豆瓣 8.5", year: "2019", area: "美国", actor: "小罗伯特·唐尼, 克里斯·埃文斯", doubanScore: 8.5),
                CmsVideo(id: "curated:mv:2", title: "复仇者联盟3：无限战争", remarks: "豆瓣 8.1", year: "2018", area: "美国", actor: "小罗伯特·唐尼, 乔什·布洛林", doubanScore: 8.1),
                CmsVideo(id: "curated:mv:3", title: "钢铁侠", remarks: "豆瓣 8.4", year: "2008", area: "美国", actor: "小罗伯特·唐尼, 格温妮斯·帕特洛", doubanScore: 8.4),
                CmsVideo(id: "curated:mv:4", title: "银河护卫队3", remarks: "豆瓣 8.4", year: "2023", area: "美国", actor: "克里斯·帕拉特, 佐伊·索尔达娜", doubanScore: 8.4),
                CmsVideo(id: "curated:mv:5", title: "洛基 第一季", remarks: "豆瓣 8.5", year: "2021", area: "美国", actor: "汤姆·希德勒斯顿, 欧文·威尔逊", doubanScore: 8.5),
                CmsVideo(id: "curated:mv:6", title: "美国队长2", remarks: "豆瓣 8.0", year: "2014", area: "美国", actor: "克里斯·埃文斯, 斯嘉丽·约翰逊", doubanScore: 8.0),
                CmsVideo(id: "curated:mv:7", title: "死侍与金刚狼", remarks: "豆瓣 7.0", year: "2024", area: "美国", actor: "瑞安·雷诺兹, 休·杰克曼", doubanScore: 7.0),
                CmsVideo(id: "curated:mv:8", title: "蜘蛛侠：英雄无归", remarks: "豆瓣 6.6", year: "2021", area: "美国", actor: "汤姆·赫兰德, 赞达亚", doubanScore: 6.6),
            ]
        ),
        CuratedModuleSpec(
            id: "dc",
            title: "DC 宇宙",
            subtitle: "哥谭暗黑史诗与正义联盟",
            badgeText: "DC",
            accentHex: 0x0476F2,
            liveUrlString: "https://movie.douban.com/j/new_search_subjects?sort=U&range=6,10&tags=DC&start=0&limit=16",
            referer: "https://movie.douban.com/",
            wave: 2,
            seedItems: [
                CmsVideo(id: "curated:dc:1", title: "蝙蝠侠：黑暗骑士", remarks: "豆瓣 9.2", year: "2008", area: "美国", actor: "克里斯蒂安·贝尔, 希斯·莱杰", doubanScore: 9.2),
                CmsVideo(id: "curated:dc:2", title: "小丑", remarks: "豆瓣 8.7", year: "2019", area: "美国", actor: "华金·菲尼克斯, 罗伯特·德尼罗", doubanScore: 8.7),
                CmsVideo(id: "curated:dc:3", title: "新蝙蝠侠", remarks: "豆瓣 7.2", year: "2022", area: "美国", actor: "罗伯特·帕丁森, 佐伊·克罗维兹", doubanScore: 7.2),
                CmsVideo(id: "curated:dc:4", title: "企鹅人", remarks: "豆瓣 8.7", year: "2024", area: "美国", actor: "科林·法瑞尔, 克里斯汀·米利欧缇", doubanScore: 8.7),
                CmsVideo(id: "curated:dc:5", title: "守望者", remarks: "豆瓣 8.6", year: "2009", area: "美国", actor: "杰基·厄尔·哈利, 帕特里克·威尔森", doubanScore: 8.6),
                CmsVideo(id: "curated:dc:6", title: "扎克·施奈德版正义联盟", remarks: "豆瓣 8.2", year: "2021", area: "美国", actor: "本·阿弗莱克, 亨利·卡维尔", doubanScore: 8.2),
                CmsVideo(id: "curated:dc:7", title: "海王", remarks: "豆瓣 7.6", year: "2018", area: "美国", actor: "杰森·莫玛, 艾梅柏·希尔德", doubanScore: 7.6),
                CmsVideo(id: "curated:dc:8", title: "V字仇杀队", remarks: "豆瓣 8.9", year: "2005", area: "美国", actor: "娜塔莉·波特曼, 雨果·维文", doubanScore: 8.9),
            ]
        ),
    ]

    public static var wave1Modules: [CuratedModuleSpec] {
        modules.filter { $0.wave == 1 }
    }

    public static var wave2Modules: [CuratedModuleSpec] {
        modules.filter { $0.wave == 2 }
    }

    // MARK: - Existing Public Catalog Builder (Preserved)

    public static func buildModules(
        from videos: [CmsVideo],
        preferences: PlaybackPreferences,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> [CuratedModule] {
        guard preferences.showCuratedDiscovery, !videos.isEmpty else { return [] }
        let hidden = Set(preferences.homeSectionHidden)
        let deduped = deduplicate(videos)

        let highRated = deduped
            .filter { ($0.doubanScore ?? 0) >= 7.5 }
            .sorted { ($0.doubanScore ?? 0) > ($1.doubanScore ?? 0) }
        let recentYear = deduped.filter {
            let y = Int($0.year.prefix(4)) ?? 0
            return y >= 2024
        }
        let seriesItems = deduped.filter {
            $0.remarks.contains("集") || $0.remarks.contains("更新") || $0.tag.contains("剧")
        }
        let movieItems = deduped.filter {
            !$0.remarks.contains("集") && !$0.remarks.contains("更新")
        }

        var moduleById: [String: CuratedModule] = [:]

        if !hidden.contains("disc_widescreen_radar") {
            let items = Array((recentYear.isEmpty ? deduped : recentYear).prefix(10))
            if !items.isEmpty {
                moduleById["disc_widescreen_radar"] = CuratedModule(
                    id: "disc_widescreen_radar",
                    title: "新片雷达",
                    subtitle: "近期热映与新上架高分片单",
                    layout: "widescreen_carousel",
                    items: items,
                    updatedAt: nowMs
                )
            }
        }

        if !hidden.contains("disc_editorial_picks") {
            let items = Array((highRated.isEmpty ? deduped.dropFirst(min(4, deduped.count)) : highRated).prefix(12))
            if !items.isEmpty {
                moduleById["disc_editorial_picks"] = CuratedModule(
                    id: "disc_editorial_picks",
                    title: "口碑严选",
                    subtitle: "高评分佳片与必看经典",
                    layout: "editorial_cards",
                    items: items,
                    updatedAt: nowMs
                )
            }
        }

        if !hidden.contains("disc_hot_stream") {
            let items = Array((seriesItems.isEmpty ? deduped : seriesItems).prefix(12))
            if !items.isEmpty {
                moduleById["disc_hot_stream"] = CuratedModule(
                    id: "disc_hot_stream",
                    title: "热播追更",
                    subtitle: "连载剧集与热门番剧同步更新",
                    layout: "poster_row",
                    items: items,
                    updatedAt: nowMs
                )
            }
        }

        if !hidden.contains("disc_poster_mosaics") {
            let items = Array((movieItems.isEmpty ? deduped : movieItems).prefix(15))
            if !items.isEmpty {
                moduleById["disc_poster_mosaics"] = CuratedModule(
                    id: "disc_poster_mosaics",
                    title: "影院精选",
                    subtitle: "按片源实时聚合的高清影片",
                    layout: "poster_grid",
                    items: items,
                    updatedAt: nowMs
                )
            }
        }

        var ordered: [CuratedModule] = []
        for secId in preferences.homeSectionOrder {
            if let mod = moduleById.removeValue(forKey: secId) {
                ordered.append(mod)
            }
        }
        for (_, mod) in moduleById.sorted(by: { $0.key < $1.key }) {
            ordered.append(mod)
        }
        return ordered
    }

    // MARK: - In-Memory Cache & Disk Snapshot

    public static func resetCache() {
        state.reset()
    }

    public static func backdropFor(_ video: CmsVideo) -> String {
        state.lock.lock()
        let hit = state.backdropById[video.id]
        state.lock.unlock()
        if let hit = hit, !hit.isEmpty {
            return hit
        }
        return video.poster
    }

    public static func genreFor(_ video: CmsVideo) -> String {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.genreById[video.id] ?? ""
    }

    public static func peekModule(_ spec: CuratedModuleSpec) -> [CmsVideo] {
        state.lock.lock()
        let hit = state.cache[spec.id]
        state.lock.unlock()
        if let hit = hit, !hit.items.isEmpty {
            return hit.items
        }
        return spec.seedItems
    }

    public static func peekModule(id: String) -> [CmsVideo] {
        guard let spec = modules.first(where: { $0.id == id }) else { return [] }
        return peekModule(spec)
    }

    public static func offlineFallbackModules(
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> [CuratedModule] {
        modules.map { spec in
            CuratedModule(
                id: spec.id,
                title: spec.title,
                subtitle: spec.subtitle,
                layout: spec.id == "weekly_trending" ? "widescreen_carousel" : "poster_row",
                items: spec.seedItems,
                updatedAt: nowMs
            )
        }
    }

    public static func defaultSnapshotFileURL(directory: URL? = nil) -> URL {
        let baseDir: URL
        if let custom = directory {
            baseDir = custom
        } else {
            baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        }
        return baseDir.appendingPathComponent(snapshotFileName)
    }

    @discardableResult
    public static func warmFromDisk(snapshotDirectory: URL? = nil) -> Bool {
        if snapshotDirectory == nil {
            state.lock.lock()
            let already = state.diskWarmed
            let hasAny = !state.cache.isEmpty
            state.lock.unlock()
            if already { return hasAny }
        }

        let fileUrl = defaultSnapshotFileURL(directory: snapshotDirectory)
        guard FileManager.default.fileExists(atPath: fileUrl.path),
              let data = try? Data(contentsOf: fileUrl),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            if snapshotDirectory == nil {
                state.lock.lock()
                state.diskWarmed = true
                state.lock.unlock()
            }
            return false
        }

        var restoredAny = false
        state.lock.lock()
        defer {
            if snapshotDirectory == nil {
                state.diskWarmed = true
            }
            state.lock.unlock()
        }

        if let backdrops = root["backdrops"] as? [String: Any] {
            for (k, v) in backdrops {
                let val = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !k.isEmpty && !val.isEmpty && state.backdropById[k] == nil {
                    state.backdropById[k] = val
                }
            }
        }
        if let genres = root["genres"] as? [String: Any] {
            for (k, v) in genres {
                let val = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !k.isEmpty && !val.isEmpty && state.genreById[k] == nil {
                    state.genreById[k] = val
                }
            }
        }
        if let modulesMap = root["modules"] as? [String: Any] {
            for spec in modules {
                if state.cache[spec.id] != nil { continue }
                guard let entry = modulesMap[spec.id] as? [String: Any],
                      let rawItems = entry["items"] as? [[String: Any]]
                else { continue }
                let items = rawItems.compactMap { videoFromSnapshotDict($0) }.filter { !$0.title.isEmpty }
                if !items.isEmpty {
                    let savedMs = (entry["savedAtMs"] as? NSNumber)?.int64Value ?? 0
                    let fetchedAt = savedMs > 0
                        ? Date(timeIntervalSince1970: TimeInterval(savedMs) / 1000.0)
                        : Date(timeIntervalSince1970: 0)
                    state.cache[spec.id] = CuratedDiscoveryStateBox.CachedEntry(fetchedAt: fetchedAt, items: items)
                    restoredAny = true
                }
            }
        }
        return restoredAny
    }

    @discardableResult
    public static func saveToDisk(snapshotDirectory: URL? = nil) -> Bool {
        state.lock.lock()
        var modulesPayload: [String: Any] = [:]
        for (modId, entry) in state.cache where !entry.items.isEmpty {
            modulesPayload[modId] = [
                "savedAtMs": Int64(entry.fetchedAt.timeIntervalSince1970 * 1000),
                "items": entry.items.map { videoToSnapshotDict($0) },
            ]
        }
        let backdrops = state.backdropById
        let genres = state.genreById
        state.lock.unlock()

        guard !modulesPayload.isEmpty else { return false }
        let fileUrl = defaultSnapshotFileURL(directory: snapshotDirectory)
        let root: [String: Any] = [
            "v": 1,
            "modules": modulesPayload,
            "backdrops": backdrops,
            "genres": genres,
        ]
        do {
            try FileManager.default.createDirectory(
                at: fileUrl.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            try data.write(to: fileUrl, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    // MARK: - Live Douban Metadata Fetchers (Wave 1 + Wave 2)

    public static func fetchModule(
        _ spec: CuratedModuleSpec,
        forceRefresh: Bool = false,
        session: URLSession? = nil,
        snapshotDirectory: URL? = nil,
        now: Date = Date(),
        liveFetcher: (@Sendable (CuratedModuleSpec) async throws -> [CmsVideo]?)? = nil
    ) async -> [CmsVideo] {
        if !forceRefresh {
            state.lock.lock()
            let hit = state.cache[spec.id]
            state.lock.unlock()
            if let hit = hit, !hit.items.isEmpty, now.timeIntervalSince(hit.fetchedAt) < cacheTtlSeconds {
                return hit.items
            }
        }

        let liveItems: [CmsVideo]?
        if let customFetcher = liveFetcher {
            liveItems = try? await customFetcher(spec)
        } else {
            liveItems = await fetchLiveDoubanModule(spec, session: session)
        }

        if let items = liveItems, !items.isEmpty {
            state.lock.lock()
            state.cache[spec.id] = CuratedDiscoveryStateBox.CachedEntry(fetchedAt: now, items: items)
            state.lock.unlock()
            if items.contains(where: { !$0.poster.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                _ = saveToDisk(snapshotDirectory: snapshotDirectory)
            }
            return items
        }

        state.lock.lock()
        let preserved = state.cache[spec.id]
        state.lock.unlock()
        if let preserved = preserved, !preserved.items.isEmpty {
            return preserved.items
        }
        return spec.seedItems
    }

    /// Fetches all 8 Douban curated discovery modules in two parallel waves:
    /// Wave 1 (`weekly_trending`, `cn_hot`, `douban_top`, `rotten_tomatoes`), then
    /// Wave 2 (`cn_variety`, `disney`, `marvel`, `dc`), falling back seamlessly to disk cache or
    /// metadata-only offline seeds whenever offline or rate-limited.
    public static func refreshAllModules(
        forceRefresh: Bool = false,
        session: URLSession? = nil,
        snapshotDirectory: URL? = nil,
        now: Date = Date(),
        liveFetcher: (@Sendable (CuratedModuleSpec) async throws -> [CmsVideo]?)? = nil,
        onWaveCompleted: (@Sendable (Int, [CuratedModule]) -> Void)? = nil
    ) async -> [CuratedModule] {
        _ = warmFromDisk(snapshotDirectory: snapshotDirectory)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        func runWave(_ specs: [CuratedModuleSpec]) async -> [String: CuratedModule] {
            await withTaskGroup(of: (String, CuratedModule).self) { group in
                for spec in specs {
                    group.addTask {
                        let items = await fetchModule(
                            spec,
                            forceRefresh: forceRefresh,
                            session: session,
                            snapshotDirectory: snapshotDirectory,
                            now: now,
                            liveFetcher: liveFetcher
                        )
                        let mod = CuratedModule(
                            id: spec.id,
                            title: spec.title,
                            subtitle: spec.subtitle,
                            layout: spec.id == "weekly_trending" ? "widescreen_carousel" : "poster_row",
                            items: items,
                            updatedAt: nowMs
                        )
                        return (spec.id, mod)
                    }
                }
                var out: [String: CuratedModule] = [:]
                for await (id, mod) in group {
                    out[id] = mod
                }
                return out
            }
        }

        let wave1Results = await runWave(wave1Modules)
        let orderedWave1 = wave1Modules.compactMap { wave1Results[$0.id] }
        onWaveCompleted?(1, orderedWave1)

        let wave2Results = await runWave(wave2Modules)
        let orderedWave2 = wave2Modules.compactMap { wave2Results[$0.id] }
        onWaveCompleted?(2, orderedWave2)

        let allMap = wave1Results.merging(wave2Results) { current, _ in current }
        return modules.compactMap { allMap[$0.id] }
    }

    private static func fetchLiveDoubanModule(
        _ spec: CuratedModuleSpec,
        session: URLSession?
    ) async -> [CmsVideo]? {
        guard let url = URL(string: spec.liveUrlString) else { return nil }
        let activeSession: URLSession = session ?? {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 6
            cfg.timeoutIntervalForResource = 8
            cfg.httpShouldSetCookies = false
            return URLSession(configuration: cfg)
        }()

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        req.httpMethod = "GET"
        req.setValue(mobileUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(spec.referer, forHTTPHeaderField: "Referer")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, resp) = try? await activeSession.marcoData(for: req),
              let http = resp as? HTTPURLResponse,
              http.statusCode == 200
        else {
            return nil
        }
        let parsed = parseDoubanDiscoveryJson(data, moduleId: spec.id)
        return parsed.isEmpty ? nil : parsed
    }

    /// Parses both Douban Rexxar (`subject_collection_items`) and `new_search_subjects` (`data`)
    /// JSON payloads into metadata-only `CmsVideo` entries and upgrades `/s_ratio_poster/` to `/m_ratio_poster/`.
    public static func parseDoubanDiscoveryJson(_ jsonData: Data, moduleId: String) -> [CmsVideo] {
        guard let decoded = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any],
              let rawList = (decoded["subject_collection_items"] ?? decoded["data"]) as? [[String: Any]]
        else {
            return []
        }

        var out: [CmsVideo] = []
        var seen = Set<String>()
        var newBackdrops: [String: String] = [:]
        var newGenres: [String: String] = [:]

        for raw in rawList {
            let title = ((raw["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, seen.insert(title).inserted else { continue }
            let id = stringValue(raw["id"])

            var poster = ""
            if let pic = raw["pic"] as? [String: Any] {
                poster = (stringValue(pic["large"]).isEmpty ? stringValue(pic["normal"]) : stringValue(pic["large"]))
            }
            if poster.isEmpty {
                if let cover = raw["cover"] as? [String: Any] {
                    poster = stringValue(cover["url"])
                } else {
                    poster = stringValue(raw["cover"])
                }
            }
            if poster.contains("/s_ratio_poster/") {
                poster = poster.replacingOccurrences(of: "/s_ratio_poster/", with: "/m_ratio_poster/")
            }

            var backdrop = ""
            if let photos = raw["photos"] as? [Any] {
                for entry in photos {
                    let u: String
                    if let s = entry as? String {
                        u = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if let m = entry as? [String: Any] {
                        u = stringValue(m["url"])
                    } else {
                        u = ""
                    }
                    if !u.isEmpty {
                        backdrop = u
                        break
                    }
                }
            }

            var score: Double?
            if let rating = raw["rating"] as? [String: Any],
               let num = rating["value"] as? NSNumber,
               num.doubleValue > 0
            {
                score = num.doubleValue
            } else if let rateVal = Double(stringValue(raw["rate"])), rateVal > 0 {
                score = rateVal
            }

            let year = stringValue(raw["year"])
            let cardSub = stringValue(raw["card_subtitle"])
            var parsedArea = ""
            var parsedGenre = ""
            if !cardSub.isEmpty {
                let subParts = cardSub
                    .components(separatedBy: "/")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if subParts.count >= 2 { parsedArea = subParts[1] }
                if subParts.count >= 3 {
                    let tokens = subParts[2]
                        .components(separatedBy: CharacterSet.whitespacesAndNewlines)
                        .filter { !$0.isEmpty }
                    parsedGenre = tokens.prefix(2).joined(separator: " / ")
                }
            }

            let actorsRaw = (raw["actors"] ?? raw["casts"]) as? [Any] ?? []
            let actor = actorsRaw
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")

            let remarks: String
            if let s = score {
                remarks = String(format: "豆瓣 %.1f", s)
            } else if !parsedGenre.isEmpty {
                remarks = parsedGenre
            } else {
                remarks = year
            }

            let videoId = !id.isEmpty ? "curated:\(moduleId):\(id)" : "curated:\(moduleId):\(out.count)"
            if !backdrop.isEmpty { newBackdrops[videoId] = backdrop }
            if !parsedGenre.isEmpty { newGenres[videoId] = parsedGenre }

            out.append(
                CmsVideo(
                    id: videoId,
                    title: title,
                    poster: poster,
                    remarks: remarks,
                    year: year,
                    area: parsedArea,
                    actor: actor,
                    description: cardSub,
                    doubanScore: score
                )
            )
            if out.count >= 16 { break }
        }

        if !newBackdrops.isEmpty || !newGenres.isEmpty {
            state.lock.lock()
            for (k, v) in newBackdrops { state.backdropById[k] = v }
            for (k, v) in newGenres { state.genreById[k] = v }
            state.lock.unlock()
        }
        return out
    }

    // MARK: - Title Fuzzy Matching Helpers

    private static let bracketQualityRegex = try! NSRegularExpression(
        pattern: #"[\(\[（【].*?(?:4k|hdr|臻彩|杜比|蓝光|国语|粤语|中字|未删减|完整版|高清|hd|1080p|2160p|抢先|tc|ts).*?[\)\]）】]"#,
        options: [.caseInsensitive]
    )
    private static let punctuationStripRegex = try! NSRegularExpression(
        pattern: #"[\s:：·\-—_,.，。!！?？《》「」]+"#,
        options: []
    )

    public static func normalizeMatchKey(_ title: String) -> String {
        var s = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return "" }
        s = bracketQualityRegex.stringByReplacingMatches(
            in: s,
            range: NSRange(s.startIndex..., in: s),
            withTemplate: ""
        )
        s = punctuationStripRegex.stringByReplacingMatches(
            in: s,
            range: NSRange(s.startIndex..., in: s),
            withTemplate: ""
        )
        return s
    }

    public static func titleMatchScore(targetTitle: String, candidateTitle: String) -> Int {
        let a = normalizeMatchKey(targetTitle)
        let b = normalizeMatchKey(candidateTitle)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 100 }
        if b.hasPrefix(a) || a.hasPrefix(b) { return 80 }
        if b.contains(a) || a.contains(b) { return 60 }
        return 0
    }

    // MARK: - Private Helpers

    private static func deduplicate(_ videos: [CmsVideo]) -> [CmsVideo] {
        var seen = Set<String>()
        var out: [CmsVideo] = []
        for v in videos {
            let key = v.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(v)
        }
        return out
    }

    private static func stringValue(_ raw: Any?) -> String {
        guard let raw = raw, !(raw is NSNull) else { return "" }
        if let s = raw as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = raw as? NSNumber { return n.stringValue }
        return ""
    }

    private static func videoToSnapshotDict(_ v: CmsVideo) -> [String: Any] {
        var out: [String: Any] = [
            "id": v.id,
            "title": v.title,
        ]
        if !v.poster.isEmpty { out["poster"] = v.poster }
        if !v.remarks.isEmpty { out["remarks"] = v.remarks }
        if !v.year.isEmpty { out["year"] = v.year }
        if !v.area.isEmpty { out["area"] = v.area }
        if !v.actor.isEmpty { out["actor"] = v.actor }
        if !v.description.isEmpty { out["description"] = v.description }
        if !v.tag.isEmpty { out["tag"] = v.tag }
        if let score = v.doubanScore { out["doubanScore"] = score }
        if let rt = v.rtScore { out["rtScore"] = rt }
        return out
    }

    private static func videoFromSnapshotDict(_ dict: [String: Any]) -> CmsVideo? {
        let title = stringValue(dict["title"])
        guard !title.isEmpty else { return nil }
        return CmsVideo(
            id: stringValue(dict["id"]),
            title: title,
            poster: stringValue(dict["poster"]),
            remarks: stringValue(dict["remarks"]),
            year: stringValue(dict["year"]),
            area: stringValue(dict["area"]),
            actor: stringValue(dict["actor"]),
            description: stringValue(dict["description"]),
            tag: stringValue(dict["tag"]),
            doubanScore: (dict["doubanScore"] as? NSNumber)?.doubleValue,
            rtScore: (dict["rtScore"] as? NSNumber)?.intValue
        )
    }
}
