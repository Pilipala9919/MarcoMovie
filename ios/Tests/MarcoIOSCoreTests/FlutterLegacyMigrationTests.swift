// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation
import XCTest
@testable import MarcoIOSCore

final class FlutterLegacyMigrationTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarcoIOSMigrationTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempRoot {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    func testSecureCredentialsEncRoundTripAndTamperRejection() throws {
        let original: [String: String] = [
            "webdav_pass": "app-secret-pass-42",
            "netdisk_quark_cookie": "__pus=quark_token_abcdef; __puus=puus_123456",
            "marco_ai_api_key_v1": "sk-test-1234567890abcdef",
        ]
        let encrypted = try LegacyFlutterMigrator.encryptLegacySecureCredentialsForTesting(
            original,
            host: "mobile_marco_credential_key"
        )
        let decrypted = LegacyFlutterMigrator.decryptLegacySecureCredentialsFile(
            encrypted,
            hostCandidates: ["mobile_marco_credential_key"]
        )
        XCTAssertEqual(decrypted, original)

        // Flip a character in the ciphertext -> HMAC verification must fail cleanly
        var payloadStr = String(decoding: encrypted, as: UTF8.self)
        let lastChar = payloadStr.removeLast()
        payloadStr.append(lastChar == "a" ? "b" : "a")
        XCTAssertNil(
            LegacyFlutterMigrator.decryptLegacySecureCredentialsFile(
                Data(payloadStr.utf8),
                hostCandidates: ["mobile_marco_credential_key"]
            )
        )
    }

    func testPbkdf2AndLegacySha256PrivacyPinVerificationAndUpgrade() throws {
        let storageDir = tempRoot.appendingPathComponent("pin_storage", isDirectory: true)
        let keychain = InMemoryKeychainStore()
        let suiteName = "com.pilipala.test.pin.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storage = IOSStorageManager(storageDirectory: storageDir, keychain: keychain, defaults: defaults)
        XCTAssertFalse(storage.hasPrivacyPin())

        // 1. Current PBKDF2-SHA256 hash format
        try storage.setPrivacyPin("258099")
        XCTAssertTrue(storage.hasPrivacyPin())
        XCTAssertEqual(storage.privacyPinExpectedLength(), 6)
        XCTAssertTrue(storage.storedPrivacyPinHash()?.hasPrefix("pbkdf2:sha256:6:100000:") == true)
        XCTAssertTrue(storage.verifyPrivacyPin("258099"))
        XCTAssertFalse(storage.verifyPrivacyPin("258098"))

        // 2. Legacy Flutter sha256:<len>:<sha256("mm_pin_v1:<pin>")> upgrades transparently to PBKDF2
        let legacyDigest = SHA256.hash(data: Data("mm_pin_v1:1357".utf8))
            .map { String(format: "%02x", $0) }.joined()
        try storage.setStoredPrivacyPinHashVerbatim("sha256:4:\(legacyDigest)")
        XCTAssertEqual(storage.privacyPinExpectedLength(), 4)
        XCTAssertFalse(storage.verifyPrivacyPin("9999"))
        XCTAssertTrue(storage.verifyPrivacyPin("1357"))
        XCTAssertTrue(storage.storedPrivacyPinHash()?.hasPrefix("pbkdf2:sha256:4:100000:") == true)
    }

