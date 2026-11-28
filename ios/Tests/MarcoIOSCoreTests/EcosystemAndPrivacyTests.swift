// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation
import XCTest
@testable import MarcoIOSCore

// MARK: - Deterministic Mock URLProtocol & Fake Playback Engine

private final class MockHttpStubRouter: @unchecked Sendable {
    static let shared = MockHttpStubRouter()
    private let lock = NSLock()
    private var routes: [String: (status: Int, headers: [String: String], body: Data)] = [:]

    func register(urlString: String, status: Int = 200, headers: [String: String] = [:], body: Data) {
        lock.lock()
        routes[urlString] = (status, headers, body)
        lock.unlock()
    }

    func lookup(urlString: String) -> (status: Int, headers: [String: String], body: Data)? {
        lock.lock()
        defer { lock.unlock() }
        return routes[urlString]
    }

    func reset() {
        lock.lock()
        routes.removeAll()
        lock.unlock()
    }
}

private final class MockStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let hit = MockHttpStubRouter.shared.lookup(urlString: url.absoluteString)
        let status = hit?.status ?? 404
        let headers = hit?.headers ?? [:]
        let body = hit?.body ?? Data()
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
private final class FakePlaybackEngineAdapter: PlaybackEngineAdapterProtocol {
    var activeItemToken: UInt64?
    var hasReadyCurrentItem: Bool = false
    var currentTimeMs: Int = 0
    var durationMs: Int = 0
    var onProgressTick: ((UInt64, Int, Int) -> Void)?
    var onPlaybackEnded: ((UInt64) -> Void)?
    var onPlaybackFailed: ((UInt64, String) -> Void)?

    var loadedCalls: [(token: UInt64, url: URL, initialSeekMs: Int, rate: Float)] = []
    var lastRate: Float = 1.0
    var stoppedCount = 0
    var tornDown = false

    func load(token: UInt64, url: URL, initialSeekMs: Int, rate: Float) {
        activeItemToken = token
        hasReadyCurrentItem = true
        currentTimeMs = initialSeekMs
        lastRate = rate
        loadedCalls.append((token, url, initialSeekMs, rate))
    }

    func stopCurrentItem() {
        activeItemToken = nil
        hasReadyCurrentItem = false
        stoppedCount += 1
    }

    func setPlaybackRate(_ rate: Float) {
        lastRate = rate
    }

    func teardown() {
        stopCurrentItem()
        tornDown = true
    }
}

private final class ThreadSafeStringList: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ val: String) {
        lock.lock()
        values.append(val)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class EcosystemAndPrivacyTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        MockHttpStubRouter.shared.reset()
        CuratedDiscoveryService.resetCache()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarcoIOSEcoTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        MockHttpStubRouter.shared.reset()
        CuratedDiscoveryService.resetCache()
        if let dir = tempRoot {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    private func makeMockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockStubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    // MARK: - 1. Curated Discovery (8 Modules + Disk Cache + Offline Seeds)

    func testCuratedDiscovery8ModulesParsingAndDiskSnapshotRoundTrip() async {
        XCTAssertEqual(CuratedDiscoveryService.modules.count, 8)
        XCTAssertEqual(CuratedDiscoveryService.wave1Modules.count, 4)
        XCTAssertEqual(CuratedDiscoveryService.wave2Modules.count, 4)

        // All offline seeds MUST be strictly metadata-only (zero playable stream lines)
        for spec in CuratedDiscoveryService.modules {
            XCTAssertFalse(spec.seedItems.isEmpty)
            for item in spec.seedItems {
                XCTAssertTrue(item.lines.isEmpty, "Curated discovery seed must never embed stream URLs")
            }
        }

        // Parse Douban Rexxar JSON & verify `/s_ratio_poster/` -> `/m_ratio_poster/` upgrade
        let sampleDouban = """
        {
          "subject_collection_items": [
            {
              "id": "35183042",
              "title": "漫长的季节",
              "year": "2023",
              "card_subtitle": "2023 / 中国大陆 / 剧情 悬疑 / 辛爽",
              "pic": {"large": "https://img1.doubanio.com/view/photo/s_ratio_poster/public/p2890.jpg"},
              "photos": ["https://img1.doubanio.com/view/photo/l/public/still1.jpg"],
              "rating": {"value": 9.4},
              "actors": ["范伟", "秦昊"]
            }
          ]
        }
        """
        let parsed = CuratedDiscoveryService.parseDoubanDiscoveryJson(Data(sampleDouban.utf8), moduleId: "cn_hot")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].title, "漫长的季节")
        XCTAssertEqual(parsed[0].poster, "https://img1.doubanio.com/view/photo/m_ratio_poster/public/p2890.jpg")
        XCTAssertEqual(CuratedDiscoveryService.backdropFor(parsed[0]), "https://img1.doubanio.com/view/photo/l/public/still1.jpg")
        XCTAssertEqual(CuratedDiscoveryService.genreFor(parsed[0]), "剧情 / 悬疑")

