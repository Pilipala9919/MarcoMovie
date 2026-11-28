// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import XCTest
@testable import MarcoIOSCore

final class SourceAndParserTests: XCTestCase {
    func testConfigDecoderJsoncBase64DeflateAndAes128Cbc() throws {
        // 1. JSONC comment stripping (including // inside strings preserved!)
        let jsonc = """
        {
          // line comment
          "spider": "https://cdn.marco.test/spider.jar", /* inline comment */
          "sites": [
            {"key": "s1", "name": "站点1", "type": 1, "api": "https://vod.marco.test/api.php/provide/vod/",}
          ],
        }
        """
        let stripped = ConfigDecoder.stripJsonComments(jsonc)
        let parsedObj = try JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any]
        XCTAssertEqual(parsedObj?["spider"] as? String, "https://cdn.marco.test/spider.jar")

        // 2. Base64-wrapped JSON & `**` prefix unpacking
        let b64 = Data(stripped.utf8).base64EncodedString()
        XCTAssertNotNil(ConfigDecoder.tryDecodeBase64Json(b64))
        let unpacked = ConfigDecoder.unpackConfigText("prefix_junk**\(b64)")
        XCTAssertTrue(unpacked.contains("vod.marco.test"))

        // 3. Raw DEFLATE round-trip
        let sample = Data(String(repeating: "MarcoMovieConfigPayload-2026-", count: 20).utf8)
        let compressed = try XCTUnwrap(ConfigDecoder.compressDeflate(sample))
        let inflated = try XCTUnwrap(ConfigDecoder.decompressDeflate(compressed))
        XCTAssertEqual(inflated, sample)