    func testEndToEndLegacyFlutterMigrationPreservesAllDataAndIsIdempotent() throws {
        let suiteName = "com.pilipala.test.mig.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyAppSupport = tempRoot.appendingPathComponent("legacy_app_support", isDirectory: true)
        let legacyDocs = tempRoot.appendingPathComponent("legacy_docs", isDirectory: true)
        let nativeStorageDir = tempRoot.appendingPathComponent("native_storage", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyAppSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyDocs, withIntermediateDirectories: true)

        let rawCmsJson = """
        {"sites":[{"key":"demo_vod","name":"演示点播","type":1,"api":"https://cms.marco.test/api.php/provide/vod/"}]}
        """
        let legacySubs: [[String: Any]] = [[
            "id": "sub_legacy_1",
            "name": "主订阅",
            "url": "https://sub.marco.test/config.json",
            "rawContent": rawCmsJson,
            "group": "默认分组",
            "isPrivate": false,
            "enabled": true,
            "updatedAt": 1_700_000_000_000,
        ]]
        let subsFile = legacyAppSupport.appendingPathComponent("subscriptions.json")
        try JSONSerialization.data(withJSONObject: legacySubs).write(to: subsFile)

        let legacyHist: [[String: Any]] = [[
            "site": "demo_vod",
            "id": "vod_101",
            "title": "星际漫游",
            "poster": "https://img.marco.test/poster.jpg",
            "line": "默认线路",
            "episode": "第02集",
            "index": 1,
            "position": 420_000,
            "duration": 2_400_000,
            "updated": 1_700_000_050_000,
        ]]
        let histFile = legacyAppSupport.appendingPathComponent("watch_history.json")
        try JSONSerialization.data(withJSONObject: legacyHist).write(to: histFile)

        // Legacy encrypted credentials file + legacy Flutter Keychain
        let encSecrets: [String: String] = [
            "webdav_pass": "webdav-secret-99",
            "netdisk_quark_cookie": "__pus=quark_session_valid_01; __puus=quark_puus_valid_01",
            "netdisk_uc_cookie": "__pus=uc_session_valid_02; __puus=uc_puus_valid_02",
            "netdisk_baidu_cookie": "BDUSS=baidu_valid_token_987654; STOKEN=abc",
            "netdisk_ali_token": "ali_token=a1b2c3d4e5f6g7h8i9j0k1l2",
            "netdisk_115_cookie": "UID=123456_A1_1700000; CID=abcdef123456; SEID=0123456789abcdef",
            "danmu_app_secret": "danmu-secret-xyz",
            "spider_gateway_token": "gw-tok-888",
        ]
        let encFile = legacyAppSupport.appendingPathComponent("secure_credentials.enc")
        let encData = try LegacyFlutterMigrator.encryptLegacySecureCredentialsForTesting(encSecrets)
        try encData.write(to: encFile)

        let legacyKeychain = InMemoryKeychainStore(initial: [
            "marco_ai_api_key_v1": Data("sk-legacy-ai-key-987654321".utf8),
        ])

        // Flutter SharedPreferences (`flutter.*`)
        let favJson = String(
            decoding: try JSONSerialization.data(withJSONObject: [[
                "site": "demo_vod",
                "id": "vod_101",
                "title": "星际漫游",
                "poster": "https://img.marco.test/poster.jpg",
                "remarks": "HD",
                "updated": 1_700_000_060_000,
            ]]),
            as: UTF8.self
        )
        let privFavJson = String(
            decoding: try JSONSerialization.data(withJSONObject: [[
                "site": "priv_site",
                "id": "priv_1",
                "title": "私密收藏",
                "updated": 1_700_000_070_000,
            ]]),
            as: UTF8.self
        )
        let pinHash = PrivacyPinCrypto.hashPin("6420")

        defaults.set(favJson, forKey: "flutter.favorites")
        defaults.set(privFavJson, forKey: "flutter.private_favorites")
        defaults.set(["三体", "沙丘2"], forKey: "flutter.global_search_history")
        defaults.set(["私密检索"], forKey: "flutter.private_search_history")
        defaults.set(pinHash, forKey: "flutter.privacy_password")
        defaults.set("mpv", forKey: "flutter.ios_player_engine_mode")
        defaults.set("bt.2446a", forKey: "flutter.ios_mpv_hdr_tone_mapping")
        defaults.set("cinema_vocal", forKey: "flutter.vocal_loudness_preset")
        defaults.set(90, forKey: "flutter.skip_intro_sec")
        defaults.set("https://dav.jianguoyun.com/dav/", forKey: "flutter.webdav_url")
        defaults.set("marco@sync.test", forKey: "flutter.webdav_user")
        defaults.set(true, forKey: "flutter.danmu_enabled")
        defaults.set("https://danmu.marco.test", forKey: "flutter.danmu_server_urls")
        defaults.set("app_demo_01", forKey: "flutter.danmu_app_id")
        defaults.set("http://10.0.2.2:9978", forKey: "flutter.spider_gateway_url")
        defaults.set(true, forKey: "flutter.spider_gateway_enabled")

        let embyDictJson = String(
            decoding: try JSONSerialization.data(withJSONObject: [
                "key": "home_emby",
                "label": "客厅 Emby",
                "serverUrl": "http://10.0.2.2:8096",
                "username": "alice",
                "userId": "u_01",
                "accessToken": "tok_emby_local",
                "allowCloudSync": true,
                "updatedAt": 1_700_000_080_000,
            ]),
            as: UTF8.self
        )
        defaults.set(embyDictJson, forKey: "flutter.emby.account.home_emby")

        // Legacy offline download manifest (active downloading item must normalize to .paused)
        let dlTask = DownloadTask(
            id: "dl_legacy_1",
            siteKey: "demo_vod",
            siteName: "演示点播",
            videoId: "vod_101",
            title: "星际漫游",
            episodeName: "第01集",
            sourceUrl: "https://cdn.marco.test/ep1.mp4",
            status: .downloading,
            progress: 0.45
        )
        let dlFile = legacyDocs.appendingPathComponent("marco_downloads.json")
        try JSONEncoder().encode([dlTask]).write(to: dlFile)

        let nativeKeychain = InMemoryKeychainStore()
        let storage = IOSStorageManager(
            storageDirectory: nativeStorageDir,
            keychain: nativeKeychain,
            defaults: defaults
        )

        let report = LegacyFlutterMigrator.migrateIfNeeded(
            into: storage,
            defaults: defaults,
            legacyApplicationSupportDir: legacyAppSupport,
            legacyDocumentsDir: legacyDocs,
            legacyKeychain: legacyKeychain
        )

        XCTAssertTrue(report.performed)
        XCTAssertFalse(report.alreadyCompleted)
        XCTAssertEqual(report.subscriptionsMigrated, 1)
        XCTAssertEqual(report.watchHistoryMigrated, 1)
        XCTAssertEqual(report.favoritesMigrated, 1)
        XCTAssertEqual(report.privateFavoritesMigrated, 1)
        XCTAssertTrue(report.privacyPinMigrated)
        XCTAssertEqual(report.mediaAccountsMigrated, 1)
        XCTAssertEqual(report.downloadsMigrated, 1)

        // Verify all 5 netdisks + WebDAV + Danmu + AI + Spider Gateway secrets migrated
        XCTAssertEqual(storage.loggedInNetdiskDrives().count, 5)
        XCTAssertEqual(storage.loadWebDavConfig().password, "webdav-secret-99")
        XCTAssertEqual(storage.danmuSettings().appSecret, "danmu-secret-xyz")
        XCTAssertEqual(storage.aiSecret(), "sk-legacy-ai-key-987654321")
        XCTAssertEqual(storage.spiderGatewayConfig().token, "gw-tok-888")
        XCTAssertTrue(storage.verifyPrivacyPin("6420"))

        let prefs = storage.preferences()
        XCTAssertEqual(prefs.iosEngineMode, .mpv)
        XCTAssertEqual(prefs.hdrToneMapping, .bt2446a)
        XCTAssertEqual(prefs.vocalLoudness, .cinemaVocal)
        XCTAssertEqual(prefs.skipIntroSec, 90)
        XCTAssertEqual(storage.downloadTasks().first?.status, .paused)

        // Verify legacy files are NEVER deleted (non-destructive migration)
        XCTAssertTrue(FileManager.default.fileExists(atPath: subsFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: histFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: encFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dlFile.path))

        // Second invocation must be an idempotent no-op
        let secondReport = LegacyFlutterMigrator.migrateIfNeeded(
            into: storage,
            defaults: defaults,
            legacyApplicationSupportDir: legacyAppSupport,
            legacyDocumentsDir: legacyDocs,
            legacyKeychain: legacyKeychain
        )
        XCTAssertFalse(secondReport.performed)
        XCTAssertTrue(secondReport.alreadyCompleted)
    }

