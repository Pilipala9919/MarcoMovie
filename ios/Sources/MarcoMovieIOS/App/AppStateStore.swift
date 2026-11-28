// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Central App State Coordinator, 5-Tap Privacy Guard & Ed25519 AI Lab Verifier

import CryptoKit
import Foundation
import MarcoIOSCore
import UIKit

// MARK: - State Broadcast Notifications

public extension Notification.Name {
    static let marcoStateDidChange = Notification.Name("com.pilipala.marcoMovie.stateDidChange")
    static let marcoSiteDidChange = Notification.Name("com.pilipala.marcoMovie.siteDidChange")
    static let marcoPrivacyDidChange = Notification.Name("com.pilipala.marcoMovie.privacyDidChange")
    static let marcoThemeDidChange = Notification.Name("com.pilipala.marcoMovie.themeDidChange")
    static let marcoDownloadsDidChange = Notification.Name("com.pilipala.marcoMovie.downloadsDidChange")
}

// MARK: - Ed25519 AI Lab Passcode Verifier (MMAILAB1)

public struct AiLabPasscodeClaims: Equatable, Sendable {
    public let rawToken: String
    public let subject: String
    public let platform: String
    public let expiresAtUnix: Int64?
    public let experimentalOAuth: Bool

    public var isExpired: Bool {
        guard let exp = expiresAtUnix, exp > 0 else { return false }
        return Int64(Date().timeIntervalSince1970) > exp
    }
}

private enum AppAiLabPasscodeHelper {
    static let keychainAccount = "marco_ai_lab_token_v1"

    static func verify(_ rawInput: String) -> Result<AiLabPasscodeClaims, MarcoError> {
        let result = MarcoIOSCore.AiLabPasscodeVerifier.verify(rawInput, targetPlatform: "ios")
        guard result.isValid, let payload = result.payload else {
            return .failure(.invalidFormat(result.messageZh))
        }
        let exp: Int64? = payload.expiresAt > 0 ? payload.expiresAt : nil
        let claims = AiLabPasscodeClaims(
            rawToken: result.canonicalToken,
            subject: payload.tag.isEmpty ? "AI Lab Member" : payload.tag,
            platform: payload.platform.isEmpty ? "ios" : payload.platform,
            expiresAtUnix: exp,
            experimentalOAuth: payload.experimentalOAuth
        )
        return .success(claims)
    }
}

// MARK: - Central Application State Store

@MainActor
public final class AppStateStore {
    public static let shared = AppStateStore()

    public let storage: IOSStorageManager
    public let cmsClient: CmsClient
    public let webDavSync: WebDavSyncService
    public private(set) var lanServer: LanConfigServer
    public let danmuService: DanmuService
    public let downloadManager: DownloadManager
    public let castService: CastService
    public let aiService: AiService
    public let appUpdateService: AppUpdateService
    public let netdiskService: NetdiskService
    public let personalNetdiskLibrary: PersonalNetdiskLibrary
    public let headerProxy: LocalHeaderProxyServer
    public let rangeProxy: NetdiskRangeProxyServer

    public private(set) var lastMigrationReport: LegacyMigrationReport?
    public private(set) var config: CmsConfig = CmsConfig()
    public private(set) var activeSite: CmsSite?
    public private(set) var isPrivacySpaceUnlocked: Bool = false
    public var isSimulatorDemoMode: Bool = false
    public private(set) var cachedAiLabClaims: AiLabPasscodeClaims?
    public private(set) var latestDownloadProgress: [String: DownloadProgressEvent] = [:]

    /// Optional biometric unlock preference stored in `UserDefaults`.
    private static let biometricEnabledDefaultsKey = "marco_ios_privacy_biometric_enabled"
    private static let logoTapWindowSeconds: TimeInterval = 2.5
    private static let requiredLogoTaps = 5

    private var logoTapTimestamps: [TimeInterval] = []

    private init() {
        let storage = IOSStorageManager()
        self.storage = storage
        self.cmsClient = CmsClient()
        self.webDavSync = WebDavSyncService(storage: storage)
        self.lanServer = LanConfigServer(
            storage: storage,
            syncService: self.webDavSync,
            cmsClient: self.cmsClient
        )
        self.danmuService = DanmuService()
        self.castService = CastService()
        self.aiService = AiService(storage: storage)
        self.appUpdateService = AppUpdateService()
        self.netdiskService = NetdiskService()
        self.personalNetdiskLibrary = PersonalNetdiskLibrary(storage: storage)
        self.headerProxy = LocalHeaderProxyServer()
        self.rangeProxy = NetdiskRangeProxyServer()
        self.downloadManager = DownloadManager(storage: storage)

        bootstrap()
    }

