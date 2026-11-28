// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation

public struct JsResolvedPlayStream: Sendable {
    public var url: String
    public var headers: [String: String]
    public var parse: Int

    public init(url: String, headers: [String: String] = [:], parse: Int = 0) {
        self.url = url
        self.headers = headers
        self.parse = parse
    }
}

/// CatVod / TVBox Type-3 JavaScript Spider host backed by `QuickJSBridge`.
/// Supports CommonJS (`module.exports`), ES default export (`export default`), and `__jsEvalReturn` spiders.
public final class JsSourceHost: @unchecked Sendable {
    public let site: CmsSite
    private let bridge: QuickJSBridge
    private let scriptSource: String
    private var initialized = false

    public init(
        site: CmsSite,
        scriptSource: String,
        httpTransport: JsHttpTransport? = nil
    ) throws {
        self.site = site
        self.scriptSource = scriptSource
        self.bridge = try QuickJSBridge(httpTransport: httpTransport)
        try loadBundledHostScriptsIfAvailable()
        try installSpiderAdapterHarness()
    }

    deinit {
        bridge.close()
    }

    public func initialize() async throws {
        guard !initialized else { return }
        let extArg = site.rawExtension ?? site.ext
        _ = try bridge.callGlobalFunction("__marcoInitSpider", arguments: [scriptSource, extArg])
        initialized = true
    }

    public func homeContent(filter: Bool = true) async throws -> SiteHomePayload {
        try await initialize()
        let rawHome = try bridge.callGlobalFunction("__marcoCallSpider", arguments: ["homeContent", [filter]])
        var categories = CmsParser.parseCategories(rawHome)
        var listing = try CmsParser.parseListing(rawHome)

        if listing.videos.isEmpty {
            if let rawHomeVod = try? bridge.callGlobalFunction("__marcoCallSpider", arguments: ["homeVideoContent", []]),
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
        try await initialize()
        let raw = try bridge.callGlobalFunction(
            "__marcoCallSpider",
            arguments: ["categoryContent", [tid, "\(max(1, page))", filter, extend]]
        )
        return try CmsParser.parseListing(raw)
    }

    public func detailContent(ids: [String]) async throws -> CmsVideo? {
        try await initialize()
        let raw = try bridge.callGlobalFunction("__marcoCallSpider", arguments: ["detailContent", [ids]])
        let listing = try CmsParser.parseListing(raw)
        return listing.videos.first
    }

    public func searchContent(keyword: String, quick: Bool = false, page: Int = 1) async throws -> [CmsVideo] {
        try await initialize()
        let raw = try bridge.callGlobalFunction(
            "__marcoCallSpider",
            arguments: ["searchContent", [keyword, quick, "\(max(1, page))"]]
        )
        let listing = try CmsParser.parseListing(raw)
        return listing.videos
    }

    public func playerContent(flag: String, id: String, vipFlags: [String] = []) async throws -> JsResolvedPlayStream {
        try await initialize()
        let raw = try bridge.callGlobalFunction(
            "__marcoCallSpider",
            arguments: ["playerContent", [flag, id, vipFlags]]
        )
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

    // MARK: - Host Asset Loading & Unified Spider Shim

    private func loadBundledHostScriptsIfAvailable() throws {
        let candidateDirs: [URL] = {
            var dirs: [URL] = []
            #if SWIFT_PACKAGE
            if let resURL = Bundle.module.resourceURL {
                dirs.append(resURL.appendingPathComponent("js-host"))
            }
            #endif
            if let mainRes = Bundle.main.resourceURL {
                dirs.append(mainRes.appendingPathComponent("js-host"))
            }
            let sourceRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            dirs.append(sourceRoot.appendingPathComponent("Resources/js-host"))
            let repoShared = sourceRoot
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("shared/script-host/js-host")
            dirs.append(repoShared)
            return dirs
        }()

        for scriptName in ["crypto-js.js", "module-interop.js"] {
            for dir in candidateDirs {
                let fileUrl = dir.appendingPathComponent(scriptName)
                if FileManager.default.fileExists(atPath: fileUrl.path),
                   let content = try? String(contentsOf: fileUrl, encoding: .utf8)
                {
                    _ = try? bridge.evaluate(content, filename: scriptName)
                    break
                }
            }
        }
    }

    private func installSpiderAdapterHarness() throws {
        let harness = #"""
        (function() {
            function normalizeSourceToCjs(src) {
                var code = String(src || "");
                code = code.replace(/^\s*import\s+[^;]+;\s*$/gm, "");
                if (/\bexport\s+default\b/.test(code)) {
                    code = code.replace(/\bexport\s+default\b/, "module.exports =");
                }
                return code;
            }

            globalThis.__marcoInitSpider = async function(sourceCode, extValue) {
                var mod = { exports: {} };
                var exports = mod.exports;
                var rewritten = normalizeSourceToCjs(sourceCode);
                var fn = new Function("module", "exports", "__jsEvalReturn",
                    rewritten + "\nif (typeof __jsEvalReturn === 'function' && Object.keys(module.exports).length === 0) { module.exports = __jsEvalReturn(); }"
                );
                fn.call(exports, mod, exports, undefined);
                var target = mod.exports && mod.exports.default ? mod.exports.default : mod.exports;
                if (typeof target === "function") {
                    target = new target();
                }
                if (!target || typeof target !== "object") {
                    throw new Error("Script did not export a valid CatVod/TVBox Spider object");
                }
                globalThis.__marcoActiveSpider = target;
                if (typeof target.init === "function") {
                    await target.init(extValue);
                }
                return "ok";
            };

            globalThis.__marcoCallSpider = async function(methodName, argsArray) {
                var sp = globalThis.__marcoActiveSpider;
                if (!sp) throw new Error("Spider not initialized");
                var aliases = {
                    homeContent: "home",
                    homeVideoContent: "homeVod",
                    categoryContent: "category",
                    detailContent: "detail",
                    searchContent: "search",
                    playerContent: "play"
                };
                var fn = sp[methodName] || (aliases[methodName] ? sp[aliases[methodName]] : null);
                if (typeof fn !== "function") {
                    return JSON.stringify({ list: [] });
                }
                var out = await fn.apply(sp, Array.isArray(argsArray) ? argsArray : []);
                return typeof out === "string" ? out : JSON.stringify(out || {});
            };
        })();
        """#
        _ = try bridge.evaluate(harness, filename: "marco-spider-harness.js")
    }
}