    func testWebDavSyncMergePrivacyScrubbingCrossDeviceRemapAndDanmuSidecar() throws {
        // 1. Canonical URL rules including Jianguoyun normalization & sidecar derivation
        let jgy = try WebDavSyncService.resolveWebdavFileUrl("https://dav.jianguoyun.com")
        XCTAssertEqual(jgy, "https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json")
        let jgyDav = try WebDavSyncService.resolveWebdavFileUrl("https://dav.jianguoyun.com/dav/")
        XCTAssertEqual(jgyDav, "https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json")
        let sidecar = WebDavSyncService.resolveDanmuSidecarUrl(fromMainSyncUrl: jgy)
        XCTAssertEqual(sidecar?.absoluteString, "https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.danmu.json")

        // 2. Private subscription + history MUST be isolated & scrubbed from outbound sync payload
        let storageDir = tempRoot.appendingPathComponent("sync_storage", isDirectory: true)
        let storage = IOSStorageManager(storageDirectory: storageDir, keychain: InMemoryKeychainStore())
        let pubJson = """
        {"sites":[{"key":"pub_vod","name":"公共源","type":1,"api":"https://pub.marco.test/api.php/provide/vod/"}]}
        """
        let privJson = """
        {"sites":[{"key":"priv_vod","name":"私密源","type":1,"api":"https://priv.marco.test/api.php/provide/vod/"}]}
        """
        let pubRes = try storage.upsertSubscription(
            id: "local_pub_sub",
            name: "公共订阅",
            url: "https://pub.marco.test/sub.json",
            rawContent: pubJson,
            isPrivate: false,
            nowMs: 1_700_001_000_000
        )
        let privRes = try storage.upsertSubscription(
            id: "local_priv_sub",
            name: "隐私订阅",
            url: "https://priv.marco.test/sub.json",
            rawContent: privJson,
            group: "隐私空间",
            isPrivate: true,
            nowMs: 1_700_001_000_000
        )
        let pubSiteKey = CmsSite.canonicalScopedKey(rawKey: "pub_vod", subscriptionId: pubRes.entry.id)
        let privSiteKey = CmsSite.canonicalScopedKey(rawKey: "priv_vod", subscriptionId: privRes.entry.id)

        storage.upsertWatchHistory(WatchHistoryItem(
            site: pubSiteKey, id: "m1", title: "公共电影", position: 120_000, duration: 600_000, updated: 1_700_001_100_000
        ))
        storage.upsertWatchHistory(WatchHistoryItem(
            site: privSiteKey, id: "p1", title: "私密影片", position: 90_000, duration: 500_000, updated: 1_700_001_200_000
        ))

        let sync = WebDavSyncService(storage: storage)
        let exported = try sync.exportSyncPayload(nowMs: 1_700_002_000_000)
        XCTAssertTrue(exported.contains("公共电影"))
        XCTAssertFalse(exported.contains("私密影片"))
        XCTAssertFalse(exported.contains("priv.marco.test"))
        XCTAssertFalse(exported.contains("local_priv_sub"))

        // Merge remote payload with a different device's subscription ID for the same URL -> remaps cleanly
        let remotePayload = """
        {
          "schema": "marco-movie-sync",
          "version": 2,
          "updated": 1700003000000,
          "subscriptions": [
            {
              "id": "remote_device_sub_99",
              "name": "公共订阅",
              "url": "https://pub.marco.test/sub.json",
              "rawContent": "{\\"sites\\":[{\\"key\\":\\"pub_vod\\",\\"name\\":\\"公共源\\",\\"type\\":1,\\"api\\":\\"https://pub.marco.test/api.php/provide/vod/\\"}]}",
              "updatedAt": 1700001000000
            }
          ],
          "watch_history": [
            {
              "site": "sub::remote_device_sub_99::pub_vod",
              "id": "m2",
              "title": "远端同步剧集",
              "position": 300000,
              "duration": 1800000,
              "updated": 1700002500000
            }
          ],
          "favorites": [],
          "tombstones": {}
        }
        """
        let summary = try sync.mergeSyncPayload(remotePayload, nowMs: 1_700_003_500_000)
        XCTAssertTrue(summary.changed)
        let mergedHist = storage.watchHistory()
        XCTAssertTrue(mergedHist.contains(where: { $0.id == "m2" && $0.site == pubSiteKey }))
        XCTAssertTrue(mergedHist.contains(where: { $0.id == "p1" })) // Local private history preserved locally!
        XCTAssertFalse(summary.payloadJson.contains("私密影片")) // Never leaked outbound!
    }

