// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Deterministic Simulator Verification Hook & Synthetic Studio Demo Fixtures

import Foundation
import MarcoIOSCore
import UIKit

/// Synthetic, 100% offline, zero-external-URL cinema fixtures for deterministic CI Simulator UI
/// verification across iPhone, iPad Portrait, and iPad Landscape.
public enum SimulatorDemoFixtures {
    public static let demoSite = CmsSite(
        key: "sim_studio_cinema",
        rawKey: "sim_studio_cinema",
        name: "极光演示片源",
        type: 1,
        api: "",
        searchable: true,
        categories: ["精选电影", "科幻剧集", "口碑纪录片", "高分动画"],
        group: "演示分组",
        isPrivate: false,
        subscriptionId: "sim_demo"
    )

    public static let demoSiteAlt = CmsSite(
        key: "sim_4k_vault",
        rawKey: "sim_4k_vault",
        name: "杜比 4K 演示库",
        type: 1,
        api: "",
        searchable: true,
        categories: ["4K 原盘", "院线新片"],
        group: "演示分组",
        isPrivate: false,
        subscriptionId: "sim_demo"
    )

    public static let sites: [CmsSite] = [demoSite, demoSiteAlt]

    public static let categories: [CmsCategory] = [
        CmsCategory(id: "all", name: "全部推荐"),
        CmsCategory(id: "movie", name: "精选电影"),
        CmsCategory(id: "series", name: "科幻剧集"),
        CmsCategory(id: "doc", name: "口碑纪录片"),
        CmsCategory(id: "anime", name: "高分动画"),
    ]

    public static let featuredVideo: CmsVideo = CmsVideo(
        id: "demo_stellar_horizon",
        title: "星际地平线：远航纪元",
        poster: "",
        remarks: "4K HDR · 更新至第10集",
        year: "2026",
        area: "国际合拍",
        actor: "林致远 / 苏念 / 陈墨 / 陆景行",
        director: "沈知微",
        description: "在深空引力波信号被首次破译的三十年后，远航舰队穿越柯伊伯带边缘，在未知星域中寻找人类文明的第二座灯塔。全片采用宽银幕影院级调色与杜比全景声制作。",
        tag: "科幻 / 冒险 / 剧集",
        doubanScore: 9.1,
        rtScore: 95,
        lines: [
            CmsLine(
                id: "demo_line_4k",
                name: "4K HDR 原画直出",
                episodes: (1...10).map { ep in
                    CmsEpisode(
                        name: "第\(String(format: "%02d", ep))集",
                        url: "demo://stellar-horizon/4k/ep-\(ep).m3u8"
                    )
                }
            ),
            CmsLine(
                id: "demo_line_1080",
                name: "1080P 极速线路",
                episodes: (1...10).map { ep in
                    CmsEpisode(
                        name: "第\(String(format: "%02d", ep))集",
                        url: "demo://stellar-horizon/1080p/ep-\(ep).m3u8"
                    )
                }
            ),
        ]
    )

