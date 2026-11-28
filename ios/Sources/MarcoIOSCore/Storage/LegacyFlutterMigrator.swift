// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation

/// Zero-loss idempotent migrator that seamlessly imports existing Flutter iOS (`v0.8.7` and earlier)
/// user data on first launch of the pure-Swift native app without ever deleting legacy files or keys.
///
/// Sources imported:
/// 1. `UserDefaults` (`flutter.*` SharedPreferences keys)
/// 2. `Application Support/` files (`subscriptions.json`, `watch_history.json`, `marco_downloads.json`, `secure_credentials.enc`)
/// 3. `flutter_secure_storage_service` Keychain items (WebDAV password, 5 netdisks, AI secrets, Danmu secret, Spider Gateway token)
public enum LegacyFlutterMigrator {
    public static let migrationFlagKey = "marco_ios_native_migrated_v1"
    public static let legacyFlutterKeychainService = "flutter_secure_storage_service"
    private static let legacyEncPrefix = "mm_sec_v1"

    private static let secretKeysToProbe: [String] = [
        "webdav_pass",
        "netdisk_quark_cookie",
        "netdisk_uc_cookie",
        "netdisk_baidu_cookie",
        "netdisk_ali_token",
        "netdisk_115_cookie",
        "spider_gateway_token",
        "marco_ai_api_key_v1",
        "marco_ai_oauth_session_v1",
        "marco_ai_lab_token_v1",
        "danmu_app_secret",
    ]

    /// Decrypts a legacy Flutter `secure_credentials.enc` payload (`mm_sec_v1:<salt>:<iv>:<tag>:<cipher>`).
    /// Matches Dart `DefaultSecureCredentialStore._decryptLegacyEntries` byte-for-byte.
    public static func decryptLegacySecureCredentialsFile(
        _ rawData: Data,
        hostCandidates: [String]? = nil
    ) -> [String: String]? {
        guard !rawData.isEmpty,
              let payload = String(data: rawData, encoding: .utf8)
        else {
            return nil
        }
        let parts = payload.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ":")
        guard parts.count == 5, parts[0] == legacyEncPrefix,
              let salt = hexDecode(parts[1]),
              let iv = hexDecode(parts[2]),
              let tag = hexDecode(parts[3]),
              let cipher = hexDecode(parts[4]),
              !salt.isEmpty, !iv.isEmpty, tag.count == 32
        else {
            return nil
        }

        let candidates: [String] = hostCandidates ?? [
            "mobile_marco_credential_key",
            ProcessInfo.processInfo.hostName,
            "desktop_marco_credential_key",
        ]