    func testWebdavBindCryptoQrRoundTripAndTamperRejection() throws {
        let key = WebdavBindCrypto.generateKey()
        let qrUrl = try WebdavBindCrypto.buildBindQrUrl(baseEndpointUrl: "http://10.0.2.2:18651", key: key)
        let parsed = WebdavBindCrypto.parseBindQrInput(qrUrl)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.bindUrl, "http://10.0.2.2:18651/bind")
        XCTAssertEqual(parsed?.syncUrl, "http://10.0.2.2:18651/sync")
        XCTAssertEqual(parsed?.key, key)

        let sealed = try WebdavBindCrypto.sealJson(key: key, payload: [
            "url": "https://dav.jianguoyun.com/dav/",
            "user": "alice@sync.test",
            "pass": "secret-pass",
        ])
        let opened = try WebdavBindCrypto.openJson(key: key, envelopeJson: sealed)
        XCTAssertEqual(opened["user"] as? String, "alice@sync.test")
        XCTAssertEqual(opened["pass"] as? String, "secret-pass")

        // Wrong key must throw authenticationFailed
        let wrongKey = WebdavBindCrypto.generateKey()
        XCTAssertThrowsError(try WebdavBindCrypto.openJson(key: wrongKey, envelopeJson: sealed))
    }
}