    public static let videos: [CmsVideo] = [
        featuredVideo,
        CmsVideo(
            id: "demo_midnight_harbor",
            title: "午夜港湾",
            poster: "",
            remarks: "4K 杜比视界",
            year: "2025",
            area: "中国香港",
            actor: "梁明轩 / 程若琳",
            director: "许安宁",
            description: "台风登陆前的维多利亚港夜色中，一卷遗失二十年的胶片将两位素未谋面的电影修复师带入尘封往事。",
            tag: "悬疑 / 剧情",
            doubanScore: 8.8,
            lines: [
                CmsLine(name: "4K 原画", episodes: [CmsEpisode(name: "正片 4K", url: "demo://midnight-harbor/main.m3u8")]),
            ]
        ),
        CmsVideo(
            id: "demo_nordic_wind",
            title: "北境之风",
            poster: "",
            remarks: "全8集 · 完结",
            year: "2026",
            area: "北欧",
            actor: "艾琳·索伦森 / 卢卡斯",
            director: "安德斯·林德",
            description: "极夜降临的冰川观测站里，气象学家记录下史无前例的大气潮汐与极光交响。",
            tag: "科幻 / 剧集",
            doubanScore: 8.6,
            lines: [
                CmsLine(
                    name: "蓝光高清",
                    episodes: (1...8).map { CmsEpisode(name: "第\($0)集", url: "demo://nordic-wind/ep\($0).m3u8") }
                ),
            ]
        ),
        CmsVideo(
            id: "demo_silent_atelier",
            title: "静谧画室",
            poster: "",
            remarks: "HDR10+",
            year: "2025",
            area: "日本",
            actor: "佐佐木晴 / 高桥悠",
            director: "森田光",
            description: "京都古巷中的独立动画工作室，用四年手绘时光记录四季交替与青春告别。",
            tag: "动画 / 治愈",
            doubanScore: 9.0,
            lines: [
                CmsLine(name: "原画线路", episodes: [CmsEpisode(name: "剧场版", url: "demo://silent-atelier/movie.m3u8")]),
            ]
        ),
        CmsVideo(
            id: "demo_deep_ocean_pulse",
            title: "深海脉动",
            poster: "",
            remarks: "4K 60fps · 全6集",
            year: "2026",
            area: "英国",
            actor: "自然纪录片",
            director: "戴维·克拉克",
            description: "深入马里亚纳海沟热液喷口与南极冰架之下，以微光摄影捕捉地球最后的未知疆域。",
            tag: "纪录片 / 自然",
            doubanScore: 9.4,
            lines: [
                CmsLine(
                    name: "4K 纪录片",
                    episodes: (1...6).map { CmsEpisode(name: "第\($0)集", url: "demo://deep-ocean/ep\($0).m3u8") }
                ),
            ]
        ),
        CmsVideo(
            id: "demo_amber_express",
            title: "琥珀快车",
            poster: "",
            remarks: "杜比全景声",
            year: "2024",
            area: "法国",
            actor: "克莱尔 / 朱利安",
            director: "马修·杜邦",
            description: "横贯欧亚大陆的冬季观光列车上，一封没有署名的信件串联起七节车厢里的秘密。",
            tag: "悬疑 / 电影",
            doubanScore: 8.4,
            lines: [
                CmsLine(name: "蓝光直连", episodes: [CmsEpisode(name: "正片", url: "demo://amber-express/main.m3u8")]),
            ]
        ),
        CmsVideo(
            id: "demo_cloud_symphony",
            title: "云端交响曲",
            poster: "",
            remarks: "更新至第16集",
            year: "2026",
            area: "中国大陆",
            actor: "周以恒 / 林晓星",
            director: "方景云",
            description: "青年声学工程师与交响乐团指挥共同打造沉浸式声场音乐厅的追梦篇章。",
            tag: "都市 / 音乐 / 剧集",
            doubanScore: 8.3,
            lines: [
                CmsLine(
                    name: "高清专线",
                    episodes: (1...16).map { CmsEpisode(name: "第\($0)集", url: "demo://cloud-symphony/ep\($0).m3u8") }
                ),
            ]
        ),
        CmsVideo(
            id: "demo_sand_citadel",
            title: "沙丘之城",
            poster: "",
            remarks: "IMAX 增强",
            year: "2025",
            area: "美国",
            actor: "伊森·霍克 / 玛雅",
            director: "丹尼斯·瓦伦",
            description: "荒漠绿洲上的太阳能城邦面临沙暴危机，年轻建筑师重启古老地下引水工程。",
            tag: "科幻 / 史诗",
            doubanScore: 8.9,
            lines: [
                CmsLine(name: "IMAX 4K", episodes: [CmsEpisode(name: "IMAX 正片", url: "demo://sand-citadel/main.m3u8")]),
            ]
        ),
        CmsVideo(
            id: "demo_glass_garden",
            title: "琉璃庭院",
            poster: "",
            remarks: "全12集",
            year: "2025",
            area: "日本",
            actor: "早见沙织 / 花江夏树",
            director: "新海诚风工作室",
            description: "玻璃工坊与光影折射交织的幻想番剧，每一帧都如水晶般通透。",
            tag: "动画 / 奇幻 / 剧集",
            doubanScore: 8.7,
            lines: [
                CmsLine(
                    name: "原画番剧",
                    episodes: (1...12).map { CmsEpisode(name: "第\($0)话", url: "demo://glass-garden/ep\($0).m3u8") }
                ),
            ]
        ),
        CmsVideo(
            id: "demo_alpine_echo",
            title: "雪岭回响",
            poster: "",
            remarks: "HDR 纪录片",
            year: "2024",
            area: "瑞士",
            actor: "登山纪实",
            director: "卢卡·梅耶",
            description: "徒步穿越阿尔卑斯群峰的高海拔纪实影像，记录雪线之上的寂静与力量。",
            tag: "纪录片 / 户外",
            doubanScore: 8.5,
            lines: [
                CmsLine(name: "4K 纪实", episodes: [CmsEpisode(name: "完整版", url: "demo://alpine-echo/main.m3u8")]),
            ]
        ),
    ]

