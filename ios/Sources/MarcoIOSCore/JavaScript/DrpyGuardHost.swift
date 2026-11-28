// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation

/// Locates SHA-256-verified DRPY2 and Guard extractor/adapter scripts bundled
/// into `MarcoIOSCore` (`Resources/catpaw/`).
public enum CatPawAssetLoader {
    private static let allowedFileRegex = try! NSRegularExpression(
        pattern: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]*\.(js|cjs)$"#
    )

    public static func candidateDirectories() -> [URL] {
        var dirs: [URL] = []
        #if SWIFT_PACKAGE
        if let resURL = Bundle.module.resourceURL {
            dirs.append(resURL.appendingPathComponent("catpaw"))
            dirs.append(resURL.appendingPathComponent("js-host"))
        }
        #endif
        if let mainRes = Bundle.main.resourceURL {
            dirs.append(mainRes.appendingPathComponent("catpaw"))
            dirs.append(mainRes.appendingPathComponent("js-host"))
        }
        let coreRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        dirs.append(coreRoot.appendingPathComponent("Resources/catpaw"))
        dirs.append(coreRoot.appendingPathComponent("Resources/js-host"))
        let repoShared = coreRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("shared/catpaw")
        dirs.append(repoShared)
        return dirs
    }

    public static func loadAsset(named rawName: String) -> String? {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("./") {
            name = String(name.dropFirst(2))
        }
        let range = NSRange(name.startIndex..., in: name)
        guard allowedFileRegex.firstMatch(in: name, range: range) != nil else {
            return nil
        }
        for dir in candidateDirectories() {
            let fileURL = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: fileURL.path),
               let content = try? String(contentsOf: fileURL, encoding: .utf8)
            {
                return content
            }
        }
        return nil
    }
}

/// Runs the verbatim `shared/catpaw/drpy-*-extractor.cjs` & `drpy-*-adapter.cjs`
/// pipeline inside a short-lived `QuickJSBridge` (`CQuickJS`) on iOS & macOS.
public enum GuardPluginExtractor {
    public static let maxArtifactBytes = 16 * 1024 * 1024

    public struct ExtractedRule: Sendable {
        public let rule: String
        public let origin: String

        public init(rule: String, origin: String) {
            self.rule = rule
            self.origin = origin
        }
    }

