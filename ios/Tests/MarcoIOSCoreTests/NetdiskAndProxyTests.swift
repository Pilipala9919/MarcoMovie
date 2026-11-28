// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import XCTest
@testable import MarcoIOSCore

final class NetdiskAndProxyTests: XCTestCase {
    func testNetdiskSessionValidatorAll5DrivesAndSecurityRejections() {
        // Valid credentials across all 5 netdisks
        XCTAssertTrue(NetdiskSessionValidator.isUsable(driveKey: "quark", credential: "__pus=valid_quark_session_01; __puus=valid_puus_01"))
        XCTAssertTrue(NetdiskSessionValidator.isUsable(driveKey: "uc", credential: "__pus=valid_uc_session_02; __puus=valid_uc_puus_02"))
        XCTAssertTrue(NetdiskSessionValidator.isUsable(driveKey: "baidu", credential: "BDUSS=abcdef1234567890; STOKEN=xyz"))
        XCTAssertTrue(NetdiskSessionValidator.isUsable(driveKey: "ali", credential: "a1b2c3d4e5f6g7h8i9j0k1l2"))
        XCTAssertTrue(NetdiskSessionValidator.isUsable(driveKey: "115", credential: "UID=12345_A1_17000; CID=abc123456; SEID=0123456789abcdef"))

        // Normalize ali token
        XCTAssertEqual(
            NetdiskSessionValidator.normalizeCredential(driveKey: "ali", rawCredential: "a1b2c3d4e5f6g7h8i9j0k1l2"),
            "ali_token=a1b2c3d4e5f6g7h8i9j0k1l2"
        )

        // Security rejections: CRLF injection, placeholder prefixes, missing required fields
        XCTAssertFalse(NetdiskSessionValidator.isUsable(driveKey: "quark", credential: "__pus=abc\r\nX-Injected: 1"))
        XCTAssertFalse(NetdiskSessionValidator.isUsable(driveKey: "quark", credential: "qr_auth_fake_session"))
        XCTAssertFalse(NetdiskSessionValidator.isUsable(driveKey: "baidu", credential: "STOKEN=only_stoken_no_bduss"))
        XCTAssertFalse(NetdiskSessionValidator.isUsable(driveKey: "ali", credential: "short"))
        XCTAssertFalse(NetdiskSessionValidator.isUsable(driveKey: "115", credential: "UID=12345; CID=abc123456"))
    }

    func testNetdiskShareResolverDriveDetectionAndHeaderPolicyIsolation() {
        XCTAssertEqual(NetdiskShareResolver.detectDriveKey(for: "https://pan.quark.cn/s/abc123"), "quark")
        XCTAssertEqual(NetdiskShareResolver.detectDriveKey(for: "https://drive.uc.cn/s/xyz456"), "uc")
        XCTAssertEqual(NetdiskShareResolver.detectDriveKey(for: "https://pan.baidu.com/s/1abcDEF"), "baidu")
        XCTAssertEqual(NetdiskShareResolver.detectDriveKey(for: "https://www.alipan.com/s/ali999"), "ali")
        XCTAssertEqual(NetdiskShareResolver.detectDriveKey(for: "mm115://share/sw3abc123?pwd=abcd"), "115")

        var comps115 = URLComponents()
        comps115.scheme = "https"
        comps115.host = "115.com"
        comps115.path = "/s/sw3abc123"
        let url115 = comps115.string ?? ""
        XCTAssertEqual(NetdiskShareResolver.detectDriveKey(for: url115), "115")
        XCTAssertTrue(NetdiskShareResolver.isSharePageOrCustomScheme(url115))

        // Header isolation: credentials sent ONLY to trusted HTTPS origin / cookieDomains, stripped cross-domain
        let origin = URL(string: "https://drive-pc.quark.cn/1/clouddrive/file")!
        let policy = NetdiskHeaderPolicy(
            originUrl: origin,
            baseHeaders: [
                "Cookie": "__pus=secret_session",
                "Authorization": "Bearer secret_bearer",
                "Referer": "https://pan.quark.cn/",
                "User-Agent": "MarcoTestUA",
                "Accept-Encoding": "gzip",
                "X-Ali-Refresh-Token": "must-never-leak",
            ],
            cookieDomains: ["quark.cn"]
        )

        // Same trusted domain over HTTPS -> Cookie + Authorization kept, blocked headers stripped, identity enforced
        let sameDomain = URL(string: "https://pan.quark.cn/dl/video.mkv")!
        let trustedHeaders = policy.headers(for: sameDomain, range: "bytes=0-1023")
        XCTAssertEqual(trustedHeaders["Cookie"], "__pus=secret_session")
        XCTAssertEqual(trustedHeaders["Authorization"], "Bearer secret_bearer")
        XCTAssertEqual(trustedHeaders["Accept-Encoding"], "identity")
        XCTAssertEqual(trustedHeaders["Range"], "bytes=0-1023")
        XCTAssertNil(trustedHeaders["X-Ali-Refresh-Token"])

        // Cross-domain CDN redirect -> Cookie, Authorization, and Referer MUST be stripped!
        let crossDomain = URL(string: "https://cdn-edge.other.test/chunk.mkv")!
        let strippedHeaders = policy.headers(for: crossDomain)
        XCTAssertNil(strippedHeaders["Cookie"])
        XCTAssertNil(strippedHeaders["Authorization"])
        XCTAssertNil(strippedHeaders["Referer"])
        XCTAssertEqual(strippedHeaders["User-Agent"], "MarcoTestUA")
        XCTAssertEqual(strippedHeaders["Accept-Encoding"], "identity")

        // Plain HTTP downgrade to same host -> credentials refused!
        let httpDowngrade = URL(string: "http://pan.quark.cn/dl/video.mkv")!
        XCTAssertFalse(policy.shouldSendCredentials(to: httpDowngrade))
    }