    public static func episodeMetadata(for video: CmsVideo, count: Int) -> [EpisodeRichMetadata] {
        let titles = [
            "信号初现", "轨道偏离", "静默星环", "冰川回声", "折跃临界",
            "引力深渊", "遗落观测站", "星尘航道", "黎明坐标", "彼岸灯塔",
        ]
        let overviews = [
            "深空阵列截获来自未知坐标的周期性窄带脉冲，远航计划正式启动。",
            "主推进器在木星引力弹弓阶段出现微弱共振，舰长决定切换手动姿态控制。",
            "穿越外层冰环带期间，探测器捕捉到非自然几何结构的反射回波。",
            "科考小队降落冻结卫星表面，在地下冰洞内发现古老的能量核心。",
            "曲速引擎首次满功率测试，全舰乘员面临时间膨胀与通讯延迟的双重考验。",
        ]
        return (0..<count).map { (idx: Int) -> EpisodeRichMetadata in
            let title: String = idx < titles.count ? titles[idx] : "第 \(idx + 1) 集"
            let overview: String = overviews[idx % overviews.count]
            let month: Int = min(9, (idx % 9) + 1)
            let airDate = "2026-0\(month)-15"
            let runtime: Int = 46 + (idx % 9)
            let vote: Double = 8.6 + Double(idx % 5) * 0.1
            return EpisodeRichMetadata(
                seasonNumber: 1,
                episodeNumber: idx + 1,
                title: title,
                overview: overview,
                stillUrl: "",
                airDate: airDate,
                runtimeMinutes: runtime,
                voteAverage: vote
            )
        }
    }

    public static let watchHistory: [WatchHistoryItem] = [
        WatchHistoryItem(
            site: demoSite.key,
            id: featuredVideo.id,
            title: featuredVideo.title,
            poster: "",
            line: "4K HDR 原画直出",
            episode: "第04集",
            index: 3,
            position: 1_840_000,
            duration: 2_880_000,
            updated: Int64(Date().timeIntervalSince1970 * 1000) - 600_000
        ),
        WatchHistoryItem(
            site: demoSite.key,
            id: "demo_midnight_harbor",
            title: "午夜港湾",
            poster: "",
            line: "4K 原画",
            episode: "正片 4K",
            index: 0,
            position: 3_420_000,
            duration: 6_900_000,
            updated: Int64(Date().timeIntervalSince1970 * 1000) - 3_600_000
        ),
        WatchHistoryItem(
            site: demoSite.key,
            id: "demo_deep_ocean_pulse",
            title: "深海脉动",
            poster: "",
            line: "4K 纪录片",
            episode: "第2集",
            index: 1,
            position: 1_510_000,
            duration: 3_000_000,
            updated: Int64(Date().timeIntervalSince1970 * 1000) - 8_400_000
        ),
    ]

    public static let favorites: [FavoriteItem] = [
        FavoriteItem(site: demoSite.key, id: featuredVideo.id, title: featuredVideo.title, poster: "", remarks: featuredVideo.remarks, updated: 1_760_000_000_000),
        FavoriteItem(site: demoSite.key, id: "demo_silent_atelier", title: "静谧画室", poster: "", remarks: "HDR10+", updated: 1_759_900_000_000),
        FavoriteItem(site: demoSite.key, id: "demo_deep_ocean_pulse", title: "深海脉动", poster: "", remarks: "4K 60fps", updated: 1_759_800_000_000),
        FavoriteItem(site: demoSite.key, id: "demo_sand_citadel", title: "沙丘之城", poster: "", remarks: "IMAX 增强", updated: 1_759_700_000_000),
    ]

    public static let downloads: [DownloadTask] = [
        DownloadTask(
            id: "sim_dl_1",
            siteKey: demoSite.key,
            siteName: demoSite.name,
            videoId: featuredVideo.id,
            title: featuredVideo.title,
            poster: "",
            lineName: "4K HDR 原画直出",
            episodeName: "第01集",
            episodeIndex: 0,
            sourceUrl: "demo://stellar-horizon/4k/ep-1.m3u8",
            status: .completed,
            progress: 1.0,
            receivedBytes: 1_480_000_000,
            totalBytes: 1_480_000_000,
            filePath: ""
        ),
        DownloadTask(
            id: "sim_dl_2",
            siteKey: demoSite.key,
            siteName: demoSite.name,
            videoId: featuredVideo.id,
            title: featuredVideo.title,
            poster: "",
            lineName: "4K HDR 原画直出",
            episodeName: "第02集",
            episodeIndex: 1,
            sourceUrl: "demo://stellar-horizon/4k/ep-2.m3u8",
            status: .downloading,
            progress: 0.64,
            receivedBytes: 910_000_000,
            totalBytes: 1_420_000_000,
            filePath: ""
        ),
        DownloadTask(
            id: "sim_dl_3",
            siteKey: demoSite.key,
            siteName: demoSite.name,
            videoId: "demo_deep_ocean_pulse",
            title: "深海脉动",
            poster: "",
            lineName: "4K 纪录片",
            episodeName: "第1集",
            episodeIndex: 0,
            sourceUrl: "demo://deep-ocean/ep1.m3u8",
            status: .paused,
            progress: 0.32,
            receivedBytes: 420_000_000,
            totalBytes: 1_310_000_000,
            filePath: ""
        ),
    ]