    // MARK: - Bootstrapping & Lifecycle

    private func bootstrap() {
        // 1. Run idempotent zero-loss Flutter v0.8.7 migration on first native launch.
        lastMigrationReport = LegacyFlutterMigrator.migrateIfNeeded(into: storage)

        // 2. Apply persisted theme mode across UIKit appearance system.
        applyStoredTheme(animated: false)

        // 3. Hydrate cached AI Lab passcode status from Keychain.
        reloadAiLabClaims()

        // 4. Wire download progress broadcast to NotificationCenter.
        Task {
            await downloadManager.setProgressHandler { event in
                Task { @MainActor in
                    AppStateStore.shared.handleDownloadProgress(event)
                }
            }
        }

        // 5. Wire LAN config server callbacks.
        configureLanServerCallbacks(lanServer)

        // 6. Load merged CMS config & active site.
        reloadConfig()
    }

    public func handleSceneDidBecomeActive() {
        Task {
            await CatpawSourceHost.shared.onAppResumed()
            if MarcoBuildCapabilities.hasCatpaw {
                await CatpawSourceHost.shared.syncNetdiskConfig(from: storage)
            }
        }
    }

    public func handleSceneDidEnterBackground() {
        // Keep privacy hygiene strict when moving to background while Privacy Space is locked.
        if !isPrivacySpaceUnlocked {
            PosterImageLoader.shared.purgePrivateMemoryCache()
        }
    }

    // MARK: - Config, Sites & Subscriptions

    public func reloadConfig() {
        config = storage.mergedConfig()
        let pool = visibleAvailableSites()
        let prefs = storage.preferences()

        if let current = activeSite, pool.contains(where: { $0.key == current.key }) {
            activeSite = pool.first(where: { $0.key == current.key })
        } else if !prefs.selectedSiteKey.isEmpty,
                  let selected = pool.first(where: { $0.key == prefs.selectedSiteKey })
        {
            activeSite = selected
        } else if !prefs.preferredSiteKey.isEmpty,
                  let preferred = pool.first(where: { $0.key == prefs.preferredSiteKey })
        {
            activeSite = preferred
        } else {
            activeSite = pool.first(where: { !$0.isBannerNoticeSite }) ?? pool.first
        }

        NotificationCenter.default.post(name: .marcoStateDidChange, object: self)
    }

    public func visibleAvailableSites() -> [CmsSite] {
        if isSimulatorDemoMode {
            return SimulatorDemoFixtures.sites
        }
        return isPrivacySpaceUnlocked ? config.availableSites : config.publicAvailableSites
    }

    public func visibleLiveSources() -> [LiveSource] {
        if isSimulatorDemoMode {
            return SimulatorDemoFixtures.liveSources
        }
        let mergedLives = isPrivacySpaceUnlocked ? config.allSupportedLives : config.publicSupportedLives
        let standalone = storage.standaloneLiveSources()
            .filter { $0.enabled }
            .map { $0.toLiveSource() }
        return standalone + mergedLives
    }

    public func selectSite(_ site: CmsSite) {
        activeSite = site
        if !site.isEffectivelyPrivate && !isSimulatorDemoMode {
            storage.updatePreferences { prefs in
                prefs.selectedSiteKey = site.key
            }
        }
        NotificationCenter.default.post(name: .marcoSiteDidChange, object: self)
        NotificationCenter.default.post(name: .marcoStateDidChange, object: self)
    }

    public func addSubscriptionFromUrl(
        _ rawUrl: String,
        name: String = "",
        group: String = "默认分组",
        isPrivate: Bool = false
    ) async throws -> SubscriptionEntry {
        let fetched = try await cmsClient.fetchConfig(
            from: rawUrl,
            defaultGroup: group,
            isPrivate: isPrivate,
            defaultName: name
        )
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (URL(string: CmsParser.extractAndNormalizeUrl(rawUrl))?.host ?? "订阅源")
            : name.trimmingCharacters(in: .whitespacesAndNewlines)

        let entry = storage.upsertSubscription(
            name: resolvedName,
            url: CmsParser.extractAndNormalizeUrl(rawUrl),
            rawContent: fetched.rawContent,
            group: group,
            isPrivate: isPrivate,
            depots: fetched.config.depots
        )
        reloadConfig()
        return entry
    }