        for host in candidates where !host.isEmpty {
            let seed = Data("marco_movie_secure_storage_seed:\(host)".utf8)
            let derivedKey = Data(HMAC<SHA256>.authenticationCode(for: salt, using: SymmetricKey(data: seed)))

            var macInput = Data()
            macInput.reserveCapacity(salt.count + iv.count + cipher.count)
            macInput.append(salt)
            macInput.append(iv)
            macInput.append(cipher)
            let expectedTag = Data(HMAC<SHA256>.authenticationCode(for: macInput, using: SymmetricKey(data: derivedKey)))
            guard constantTimeEquals(tag, expectedTag) else { continue }

            let keystream = deriveLegacyKeystream(key: derivedKey, iv: iv, length: cipher.count)
            var plain = Data(count: cipher.count)
            for i in 0..<cipher.count {
                plain[i] = cipher[i] ^ keystream[i]
            }
            guard let jsonObj = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else {
                continue
            }
            var out: [String: String] = [:]
            for (k, v) in jsonObj where !(v is NSNull) {
                out[k] = String(describing: v)
            }
            return out
        }
        return nil
    }

    /// Encrypts entries using the exact legacy `mm_sec_v1:` wire format (used in round-trip migration unit tests).
    public static func encryptLegacySecureCredentialsForTesting(
        _ entries: [String: String],
        host: String = "mobile_marco_credential_key"
    ) throws -> Data {
        let plainData = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
        var saltBytes = [UInt8](repeating: 0, count: 16)
        var ivBytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            saltBytes[i] = UInt8.random(in: 0...255)
            ivBytes[i] = UInt8.random(in: 0...255)
        }
        let salt = Data(saltBytes)
        let iv = Data(ivBytes)
        let seed = Data("marco_movie_secure_storage_seed:\(host)".utf8)
        let key = Data(HMAC<SHA256>.authenticationCode(for: salt, using: SymmetricKey(data: seed)))
        let ks = deriveLegacyKeystream(key: key, iv: iv, length: plainData.count)
        var cipher = Data(count: plainData.count)
        for i in 0..<plainData.count {
            cipher[i] = plainData[i] ^ ks[i]
        }
        var macInput = Data()
        macInput.append(salt)
        macInput.append(iv)
        macInput.append(cipher)
        let tag = Data(HMAC<SHA256>.authenticationCode(for: macInput, using: SymmetricKey(data: key)))

        func toHex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
        let line = "\(legacyEncPrefix):\(toHex(salt)):\(toHex(iv)):\(toHex(tag)):\(toHex(cipher))"
        return Data(line.utf8)
    }

    /// Executes one-time non-destructive migration into `storage`.
    @discardableResult
    public static func migrateIfNeeded(
        into storage: IOSStorageManager,
        defaults: UserDefaults = .standard,
        legacyApplicationSupportDir: URL? = nil,
        legacyDocumentsDir: URL? = nil,
        legacyKeychain: KeychainStoreProtocol? = nil,
        force: Bool = false
    ) -> LegacyMigrationReport {
        if !force && defaults.bool(forKey: migrationFlagKey) {
            return LegacyMigrationReport(performed: false, alreadyCompleted: true)
        }

        let appSupportDir = legacyApplicationSupportDir
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let documentsDir = legacyDocumentsDir
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? appSupportDir
        let flutterKeychain = legacyKeychain ?? SystemKeychainStore(service: legacyFlutterKeychainService)

        var report = LegacyMigrationReport(performed: true, alreadyCompleted: false)

        func fStr(_ key: String) -> String? {
            if let s = defaults.string(forKey: "flutter.\(key)") { return s }
            return nil
        }
        func fBool(_ key: String) -> Bool? {
            let full = "flutter.\(key)"
            guard defaults.object(forKey: full) != nil else { return nil }
            return defaults.bool(forKey: full)
        }
        func fInt(_ key: String) -> Int? {
            let full = "flutter.\(key)"
            guard let obj = defaults.object(forKey: full) else { return nil }
            if let n = obj as? NSNumber { return n.intValue }
            if let s = obj as? String { return Int(s) }
            return nil
        }
        func fDouble(_ key: String) -> Double? {
            let full = "flutter.\(key)"
            guard let obj = defaults.object(forKey: full) else { return nil }
            if let n = obj as? NSNumber { return n.doubleValue }
            if let s = obj as? String { return Double(s) }
            return nil
        }
        func fStringList(_ key: String) -> [String]? {
            let full = "flutter.\(key)"
            if let arr = defaults.stringArray(forKey: full) { return arr }
            if let raw = defaults.string(forKey: full),
               let parsed = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [Any]
            {
                return parsed.compactMap { $0 as? String }
            }
            return nil
        }

        // 1. Decrypt legacy secure_credentials.enc (if still on disk) + read flutter_secure_storage Keychain
        var legacySecrets: [String: String] = [:]
        let encFile = appSupportDir.appendingPathComponent("secure_credentials.enc")
        if FileManager.default.fileExists(atPath: encFile.path),
           let encData = try? Data(contentsOf: encFile)
        {
            if let decrypted = decryptLegacySecureCredentialsFile(encData) {
                for (k, v) in decrypted where !v.isEmpty {
                    legacySecrets[k] = v
                }
            } else {
                report.warnings.append("legacy_secure_credentials_decrypt_failed")
            }
        }
        for key in secretKeysToProbe {
            if let data = try? flutterKeychain.data(forAccount: key),
               let val = String(data: data, encoding: .utf8),
               !val.isEmpty
            {
                legacySecrets[key] = val
            } else if let fallback = fStr(key), !fallback.isEmpty, legacySecrets[key] == nil {
                legacySecrets[key] = fallback
            }
        }

        // 2. Subscriptions: prefer Application Support/subscriptions.json, fallback to flutter.saved_subscriptions / flutter.config_raw_json
        var migratedSubs: [SubscriptionEntry] = []
        let subsFile = appSupportDir.appendingPathComponent("subscriptions.json")
        if FileManager.default.fileExists(atPath: subsFile.path),
           let data = try? Data(contentsOf: subsFile),
           let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        {
            migratedSubs = arr.map { SubscriptionEntry.fromDictionary($0) }
        } else if let rawSubsStr = fStr("saved_subscriptions"),
                  let arr = (try? JSONSerialization.jsonObject(with: Data(rawSubsStr.utf8))) as? [[String: Any]]
        {
            migratedSubs = arr.map { SubscriptionEntry.fromDictionary($0) }
        } else if let rawConfig = fStr("config_raw_json"), !rawConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let origin = fStr("origin") ?? ""
            let activeDepot = fStr("active_depot_name") ?? ""
            var depots: [CmsDepot] = []
            if let rawDepots = fStr("saved_depots"),
               let dArr = (try? JSONSerialization.jsonObject(with: Data(rawDepots.utf8))) as? [[String: Any]]
            {
                depots = dArr.map {
                    CmsDepot(
                        name: ($0["name"] as? String) ?? "",
                        url: ($0["url"] as? String) ?? "",
                        subscriptionId: ($0["subscriptionId"] as? String) ?? "migrated_primary"
                    )
                }
            }
            if let parsed = try? CmsParser.parseConfig(rawConfig, origin: origin) {
                migratedSubs = [
                    SubscriptionEntry(
                        id: "migrated_primary",
                        name: activeDepot.isEmpty ? "已迁移的订阅" : activeDepot,
                        url: origin,
                        rawContent: rawConfig,
                        siteCount: parsed.sites.count,
                        liveCount: parsed.lives.count,
                        updatedAt: Int64(Date().timeIntervalSince1970 * 1000),
                        activeDepotName: activeDepot,
                        depots: depots.isEmpty ? parsed.depots : depots
                    ),
                ]
            }
        }
        if !migratedSubs.isEmpty && storage.subscriptions().isEmpty {
            storage.saveSubscriptions(migratedSubs)
            report.subscriptionsMigrated = migratedSubs.count
        }

        // 3. Watch History: prefer Application Support/watch_history.json, fallback to flutter.watch_history
        var migratedHist: [WatchHistoryItem] = []
        let histFile = appSupportDir.appendingPathComponent("watch_history.json")
        if FileManager.default.fileExists(atPath: histFile.path),
           let data = try? Data(contentsOf: histFile),
           let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        {
            migratedHist = arr.map { WatchHistoryItem.fromDictionary($0) }
        } else if let rawHist = fStr("watch_history"),
                  let arr = (try? JSONSerialization.jsonObject(with: Data(rawHist.utf8))) as? [[String: Any]]
        {
            migratedHist = arr.map { WatchHistoryItem.fromDictionary($0) }
        }
        if !migratedHist.isEmpty && storage.watchHistory().isEmpty {
            storage.saveWatchHistoryRaw(migratedHist)
            report.watchHistoryMigrated = migratedHist.count
        }

        // 4. Public & Private Favorites
        if let rawFav = fStr("favorites"),
           let arr = (try? JSONSerialization.jsonObject(with: Data(rawFav.utf8))) as? [[String: Any]],
           storage.favorites().isEmpty
        {
            let favs = arr.map { FavoriteItem.fromDictionary($0) }
            storage.saveFavoritesRaw(favs)
            report.favoritesMigrated = favs.count
        }
        if let rawPrivFav = fStr("private_favorites"),
           let arr = (try? JSONSerialization.jsonObject(with: Data(rawPrivFav.utf8))) as? [[String: Any]],
           storage.privateFavorites().isEmpty
        {
            let privFavs = arr.map { FavoriteItem.fromDictionary($0) }
            storage.savePrivateFavorites(privFavs)
            report.privateFavoritesMigrated = privFavs.count
        }

        // 5. Search History (Public & Private)
        if let pubSearch = fStringList("global_search_history"), !pubSearch.isEmpty {
            storage.saveSearchHistory(pubSearch, isPrivateSpace: false)
        }
        if let privSearch = fStringList("private_search_history"), !privSearch.isEmpty {
            storage.saveSearchHistory(privSearch, isPrivateSpace: true)
        }

        // 6. Tombstones & Video Skip Records
        if let rawTombs = fStr("sync_tombstones"),
           let map = (try? JSONSerialization.jsonObject(with: Data(rawTombs.utf8))) as? [String: Any]
        {
            var tombs: [String: Int64] = storage.tombstones()
            for (k, v) in map {
                if let n = v as? NSNumber, n.int64Value > 0 {
                    tombs[k] = max(tombs[k] ?? 0, n.int64Value)
                }
            }
            storage.saveTombstones(tombs)
        }
        if let rawSkips = fStr("video_skip_records"),
           let map = (try? JSONSerialization.jsonObject(with: Data(rawSkips.utf8))) as? [String: Any]
        {
            for (k, v) in map {
                guard let entry = v as? [String: Any] else { continue }
                let intro = (entry["intro"] as? NSNumber)?.intValue ?? 0
                let outro = (entry["outro"] as? NSNumber)?.intValue ?? 0
                let updated = (entry["updated"] as? NSNumber)?.int64Value ?? 0
                storage.setVideoSkipRecord(VideoSkipRecord(intro: intro, outro: outro, updated: updated), for: k)
            }
        }

        // 7. Standalone Live Sources
        if let rawLives = fStr("standalone_live_sources_v1"),
           let arr = (try? JSONSerialization.jsonObject(with: Data(rawLives.utf8))) as? [[String: Any]]
        {
            let lives = arr.compactMap { StandaloneLiveSource.fromDictionary($0) }
            if !lives.isEmpty {
                storage.saveStandaloneLiveSources(lives)
                report.standaloneLivesMigrated = lives.count
            }
        }

        // 8. Privacy PIN (preserve PBKDF2-SHA256 or legacy hash verbatim!)
        if let rawPin = fStr("privacy_password"), !rawPin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !storage.hasPrivacyPin() {
                try? storage.setStoredPrivacyPinHashVerbatim(rawPin)
                report.privacyPinMigrated = true
            }
        }

        // 9. Preferences
        storage.updatePreferences { prefs in
            if let v = fInt("skip_intro_sec") { prefs.skipIntroSec = v }
            if let v = fInt("skip_outro_sec") { prefs.skipOutroSec = v }
            if let v = fDouble("play_speed") { prefs.playSpeed = v }
            if let v = fBool("auto_next") { prefs.autoNext = v }
            if let v = fBool("episodes_descending") { prefs.episodesDescending = v }
            if let v = fStr("repeat_mode"), !v.isEmpty { prefs.repeatMode = v }
            if let v = fStr("selected_site"), !v.isEmpty { prefs.selectedSiteKey = v }
            if let v = fStr("preferred_site"), !v.isEmpty { prefs.preferredSiteKey = v }
            if let v = fStr("preferred_line"), !v.isEmpty { prefs.preferredLine = v }
            if let v = fStr("ios_player_engine_mode") { prefs.iosEngineMode = IosPlaybackEngineMode.fromId(v) }
            if let v = fStr("ios_mpv_hdr_tone_mapping") { prefs.hdrToneMapping = IosHdrToneMappingMode.fromId(v) }
            if let v = fStr("vocal_loudness_preset") { prefs.vocalLoudness = VocalLoudnessPreset.fromId(v) }
            if let v = fStr("app_theme_mode") { prefs.appThemeMode = AppThemeMode.fromId(v) }
            if let v = fBool("ambient_glow_enabled") { prefs.ambientGlowEnabled = v }
            if let v = fStr("tv_ambient_theme"), !v.isEmpty { prefs.ambientTheme = v }
            if let v = fStr("tv_ambient_intensity"), !v.isEmpty { prefs.ambientIntensity = v }
            if let v = fBool("tv_ambient_poster_sync") { prefs.ambientPosterSync = v }
            if let v = fBool("hls_ad_strip_enabled") ?? fBool("hls_ad_removal_enabled") { prefs.hlsAdStripEnabled = v }
            if let v = fInt("disk_cache_max_mb") ?? fInt("media_disk_cache_limit_mb") { prefs.diskCacheMaxMb = v }
            if let v = fStr("default_aspect_mode"), !v.isEmpty { prefs.defaultAspectMode = v }
            if let v = fBool("player_always_show_clock") { prefs.playerAlwaysShowClock = v }
            if let v = fBool("show_hero_banner") { prefs.showHeroBanner = v }
            if let v = fBool("show_continue_watching") { prefs.showContinueWatching = v }
            if let v = fBool("show_curated_discovery") { prefs.showCuratedDiscovery = v }
            if let v = fStringList("home_section_order"), !v.isEmpty { prefs.homeSectionOrder = v }
            if let v = fStringList("home_section_hidden") { prefs.homeSectionHidden = v }
            if let v = fStringList("ios_player_toolbar_items_v1"), !v.isEmpty { prefs.iosPlayerToolbarItems = v }
            if let v = fStringList("netdisk_drive_order"), !v.isEmpty { prefs.netdiskDriveOrder = v }
            if let v = fBool("netdisk_prioritize_logged_in") { prefs.prioritizeLoggedInDrives = v }
            if let v = fBool("live_auto_categorize_v1") { prefs.liveAutoCategorize = v }
            if let v = fBool("live_hide_unreachable_v1") { prefs.liveHideUnreachable = v }
        }

        // 10. Netdisk Credentials (all 5 providers)
        let netdiskMap: [(provider: NetdiskProvider, secretKey: String)] = [
            (.quark, "netdisk_quark_cookie"),
            (.uc, "netdisk_uc_cookie"),
            (.baidu, "netdisk_baidu_cookie"),
            (.ali, "netdisk_ali_token"),
            (.drive115, "netdisk_115_cookie"),
        ]
        for (provider, secretKey) in netdiskMap {
            if let val = legacySecrets[secretKey], !val.isEmpty {
                if (try? storage.setNetdiskCredential(val, for: provider.rawValue)) != nil {
                    report.credentialsMigrated += 1
                }
            }
        }

        // 11. WebDAV Config
        let webdavUrl = fStr("webdav_url") ?? ""
        if !webdavUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let webdavCfg = WebDavConfig(
                url: webdavUrl,
                username: fStr("webdav_user") ?? "",
                password: legacySecrets["webdav_pass"] ?? "",
                autoSync: fBool("webdav_auto") ?? true,
                syncSubscriptions: fBool("webdav_sync_subs") ?? true,
                syncHistory: fBool("webdav_sync_history") ?? true,
                syncDanmu: fBool("webdav_sync_danmu") ?? true,
                lastSyncTimeMs: Int64(fInt("sync_last_time") ?? 0),
                lastSyncStatus: fStr("sync_last_status") ?? "",
                lastDanmuSyncStatus: fStr("sync_danmu_last_status") ?? ""
            )
            if (try? storage.saveWebDavConfig(webdavCfg)) != nil {
                report.credentialsMigrated += 1
            }
        }

        // 12. Spider Gateway
        if let gwUrl = fStr("spider_gateway_url"), !gwUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let gw = SpiderGatewayConfig(
                enabled: fBool("spider_gateway_enabled") ?? false,
                baseUrl: gwUrl,
                deviceName: fStr("spider_gateway_device_name") ?? "",
                token: legacySecrets["spider_gateway_token"] ?? ""
            )
            try? storage.saveSpiderGatewayConfig(gw)
        }

        // 13. Danmaku Settings & Sync Doc
        let danmuServerUrls = fStr("danmu_server_urls") ?? ""
        let danmuEnabled = fBool("danmu_enabled") ?? false
        if danmuEnabled || !danmuServerUrls.isEmpty || fStr("danmu_app_id") != nil {
            let ds = DanmuSettings(
                enabled: danmuEnabled,
                serverUrls: danmuServerUrls,
                appId: fStr("danmu_app_id") ?? "",
                appSecret: legacySecrets["danmu_app_secret"] ?? "",
                opacity: fDouble("danmu_opacity") ?? 0.85,
                displayArea: fDouble("danmu_display_area") ?? 0.50,
                fontSize: fDouble("danmu_font_size") ?? 20.0,
                speedMultiplier: fDouble("danmu_speed_multiplier") ?? 1.0,
                timeOffsetMs: fInt("danmu_time_offset_ms") ?? 0,
                showScroll: fBool("danmu_show_scroll") ?? true,
                showTop: fBool("danmu_show_top") ?? true,
                showBottom: fBool("danmu_show_bottom") ?? true,
                maxRows: fInt("danmu_max_rows") ?? 14,
                blockRules: fStringList("danmu_block_rules") ?? [],
                authorizedCredentialOrigins: fStringList("danmu_authorized_credential_origins") ?? [],
                pendingAuthOrigins: fStringList("danmu_pending_auth_origins") ?? [],
                dismissedAuthOrigins: fStringList("danmu_dismissed_auth_origins") ?? []
            )
            storage.saveDanmuSettings(ds)

            let parsedOrigins = danmuServerUrls
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { DanmuSourceEntry(url: $0) }
            let syncDoc = DanmuSourceSyncDocument(
                updatedAt: Int64(fInt("danmu_sources_updated_at") ?? 0),
                revision: fInt("danmu_sources_revision") ?? 0,
                clearedAt: Int64(fInt("danmu_sources_cleared_at") ?? 0),
                initialized: fBool("danmu_sources_initialized") ?? !parsedOrigins.isEmpty,
                sources: parsedOrigins
            )
            storage.saveDanmuSyncDocuments(current: syncDoc, base: syncDoc)
        }

        // 14. AI Config, Profiles & Secrets
        if let rawAiCfg = fStr("marco_ai_config_v1"),
           let cfgData = rawAiCfg.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(AiConfig.self, from: cfgData)
        {
            storage.saveAiConfig(decoded)
        }
        if let rawProfiles = fStr("marco_ai_profiles_v1"),
           let data = rawProfiles.data(using: .utf8),
           let profiles = try? JSONDecoder().decode([AiProviderProfile].self, from: data)
        {
            storage.saveAiProfiles(profiles)
            report.aiProfilesMigrated = profiles.count
            for profile in profiles {
                let secretKey = profile.secretKeychainKey
                if let secData = try? flutterKeychain.data(forAccount: secretKey),
                   let secStr = String(data: secData, encoding: .utf8),
                   !secStr.isEmpty
                {
                    if (try? storage.setAiSecret(secStr, forProfileId: profile.id)) != nil {
                        report.credentialsMigrated += 1
                    }
                } else if let encSec = legacySecrets[secretKey], !encSec.isEmpty {
                    if (try? storage.setAiSecret(encSec, forProfileId: profile.id)) != nil {
                        report.credentialsMigrated += 1
                    }
                }
            }
        }
        if let apiKey = legacySecrets["marco_ai_api_key_v1"], !apiKey.isEmpty {
            if (try? storage.setAiSecret(apiKey)) != nil {
                report.credentialsMigrated += 1
            }
        }

        // 15. External Media Library & Emby Accounts (`flutter.emby.account.*`, `flutter.jellyfin.account.*`, etc.)
        let allDefaultsDict = defaults.dictionaryRepresentation()
        var embyAccounts = storage.embyAccounts()
        var mediaAccounts = storage.mediaLibraryAccounts()
        let prefixKinds: [(prefix: String, kind: MediaLibraryKind)] = [
            ("flutter.emby.account.", .emby),
            ("flutter.jellyfin.account.", .jellyfin),
            ("flutter.plex.account.", .plex),
            ("flutter.webdavlib.account.", .webdav),
            ("flutter.alist.account.", .alist),
            ("flutter.smbnas.account.", .smb2),
            ("flutter.localfile.account.", .local),
        ]
        for (defKey, rawVal) in allDefaultsDict {
            guard let jsonStr = rawVal as? String,
                  let dict = (try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8))) as? [String: Any]
            else { continue }
            for (prefix, kind) in prefixKinds where defKey.hasPrefix(prefix) {
                let accKey = String(defKey.dropFirst(prefix.count))
                guard !accKey.isEmpty else { continue }
                if kind == .emby {
                    var copy = dict
                    if copy["key"] == nil { copy["key"] = accKey }
                    if let emby = EmbyAccount.fromDictionary(copy),
                       !embyAccounts.contains(where: { $0.key == emby.key })
                    {
                        embyAccounts.append(emby)
                        report.mediaAccountsMigrated += 1
                    }
                } else {
                    let label = ((dict["label"] ?? dict["name"]) as? String) ?? accKey
                    let baseUrl = ((dict["baseUrl"] ?? dict["url"] ?? dict["serverUrl"]) as? String) ?? ""
                    let host = (dict["host"] as? String) ?? ""
                    let port = (dict["port"] as? NSNumber)?.intValue
                    let path = (dict["path"] as? String) ?? ""
                    let share = (dict["share"] as? String) ?? ""
                    let user = (dict["username"] as? String) ?? ""
                    let domain = (dict["domain"] as? String) ?? ""
                    let userId = (dict["userId"] as? String) ?? ""
                    let deviceId = (dict["deviceId"] as? String) ?? ""
                    let account = MediaLibraryAccount(
                        kind: kind,
                        key: accKey,
                        label: label,
                        baseUrl: baseUrl,
                        host: host,
                        port: port,
                        path: path,
                        shareName: share,
                        username: user,
                        domain: domain,
                        userId: userId,
                        deviceId: deviceId,
                        allowInvalidCert: (dict["allowInvalidCert"] as? Bool) ?? false,
                        allowCloudSync: (dict["allowCloudSync"] as? Bool) ?? false,
                        updatedAt: (dict["updatedAt"] as? NSNumber)?.int64Value ?? 0
                    )
                    if !mediaAccounts.contains(where: { $0.id == account.id }) {
                        mediaAccounts.append(account)
                        if let tokenOrPass = (dict["token"] ?? dict["accessToken"] ?? dict["password"]) as? String,
                           !tokenOrPass.isEmpty
                        {
                            try? storage.setMediaLibrarySecret(tokenOrPass, for: account)
                        }
                        report.mediaAccountsMigrated += 1
                    }
                }
            }
        }
        if !embyAccounts.isEmpty { storage.saveEmbyAccounts(embyAccounts) }
        if !mediaAccounts.isEmpty { storage.saveMediaLibraryAccounts(mediaAccounts) }

        // 16. Offline Downloads (`marco_downloads.json` in Documents or Application Support)
        let downloadCandidates = [
            documentsDir.appendingPathComponent("marco_downloads.json"),
            appSupportDir.appendingPathComponent("marco_downloads.json"),
        ]
        for dlFile in downloadCandidates where FileManager.default.fileExists(atPath: dlFile.path) {
            if let data = try? Data(contentsOf: dlFile),
               let tasks = try? JSONDecoder().decode([DownloadTask].self, from: data),
               !tasks.isEmpty,
               storage.downloadTasks().isEmpty
            {
                let normalized = tasks.map { task -> DownloadTask in
                    var copy = task
                    if copy.status == .downloading || copy.status == .queued {
                        copy.status = .paused
                    }
                    return copy
                }
                storage.saveDownloadTasks(normalized)
                report.downloadsMigrated = normalized.count
                break
            }
        }

        defaults.set(true, forKey: migrationFlagKey)
        return report
    }

    // MARK: - Crypto Helpers

    private static func deriveLegacyKeystream(key: Data, iv: Data, length: Int) -> Data {
        var result = Data()
        result.reserveCapacity(length)
        let symKey = SymmetricKey(data: key)
        var counter: UInt32 = 0
        while result.count < length {
            var blockInput = Data(iv)
            blockInput.append(UInt8((counter >> 24) & 0xFF))
            blockInput.append(UInt8((counter >> 16) & 0xFF))
            blockInput.append(UInt8((counter >> 8) & 0xFF))
            blockInput.append(UInt8(counter & 0xFF))
            let mac = Data(HMAC<SHA256>.authenticationCode(for: blockInput, using: symKey))
            let remaining = length - result.count
            result.append(mac.prefix(remaining))
            counter &+= 1
        }
        return result
    }

    private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) {
            diff |= x ^ y
        }
        return diff == 0
    }

    private static func hexDecode(_ hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = hexVal(chars[i]), let lo = hexVal(chars[i + 1]) else { return nil }
            out.append((hi << 4) | lo)
            i += 2
        }
        return out
    }

    private static func hexVal(_ b: UInt8) -> UInt8? {
        if b >= 0x30 && b <= 0x39 { return b - 0x30 }
        if b >= 0x41 && b <= 0x46 { return b - 0x41 + 10 }
        if b >= 0x61 && b <= 0x66 { return b - 0x61 + 10 }
        return nil
    }
}
