// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CoreFoundation
import CryptoKit
import Foundation

public enum UpdateVersionRelation: Equatable, Sendable {
    case updateAvailable
    case upToDate
    case aheadOfChannel
}

/// Checks Marco Movie iOS update feeds (mirror-first `marcotv.wlj9919.top/movie/updates/ios.json`
/// with automatic GitHub Releases fallback), routes iOS 14 (`-ios14-unsigned.ipa`) vs iOS 15+
/// (`-ios-unsigned.ipa`), verifies optional Ed25519 manifest signatures and mandatory SHA-256 IPA
/// digests against trusted release hosts, and constructs `apple-magnifier://install?url=...` TrollStore URLs.
public final class AppUpdateService: @unchecked Sendable {
    public static let mirrorManifestUrl = "https://marcotv.wlj9919.top/movie/updates/ios.json"
    public static let githubReleasesUrl = "https://api.github.com/repos/Pilipala9919/MarcoMovie/releases?per_page=100"
    public static let defaultManifestUrl = mirrorManifestUrl

    private let session: URLSession
    private let manifestUrl: String
    private let fallbackReleasesUrl: String?

    public init(
        manifestUrl: String = AppUpdateService.defaultManifestUrl,
        fallbackReleasesUrl: String? = AppUpdateService.githubReleasesUrl,
        session: URLSession? = nil
    ) {
        self.manifestUrl = manifestUrl
        self.fallbackReleasesUrl = fallbackReleasesUrl
        if let session = session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 12
            cfg.timeoutIntervalForResource = 60
            cfg.httpShouldSetCookies = false
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: - iOS 14 vs iOS 15+ Routing & Trusted Hosts

    public static func prefersIos14CompatPackage(
        osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> Bool {
        #if os(iOS)
        return osMajorVersion > 0 && osMajorVersion < 15
        #else
        return osMajorVersion > 0 && osMajorVersion < 15
        #endif
    }

    public static func expectedIosAssetNames(version: String, preferIos14: Bool) -> [String] {
        let cleanVer = stripLeadingV(version)
        if preferIos14 {
            return ["MarcoMovie-\(cleanVer)-ios14-unsigned.ipa"]
        }
        return [
            "MarcoMovie-\(cleanVer)-ios-unsigned.ipa",
            "MarcoMovie-\(cleanVer)-ios-iphone-ipad-unsigned.ipa",
        ]
    }

    /// Strictly allows official Marco Movie release package hosts over HTTPS without userinfo or fragments.
    public static func isTrustedAssetUrl(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https",
              url.user == nil, url.password == nil,
              url.fragment == nil,
              (url.port == nil || url.port == 443),
              let host = url.host?.lowercased()
        else {
            return false
        }
        if host == "github.com" && url.path.hasPrefix("/Pilipala9919/MarcoMovie/releases/download/") {
            return true
        }
        if host == "marcotv.wlj9919.top" && url.path.hasPrefix("/movie/") {
            return true
        }
        return false
    }

    /// Builds a TrollStore install URL (`apple-magnifier://install?url=...`) for a trusted remote
    /// HTTPS IPA asset or a locally SHA-256-verified `file://` IPA package.
    public static func trollStoreInstallUrl(for ipaUrl: URL) throws -> URL {
        let scheme = ipaUrl.scheme?.lowercased() ?? ""
        if scheme == "file" {
            guard ipaUrl.pathExtension.lowercased() == "ipa" else {
                throw MarcoError.invalidFormat("本地安装文件必须是 .ipa 格式")
            }
        } else {
            guard isTrustedAssetUrl(ipaUrl) else {
                throw MarcoError.invalidFormat("更新包地址不在可信发布域名白名单内")
            }
        }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#:/")
        let encoded = ipaUrl.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? ipaUrl.absoluteString
        guard let out = URL(string: "apple-magnifier://install?url=\(encoded)") else {
            throw MarcoError.invalidFormat("无法构造 TrollStore 安装链接")
        }
        return out
    }

    // MARK: - Optional Ed25519 Manifest Signature Verification

    public static func extractSignedPayload(_ body: [String: Any]) -> [String: Any]? {
        if body["payload"] != nil {
            guard let rawPayload = body["payload"] as? [String: Any] else { return nil }
            for key in body.keys where key != "payload" && key != "signature" && key != "sig" {
                return nil
            }
            return rawPayload
        }
        var copy = body
        copy.removeValue(forKey: "signature")
        copy.removeValue(forKey: "sig")
        return copy
    }

    public static func canonicalizeJson(_ value: Any) -> String {
        if let dict = value as? [String: Any] {
            let sortedKeys = dict.keys.sorted()
            let parts = sortedKeys.map { key -> String in
                "\(jsonStringLiteral(key)):\(canonicalizeJson(dict[key] ?? NSNull()))"
            }
            return "{\(parts.joined(separator: ","))}"
        }
        if let arr = value as? [Any] {
            return "[\(arr.map { canonicalizeJson($0) }.joined(separator: ","))]"
        }
        if let str = value as? String {
            return jsonStringLiteral(str)
        }
        if let num = value as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return num.boolValue ? "true" : "false"
            }
            return num.stringValue
        }
        if value is NSNull {
            return "null"
        }
        return jsonStringLiteral(String(describing: value))
    }