    /// Parses a TVBox `jar` / `spider` reference such as `https://fixture.invalid/spider.jar;md5;abcdef...`.
    public static func parsePluginReference(_ raw: String) -> (url: String, expectedMd5: String?)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.components(separatedBy: ";")
        guard let first = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              first.lowercased().hasPrefix("http://") || first.lowercased().hasPrefix("https://")
        else {
            return nil
        }
        var expectedMd5: String?
        if parts.count >= 3 && parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "md5" {
            let candidate = parts[2].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if candidate.count == 32 && candidate.allSatisfy({ $0.isHexDigit }) {
                expectedMd5 = candidate
            }
        }
        return (CmsParser.normalizeUrl(first), expectedMd5)
    }

    public static func verifyOptionalMd5(data: Data, expectedMd5: String?) throws {
        guard let expected = expectedMd5, !expected.isEmpty else { return }
        let actual = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else {
            throw MarcoError.scriptExecutionFailed("插件文件 MD5 校验失败")
        }
    }

    public static func extract(
        artifactBytes: Data,
        adapter: String,
        extension extValue: String? = nil
    ) throws -> ExtractedRule {
        guard !artifactBytes.isEmpty, artifactBytes.count <= maxArtifactBytes else {
            throw MarcoError.scriptExecutionFailed("插件包文件大小无效")
        }
        let bridge = try QuickJSBridge(
            memoryLimitBytes: 96 * 1024 * 1024,
            maxStackBytes: 2 * 1024 * 1024
        )
        defer { bridge.close() }

        bridge.configureBootstrapContext(
            artifactBytes: artifactBytes,
            assetReader: { name in CatPawAssetLoader.loadAsset(named: name) }
        )

        let runner = #"""
        (function() {
            function toArrayBuffer(v) {
                if (v instanceof ArrayBuffer) return v;
                if (ArrayBuffer.isView(v)) {
                    if (v.byteOffset === 0 && v.byteLength === v.buffer.byteLength) return v.buffer;
                    return v.buffer.slice(v.byteOffset, v.byteOffset + v.byteLength);
                }
                return Buffer.from(String(v)).buffer;
            }
            var nodeCrypto = {
                createHash: function(algo) {
                    var chunks = [];
                    return {
                        update: function(data, encoding) {
                            if (typeof data === "string") chunks.push(Buffer.from(data, encoding || "utf8"));
                            else if (data instanceof Buffer) chunks.push(data);
                            else if (ArrayBuffer.isView(data)) chunks.push(Buffer.from(data));
                            else if (data instanceof ArrayBuffer) chunks.push(Buffer.from(data));
                            else chunks.push(Buffer.from(String(data)));
                            return this;
                        },
                        digest: function(encoding) {
                            var all = chunks.length === 1 ? chunks[0] : Buffer.concat(chunks);
                            var out = Buffer.from(__hostHash(String(algo), toArrayBuffer(all)));
                            return encoding ? out.toString(encoding) : out;
                        }
                    };
                }
            };
            var nodeZlib = {
                inflateRawSync: function(buf, opts) {
                    var maxOut = (opts && typeof opts.maxOutputLength === "number") ? opts.maxOutputLength : (8 * 1024 * 1024);
                    var b = Buffer.isBuffer(buf) ? buf : Buffer.from(buf);
                    return Buffer.from(__hostZlib("inflateRaw", toArrayBuffer(b), maxOut));
                }
            };
            var moduleCache = Object.create(null);
            function customRequire(spec) {
                if (spec === "node:crypto" || spec === "crypto") return nodeCrypto;
                if (spec === "node:zlib" || spec === "zlib") return nodeZlib;
                if (spec === "buffer" || spec === "node:buffer") return { Buffer: Buffer, kMaxLength: 0x7fffffff };
                var name = String(spec);
                if (name.startsWith("./")) name = name.slice(2);
                if (Object.prototype.hasOwnProperty.call(moduleCache, name)) return moduleCache[name].exports;
                var source = __hostReadAsset(name);
                var mod = { exports: {} };
                moduleCache[name] = mod;
                var fn = new Function("require", "module", "exports", source);
                fn(customRequire, mod, mod.exports);
                return mod.exports;
            }
            globalThis.__runGuardBootstrap = function(adapter, extArg) {
                try {
                    var data = Buffer.from(__hostReadArtifact());
                    var guardMod = customRequire("./drpy-guard-extractor.cjs");
                    var ftyMod = customRequire("./drpy-fty-extractor.cjs");
                    var wexMod = customRequire("./drpy-wex-extractor.cjs");
                    var VOD_FTY = new Set(["jpys-v1", "jpj-v1", "nmyswv-v1", "hmys-v1", "app99-v1", "appsx-v1", "newcz-v1", "libvio-v1", "ygp-v1", "jumitv-v1"]);
                    var LIVE_FTY = new Set(["kanqiu-v1", "doubao-v1", "livegz-v1", "alllive-v1", "tingshu275-v1", "yueting-v1"]);
                    var VOD_WEX = new Set(wexMod.VOD_WEX_ADAPTERS);
                    var isFty = ftyMod.FTY_ADAPTERS.includes(adapter);
                    var isWex = wexMod.WEX_ADAPTERS.includes(adapter);
                    if (!isFty && !isWex && !["dm84-v1", "auete-v1", "bttwoo-v1", "appgz-v1", "t4-v1", "apptt-v1", "fy-v1"].includes(adapter)) {
                        throw new Error("guard_artifact_invalid");
                    }
                    var extVal = (extArg === null || extArg === undefined) ? undefined : String(extArg);
                    var config = isFty ? ftyMod.extractFty(data, adapter, extVal)
                        : isWex ? wexMod.extractWex(data, adapter, extVal)
                        : adapter === "t4-v1" ? customRequire("./drpy-t4-extractor.cjs").extractT4(data, extVal)
                        : adapter === "apptt-v1" ? customRequire("./drpy-apptt-extractor.cjs").extractAppTT(data, extVal)
                        : adapter === "fy-v1" ? customRequire("./drpy-fy-extractor.cjs").extractFy(data)
                        : guardMod.extractKnownPlugin(data, adapter);
                    var factory = isFty
                        ? (VOD_FTY.has(adapter) ? "./drpy-fty-vod-adapter.cjs" : LIVE_FTY.has(adapter) ? "./drpy-fty-live-adapter.cjs" : "./drpy-fty-pan-adapter.cjs")
                        : isWex
                            ? (VOD_WEX.has(adapter) ? "./drpy-wex-vod-adapter.cjs" : "./drpy-wex-pan-adapter.cjs")
                            : {
                                "dm84-v1": "./drpy-dm84-adapter.cjs",
                                "auete-v1": "./drpy-auete-adapter.cjs",
                                "bttwoo-v1": "./drpy-bttwoo-adapter.cjs",
                                "appgz-v1": "./drpy-appgz-adapter.cjs",
                                "t4-v1": "./drpy-t4-adapter.cjs",
                                "apptt-v1": "./drpy-apptt-adapter.cjs",
                                "fy-v1": "./drpy-fy-adapter.cjs"
                            }[adapter];
                    var rule = customRequire(factory)(config);
                    return JSON.stringify({ version: 1, rule: rule, origin: config.origin });
                } catch (err) {
                    var msg = err && err.message ? String(err.message) : "";
                    var code = (msg === "guard_artifact_unsupported" || msg === "guard_artifact_integrity") ? msg : "guard_artifact_invalid";
                    return JSON.stringify({ error: code });
                }
            };
        })();
        """#
        _ = try bridge.evaluate(runner, filename: "ios-guard-bootstrap.js", timeoutSeconds: 4.0)

        let extArg: Any = extValue ?? NSNull()
        let raw = try bridge.callGlobalFunction(
            "__runGuardBootstrap",
            arguments: [adapter, extArg],
            timeoutSeconds: 6.0
        )
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
            throw MarcoError.scriptExecutionFailed("插件解析结果格式无效")
        }
        if let errCode = obj["error"] as? String {
            switch errCode {
            case "guard_artifact_unsupported":
                throw MarcoError.scriptExecutionFailed("当前插件版本尚未完成本机移植（\(errCode)）")
            case "guard_artifact_integrity":
                throw MarcoError.scriptExecutionFailed("插件文件校验失败（\(errCode)）")
            default:
                throw MarcoError.scriptExecutionFailed("插件包格式无效（\(errCode)）")
            }
        }
        guard let rule = obj["rule"] as? String,
              let origin = obj["origin"] as? String,
              !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              origin.lowercased().hasPrefix("http://") || origin.lowercased().hasPrefix("https://")
        else {
            throw MarcoError.scriptExecutionFailed("插件解析结果缺少规则或源站地址")
        }
        return ExtractedRule(rule: rule, origin: origin)
    }
}

/// Native QuickJS-NG host for DRPY2 rules (`var rule = {...}`) and Guard-ported
/// TVBox plugins on iOS (`iOS 14+` & `macOS 13+`).
public final class DrpySourceHost: @unchecked Sendable {
    public let site: CmsSite
    public let ruleSource: String
    public let origin: String
    private let bridge: QuickJSBridge
    private var initialized = false

    public init(
        site: CmsSite,
        ruleSource: String,
        origin: String,
        localModules: [String: String] = [:],
        httpTransport: JsHttpTransport? = nil
    ) throws {
        self.site = site
        self.ruleSource = ruleSource
        self.origin = origin

        let stateUrl: URL? = {
            guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                return nil
            }
            let keyHash = SHA256.hash(data: Data("\(site.key)|\(origin)".utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            return caches
                .appendingPathComponent("MarcoMovieIOS/drpy-state/\(keyHash)", isDirectory: true)
                .appendingPathComponent("local.json")
        }()

        self.bridge = try QuickJSBridge(
            memoryLimitBytes: 128 * 1024 * 1024,
            maxStackBytes: 2 * 1024 * 1024,
            httpTransport: httpTransport,
            storageFileUrl: stateUrl
        )
        self.bridge.configureSourceContext(
            origin: origin,
            headers: site.headers,
            localModules: localModules
        )
        try loadDrpyRuntime()
    }

    deinit {
        bridge.close()
    }

    public static func looksLikeDrpyRule(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return false
        }
        let hasRuleDecl = trimmed.range(of: #"\b(?:var|let|const)\s+rule\s*="#, options: .regularExpression) != nil
        let hasModuleExport = trimmed.contains("export default") || trimmed.contains("module.exports") || trimmed.contains("__jsEvalReturn")
        return hasRuleDecl && !hasModuleExport
    }

    private func loadDrpyRuntime() throws {
        guard let deps = CatPawAssetLoader.loadAsset(named: "drpy-dependencies.js") else {
            throw MarcoError.scriptExecutionFailed("缺少 DRPY 运行依赖（drpy-dependencies.js）")
        }
        guard let core = CatPawAssetLoader.loadAsset(named: "drpy-core.js") else {
            throw MarcoError.scriptExecutionFailed("缺少 DRPY 运行核心（drpy-core.js）")
        }

        let drpyLocalShim = #"""
        (function() {
            globalThis.local = {
                get: function(ns, key) {
                    var raw = __hostStorage("get", String(ns || ""), String(key || ""), "");
                    if (!raw) return null;
                    try { return JSON.parse(raw); } catch (_) { return raw; }
                },
                set: function(ns, key, val) {
                    __hostStorage("set", String(ns || ""), String(key || ""), JSON.stringify(val));
                    return null;
                },
                delete: function(ns, key) {
                    __hostStorage("delete", String(ns || ""), String(key || ""), "");
                    return null;
                }
            };
        })();
        """#
        _ = try bridge.evaluate(drpyLocalShim, filename: "drpy-local-shim.js", timeoutSeconds: 4.0)
        _ = try bridge.evaluate(deps, filename: "drpy-dependencies.js", timeoutSeconds: 10.0)

        let selectorsJs = #"""
        function selectHtml(html, parts) {
            var $ = DRPYDeps.cheerio.load(String(html));
            var selected = $.root();
            for (var i = 0; i < parts.length; i++) {
                var step = parts[i];
                if (!step) continue;
                var cuts = step.split("--");
                var selector = cuts.shift().trim();
                if (selector && selector !== "*") selected = selected.find(selector);
                if (cuts.length) {
                    selected = selected.clone();
                    for (var j = 0; j < cuts.length; j++) selected.find(cuts[j]).remove();
                }
            }
            return { $: $, selected: selected };
        }
        globalThis.pdfa = function(html, expression) {
            var res = selectHtml(html, String(expression).split("&&"));
            return res.selected.toArray().map(function(node) { return res.$.html(node); });
        };
        globalThis.pdfl = globalThis.pdfa;
        globalThis.pdfh = function(html, expression) {
            var parts = String(expression).split("&&");
            var field = parts.pop();
            var res = selectHtml(html, parts);
            var first = res.selected.first();
            if (field === "Text") return first.text().trim();
            if (field === "Html") return first.html() || "";
            return first.attr(field) || "";
        };
        globalThis.pd = function(html, expression, base) {
            var value = pdfh(html, expression);
            return value ? joinUrl(base, value) : "";
        };
        """#
        _ = try bridge.evaluate(selectorsJs, filename: "drpy-selectors.js", timeoutSeconds: 4.0)
        _ = try bridge.evaluate(core, filename: "drpy-core.js", timeoutSeconds: 10.0)

        let harness = #"""
        globalThis.__marcoInitDrpy = function(ruleCode, originStr) {
            globalThis.__drpyOrigin = String(originStr || "");
            globalThis.__drpyUnsupported = null;
            var fn = new Function(
                String(ruleCode || "") + "\n;if(typeof rule!==\"object\"||rule===null)throw new Error(\"drpy_rule_missing\");return rule;"
            );
            __drpy.init(fn());
            if (globalThis.__drpyUnsupported) throw new Error(globalThis.__drpyUnsupported);
            return "ok";
        };
        globalThis.__marcoCallDrpy = function(methodName, argsArray) {
            globalThis.__drpyUnsupported = null;
            var fn = __drpy[methodName];
            if (typeof fn !== "function") throw new Error("drpy_method_arguments");
            var out = fn.apply(__drpy, Array.isArray(argsArray) ? argsArray : []);
            if (globalThis.__drpyUnsupported) throw new Error(globalThis.__drpyUnsupported);
            if (out && typeof out.then === "function") throw new Error("drpy_async_result");
            return typeof out === "string" ? out : JSON.stringify(out || {});
        };
        """#
        _ = try bridge.evaluate(harness, filename: "drpy-ios-harness.js", timeoutSeconds: 4.0)
    }

    public func initialize() async throws {
        guard !initialized else { return }
        do {
            _ = try bridge.callGlobalFunction(
                "__marcoInitDrpy",
                arguments: [ruleSource, origin],
                timeoutSeconds: 15.0
            )
            initialized = true
        } catch {
            throw translateDrpyError(error)
        }
    }

    private func invoke(_ method: String, arguments: [Any]) async throws -> String {
        try await initialize()
        do {
            return try bridge.callGlobalFunction(
                "__marcoCallDrpy",
                arguments: [method, arguments],
                timeoutSeconds: 18.0
            )
        } catch {
            throw translateDrpyError(error)
        }
    }

    public func homeContent(filter: Bool = true) async throws -> SiteHomePayload {
        let rawHome = try await invoke("home", arguments: [filter])
        var categories = CmsParser.parseCategories(rawHome)
        var listing = try CmsParser.parseListing(rawHome)

        if listing.videos.isEmpty {
            if let rawHomeVod = try? await invoke("homeVod", arguments: []),
               !rawHomeVod.isEmpty,
               let vodListing = try? CmsParser.parseListing(rawHomeVod),
               !vodListing.videos.isEmpty
            {
                listing = vodListing
            } else if let firstCat = categories.first,
                      let catListing = try? await categoryContent(tid: firstCat.id, page: 1),
                      !catListing.videos.isEmpty
            {
                listing = catListing
            }
        }
        if categories.isEmpty && !listing.videos.isEmpty {
            categories = [CmsCategory(id: "all", name: "精选")]
        }
        return SiteHomePayload(categories: categories, listing: listing)
    }

    public func categoryContent(
        tid: String,
        page: Int = 1,
        filter: Bool = true,
        extend: [String: String] = [:]
    ) async throws -> CmsListing {
        let raw = try await invoke("category", arguments: [tid, max(1, page), filter, extend])
        let listing = try CmsParser.parseListing(raw)
        if listing.videos.count == 1,
           let first = listing.videos.first,
           first.id == "no_data" && first.title == "无数据,防无限请求"
        {
            return CmsListing(page: listing.page, pageCount: listing.pageCount, videos: [])
        }
        return listing
    }

    public func detailContent(ids: [String]) async throws -> CmsVideo? {
        guard let firstId = ids.first, !firstId.isEmpty else { return nil }
        let raw = try await invoke("detail", arguments: [firstId])
        let listing = try CmsParser.parseListing(raw)
        return listing.videos.first
    }

    public func searchContent(keyword: String, quick: Bool = false, page: Int = 1) async throws -> [CmsVideo] {
        let raw = try await invoke("search", arguments: [keyword, quick, max(1, page)])
        let listing = try CmsParser.parseListing(raw)
        return listing.videos
    }

    public func playerContent(flag: String, id: String, vipFlags: [String] = []) async throws -> JsResolvedPlayStream {
        let raw = try await invoke("play", arguments: [flag, id, vipFlags])
        let cleaned = ConfigDecoder.stripJsonComments(raw)
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) as? [String: Any] else {
            return JsResolvedPlayStream(url: id)
        }
        let url = (obj["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? id
        let parseFlag = (obj["parse"] as? NSNumber)?.intValue ?? 0
        var hdrs: [String: String] = [:]
        if let hMap = (obj["header"] ?? obj["headers"]) as? [String: Any] {
            for (k, v) in hMap where !(v is NSNull) {
                hdrs[k] = String(describing: v)
            }
        }
        return JsResolvedPlayStream(url: url, headers: hdrs, parse: parseFlag)
    }

    private func translateDrpyError(_ error: Error) -> Error {
        let text = error.localizedDescription
        let map: [String: String] = [
            "drpy_verification_required": "此片源需要完成网站验证码，暂时无法加载",
            "drpy_authentication_required": "此站点需要登录账号后才能查看网盘或播放链接，请切换其他片源",
            "drpy_source_unavailable": "此片源暂时无法访问",
            "drpy_source_response": "此片源返回了无法识别的数据",
            "drpy_crypto_invalid": "此片源的加密响应暂不兼容",
            "drpy_media_unresolved": "此片源暂未解析出可播放地址",
            "drpy_media_protocol": "此片源返回的播放地址协议暂不支持",
            "drpy_execution_timeout": "片源脚本加载超时，请重试或切换其他片源",
        ]
        for (code, message) in map where text.contains(code) {
            return MarcoError.scriptExecutionFailed(message)
        }
        return error
    }
}