    func testLocalHeaderProxyDisguisedTsOffsetAndHlsAdStripping() {
        // 1. Disguised PNG prefix before 188-byte MPEG-TS sync bytes (0x47)
        var disguised = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01, 0x02, 0x03])
        let tsOffset = disguised.count
        var tsChunk = Data(repeating: 0xAA, count: 188 * 3)
        tsChunk[0] = 0x47
        tsChunk[188] = 0x47
        tsChunk[376] = 0x47
        disguised.append(tsChunk)
        XCTAssertEqual(LocalHeaderProxyServer.findDisguisedTsOffset(disguised), tsOffset)

        // Standard MP4 ftyp header & #EXTM3U MUST NOT be stripped
        var mp4 = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70])
        mp4.append(tsChunk)
        XCTAssertEqual(LocalHeaderProxyServer.findDisguisedTsOffset(mp4), 0)

        var m3u = Data("#EXTM3U\n#EXT-X-VERSION:3\n".utf8)
        m3u.append(tsChunk)
        XCTAssertEqual(LocalHeaderProxyServer.findDisguisedTsOffset(m3u), 0)

        // 2. Heuristic HLS VOD ad stripping on explicit ad host splice block
        let vodOrigin = URL(string: "https://cdn.marco.test/vod/index.m3u8")!
        let vodWithAd = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXTINF:5.0,
        seg001.ts
        #EXTINF:5.0,
        seg002.ts
        #EXTINF:5.0,
        seg003.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:4.0,
        https://ads.marco.invalid/promo1.ts
        #EXTINF:4.0,
        https://ads.marco.invalid/promo2.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:5.0,
        seg004.ts
        #EXTINF:5.0,
        seg005.ts
        #EXT-X-ENDLIST
        """
        let stripped = LocalHeaderProxyServer.stripHlsAdsIfVod(
            vodWithAd,
            origin: vodOrigin,
            enabled: true,
            isLive: false,
            adHosts: ["ads.marco.invalid"]
        )
        XCTAssertEqual(stripped.removedSegments, 2)
        XCTAssertFalse(stripped.playlist.contains("ads.marco.invalid"))
        XCTAssertTrue(stripped.playlist.contains("seg001.ts"))
        XCTAssertTrue(stripped.playlist.contains("seg005.ts"))

        // Live streams MUST NEVER be stripped
        let liveOutcome = LocalHeaderProxyServer.stripHlsAdsIfVod(
            vodWithAd,
            origin: vodOrigin,
            enabled: true,
            isLive: true,
            adHosts: ["ads.marco.invalid"]
        )
        XCTAssertEqual(liveOutcome.removedSegments, 0)
    }

    func testLocalHeaderProxyLoopbackServeAndSessionRevocation() async throws {
        let proxy = LocalHeaderProxyServer { url, _, headers in
            let body = "proxied:\(url.path)|ref=\(headers["Referer"] ?? "")"
            return ProxyUpstreamResponse(
                statusCode: 200,
                headers: ["Content-Type": "video/mp4"],
                body: Data(body.utf8)
            )
        }
        defer { proxy.stop() }

        let upstream = URL(string: "https://media.marco.test/movie.mp4")!
        let reg = try await proxy.registerStreamWithId(
            url: upstream,
            headers: ["Referer": "https://media.marco.test/"]
        )
        XCTAssertTrue(proxy.hasActiveSession(reg.sessionId))

        let cfg = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: cfg)
        let (data, resp) = try await session.marcoData(from: reg.proxyUrl)
        let http = try XCTUnwrap(resp as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "proxied:/movie.mp4|ref=https://media.marco.test/"
        )

        // Revoking the session immediately rejects subsequent requests with 404
        proxy.revokeSession(reg.sessionId)
        XCTAssertFalse(proxy.hasActiveSession(reg.sessionId))
        let (_, revokedResp) = try await session.marcoData(from: reg.proxyUrl)
        XCTAssertEqual((revokedResp as? HTTPURLResponse)?.statusCode, 404)
    }

    func testNetdiskRangeProxyLifecycleAndDiskBlockCacheLru() async throws {
        // 1. NetdiskRangeProxyServer register + metrics + revoke lifecycle
        let rangeProxy = NetdiskRangeProxyServer(workers: 2, chunkSize: 65_536, memoryLimit: 262_144)
        defer { rangeProxy.stop() }

        let upstream = URL(string: "https://media.marco.test/video.mkv")!
        let policy = NetdiskHeaderPolicy(originUrl: upstream, baseHeaders: ["Cookie": "__pus=ok"])
        let reg = try await rangeProxy.registerStream(url: upstream, policy: policy)
        XCTAssertEqual(reg.proxyUrl.host, "127.0.0.1")
        XCTAssertTrue(rangeProxy.hasActiveResource(reg.resourceId))
        XCTAssertEqual(rangeProxy.activeResourceCount(), 1)

        await rangeProxy.revokeResource(reg.resourceId)
        XCTAssertFalse(rangeProxy.hasActiveResource(reg.resourceId))
        XCTAssertEqual(rangeProxy.activeResourceCount(), 0)

        let metrics = await rangeProxy.metrics()
        XCTAssertEqual(metrics.currentBufferedBytes, 0)

        // 2. DiskBlockCache write/read + LRU eviction when exceeding maxBytes
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarcoBlockCacheTest_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let cache = DiskBlockCache(directory: cacheDir, maxBytes: 100)
        let key = DiskBlockCache.cacheKey(for: "https://media.marco.test/file.mkv")
        let b0 = Data(repeating: 0x11, count: 40)
        let b1 = Data(repeating: 0x22, count: 40)
        let b2 = Data(repeating: 0x33, count: 40)

        await cache.writeBlock(key: key, blockIndex: 0, data: b0)
        await cache.writeBlock(key: key, blockIndex: 1, data: b1)
        // Touch block 0 so block 1 becomes LRU
        let hit0 = await cache.readBlock(key: key, blockIndex: 0)
        XCTAssertEqual(hit0, b0)
        // Writing block 2 (total 120 > 100) must evict LRU block 1 while retaining block 0 & 2
        await cache.writeBlock(key: key, blockIndex: 2, data: b2)
        let evicted1 = await cache.readBlock(key: key, blockIndex: 1)
        let kept0 = await cache.readBlock(key: key, blockIndex: 0)
        let kept2 = await cache.readBlock(key: key, blockIndex: 2)
        XCTAssertNil(evicted1)
        XCTAssertEqual(kept0, b0)
        XCTAssertEqual(kept2, b2)
    }

    func testSmb2NtlmCryptoAndBlurayMplsChapterAndFakeLoopDetection() {
        // 1. SMB2 NTLM Type 1 signature & RFC 1320 MD4 / HMAC-MD5 vectors
        let type1 = Smb2Client.buildNtlmType1()
        XCTAssertTrue(type1.starts(with: Data("NTLMSSP\0".utf8)))
        let md4Empty = Smb2Client.md4(Data()).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(md4Empty, "31d6cfe0d16ae931b73c59d7e0c089c0")
        let hmac = Smb2Client.hmacMd5(key: Data("key".utf8), data: Data("The quick brown fox jumps over the lazy dog".utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hmac, "80070713463e7749b90c2dc24911e275")

        // 2. Synthetic Blu-ray MPLS binary with 2 clips & 2 chapter marks
        let validMpls = buildSyntheticMpls(
            clips: [("00001", UInt32(45_000), UInt32(45_000 * 61)), ("00002", UInt32(45_000), UInt32(45_000 * 121))],
            marks: [(0, 45_000), (1, 45_000)]
        )
        let parsed = MplsParser.parse(fileName: "00800.mpls", data: validMpls)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.clipNames, ["00001", "00002"])
        XCTAssertEqual(parsed?.chapters.count, 2)
        XCTAssertEqual(parsed?.chapters[0].positionMs, 0)
        XCTAssertEqual(parsed?.chapters[1].positionMs, 60_000)
        XCTAssertFalse(MplsParser.isSuspectedFakeLoopPlaylist(parsed!))

        // 3. Suspected fake loop playlist (repeating clip 00001 three times)
        let fakeLoopMpls = buildSyntheticMpls(
            clips: [
                ("00001", 45_000, 90_000),
                ("00001", 45_000, 90_000),
                ("00001", 45_000, 90_000),
            ],
            marks: []
        )
        let fakeParsed = MplsParser.parse(fileName: "00999.mpls", data: fakeLoopMpls)
        XCTAssertNotNil(fakeParsed)
        XCTAssertTrue(MplsParser.isSuspectedFakeLoopPlaylist(fakeParsed!))
    }

    // MARK: - Synthetic MPLS Builder

    private func buildSyntheticMpls(
        clips: [(name: String, inTicks: UInt32, outTicks: UInt32)],
        marks: [(refIdx: UInt16, ticks: UInt32)]
    ) -> Data {
        func appendU16BE(_ buf: inout Data, _ v: UInt16) {
            buf.append(UInt8((v >> 8) & 0xFF))
            buf.append(UInt8(v & 0xFF))
        }
        func appendU32BE(_ buf: inout Data, _ v: UInt32) {
            buf.append(UInt8((v >> 24) & 0xFF))
            buf.append(UInt8((v >> 16) & 0xFF))
            buf.append(UInt8((v >> 8) & 0xFF))
            buf.append(UInt8(v & 0xFF))
        }

        var playlist = Data()
        appendU32BE(&playlist, 0) // section length placeholder
        appendU16BE(&playlist, 0) // reserved
        appendU16BE(&playlist, UInt16(clips.count))
        appendU16BE(&playlist, 0) // subpaths
        for clip in clips {
            var item = Data()
            item.append(Data(clip.name.prefix(5).utf8))
            while item.count < 5 { item.append(0x20) }
            item.append(Data("M2TS".utf8))
            item.append(contentsOf: [UInt8](repeating: 0, count: 5)) // bytes 9..13
            appendU32BE(&item, clip.inTicks) // offset 14
            appendU32BE(&item, clip.outTicks) // offset 18
            appendU16BE(&playlist, UInt16(item.count))
            playlist.append(item)
        }

        var markSec = Data()
        appendU32BE(&markSec, 0)
        appendU16BE(&markSec, UInt16(marks.count))
        for m in marks {
            markSec.append(0x00) // reserved
            markSec.append(0x01) // entry mark (chapter)
            appendU16BE(&markSec, m.refIdx)
            appendU32BE(&markSec, m.ticks)
            markSec.append(contentsOf: [UInt8](repeating: 0, count: 6)) // pad to 14 bytes
        }

        var header = Data("MPLS0200".utf8)
        let playlistStart: UInt32 = 40
        let markStart: UInt32 = playlistStart + UInt32(playlist.count)
        appendU32BE(&header, playlistStart)
        appendU32BE(&header, markStart)
        while header.count < 40 { header.append(0) }

        var full = Data()
        full.append(header)
        full.append(playlist)
        full.append(markSec)
        return full
    }
}