    public static let liveSources: [LiveSource] = [
        LiveSource(name: "演示超清频道源", url: "", group: "演示分组", inlineContent: "demo"),
        LiveSource(name: "演示纪录与影院源", url: "", group: "演示分组", inlineContent: "demo"),
    ]

    public static let liveGroups: [LiveGroup] = [
        LiveGroup(name: "4K 超清", channels: [
            LiveChannel(name: "4K 极光影院", group: "4K 超清", urls: ["demo://live/4k-cinema.m3u8"], health: .reachable, latencyMs: 38),
            LiveChannel(name: "4K 纪实自然", group: "4K 超清", urls: ["demo://live/4k-nature.m3u8"], health: .reachable, latencyMs: 42),
            LiveChannel(name: "4K 视界音乐", group: "4K 超清", urls: ["demo://live/4k-music.m3u8"], health: .reachable, latencyMs: 51),
            LiveChannel(name: "4K 体育赛事", group: "4K 超清", urls: ["demo://live/4k-sports.m3u8"], health: .reachable, latencyMs: 44),
        ]),
        LiveGroup(name: "综合卫视", channels: [
            LiveChannel(name: "综合高清频道", group: "综合卫视", urls: ["demo://live/general-1.m3u8"], health: .reachable, latencyMs: 32),
            LiveChannel(name: "新闻资讯频道", group: "综合卫视", urls: ["demo://live/news-1.m3u8"], health: .reachable, latencyMs: 29),
            LiveChannel(name: "财经观察频道", group: "综合卫视", urls: ["demo://live/finance-1.m3u8"], health: .reachable, latencyMs: 47),
            LiveChannel(name: "人文科教频道", group: "综合卫视", urls: ["demo://live/edu-1.m3u8"], health: .reachable, latencyMs: 55),
        ]),
        LiveGroup(name: "影院剧场", channels: [
            LiveChannel(name: "经典电影频道", group: "影院剧场", urls: ["demo://live/movie-classic.m3u8"], health: .reachable, latencyMs: 40),
            LiveChannel(name: "科幻动作剧场", group: "影院剧场", urls: ["demo://live/movie-scifi.m3u8"], health: .reachable, latencyMs: 45),
            LiveChannel(name: "悬疑佳片频道", group: "影院剧场", urls: ["demo://live/movie-mystery.m3u8"], health: .reachable, latencyMs: 63),
            LiveChannel(name: "华语院线剧场", group: "影院剧场", urls: ["demo://live/movie-cn.m3u8"], health: .reachable, latencyMs: 39),
        ]),
        LiveGroup(name: "纪录与少儿", channels: [
            LiveChannel(name: "寰宇地理纪实", group: "纪录与少儿", urls: ["demo://live/doc-geo.m3u8"], health: .reachable, latencyMs: 49),
            LiveChannel(name: "历史档案频道", group: "纪录与少儿", urls: ["demo://live/doc-history.m3u8"], health: .reachable, latencyMs: 52),
            LiveChannel(name: "高清动漫频道", group: "纪录与少儿", urls: ["demo://live/anime-hd.m3u8"], health: .reachable, latencyMs: 36),
        ]),
    ]
}

// MARK: - Simulator Launch Argument Hook

@MainActor
public enum SimulatorVerificationHook {
    public static var isVerifyModeEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-MarcoSimVerifyMode")
    }

    public static var requestedScreen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-MarcoSimScreen"), idx + 1 < args.count else {
            return nil
        }
        return args[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static var requestedTheme: AppThemeMode? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-MarcoSimTheme"), idx + 1 < args.count else {
            return nil
        }
        return AppThemeMode.fromId(args[idx + 1])
    }

    public static func applyIfNeeded(to coordinator: RootNavigationCoordinator) {
        guard isVerifyModeEnabled else { return }

        AppStateStore.shared.isSimulatorDemoMode = true
        if let theme = requestedTheme {
            AppStateStore.shared.applyThemeMode(theme, animated: false)
        }
        AppStateStore.shared.reloadConfig()

        if let screen = requestedScreen, !screen.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                coordinator.presentDemoScreen(screen)
            }
        }
    }
}