        // 4. AES-128-CBC decrypt verification against CommonCrypto encryptor
        let key = Data("0123456789abcdef".utf8)
        let iv = Data("fedcba9876543210".utf8)
        let plain = Data("{\"sites\":[]}".utf8)
        let cipher = try DownloadManager.encryptAes128Cbc(data: plain, key: key, iv: iv)
        let decrypted = ConfigDecoder.aes128CbcDecrypt(
            cipher: [UInt8](cipher),
            key: [UInt8](key),
            iv: [UInt8](iv)
        )
        XCTAssertEqual(decrypted.map { Data($0) }, plain)
    }

    func testCmsParserSingleRepoMultiDepotLinesAndPublicSanitization() throws {
        let singleJson = """
        {
          "spider": "./spider.jar;md5;0123456789abcdef0123456789abcdef",
          "sites": [
            {"key": "pub_site", "name": "公共影院", "type": 1, "api": "https://pub.marco.test/api.php/provide/vod/"},
            {"key": "priv_site", "name": "私密频道", "type": 1, "api": "https://priv.marco.test/api.php/provide/vod/", "isPrivate": true}
          ],
          "lives": [
            {"name": "央视卫视", "type": 0, "url": "./live.m3u"}
          ],
          "parses": [
            {"name": "解析1", "type": 1, "url": "https://jx.marco.test/?url="}
          ],
          "ads": ["ad.marco.invalid"]
        }
        """
        let cfg = try CmsParser.parseConfig(
            singleJson,
            origin: "https://repo.marco.test/tv/config.json",
            subscriptionId: "sub_alpha"
        )
        XCTAssertEqual(cfg.sites.count, 2)
        XCTAssertEqual(cfg.lives.count, 1)
        XCTAssertEqual(cfg.lives.first?.url, "https://repo.marco.test/tv/live.m3u")
        XCTAssertEqual(cfg.parses.count, 1)
        XCTAssertEqual(cfg.ads, ["ad.marco.invalid"])

        // Public sanitization strips private sites cleanly
        let sanitized = CmsParser.sanitizePublicRawConfig(singleJson)
        XCTAssertTrue(sanitized.contains("pub_site"))
        XCTAssertFalse(sanitized.contains("priv_site"))

        // Multi-depot config (`urls`)
        let multiRepoJson = """
        {
          "urls": [
            {"name": "主仓", "url": "https://repo1.marco.test/main.json"},
            {"name": "备用仓", "url": "https://repo2.marco.test/backup.json"}
          ]
        }
        """
        let multi = try CmsParser.parseConfig(multiRepoJson, origin: "https://hub.marco.test/dc.json")
        XCTAssertEqual(multi.depots.count, 2)
        XCTAssertEqual(multi.depots[0].name, "主仓")

        // PlayFrom / PlayUrl parsing
        let lines = CmsParser.parseLines(
            playFrom: "qq$$$m3u8",
            playUrl: "第1集$https://stream.marco.test/1.mp4#第2集$https://stream.marco.test/2.mp4$$$HD$https://stream.marco.test/1.m3u8"
        )
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].episodes.count, 2)
        XCTAssertEqual(lines[1].episodes.first?.url, "https://stream.marco.test/1.m3u8")
    }

    func testLiveCatalogParserM3uTxtBase64AndPipeHeaders() throws {
        // 1. M3U with tvg-logo, group-title, and pipe headers
        let m3u = """
        #EXTM3U
        #EXTINF:-1 tvg-logo="https://img.marco.test/cctv1.png" group-title="央视频道",CCTV-1 综合
        https://live.marco.test/cctv1.m3u8|Referer=https%3A%2F%2Flive.marco.test%2F&User-Agent=MarcoTV
        #EXTINF:-1 group-title="卫视频道",湖南卫视
        https://live.marco.test/hunan.m3u8
        """
        let groups = try LiveCatalogParser.parse(m3u, origin: "https://live.marco.test/list.m3u")
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].name, "央视频道")
        XCTAssertEqual(groups[0].channels.first?.name, "CCTV-1 综合")
        XCTAssertEqual(groups[0].channels.first?.episodes.first?.headers["Referer"], "https://live.marco.test/")
        XCTAssertEqual(groups[0].channels.first?.episodes.first?.headers["User-Agent"], "MarcoTV")

        // 2. TXT `#genre#` multi-source channel parsing
        let txt = """
        央视频道,#genre#
        CCTV-1,https://live.marco.test/line1.m3u8#https://live.marco.test/line2.m3u8
        """
        let txtGroups = try LiveCatalogParser.parse(txt)
        XCTAssertEqual(txtGroups.count, 1)
        XCTAssertEqual(txtGroups[0].channels.first?.episodes.count, 2)

        // 3. Base64-encoded live text detection
        let encodedTxt = Data(txt.utf8).base64EncodedString()
        let decodedTxt = LiveCatalogParser.tryDecodeBase64LiveText(encodedTxt)
        XCTAssertNotNil(decodedTxt)
        XCTAssertTrue(decodedTxt?.contains("CCTV-1") == true)
    }

    func testCspRuleEnginesXbpqXyqXpathAndHomeExtraction() async throws {
        let xbpqRule = """
        {
          "主页url": "https://site.marco.test/",
          "分类": "电影$1#剧集$2",
          "数组": "<div class=\\"card\\">&&</div>",
          "标题": "title=\\"&&\\"",
          "链接": "href=\\"&&\\"",
          "图片": "data-src=\\"&&\\""
        }
        """
        let xbpqSite = CmsSite(key: "xbpq_demo", name: "XBPQ测试", type: 3, api: "csp_XBPQ", ext: xbpqRule)
        let xyqSite = CmsSite(key: "xyq_demo", name: "XYQ测试", type: 3, api: "csp_XYQ", ext: "{}")
        let xpathSite = CmsSite(key: "xp_demo", name: "XPath测试", type: 3, api: "csp_XPathFilter", ext: "{}")
        XCTAssertTrue(CspRuleEngines.supports(xbpqSite))
        XCTAssertTrue(CspRuleEngines.isXbpqSite(xbpqSite))
        XCTAssertTrue(CspRuleEngines.isXyqSite(xyqSite))
        XCTAssertTrue(CspRuleEngines.isXpathSite(xpathSite))

        let sampleHtml = """
        <html><body>
          <div class="card"><a href="/vod/101.html" title="流浪地球2"><img data-src="/img/101.jpg"/></a></div>
          <div class="card"><a href="/vod/102.html" title="漫长的季节"><img data-src="/img/102.jpg"/></a></div>
        </body></html>
        """
        let payload = try await CspRuleEngines.homeContent(site: xbpqSite) { _, _ in sampleHtml }
        XCTAssertEqual(payload.categories.count, 2)
        XCTAssertEqual(payload.listing.videos.count, 2)
        XCTAssertEqual(payload.listing.videos[0].title, "流浪地球2")
        XCTAssertEqual(payload.listing.videos[0].id, "https://site.marco.test/vod/101.html")
        XCTAssertEqual(payload.listing.videos[0].poster, "https://site.marco.test/img/101.jpg")
    }

    func testQuickJSBridgeDeadlineInterruptJsSourceHostAndDrpyDetection() async throws {
        // 1. QuickJS evaluation + interrupt handler stops infinite loop cleanly
        let bridge = try QuickJSBridge(memoryLimitBytes: 16 * 1024 * 1024)
        defer { bridge.close() }

        let sum = try bridge.evaluate("JSON.stringify({ ok: true, answer: 21 + 21 })")
        XCTAssertTrue(sum.contains("\"answer\":42"))

        let start = Date()
        XCTAssertThrowsError(try bridge.evaluate("while (true) {}", timeoutSeconds: 0.15))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.5, "QuickJS interrupt handler must abort infinite loops promptly")

        // 2. CommonJS Type-3 spider lifecycle through JsSourceHost
        let spiderSource = """
        module.exports = {
          init: function(ext) {},
          homeContent: function(filter) {
            return JSON.stringify({
              class: [{ type_id: "1", type_name: "电影" }],
              list: [{ vod_id: "v_42", vod_name: "沙丘2", vod_pic: "https://img.marco.test/d2.jpg", vod_remarks: "4K" }]
            });
          },
          detailContent: function(ids) {
            return JSON.stringify({
              list: [{
                vod_id: ids[0],
                vod_name: "沙丘2",
                vod_play_from: "蓝光专线",
                vod_play_url: "正片$https://stream.marco.test/dune2.m3u8"
              }]
            });
          },
          searchContent: function(wd, quick, pg) {
            return JSON.stringify({ list: [{ vod_id: "v_42", vod_name: wd }] });
          },
          playerContent: function(flag, id, vipFlags) {
            return JSON.stringify({ parse: 0, url: id, header: { Referer: "https://stream.marco.test/" } });
          }
        };
        """
        let jsSite = CmsSite(key: "js_demo", name: "JS测试", type: 3, api: "https://js.marco.test/spider.js")
        let host = try JsSourceHost(site: jsSite, scriptSource: spiderSource)
        let home = try await host.homeContent()
        XCTAssertEqual(home.categories.first?.name, "电影")
        XCTAssertEqual(home.listing.videos.first?.title, "沙丘2")

        let detail = try await host.detailContent(ids: ["v_42"])
        XCTAssertEqual(detail?.lines.first?.episodes.first?.url, "https://stream.marco.test/dune2.m3u8")

        let play = try await host.playerContent(flag: "蓝光专线", id: "https://stream.marco.test/dune2.m3u8")
        XCTAssertEqual(play.parse, 0)
        XCTAssertEqual(play.headers["Referer"], "https://stream.marco.test/")

        // 3. DRPY2 rule detection
        XCTAssertTrue(DrpySourceHost.looksLikeDrpyRule("var rule = { title: 'Test', host: 'https://drpy.marco.test' };"))
        XCTAssertFalse(DrpySourceHost.looksLikeDrpyRule("export default { init() {} };"))
        XCTAssertFalse(DrpySourceHost.looksLikeDrpyRule("{\"sites\": []}"))
    }

    func testCatPawCryptoHashAndAesCipherRoundTrip() throws {
        let digest = try CatPawCrypto.hash(algorithm: "sha256", data: Data("marco".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex.count, 64)

        let keyB64 = Data("0123456789abcdef".utf8).base64EncodedString()
        let ivB64 = Data("abcdef0123456789".utf8).base64EncodedString()
        let inputB64 = Data("CatPawCryptoTestPayload".utf8).base64EncodedString()

        let encryptedDict = try CatPawCrypto.nodeCipher(
            op: "encrypt",
            algo: "aes-128-cbc",
            keyBase64: keyB64,
            ivBase64: ivB64,
            dataBase64: inputB64
        )
        let encryptedB64 = try XCTUnwrap(encryptedDict["data"])
        let decryptedDict = try CatPawCrypto.nodeCipher(
            op: "decrypt",
            algo: "aes-128-cbc",
            keyBase64: keyB64,
            ivBase64: ivB64,
            dataBase64: encryptedB64
        )
        let decryptedB64 = try XCTUnwrap(decryptedDict["data"])
        let decoded = try XCTUnwrap(CatPawCrypto.decodeLooseBase64(decryptedB64))
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "CatPawCryptoTestPayload")
    }
}