    public static func verifyManifestSignature(
        _ body: [String: Any],
        publicKeyHex: String
    ) -> Bool {
        let hex = publicKeyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count == 64,
              let pubBytes = decodeHex(hex),
              pubBytes.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubBytes),
              let rawSig = (body["signature"] ?? body["sig"]) as? String,
              let sigBytes = Data(base64Encoded: rawSig.trimmingCharacters(in: .whitespacesAndNewlines)),
              sigBytes.count == 64,
              let payload = extractSignedPayload(body)
        else {
            return false
        }
        let canonical = canonicalizeJson(payload)
        return publicKey.isValidSignature(sigBytes, for: Data(canonical.utf8))
    }

    // MARK: - Check & Download

    public func checkForUpdate(
        currentVersion: String,
        currentBuild: Int = 0
    ) async throws -> (relation: UpdateVersionRelation, release: AppUpdateRelease) {
        try await checkForUpdate(
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            preferIos14: nil,
            publicKeyHex: nil
        )
    }

    public func checkForUpdate(
        currentVersion: String,
        currentBuild: Int = 0,
        preferIos14: Bool?,
        publicKeyHex: String? = nil
    ) async throws -> (relation: UpdateVersionRelation, release: AppUpdateRelease) {
        let useIos14 = preferIos14 ?? Self.prefersIos14CompatPackage()
        var candidates: [(url: String, isGithub: Bool)] = [(manifestUrl, manifestUrl.contains("api.github.com"))]
        if let fb = fallbackReleasesUrl, !fb.isEmpty, fb != manifestUrl {
            candidates.append((fb, fb.contains("api.github.com")))
        }

        var lastError: Error = MarcoError.networkFailure("暂时无法检查更新，请稍后重试")
        for candidate in candidates {
            guard let url = URL(string: candidate.url) else {
                lastError = MarcoError.invalidFormat("更新清单地址无效")
                continue
            }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("MarcoMovie-Updater", forHTTPHeaderField: "User-Agent")
            req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

            do {
                let (data, resp) = try await session.marcoData(for: req)
                if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    lastError = MarcoError.networkFailure("检查更新失败 (HTTP \(http.statusCode))")
                    continue
                }
                let release: AppUpdateRelease
                if candidate.isGithub {
                    release = try Self.parseGithubReleasesJson(data, preferIos14: useIos14)
                } else {
                    release = try Self.parseReleaseJson(data, preferIos14: useIos14, publicKeyHex: publicKeyHex)
                }
                let relation = Self.compareVersion(
                    currentVersion: currentVersion,
                    currentBuild: currentBuild,
                    remoteVersion: release.version,
                    remoteBuild: release.buildNumber
                )
                return (relation, release)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Downloads the release IPA to an isolated staging `.part` file, verifies SHA-256 against
    /// `release.sha256`, and atomically exposes the verified IPA under `destinationDirectory`.
    public func downloadVerifiedIpa(
        release: AppUpdateRelease,
        destinationDirectory: URL,
        preferIos14: Bool? = nil
    ) async throws -> URL {
        guard let url = URL(string: release.downloadUrl), Self.isTrustedAssetUrl(url) else {
            throw MarcoError.invalidFormat("缺少可信的 iOS 更新包下载地址")
        }
        let expectedSha = release.sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard expectedSha.count == 64 else {
            throw MarcoError.invalidFormat("更新清单缺少有效的 SHA-256 校验摘要")
        }
        let isIos14 = preferIos14 ?? release.downloadUrl.hasSuffix("-ios14-unsigned.ipa")
        let fileName = Self.expectedIosAssetNames(version: release.version, preferIos14: isIos14).first
            ?? "MarcoMovie-\(Self.stripLeadingV(release.version))-ios-unsigned.ipa"

        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let finalUrl = destinationDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: finalUrl.path),
           let existingData = try? Data(contentsOf: finalUrl),
           Self.verifySha256(data: existingData, expectedHex: expectedSha)
        {
            return finalUrl
        }

        let stagingUrl = destinationDirectory.appendingPathComponent(".\(fileName).\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: stagingUrl) }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        req.httpMethod = "GET"
        req.setValue("MarcoMovie-Updater", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.marcoData(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MarcoError.networkFailure("更新包下载失败 (HTTP \(http.statusCode))")
        }
        guard Self.verifySha256(data: data, expectedHex: expectedSha) else {
            throw MarcoError.invalidFormat("更新包 SHA-256 完整性校验失败，已自动丢弃")
        }
        try data.write(to: stagingUrl, options: [.atomic])
        if FileManager.default.fileExists(atPath: finalUrl.path) {
            try? FileManager.default.removeItem(at: finalUrl)
        }
        try FileManager.default.moveItem(at: stagingUrl, to: finalUrl)
        return finalUrl
    }

    // MARK: - Parsing & Version Comparison

    /// Preserved single-argument signature calling the full iOS 14 / 15+ aware manifest parser.
    public static func parseReleaseJson(_ data: Data) throws -> AppUpdateRelease {
        try parseReleaseJson(data, preferIos14: prefersIos14CompatPackage(), publicKeyHex: nil)
    }

    public static func parseReleaseJson(
        _ data: Data,
        preferIos14: Bool,
        publicKeyHex: String? = nil
    ) throws -> AppUpdateRelease {
        guard let rawObj = try? JSONSerialization.jsonObject(with: data) else {
            throw MarcoError.invalidFormat("更新清单不是有效的 JSON 格式")
        }
        if rawObj is [[String: Any]] {
            return try parseGithubReleasesJson(data, preferIos14: preferIos14)
        }
        guard let root = rawObj as? [String: Any] else {
            throw MarcoError.invalidFormat("更新清单不是有效的 JSON 对象")
        }

        let manifest: [String: Any]
        let hasSig = (root["signature"] ?? root["sig"]) != nil
        if let pubHex = publicKeyHex?.trimmingCharacters(in: .whitespacesAndNewlines), !pubHex.isEmpty {
            guard hasSig, verifyManifestSignature(root, publicKeyHex: pubHex),
                  let extracted = extractSignedPayload(root)
            else {
                throw MarcoError.invalidFormat("更新清单 Ed25519 签名校验失败")
            }
            manifest = extracted
        } else if root["payload"] != nil {
            guard let extracted = extractSignedPayload(root) else {
                throw MarcoError.invalidFormat("更新清单 payload 结构无效")
            }
            manifest = extracted
        } else {
            manifest = root
        }

        if let declaredPlatform = (manifest["platform"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !declaredPlatform.isEmpty,
           declaredPlatform.lowercased() != "ios"
        {
            throw MarcoError.invalidFormat("更新包平台不匹配（期望 ios，实际 \(declaredPlatform)）")
        }
        if (manifest["prerelease"] as? Bool) == true {
            throw MarcoError.invalidFormat("跳过预发布版本清单")
        }

        let rawVersion = ((manifest["version"] ?? manifest["versionName"] ?? manifest["tag_name"]) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawVersion.isEmpty else {
            throw MarcoError.invalidFormat("更新清单缺少版本号")
        }
        let cleanVer = stripLeadingV(rawVersion)
        let buildNumber = ((manifest["build"] ?? manifest["buildNumber"] ?? manifest["versionCode"]) as? NSNumber)?.intValue ?? 0
        let notes = ((manifest["notes"] ?? manifest["releaseNotes"] ?? manifest["changelog"] ?? manifest["body"]) as? String) ?? ""
        let mandatory = (manifest["mandatory"] as? Bool) ?? (manifest["force"] as? Bool) ?? false
        let publishedAt = ((manifest["publishedAt"] ?? manifest["date"] ?? manifest["published_at"]) as? String) ?? ""

        // Select package according to iOS 14 vs iOS 15+ routing
        var assetDict: [String: Any]?
        let expectedNames = expectedIosAssetNames(version: cleanVer, preferIos14: preferIos14)
        if preferIos14 {
            if let pkgs = manifest["packages"] as? [String: Any] {
                for name in expectedNames {
                    if let cand = pkgs[name] as? [String: Any] {
                        assetDict = cand
                        break
                    }
                }
            }
            if assetDict == nil, let ios14 = manifest["ios14"] as? [String: Any] {
                assetDict = ios14
            }
            if assetDict == nil, let pkg = manifest["package"] as? [String: Any],
               let pkgUrl = pkg["url"] as? String, pkgUrl.hasSuffix("-ios14-unsigned.ipa")
            {
                assetDict = pkg
            }
        } else {
            if let pkg = manifest["package"] as? [String: Any],
               let pkgUrl = pkg["url"] as? String, !pkgUrl.hasSuffix("-ios14-unsigned.ipa")
            {
                assetDict = pkg
            }
            if assetDict == nil, let pkgs = manifest["packages"] as? [String: Any] {
                for name in expectedNames {
                    if let cand = pkgs[name] as? [String: Any] {
                        assetDict = cand
                        break
                    }
                }
            }
            if assetDict == nil, let iosPkg = manifest["ios"] as? [String: Any] {
                assetDict = iosPkg
            }
        }

        let downloadUrl: String
        let sha256: String
        if let asset = assetDict {
            downloadUrl = ((asset["url"] ?? asset["browser_download_url"]) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            sha256 = (((asset["sha256"] ?? asset["digest"] ?? asset["checksum"]) as? String) ?? "")
                .replacingOccurrences(of: "sha256:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        } else {
            downloadUrl = ((manifest["url"] ?? manifest["downloadUrl"] ?? manifest["ipaUrl"]) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            sha256 = (((manifest["sha256"] ?? manifest["checksum"]) as? String) ?? "")
                .replacingOccurrences(of: "sha256:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }

        return AppUpdateRelease(
            version: rawVersion,
            buildNumber: buildNumber,
            releaseNotes: notes,
            downloadUrl: downloadUrl,
            sha256: sha256,
            mandatory: mandatory,
            publishedAt: publishedAt
        )
    }

    public static func parseGithubReleasesJson(
        _ data: Data,
        preferIos14: Bool = prefersIos14CompatPackage()
    ) throws -> AppUpdateRelease {
        guard let decoded = try? JSONSerialization.jsonObject(with: data) else {
            throw MarcoError.invalidFormat("GitHub Releases 响应格式无效")
        }
        let items: [[String: Any]]
        if let arr = decoded as? [[String: Any]] {
            items = arr
        } else if let single = decoded as? [String: Any] {
            items = [single]
        } else {
            throw MarcoError.invalidFormat("GitHub Releases 响应结构无效")
        }

        var candidates: [AppUpdateRelease] = []
        for item in items {
            if (item["draft"] as? Bool) == true || (item["prerelease"] as? Bool) == true {
                continue
            }
            let rawTag = ((item["tag_name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawTag.isEmpty else { continue }
            let cleanVer = stripLeadingV(rawTag.hasPrefix("ios-") ? String(rawTag.dropFirst(4)) : rawTag)
            let expectedNames = Set(expectedIosAssetNames(version: cleanVer, preferIos14: preferIos14))
            guard let assets = item["assets"] as? [[String: Any]] else { continue }

            for asset in assets {
                let name = ((asset["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard expectedNames.contains(name),
                      let urlStr = (asset["browser_download_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let url = URL(string: urlStr),
                      isTrustedAssetUrl(url)
                else { continue }
                let digest = ((asset["digest"] as? String) ?? "")
                    .replacingOccurrences(of: "sha256:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                candidates.append(
                    AppUpdateRelease(
                        version: cleanVer,
                        buildNumber: 0,
                        releaseNotes: (item["body"] as? String) ?? "",
                        downloadUrl: urlStr,
                        sha256: digest,
                        mandatory: false,
                        publishedAt: (item["published_at"] as? String) ?? ""
                    )
                )
                break
            }
        }

        guard !candidates.isEmpty else {
            throw MarcoError.invalidFormat("未找到适用于当前 iOS 版本的正式更新包")
        }
        candidates.sort { lhs, rhs in
            compareVersion(currentVersion: lhs.version, remoteVersion: rhs.version) == .aheadOfChannel
        }
        return candidates[0]
    }

    public static func compareVersion(
        currentVersion: String,
        currentBuild: Int = 0,
        remoteVersion: String,
        remoteBuild: Int = 0
    ) -> UpdateVersionRelation {
        let curParts = parseSemverParts(currentVersion)
        let remParts = parseSemverParts(remoteVersion)
        let count = max(curParts.count, remParts.count)
        for i in 0..<count {
            let c = i < curParts.count ? curParts[i] : 0
            let r = i < remParts.count ? remParts[i] : 0
            if r > c { return .updateAvailable }
            if r < c { return .aheadOfChannel }
        }
        if remoteBuild > 0 && currentBuild > 0 {
            if remoteBuild > currentBuild { return .updateAvailable }
            if remoteBuild < currentBuild { return .aheadOfChannel }
        }
        return .upToDate
    }

    public static func verifySha256(data: Data, expectedHex: String) -> Bool {
        let expected = expectedHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard expected.count == 64 else { return false }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual == expected
    }

    // MARK: - Private Helpers

    private static func stripLeadingV(_ raw: String) -> String {
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("v") || clean.hasPrefix("V") { clean.removeFirst() }
        return clean.components(separatedBy: CharacterSet(charactersIn: "-+")).first ?? clean
    }

    private static func parseSemverParts(_ raw: String) -> [Int] {
        stripLeadingV(raw).split(separator: ".").map { Int($0) ?? 0 }
    }

    private static func jsonStringLiteral(_ str: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [str]),
           let arr = String(data: data, encoding: .utf8),
           arr.count >= 2
        {
            return String(arr.dropFirst().dropLast())
        }
        return "\"\(str)\""
    }

    private static func decodeHex(_ hex: String) -> Data? {
        let bytes = Array(hex.utf8)
        guard bytes.count % 2 == 0 else { return nil }
        var out = Data(capacity: bytes.count / 2)
        var i = 0
        while i < bytes.count {
            guard let hi = hexVal(bytes[i]), let lo = hexVal(bytes[i + 1]) else { return nil }
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