    public func addSubscriptionFromRawJson(
        _ rawJson: String,
        name: String,
        group: String = "默认分组",
        isPrivate: Bool = false
    ) throws -> SubscriptionEntry {
        let parsed = try CmsParser.parseConfig(
            rawJson,
            origin: "",
            defaultGroup: group,
            isPrivate: isPrivate,
            defaultName: name
        )
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "本地 JSON 订阅" : name
        let entry = storage.upsertSubscription(
            name: cleanName,
            url: "",
            rawContent: rawJson,
            group: group,
            isPrivate: isPrivate,
            depots: parsed.depots
        )
        reloadConfig()
        return entry
    }

    public func switchDepot(_ depot: CmsDepot, for subscription: SubscriptionEntry) async throws {
        let fetched = try await cmsClient.fetchDepotConfig(depot)
        _ = storage.upsertSubscription(
            id: subscription.id,
            name: subscription.name,
            url: subscription.url,
            rawContent: fetched.rawContent,
            group: subscription.group,
            isPrivate: subscription.isPrivate,
            enabled: subscription.enabled,
            warehouseUrl: subscription.warehouseUrl.isEmpty ? subscription.url : subscription.warehouseUrl,
            activeDepotUrl: depot.url,
            activeDepotName: depot.name,
            depots: subscription.depots
        )
        reloadConfig()
    }

    // MARK: - Web Media Sniffer Bridge

    /// Bridges `HeadlessMediaWebSniffer` with active subscription `rules` and `ads`.
    public func sniffPlayableMedia(
        urlString: String,
        headers: [String: String] = [:],
        timeoutMs: Int = 12_000,
        clickScript: String = ""
    ) async -> SniffedMediaResult? {
        let rules: [WebSniffRule] = config.rules.map { rule in
            WebSniffRule(
                hosts: rule.hosts,
                regex: rule.regex,
                exclude: rule.exclude,
                clickScript: rule.combinedClickScript
            )
        }
        return await HeadlessMediaWebSniffer.sniff(
            urlString: urlString,
            headers: headers,
            timeoutMs: timeoutMs,
            rules: rules,
            ads: config.ads,
            clickScript: clickScript
        )
    }

    // MARK: - Theme Synchronization

    public func applyThemeMode(_ mode: AppThemeMode, animated: Bool = true) {
        storage.updatePreferences { prefs in
            prefs.appThemeMode = mode
        }
        let uiMode: MarcoThemeMode
        switch mode {
        case .system: uiMode = .system
        case .light: uiMode = .light
        case .dark: uiMode = .dark
        }
        MarcoThemeManager.shared.apply(uiMode, animated: animated)
        NotificationCenter.default.post(name: .marcoThemeDidChange, object: self)
    }

    public func applyStoredTheme(animated: Bool = false) {
        let mode = storage.preferences().appThemeMode
        let uiMode: MarcoThemeMode
        switch mode {
        case .system: uiMode = .system
        case .light: uiMode = .light
        case .dark: uiMode = .dark
        }
        MarcoThemeManager.shared.apply(uiMode, animated: animated)
    }

    // MARK: - 5-Tap Logo Privacy Space Entry & Exit

    public var isBiometricUnlockEnabled: Bool {
        get {
            if storage.defaults.object(forKey: Self.biometricEnabledDefaultsKey) == nil {
                return BiometricPrivacyAuth.isBiometricAvailable()
            }
            return storage.defaults.bool(forKey: Self.biometricEnabledDefaultsKey)
        }
        set {
            storage.defaults.set(newValue, forKey: Self.biometricEnabledDefaultsKey)
        }
    }

    /// Detects 5 consecutive logo taps within 2500ms to toggle Privacy Space authentication.
    /// Returns `true` when the 5-tap threshold is reached.
    @discardableResult
    public func recordLogoTap(from presenter: UIViewController) -> Bool {
        let now = Date().timeIntervalSince1970
        logoTapTimestamps = logoTapTimestamps.filter { (now - $0) <= Self.logoTapWindowSeconds }
        logoTapTimestamps.append(now)

        guard logoTapTimestamps.count >= Self.requiredLogoTaps else {
            return false
        }
        logoTapTimestamps.removeAll()
        MarcoHaptics.medium()

        if isPrivacySpaceUnlocked {
            lockPrivacySpace()
        } else {
            promptUnlockPrivacySpace(from: presenter)
        }
        return true
    }