        // Wave refresh + disk snapshot warm round-trip
        let snapDir = tempRoot.appendingPathComponent("curated_snap", isDirectory: true)
        let refreshed = await CuratedDiscoveryService.refreshAllModules(
            forceRefresh: true,
            snapshotDirectory: snapDir,
            liveFetcher: { spec in
                spec.id == "cn_hot" ? parsed : nil
            }
        )
        XCTAssertEqual(refreshed.count, 8)
        XCTAssertEqual(refreshed.first(where: { $0.id == "cn_hot" })?.items.first?.poster, parsed[0].poster)

        CuratedDiscoveryService.resetCache()
        XCTAssertTrue(CuratedDiscoveryService.warmFromDisk(snapshotDirectory: snapDir))
        XCTAssertEqual(CuratedDiscoveryService.peekModule(id: "cn_hot").first?.poster, parsed[0].poster)
    }

    // MARK: - 2. Episode Scraper (360 Baike CSS De-obfuscation & Bing Stills)

    func testEpisodeScraper360BaikeCssDeobfuscationAndBingStills() {
        let baikeHtml = """
        <html>
          <head>
            <style>
              .obfA { display: none; }
              .obfB { font-size: 0; height: 0; }
              .vis { color: #333; }
            </style>
          </head>
          <body>
            <div id="tvplot">
              <dl>
                <dt>第1集：破晓时刻</dt>
                <dd>王响在桦林<span class="obfA">干扰乱码文字</span>发现异常线索，<em class="obfB">隐藏噪声</em><span class="vis">决定追查真相。</span></dd>
                <dt>第2集：旧日回响</dt>
                <dd>龚彪和马德胜联手排查线索，逐步揭开尘封往事。</dd>
              </dl>
            </div>
          </body>
        </html>
        """
        let episodes = EpisodeScraperService.parse360BaikeEpisodes(html: baikeHtml, season: 1)
        XCTAssertEqual(episodes.count, 2)
        XCTAssertEqual(episodes[0].episodeNumber, 1)
        XCTAssertEqual(episodes[0].title, "破晓时刻")
        XCTAssertEqual(episodes[0].overview, "王响在桦林发现异常线索，决定追查真相。")
        XCTAssertFalse(episodes[0].overview.contains("干扰乱码文字"))
        XCTAssertFalse(episodes[0].overview.contains("隐藏噪声"))

        // Bing 16:9 widescreen still parser filters vertical HaK/HaL thumbnails
        let bingHtml = """
        <a m="{&quot;t&quot;:&quot;三体 剧照&quot;,&quot;turl&quot;:&quot;https://tse1-mm.cn.bing.net/th/id/OIP-C.wideValid123456&quot;}"></a>
        <a m="{&quot;t&quot;:&quot;竖版海报&quot;,&quot;turl&quot;:&quot;https://tse1-mm.cn.bing.net/th/id/OIP.portraitBadHaK9&quot;}"></a>
        """
        let stills = EpisodeScraperService.parseBingWidescreenStills(html: bingHtml, count: 10)
        XCTAssertEqual(stills.count, 1)
        XCTAssertTrue(stills[0].contains("OIP-C.wideValid123456"))

        // Badge extraction
        let badges = EpisodeScraperService.parseEpisodeBadges(
            name: "Show.S02E05.2160p.Dolby.Vision.Atmos.HEVC.mkv"
        )
        XCTAssertEqual(badges.seasonNumber, 2)
        XCTAssertEqual(badges.episodeNumber, 5)
        XCTAssertEqual(badges.resolution, "4K")
        XCTAssertEqual(badges.hdrBadge, "Dolby Vision")
        XCTAssertEqual(badges.audioBadge, "Atmos")
        XCTAssertEqual(badges.codecBadge, "HEVC")
        XCTAssertTrue(badges.isDolbyVision)
    }

    // MARK: - 3. Danmaku ReDoS Validator, Segment Cache LRU, XML XXE Guard & Credential Isolation

    func testDanmuBlockFilterStaticReDoSRejectionXmlXxeGuardAndSegmentCache() throws {
        // Static ReDoS rejections
        XCTAssertFalse(DanmuBlockFilter.validateRule("re:(a+)+$").valid)
        XCTAssertFalse(DanmuBlockFilter.validateRule("re:(a|aa)+").valid)
        XCTAssertFalse(DanmuBlockFilter.validateRule("re:(?=lookahead)abc").valid)
        XCTAssertFalse(DanmuBlockFilter.validateRule("re:(abc)\\1").valid)
        XCTAssertFalse(DanmuBlockFilter.validateRule("re:.*.*.*.*").valid)
        XCTAssertFalse(DanmuBlockFilter.validateRule("re:" + String(repeating: "a", count: 121)).valid)

        // Safe regex & plain rules pass
        XCTAssertTrue(DanmuBlockFilter.validateRule("re:^剧透.*结局$").valid)
        XCTAssertTrue(DanmuBlockFilter.validateRule("广告词").valid)

        let filter = DanmuBlockFilter(rules: ["re:(a+)+$", "re:^剧透.*结局$", "刷屏"])
        XCTAssertEqual(filter.ruleCount, 2) // ReDoS rule dropped automatically
        XCTAssertTrue(filter.shouldBlock("剧透大结局"))
        XCTAssertTrue(filter.shouldBlock("禁止刷屏哦"))
        XCTAssertFalse(filter.shouldBlock("精彩片段"))

        // XML XXE guard MUST throw on DOCTYPE / ENTITY
        let xxeXml = """
        <?xml version="1.0"?>
        <!DOCTYPE foo [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]>
        <i><d p="1.5,1,25,16777215,0,0,0,1">&xxe;</d></i>
        """
        XCTAssertThrowsError(try DanmuService.parseCommentsPayload(Data(xxeXml.utf8)))

        // Valid XML + JSON tuple + JSON dict parsing
        let safeXml = "<i><d p=\"12.5,5,25,16711680,0,0,0,99\">前方高能 &amp; 名场面</d></i>"
        let xmlComments = try DanmuService.parseCommentsPayload(Data(safeXml.utf8))
        XCTAssertEqual(xmlComments.count, 1)
        XCTAssertEqual(xmlComments[0].timeMs, 12_500)
        XCTAssertEqual(xmlComments[0].mode, .top)
        XCTAssertEqual(xmlComments[0].text, "前方高能 & 名场面")

        let tupleJson = #"{"danmuku":[[3.0,1,16777215,"第一条","c1"],[6.2,4,65280,"底部字幕","c2"]]}"#
        let tupleComments = try DanmuService.parseCommentsPayload(Data(tupleJson.utf8))
        XCTAssertEqual(tupleComments.count, 2)
        XCTAssertEqual(tupleComments[1].mode, .bottom)

        // SegmentCache 30s windows, 12s lifetime, signed effective clock, and 3-window LRU pinning
        let cache = DanmuSegmentCache()
        for w in 0..<30 {
            let startMs = w * DanmuSegmentCache.windowDurationMs
            cache.putWindow(w, items: [
                DanmuComment(id: "w\(w)_a", timeMs: startMs + 2_000, text: "窗口\(w)"),
            ])
        }
        XCTAssertLessThanOrEqual(cache.cachedWindowCount, DanmuSegmentCache.maxCachedWindows)
        // Pin around window 29 and verify comments within [t-12s, t]
        let visible = cache.comments(atMs: 29 * 30_000 + 5_000)
        XCTAssertEqual(visible.map(\.id), ["w29_a"])
        // Negative effective clock returns empty (prevents 0.0s freeze)
        cache.setTimeOffsetMs(-5_000)
        XCTAssertTrue(cache.comments(atMs: 2_000).isEmpty)

        // Credential authorization isolation for cloud-synced origins
        let localDoc = DanmuSourceSyncDocument(
            updatedAt: 100,
            revision: 1,
            initialized: true,
            sources: [DanmuSourceEntry(url: "https://local.danmu.test", requiresAuth: true)]
        )
        let remoteDoc = DanmuSourceSyncDocument(
            updatedAt: 200,
            revision: 2,
            initialized: true,
            sources: [
                DanmuSourceEntry(url: "https://local.danmu.test", requiresAuth: true),
                DanmuSourceEntry(url: "https://cloud.danmu.test", requiresAuth: true),
            ]
        )
        let mergeRes = DanmuSourceSyncMerger.merge(
            local: localDoc,
            base: localDoc,
            remote: remoteDoc,
            hasLocalCredentials: true,
            authorizedCredentialOrigins: ["https://local.danmu.test"],
            nowMs: 300
        )
        XCTAssertEqual(mergeRes.pendingAuthOrigins, ["https://cloud.danmu.test"])

        let ds = DanmuSettings(
            enabled: true,
            serverUrls: "https://local.danmu.test\nhttps://cloud.danmu.test",
            appId: "app_1",
            appSecret: "sec_1",
            authorizedCredentialOrigins: ["https://local.danmu.test"],
            pendingAuthOrigins: mergeRes.pendingAuthOrigins
        )
        XCTAssertTrue(DanmuService.shouldSendCredentials(toOrigin: "https://local.danmu.test", settings: ds))
        XCTAssertFalse(DanmuService.shouldSendCredentials(toOrigin: "https://cloud.danmu.test", settings: ds))
    }

    // MARK: - 4. DownloadManager Privacy Isolation, AES-128-CBC HLS & Separate Audio Bundles

    func testDownloadManagerPrivacyIsolationAes128AndSampleAesRejection() async throws {
        let storageDir = tempRoot.appendingPathComponent("dl_storage", isDirectory: true)
        let dlDir = tempRoot.appendingPathComponent("dl_files", isDirectory: true)
        let storage = IOSStorageManager(storageDirectory: storageDir, keychain: InMemoryKeychainStore())
        let manager = DownloadManager(storage: storage, downloadsDirectory: dlDir, session: makeMockSession())

        // 1. Hard privacy isolation: private task MUST be rejected and NEVER persisted
        let privSite = CmsSite(key: "priv_k", name: "私密源", type: 1, api: "https://priv.marco.test/", isPrivate: true)
        let privTask = DownloadTask(
            id: "dl_priv_1",
            siteKey: privSite.key,
            siteName: privSite.name,
            videoId: "pv1",
            title: "私密影片",
            episodeName: "第1集",
            sourceUrl: "https://priv.marco.test/ep1.mp4",
            sourceSite: privSite,
            isPrivate: true
        )
        let rejected = await manager.enqueue(privTask)
        XCTAssertEqual(rejected.status, .failed)
        XCTAssertEqual(rejected.error, DownloadManager.privacyBlockedMessage)
        let storedAfterPriv = await manager.allTasks(includePrivate: true)
        XCTAssertTrue(storedAfterPriv.isEmpty)

        do {
            _ = try await manager.enqueueValidated(privTask, site: privSite)
            XCTFail("enqueueValidated must throw for private sources")
        } catch {}

        // 2. AES-128-CBC encrypted HLS download -> decrypted offline segment & clean playlist
        let aesKey = Data("0123456789abcdef".utf8)
        let ivHex = "0x000102030405060708090a0b0c0d0e0f"
        let ivData = DownloadManager.deriveHlsIv(explicitHex: ivHex, mediaSequence: 0)
        var rawTs = Data(repeating: 0x55, count: 188 * 2)
        rawTs[0] = 0x47
        rawTs[188] = 0x47
        let encryptedSeg = try DownloadManager.encryptAes128Cbc(data: rawTs, key: aesKey, iv: ivData)

        let hlsPlaylist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXT-X-KEY:METHOD=AES-128,URI="https://dl.marco.test/key.bin",IV=\(ivHex)
        #EXTINF:5.0,
        https://dl.marco.test/seg0.ts
        #EXT-X-ENDLIST
        """
        MockHttpStubRouter.shared.register(urlString: "https://dl.marco.test/aes.m3u8", body: Data(hlsPlaylist.utf8))
        MockHttpStubRouter.shared.register(urlString: "https://dl.marco.test/key.bin", body: aesKey)
        MockHttpStubRouter.shared.register(urlString: "https://dl.marco.test/seg0.ts", body: encryptedSeg)

        let aesTask = DownloadTask(
            id: "dl_aes_1",
            siteKey: "pub_vod",
            siteName: "公共点播",
            videoId: "v100",
            title: "测试剧集",
            episodeName: "第1集",
            sourceUrl: "https://dl.marco.test/aes.m3u8"
        )
        _ = await manager.enqueue(aesTask)
        await manager.waitUntilFinished(taskId: "dl_aes_1")

        let completedAes = await manager.allTasks().first(where: { $0.id == "dl_aes_1" })
        XCTAssertEqual(completedAes?.status, .completed)
        let localM3uPath = try XCTUnwrap(completedAes?.filePath)
        let localM3uText = try String(contentsOfFile: localM3uPath, encoding: .utf8)
        XCTAssertFalse(localM3uText.contains("EXT-X-KEY"))
        let segLocalUrl = URL(fileURLWithPath: localM3uPath).deletingLastPathComponent().appendingPathComponent("seg_00000.ts")
        XCTAssertEqual(try Data(contentsOf: segLocalUrl), rawTs)

        // 3. SAMPLE-AES DRM stream MUST fail cleanly
        let sampleAesPlaylist = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="https://dl.marco.test/drm.key"
        #EXTINF:5.0,
        https://dl.marco.test/drm.ts
        #EXT-X-ENDLIST
        """
        MockHttpStubRouter.shared.register(urlString: "https://dl.marco.test/drm.m3u8", body: Data(sampleAesPlaylist.utf8))
        let drmTask = DownloadTask(
            id: "dl_drm_1",
            siteKey: "pub_vod",
            siteName: "公共点播",
            videoId: "v101",
            title: "DRM测试",
            episodeName: "正片",
            sourceUrl: "https://dl.marco.test/drm.m3u8"
        )
        _ = await manager.enqueue(drmTask)
        await manager.waitUntilFinished(taskId: "dl_drm_1")
        let failedDrm = await manager.allTasks().first(where: { $0.id == "dl_drm_1" })
        XCTAssertEqual(failedDrm?.status, .failed)
        XCTAssertTrue(failedDrm?.error.contains("SAMPLE-AES") == true)

        // 4. Separate-audio `#EXT-X-MEDIA:TYPE=AUDIO` master HLS offline bundle
        let masterSplit = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Chinese",LANGUAGE="zh",DEFAULT=YES,AUTOSELECT=YES,URI="https://dl.marco.test/audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=4500000,AUDIO="aud"
        https://dl.marco.test/video.m3u8
        """
        let vSplit = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:5.0,\nhttps://dl.marco.test/v0.ts\n#EXT-X-ENDLIST\n"
        let aSplit = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:5.0,\nhttps://dl.marco.test/a0.aac\n#EXT-X-ENDLIST\n"
        MockHttpStubRouter.shared.register(urlString: "https://dl.marco.test/split_master.m3u8", body: Data(masterSplit.utf8))
        MockHttpStubRouter.shared.register(urlString: "https://dl.marco.test/video.m3u8", body: Data(vSplit.utf8))
        MockHttpStubRouter.shared.register(urlString: "https://dl.marco.test/audio.m3u8", body: Data(aSplit.utf8))
        MockHttpStubRouter.shared.register(urlString: "https://dl.marco.test/v0.ts", body: rawTs)
        MockHttpStubRouter.shared.register(urlString: "https://dl.marco.test/a0.aac", body: Data("AAC_AUDIO_BYTES".utf8))

        let splitTask = DownloadTask(
            id: "dl_split_1",
            siteKey: "pub_vod",
            siteName: "公共点播",
            videoId: "v100",
            title: "测试剧集",
            episodeName: "第2集",
            episodeIndex: 1,
            sourceUrl: "https://dl.marco.test/split_master.m3u8"
        )
        _ = await manager.enqueue(splitTask)
        await manager.waitUntilFinished(taskId: "dl_split_1")
        let completedSplit = await manager.allTasks().first(where: { $0.id == "dl_split_1" })
        XCTAssertEqual(completedSplit?.status, .completed)
        let splitMasterPath = try XCTUnwrap(completedSplit?.filePath)
        let splitMasterText = try String(contentsOfFile: splitMasterPath, encoding: .utf8)
        XCTAssertTrue(splitMasterText.contains("URI=\"hls/audio.m3u8\""))
        XCTAssertTrue(splitMasterText.contains("hls/video.m3u8"))

        // Series grouping merges episodes of the same public series cleanly
        let groups = await manager.groupedTasks()
        let seriesGroup = groups.first(where: { $0.displayTitle == "测试剧集" })
        XCTAssertEqual(seriesGroup?.tasks.count, 2)
        XCTAssertEqual(seriesGroup?.allowExternalPosterScrape, true)
    }

    // MARK: - 5. CastService Discovery Helpers, XML Parsing & Relay Rewrite

    func testCastServiceHelpersDeviceXmlAndLoopbackPlaylistRewrite() {
        XCTAssertTrue(CastService.isPrivateLanIpv4("10.0.2.2"))
        XCTAssertTrue(CastService.isPrivateLanIpv4("172.20.10.3"))
        XCTAssertTrue(CastService.isPrivateLanIpv4("100.64.1.5"))
        XCTAssertFalse(CastService.isPrivateLanIpv4("198.51.100.10"))

        XCTAssertTrue(CastService.isSkippedInterfaceName("utun3"))
        XCTAssertTrue(CastService.isSkippedInterfaceName("pdp_ip0"))
        XCTAssertTrue(CastService.isSkippedInterfaceName("clash0"))
        XCTAssertFalse(CastService.isSkippedInterfaceName("en0"))

        let peers = CastService.buildSubnetScanIps(lanIp: "10.0.2.2")
        XCTAssertEqual(peers.count, 253)
        XCTAssertFalse(peers.contains("10.0.2.2"))
        XCTAssertTrue(peers.contains("10.0.2.1"))
        XCTAssertTrue(peers.contains("10.0.2.254"))

        let ssdpResp = "HTTP/1.1 200 OK\r\nST: urn:schemas-upnp-org:service:AVTransport:1\r\nLOCATION: http://10.0.2.15:18652/dlna/device.xml\r\n\r\n"
        let locUrl = CastService.parseSsdpLocation(from: ssdpResp)
        XCTAssertEqual(locUrl?.absoluteString, "http://10.0.2.15:18652/dlna/device.xml")

        let deviceXml = """
        <root><device>
          <friendlyName>客厅 Marco TV</friendlyName>
          <UDN>uuid:marco-tv-01</UDN>
          <serviceList>
            <service>
              <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
              <controlURL>/upnp/control/avtransport</controlURL>
            </service>
            <service>
              <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
              <controlURL>/upnp/control/rendering</controlURL>
            </service>
          </serviceList>
        </device></root>
        """
        let dev = CastService.parseDeviceDescriptorXml(deviceXml, locationUrl: locUrl!)
        XCTAssertEqual(dev?.name, "客厅 Marco TV")
        XCTAssertEqual(dev?.controlUrl, "http://10.0.2.15:18652/upnp/control/avtransport")
        XCTAssertEqual(
            CastService.parseRenderingControlUrl(deviceXml, locationUrl: locUrl!),
            "http://10.0.2.15:18652/upnp/control/rendering"
        )

        let didl = CastService.buildDidlLiteMetadata(title: "沙丘2", mediaUrl: "http://10.0.2.2:8080/video.m3u8")
        XCTAssertTrue(didl.contains("application/vnd.apple.mpegurl"))
        XCTAssertTrue(didl.contains("<dc:title>沙丘2</dc:title>"))

        XCTAssertEqual(CastService.formatHms(3665), "01:01:05")
        XCTAssertEqual(CastService.parseHms("01:01:05"), 3665)

        let rewritten = CastMediaRelayServer.rewriteLoopbackPlaylist(
            "#EXTM3U\nhttp://127.0.0.1:9001/seg/0.ts\n",
            upstream: URL(string: "http://127.0.0.1:9001/master.m3u8")!,
            lanHost: "10.0.2.2",
            relayPort: 45123,
            token: "abc123"
        )
        XCTAssertTrue(rewritten.contains("http://10.0.2.2:45123/p/abc123/seg/0.ts"))
    }

    // MARK: - 6. AI Ed25519 Passcode, Privacy Space Gate, Zero-URL Filter & Bilibili Deflate

    func testAiEd25519PasscodeZeroUrlFilterPrivacyGateAndDeflateXml() async throws {
        // 1. Ephemeral Ed25519 keypair verification
        let privKey = Curve25519.Signing.PrivateKey()
        let pubHex = privKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        let validToken = try AiLabPasscodeVerifier.signForTesting(
            payload: ["v": 1, "tag": "beta-ios", "iat": 1_749_000_000, "exp": 1_760_000_000, "plat": "ios", "shared": true],
            privateKey: privKey
        )
        let okRes = AiLabPasscodeVerifier.verify("口令：\(validToken) 请妥善保存", publicKeyHex: pubHex, targetPlatform: "ios", now: now)
        XCTAssertTrue(okRes.isValid)
        XCTAssertEqual(okRes.payload?.tag, "beta-ios")

        let expiredToken = try AiLabPasscodeVerifier.signForTesting(
            payload: ["v": 1, "tag": "old", "exp": 1_740_000_000, "plat": "all"],
            privateKey: privKey
        )
        XCTAssertEqual(AiLabPasscodeVerifier.verify(expiredToken, publicKeyHex: pubHex, targetPlatform: "ios", now: now).status, .expired)

        let winOnlyToken = try AiLabPasscodeVerifier.signForTesting(
            payload: ["v": 1, "tag": "win-only", "plat": "windows"],
            privateKey: privKey
        )
        XCTAssertEqual(AiLabPasscodeVerifier.verify(winOnlyToken, publicKeyHex: pubHex, targetPlatform: "ios", now: now).status, .wrongPlatform)

        // Tampered signature must fail
        var tampered = validToken
        let lastCh = tampered.removeLast()
        tampered.append(lastCh == "A" ? "B" : "A")
        XCTAssertEqual(AiLabPasscodeVerifier.verify(tampered, publicKeyHex: pubHex, targetPlatform: "ios", now: now).status, .invalidSignature)

        // 2. Zero-URL filter & diagnostic desensitization
        XCTAssertTrue(AiService.containsForbiddenUrl("点击访问 https://evil.marco.invalid/watch"))
        XCTAssertTrue(AiService.containsForbiddenUrl("magnet:?xt=urn:btih:123456"))
        XCTAssertTrue(AiService.containsForbiddenUrl("www.badsite.test"))
        XCTAssertFalse(AiService.containsForbiddenUrl("这是一部零剧透高分科幻片《星际穿越》"))

        let cleanDiag = AiService.desensitizeDiagnosticText("HTTP 403 at https://secret.marco.test/tok with sk-proj-1234567890abcdef from 198.51.100.7")
        XCTAssertFalse(cleanDiag.contains("secret.marco.test"))
        XCTAssertFalse(cleanDiag.contains("sk-proj-1234567890abcdef"))
        XCTAssertFalse(cleanDiag.contains("198.51.100.7"))

        // 3. Hard Privacy Space gate blocks ALL AI calls
        let storageDir = tempRoot.appendingPathComponent("ai_storage", isDirectory: true)
        let storage = IOSStorageManager(storageDirectory: storageDir, keychain: InMemoryKeychainStore())
        var aiCfg = AiConfig()
        aiCfg.enabled = true
        aiCfg.baseUrl = "http://127.0.0.1:11434/v1"
        aiCfg.model = "qwen2.5:7b"
        aiCfg.authMode = .localNoAuth
        storage.saveAiConfig(aiCfg)

        let ai = AiService(storage: storage, session: makeMockSession())
        do {
            _ = try await ai.complete(systemPrompt: "sys", userPrompt: "hi", isPrivateSpace: true)
            XCTFail("AI requests MUST be blocked in Privacy Space")
        } catch {}

        let matcher = AiDanmuMatcher(aiService: ai, session: makeMockSession())
        do {
            _ = try await matcher.extractQueryPlan(rawTitle: "测试", isPrivateSpace: true)
            XCTFail("AI Danmaku matcher MUST be blocked in Privacy Space")
        } catch {}

        // 4. Bilibili RFC-1951 raw-deflate XML decoding
        let rawXml = "<i><d p=\"5.0,1,25,16777215,0,0,0,77\">高能预警</d></i>"
        let deflated = try XCTUnwrap(ConfigDecoder.compressDeflate(Data(rawXml.utf8)))
        XCTAssertEqual(AiDanmuMatcher.decodeBilibiliDanmuXml(deflated), rawXml)
    }

    // MARK: - 7. AppUpdateService (iOS 14 vs 15+, Trusted Hosts, Ed25519 Manifest, TrollStore)

    func testAppUpdateServiceIos14RoutingTrustedHostsEd25519AndTrollStore() throws {
        XCTAssertTrue(AppUpdateService.prefersIos14CompatPackage(osMajorVersion: 14))
        XCTAssertFalse(AppUpdateService.prefersIos14CompatPackage(osMajorVersion: 15))
        XCTAssertFalse(AppUpdateService.prefersIos14CompatPackage(osMajorVersion: 26))

        let sha15 = String(repeating: "a", count: 64)
        let sha14 = String(repeating: "b", count: 64)
        let payload: [String: Any] = [
            "platform": "ios",
            "versionName": "1.2.0",
            "buildNumber": 205,
            "notes": "iOS 26 Liquid Glass 更新",
            "packages": [
                "MarcoMovie-1.2.0-ios-unsigned.ipa": [
                    "url": "https://github.com/Pilipala9919/MarcoMovie/releases/download/v1.2.0/MarcoMovie-1.2.0-ios-unsigned.ipa",
                    "sha256": sha15,
                    "size": 12_345_678,
                ],
                "MarcoMovie-1.2.0-ios14-unsigned.ipa": [
                    "url": "https://github.com/Pilipala9919/MarcoMovie/releases/download/v1.2.0/MarcoMovie-1.2.0-ios14-unsigned.ipa",
                    "sha256": sha14,
                    "size": 11_111_111,
                ],
            ],
        ]

        // Sign payload with ephemeral Ed25519 key
        let privKey = Curve25519.Signing.PrivateKey()
        let pubHex = privKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        let canonical = AppUpdateService.canonicalizeJson(payload)
        let sig = try privKey.signature(for: Data(canonical.utf8)).base64EncodedString()
        let signedEnvelope: [String: Any] = ["payload": payload, "signature": sig]
        let signedData = try JSONSerialization.data(withJSONObject: signedEnvelope)

        let rel15 = try AppUpdateService.parseReleaseJson(signedData, preferIos14: false, publicKeyHex: pubHex)
        XCTAssertTrue(rel15.downloadUrl.hasSuffix("MarcoMovie-1.2.0-ios-unsigned.ipa"))
        XCTAssertEqual(rel15.sha256, sha15)

        let rel14 = try AppUpdateService.parseReleaseJson(signedData, preferIos14: true, publicKeyHex: pubHex)
        XCTAssertTrue(rel14.downloadUrl.hasSuffix("MarcoMovie-1.2.0-ios14-unsigned.ipa"))
        XCTAssertEqual(rel14.sha256, sha14)

        // Extra unsigned outer field MUST fail signature verification
        var forgedEnvelope = signedEnvelope
        forgedEnvelope["extra"] = "injected"
        XCTAssertFalse(AppUpdateService.verifyManifestSignature(forgedEnvelope, publicKeyHex: pubHex))

        // Trusted hosts & TrollStore install URL
        let trustedUrl = URL(string: rel15.downloadUrl)!
        XCTAssertTrue(AppUpdateService.isTrustedAssetUrl(trustedUrl))
        XCTAssertFalse(AppUpdateService.isTrustedAssetUrl(URL(string: "https://untrusted.marco.invalid/MarcoMovie.ipa")!))
        XCTAssertFalse(AppUpdateService.isTrustedAssetUrl(URL(string: "http://marcotv.wlj9919.top/movie/test.ipa")!))

        let tsUrl = try AppUpdateService.trollStoreInstallUrl(for: trustedUrl)
        XCTAssertTrue(tsUrl.absoluteString.hasPrefix("apple-magnifier://install?url="))
        XCTAssertThrowsError(try AppUpdateService.trollStoreInstallUrl(for: URL(string: "https://evil.marco.invalid/a.ipa")!))

        XCTAssertEqual(
            AppUpdateService.compareVersion(currentVersion: "1.1.9", currentBuild: 200, remoteVersion: "1.2.0", remoteBuild: 205),
            .updateAvailable
        )
    }

    // MARK: - 8. PlayerProfiles (MPV RAM Tiers, Anime4K SHA-256 + Thermal Guard, Engine Selector) & PlaybackSessionCoordinator

    func testPlayerProfilesAnime4kThermalGuardAndEngineSelector() throws {
        // RAM-tiered MPV properties
        let props4Gb = IosMpvProfile.buildMpvProperties(
            physicalMemoryBytes: 4_000_000_000,
            hdrToneMapping: .bt2390,
            vocalLoudness: .cinemaVocal,
            lowPowerThermalMode: false
        )
        XCTAssertEqual(props4Gb["demuxer-max-bytes"], "\(64 * 1024 * 1024)")
        XCTAssertEqual(props4Gb["hwdec-image-format"], "nv12")
        XCTAssertEqual(props4Gb["hdr-compute-peak"], "yes")
        XCTAssertEqual(props4Gb["volume-max"], "200")
        XCTAssertTrue(props4Gb["af"]?.contains("dynaudnorm") == true)

        let props8GbLarge = IosMpvProfile.buildMpvProperties(
            physicalMemoryBytes: 8_000_000_000,
            largeBuffer: true,
            lowPowerThermalMode: true
        )
        XCTAssertEqual(props8GbLarge["demuxer-max-bytes"], "\(256 * 1024 * 1024)")
        XCTAssertEqual(props8GbLarge["hdr-compute-peak"], "no")
        XCTAssertEqual(props8GbLarge["dither-depth"], "no")
        XCTAssertEqual(props8GbLarge["video-sync"], "audio")

        let propsLive = IosMpvProfile.buildMpvProperties(isLive: true)
        XCTAssertEqual(propsLive["demuxer-max-bytes"], "\(16 * 1024 * 1024)")

        // Anime4K thermal guard & SHA-256 verification
        XCTAssertTrue(Anime4kShaderManager.isAllowed(thermalState: .nominal))
        XCTAssertTrue(Anime4kShaderManager.isAllowed(thermalState: .fair))
        XCTAssertFalse(Anime4kShaderManager.isAllowed(thermalState: .serious))
        XCTAssertFalse(Anime4kShaderManager.isAllowed(thermalState: .critical))
        XCTAssertFalse(Anime4kShaderManager.verifyShaderIntegrity(
            fileName: Anime4kShaderManager.iosSinglePassShaderFile,
            data: Data("tampered glsl".utf8)
        ))
        XCTAssertNil(Anime4kShaderManager.resolveIosLightweightShaderChain(thermalState: .serious))

        // Verify real bundled Anime4K_Upscale_CNN_x2_S.glsl if present in repo
        let resolvedChain = Anime4kShaderManager.resolveIosLightweightShaderChain(thermalState: .nominal)
        XCTAssertNotNil(resolvedChain)

        // Engine selector routing
        let mkvDecision = IosPlaybackEngineSelector.selectEngine(
            preferredMode: .avplayer,
            url: "https://cdn.marco.test/movie.mkv",
            mpvAvailable: true
        )
        XCTAssertEqual(mkvDecision.engine, .mpv)
        XCTAssertTrue(mkvDecision.fellBackFromPreferred)

        let dvMp4Decision = IosPlaybackEngineSelector.selectEngine(
            preferredMode: .avplayer,
            url: "https://cdn.marco.test/movie.mp4",
            episodeName: "4K Dolby Vision",
            mpvAvailable: true
        )
        XCTAssertEqual(dvMp4Decision.engine, .avplayer)
        XCTAssertFalse(dvMp4Decision.fellBackFromPreferred)
    }

    @MainActor
    func testPlaybackSessionCoordinatorTokenSafetyLineSwitchAndResourceRelease() async {
        let site = CmsSite(key: "s1", name: "测试站", type: 1, api: "https://s1.marco.test/")
        let line1 = CmsLine(name: "蓝光线路", episodes: [
            CmsEpisode(name: "第01集", url: "https://cdn.marco.test/l1_e1.m3u8"),
            CmsEpisode(name: "第02集", url: "https://cdn.marco.test/l1_e2.m3u8"),
            CmsEpisode(name: "第03集", url: "https://cdn.marco.test/l1_e3.m3u8"),
        ])
        let line2 = CmsLine(name: "备用线路", episodes: [
            CmsEpisode(name: "EP1", url: "https://cdn.marco.test/l2_e1.m3u8"),
            CmsEpisode(name: "EP2", url: "https://cdn.marco.test/l2_e2.m3u8"),
        ])
        let video = CmsVideo(id: "v1", title: "三体", lines: [line1, line2])
        let initial = PlaybackTargetDescriptor(site: site, video: video, lineIndex: 0, episodeIndex: 0)

        let engine = FakePlaybackEngineAdapter()
        let releasedIds = ThreadSafeStringList()
        var recordedProgress: [(epIndex: Int, posMs: Int)] = []

        let coordinator = PlaybackSessionCoordinator(
            initialTarget: initial,
            engine: engine,
            resolver: { desc in
                let ep = desc.currentEpisode!
                let proxyId = "res_\(desc.lineIndex)_\(desc.episodeIndex)"
                return ResolvedPlayback(
                    originalUrl: ep.url,
                    playableUrl: URL(string: ep.url)!,
                    isProxied: true,
                    kernelLabel: "AVPlayer 硬解",
                    resolutionBadge: "4K",
                    rangeProxyResourceId: proxyId
                )
            },
            progressRecorder: { desc, posMs, _ in
                recordedProgress.append((desc.episodeIndex, posMs))
            },
            resourceReleaser: { resolved in
                if let rid = resolved.rangeProxyResourceId {
                    releasedIds.append(rid)
                }
            },
            skipOutroSec: 60,
            autoNext: true
        )

        coordinator.startInitialLoad()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(engine.loadedCalls.count, 1)
        let firstToken = engine.loadedCalls[0].token

        // Progress tick on active token records progress
        engine.currentTimeMs = 120_000
        engine.durationMs = 2_400_000
        engine.onProgressTick?(firstToken, 120_000, 2_400_000)
        XCTAssertEqual(recordedProgress.last?.epIndex, 0)
        XCTAssertEqual(recordedProgress.last?.posMs, 120_000)

        // Switch VOD line 0 -> line 1: matches "第01集" -> "EP1" and carries exact current position 120_000 ms
        let outcome = coordinator.switchVodLine(to: 1)
        XCTAssertEqual(outcome, .switched(lineIndex: 1, episodeIndex: 0, seekMs: 120_000))
        try? await Task.sleep(nanoseconds: 50_000_000)
        await coordinator.waitForPendingResourceReleases()
        XCTAssertTrue(releasedIds.snapshot().contains("res_0_0"))

        // Stale progress tick with old token MUST be silently dropped
        let countBeforeStale = recordedProgress.count
        engine.onProgressTick?(firstToken, 999_000, 2_400_000)
        XCTAssertEqual(recordedProgress.count, countBeforeStale)

        // Switch to Episode 3 on line 0, then attempt switching to line 1 (which only has 2 episodes) -> .missingEpisode
        coordinator.switchToEpisode(lineIndex: 0, episodeIndex: 2, seekMs: 0)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let missingOutcome = coordinator.switchVodLine(to: 1)
        if case .missingEpisode(let info) = missingOutcome {
            XCTAssertEqual(info.targetLineIndex, 1)
            XCTAssertEqual(info.availableEpisodeCount, 2)
        } else {
            XCTFail("Expected .missingEpisode when target line lacks Episode 3")
        }

        // Teardown releases active proxy resource cleanly
        coordinator.teardownAndPersist()
        await coordinator.waitForPendingResourceReleases()
        XCTAssertTrue(engine.tornDown)
        XCTAssertTrue(releasedIds.snapshot().contains("res_0_2"))
    }
}