    public func promptUnlockPrivacySpace(
        from presenter: UIViewController,
        onFinished: ((Bool) -> Void)? = nil
    ) {
        if !storage.hasPrivacyPin() {
            PrivacyPinViewController.present(
                from: presenter,
                mode: .setup,
                pinLength: 4,
                allowsBiometrics: false,
                autoPromptBiometrics: false
            ) { [weak self] result in
                guard let self = self else { return }
                if case .created(let pin) = result {
                    try? self.storage.setPrivacyPin(pin)
                    self.unlockPrivacySpace()
                    onFinished?(true)
                } else {
                    onFinished?(false)
                }
            }
            return
        }

        let pinLen = storage.privacyPinExpectedLength()
        PrivacyPinViewController.present(
            from: presenter,
            mode: .verify,
            pinLength: min(max(pinLen, 4), 6),
            allowsBiometrics: isBiometricUnlockEnabled && BiometricPrivacyAuth.isBiometricAvailable(),
            autoPromptBiometrics: isBiometricUnlockEnabled,
            verifyHandler: { [weak self] candidate in
                self?.storage.verifyPrivacyPin(candidate) ?? false
            }
        ) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .verified, .biometricUnlocked:
                self.unlockPrivacySpace()
                onFinished?(true)
            default:
                onFinished?(false)
            }
        }
    }

    public func unlockPrivacySpace() {
        isPrivacySpaceUnlocked = true
        reloadConfig()
        NotificationCenter.default.post(name: .marcoPrivacyDidChange, object: self)
    }

    public func lockPrivacySpace() {
        guard isPrivacySpaceUnlocked else {
            PosterImageLoader.shared.purgePrivateMemoryCache()
            return
        }
        isPrivacySpaceUnlocked = false
        PosterImageLoader.shared.purgePrivateMemoryCache()
        if activeSite?.isEffectivelyPrivate == true {
            activeSite = nil
        }
        reloadConfig()
        NotificationCenter.default.post(name: .marcoPrivacyDidChange, object: self)
    }

    // MARK: - AI Lab Passcode Management

    public var isAiLabUnlocked: Bool {
        guard let claims = cachedAiLabClaims else { return false }
        return !claims.isExpired
    }

    public func reloadAiLabClaims() {
        guard let data = try? storage.keychain.data(forAccount: AppAiLabPasscodeHelper.keychainAccount),
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else {
            cachedAiLabClaims = nil
            return
        }
        switch AppAiLabPasscodeHelper.verify(token) {
        case .success(let claims):
            cachedAiLabClaims = claims
        case .failure:
            cachedAiLabClaims = nil
        }
    }

    public func unlockAiLab(passcode: String) -> Result<AiLabPasscodeClaims, MarcoError> {
        let verified = AppAiLabPasscodeHelper.verify(passcode)
        if case .success(let claims) = verified {
            try? storage.keychain.setData(Data(claims.rawToken.utf8), forAccount: AppAiLabPasscodeHelper.keychainAccount)
            cachedAiLabClaims = claims
            NotificationCenter.default.post(name: .marcoStateDidChange, object: self)
        }
        return verified
    }

    public func clearAiLabPasscode() {
        try? storage.keychain.removeData(forAccount: AppAiLabPasscodeHelper.keychainAccount)
        cachedAiLabClaims = nil
        NotificationCenter.default.post(name: .marcoStateDidChange, object: self)
    }

    // MARK: - LAN Server Management & Deep Links

    public func freshLanServer() -> LanConfigServer {
        if lanServer.isExpired {
            lanServer.stop()
            lanServer = LanConfigServer(
                storage: storage,
                syncService: webDavSync,
                cmsClient: cmsClient
            )
            configureLanServerCallbacks(lanServer)
        }
        return lanServer
    }

    private func configureLanServerCallbacks(_ server: LanConfigServer) {
        server.onApplied = { _ in
            Task { @MainActor in
                AppStateStore.shared.reloadConfig()
            }
        }
        server.onWebDavBound = { _ in
            Task { @MainActor in
                NotificationCenter.default.post(name: .marcoStateDidChange, object: AppStateStore.shared)
            }
        }
    }

    public func handleDeepLink(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "marcomovie" else { return nil }
        let host = (url.host ?? "").lowercased()

        if host == "bind" || url.absoluteString.contains(WebdavBindCrypto.bindSchemeFragment) {
            if let parsed = WebdavBindCrypto.parseBindQrInput(url.absoluteString) {
                return "已识别绑定地址：\(parsed.baseEndpointUrl)"
            }
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let items = comps.queryItems
            {
                let webdavUrl = items.first(where: { $0.name == "url" })?.value ?? ""
                let user = items.first(where: { $0.name == "user" || $0.name == "username" })?.value ?? ""
                let pass = items.first(where: { $0.name == "pass" || $0.name == "password" })?.value ?? ""
                if !webdavUrl.isEmpty {
                    var cfg = storage.loadWebDavConfig()
                    cfg.url = webdavUrl
                    if !user.isEmpty { cfg.username = user }
                    if !pass.isEmpty { cfg.password = pass }
                    try? storage.saveWebDavConfig(cfg)
                    NotificationCenter.default.post(name: .marcoStateDidChange, object: self)
                    return "已通过链接绑定 WebDAV 配置"
                }
            }
        }
        return nil
    }

    // MARK: - Synthetic Playback Site & Locked CinemaPlayer Launch Contract

    public static func makeSyntheticPlaybackSite(
        key: String,
        name: String,
        api: String = "",
        isPrivate: Bool = false
    ) -> CmsSite {
        CmsSite(
            key: key,
            name: name,
            type: 1,
            api: api,
            isPrivate: isPrivate
        )
    }

    public func presentPlayer(
        from presenter: UIViewController,
        video: CmsVideo,
        site: CmsSite,
        lines: [CmsLine],
        initialLineIndex: Int = 0,
        initialEpisodeIndex: Int = 0,
        startPositionMs: Int = 0,
        isLive: Bool = false,
        liveChannelName: String? = nil,
        demoPreviewMode: Bool? = nil
    ) {
        let effectiveDemo = demoPreviewMode ?? isSimulatorDemoMode
        let isPriv = site.isEffectivelyPrivate || isPrivacySpaceUnlocked && site.isPrivate
        let safeLines = lines.isEmpty ? video.lines : lines
        let safeLineIdx = min(max(0, initialLineIndex), max(0, safeLines.count - 1))
        let safeEpIdx: Int = {
            guard safeLineIdx < safeLines.count else { return 0 }
            return min(max(0, initialEpisodeIndex), max(0, safeLines[safeLineIdx].episodes.count - 1))
        }()

        let context = CinemaPlayerLaunchContext(
            video: video,
            site: site,
            lines: safeLines,
            initialLineIndex: safeLineIdx,
            initialEpisodeIndex: safeEpIdx,
            startPositionMs: Int64(max(0, startPositionMs)),
            isLive: isLive,
            isPrivate: isPriv,
            liveChannelName: liveChannelName,
            directStreamURL: nil,
            directHeaders: [:],
            demoPreviewMode: effectiveDemo
        )

        let player = CinemaPlayerViewController(
            context: context,
            cmsClient: cmsClient,
            storage: storage,
            danmuService: danmuService,
            castService: castService,
            onPlaybackStateChanged: { [weak self] lineIdx, epIdx, posMs, durMs in
                guard let self = self, !isLive, !effectiveDemo else { return }
                let resolvedLine = (lineIdx >= 0 && lineIdx < safeLines.count) ? safeLines[lineIdx] : nil
                let resolvedEp = (resolvedLine != nil && epIdx >= 0 && epIdx < resolvedLine!.episodes.count)
                    ? resolvedLine!.episodes[epIdx]
                    : nil
                let item = WatchHistoryItem(
                    site: site.key,
                    id: video.id,
                    title: video.title,
                    poster: video.poster,
                    line: resolvedLine?.name ?? "",
                    lineId: resolvedLine?.id ?? "",
                    episode: resolvedEp?.name ?? "",
                    episodeMediaId: WatchHistoryItem.mediaIdentityForUrl(resolvedEp?.url ?? ""),
                    subscriptionId: site.subscriptionId,
                    sourceKey: site.sourceKey,
                    sourceApi: site.sourceApi,
                    sourceExt: site.ext,
                    index: max(0, epIdx),
                    position: max(0, Int(posMs)),
                    duration: max(0, Int(durMs)),
                    updated: Int64(Date().timeIntervalSince1970 * 1000)
                )
                Task { @MainActor in
                    self.storage.upsertWatchHistory(item)
                    NotificationCenter.default.post(name: .marcoStateDidChange, object: self)
                }
            }
        )
        player.modalPresentationStyle = .fullScreen
        MarcoModalPresenter.topPresenter(from: presenter).present(player, animated: true)
    }

    // MARK: - Download Progress Bridge

    private func handleDownloadProgress(_ event: DownloadProgressEvent) {
        latestDownloadProgress[event.taskId] = event
        NotificationCenter.default.post(name: .marcoDownloadsDidChange, object: event)
    }
}
