// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CoreFoundation
import CQuickJS
import Foundation

public struct JsHttpResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data
    public var finalUrl: String

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data = Data(),
        finalUrl: String = ""
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.finalUrl = finalUrl
    }
}

public typealias JsHttpTransport = @Sendable (
    _ url: String,
    _ method: String,
    _ headers: [String: String],
    _ body: Data?,
    _ timeoutSeconds: TimeInterval
) throws -> JsHttpResponse

private enum NativeCallbackMagic: Int32 {
    case httpReq = 1
    case storage = 2
    case base64 = 3
    case joinUrl = 4
    case cryptoRandom = 5
    case cryptoHash = 6
    case rsaPkcs1 = 7
    case rsaPubEnc = 8
    case zlibInflate = 9
    case nodeCipher = 10
    case parseUrl = 11
    case readAsset = 12
    case readArtifact = 13
}

private func quickJsInterruptCallback(
    _ rt: OpaquePointer?,
    _ opaque: UnsafeMutableRawPointer?
) -> Int32 {
    guard let opaque = opaque else { return 0 }
    let deadlineNs = opaque.assumingMemoryBound(to: UInt64.self).pointee
    if deadlineNs == 0 { return 0 }
    return DispatchTime.now().uptimeNanoseconds > deadlineNs ? 1 : 0
}

private func quickJsNativeClosureCallback(
    _ ctx: OpaquePointer?,
    _ thisVal: JSValue,
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<JSValue>?,
    _ magic: Int32,
    _ opaque: UnsafeMutableRawPointer?
) -> JSValue {
    guard let ctx = ctx, let opaque = opaque else {
        return cquickjs_undefined()
    }
    let bridge = Unmanaged<QuickJSBridge>.fromOpaque(opaque).takeUnretainedValue()
    return bridge.handleNativeCallback(ctx: ctx, argc: argc, argv: argv, magic: magic)
}

/// Thread-safe, memory-bounded, deadline-enforced Swift wrapper around QuickJS-NG (`CQuickJS`).
public final class QuickJSBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.pilipala.marcoMovie.ios.quickjs")
    private let httpQueue = DispatchQueue(label: "com.pilipala.marcoMovie.ios.quickjs.http", attributes: .concurrent)
    private var runtime: OpaquePointer?
    private var context: OpaquePointer?
    private let deadlinePtr: UnsafeMutablePointer<UInt64>
    private var kvStorage: [String: Any] = [:]
    private let storageFileUrl: URL?
    private let httpTransport: JsHttpTransport
    private var moduleRegistry: [String: String] = [:]
    private var originUrlString: String = ""
    private var defaultOriginHeaders: [String: String] = [:]
    private var localModules: [String: String] = [:]
    private var assetReader: ((String) -> String?)?
    private var artifactBytes: Data?
    private var disposed = false

    public init(
        memoryLimitBytes: Int = 96 * 1024 * 1024,
        maxStackBytes: Int = 2 * 1024 * 1024,
        httpTransport: JsHttpTransport? = nil,
        storageFileUrl: URL? = nil
    ) throws {
        self.deadlinePtr = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        self.deadlinePtr.initialize(to: 0)
        self.storageFileUrl = storageFileUrl

        if let storageFileUrl = storageFileUrl,
           let raw = try? Data(contentsOf: storageFileUrl),
           let parsed = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        {
            self.kvStorage = parsed
        }

        if let customTransport = httpTransport {
            self.httpTransport = customTransport
        } else {
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.httpShouldSetCookies = false
            let urlSession = URLSession(configuration: sessionConfig)
            self.httpTransport = { urlString, method, headers, bodyData, timeoutSec in
                guard let url = URL(string: CmsParser.normalizeUrl(urlString)),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https"
                else {
                    throw MarcoError.invalidFormat("Invalid HTTP URL in JS req: \(urlString)")
                }
                var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutSec)
                req.httpMethod = method
                for (k, v) in headers {
                    req.setValue(v, forHTTPHeaderField: k)
                }
                if req.value(forHTTPHeaderField: "User-Agent") == nil {
                    req.setValue(CmsClient.defaultSafariUserAgent, forHTTPHeaderField: "User-Agent")
                }
                req.httpBody = bodyData

                let sema = DispatchSemaphore(value: 0)
                let box = LockedResultBox<JsHttpResponse>()
                let task = urlSession.dataTask(with: req) { data, resp, err in
                    defer { sema.signal() }
                    if let err = err {
                        box.store(.failure(err))
                        return
                    }
                    let http = resp as? HTTPURLResponse
                    var respHeaders: [String: String] = [:]
                    if let all = http?.allHeaderFields {
                        for (rk, rv) in all {
                            respHeaders[String(describing: rk).lowercased()] = String(describing: rv)
                        }
                    }
                    box.store(
                        .success(
                            JsHttpResponse(
                                statusCode: http?.statusCode ?? 200,
                                headers: respHeaders,
                                body: data ?? Data(),
                                finalUrl: http?.url?.absoluteString ?? urlString
                            )
                        )
                    )
                }
                task.resume()
                let waitResult = sema.wait(timeout: .now() + timeoutSec + 0.5)
                if waitResult == .timedOut {
                    task.cancel()
                    throw MarcoError.networkFailure("JS HTTP request timed out")
                }
                return try box.load()
            }
        }

        try queue.sync {
            guard let rt = JS_NewRuntime() else {
                throw MarcoError.scriptExecutionFailed("Failed to allocate QuickJS runtime")
            }
            JS_SetMemoryLimit(rt, memoryLimitBytes)
            JS_SetMaxStackSize(rt, maxStackBytes)
            JS_SetInterruptHandler(rt, quickJsInterruptCallback, deadlinePtr)

            guard let ctx = JS_NewContext(rt) else {
                JS_FreeRuntime(rt)
                throw MarcoError.scriptExecutionFailed("Failed to allocate QuickJS context")
            }
            self.runtime = rt
            self.context = ctx
            try installHostGlobals(ctx: ctx)
        }
    }

    deinit {
        close()
        deadlinePtr.deinitialize(count: 1)
        deadlinePtr.deallocate()
    }

    public func close() {
        queue.sync {
            guard !disposed else { return }
            disposed = true
            assetReader = nil
            artifactBytes = nil
            if let ctx = context {
                JS_FreeContext(ctx)
                context = nil
            }
            if let rt = runtime {
                JS_FreeRuntime(rt)
                runtime = nil
            }
        }
    }

    public func registerModule(name: String, source: String) {
        queue.sync {
            moduleRegistry[name] = source
        }
    }

    public func configureSourceContext(
        origin: String,
        headers: [String: String] = [:],
        localModules: [String: String] = [:]
    ) {
        queue.sync {
            self.originUrlString = origin
            self.defaultOriginHeaders = headers
            self.localModules = localModules
        }
    }

    public func configureBootstrapContext(
        artifactBytes: Data,
        assetReader: @escaping (String) -> String?
    ) {
        queue.sync {
            self.artifactBytes = artifactBytes
            self.assetReader = assetReader
        }
    }

    public func evaluate(
        _ script: String,
        filename: String = "<eval>",
        asModule: Bool = false,
        timeoutSeconds: TimeInterval = 8.0
    ) throws -> String {
        try queue.sync {
            guard !disposed, let rt = runtime, let ctx = context else {
                throw MarcoError.scriptExecutionFailed("QuickJS runtime already closed")
            }
            JS_UpdateStackTop(rt)
            let budgetNs = UInt64(max(0.05, timeoutSeconds) * 1_000_000_000)
            deadlinePtr.pointee = DispatchTime.now().uptimeNanoseconds &+ budgetNs
            defer { deadlinePtr.pointee = 0 }

            let flags = asModule ? Int32(JS_EVAL_TYPE_MODULE) : Int32(JS_EVAL_TYPE_GLOBAL)
            var utf8Bytes = Array(script.utf8)
            let byteCount = utf8Bytes.count
            utf8Bytes.append(0)

            let rawVal: JSValue = utf8Bytes.withUnsafeBufferPointer { codePtr in
                filename.withCString { filePtr in
                    JS_Eval(ctx, codePtr.baseAddress, byteCount, filePtr, flags)
                }
            }

            return try resolveAndStringifyValue(ctx: ctx, rt: rt, value: rawVal)
        }
    }

    public func callGlobalFunction(
        _ name: String,
        arguments: [Any] = [],
        timeoutSeconds: TimeInterval = 10.0
    ) throws -> String {
        try queue.sync {
            guard !disposed, let rt = runtime, let ctx = context else {
                throw MarcoError.scriptExecutionFailed("QuickJS runtime already closed")
            }
            JS_UpdateStackTop(rt)
            let budgetNs = UInt64(max(0.05, timeoutSeconds) * 1_000_000_000)
            deadlinePtr.pointee = DispatchTime.now().uptimeNanoseconds &+ budgetNs
            defer { deadlinePtr.pointee = 0 }

            let global = JS_GetGlobalObject(ctx)
            defer { JS_FreeValue(ctx, global) }

            let fnVal = name.withCString { JS_GetPropertyStr(ctx, global, $0) }
            defer { JS_FreeValue(ctx, fnVal) }

            guard JS_IsFunction(ctx, fnVal) else {
                throw MarcoError.scriptExecutionFailed("JS function '\(name)' is not defined")
            }

            var jsArgs: [JSValue] = []
            jsArgs.reserveCapacity(arguments.count)
            defer {
                for arg in jsArgs {
                    JS_FreeValue(ctx, arg)
                }
            }

            for arg in arguments {
                jsArgs.append(makeJsValue(ctx: ctx, from: arg))
            }

            let retVal: JSValue = jsArgs.withUnsafeMutableBufferPointer { buf in
                JS_Call(ctx, fnVal, global, Int32(buf.count), buf.baseAddress)
            }
            return try resolveAndStringifyValue(ctx: ctx, rt: rt, value: retVal)
        }
    }

    // MARK: - Internal Host Setup & Callback Dispatch

    private func installHostGlobals(ctx: OpaquePointer) throws {
        let global = JS_GetGlobalObject(ctx)
        defer { JS_FreeValue(ctx, global) }

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        func bindClosure(_ jsName: String, argc: Int32, magic: NativeCallbackMagic) {
            let fn = jsName.withCString { namePtr in
                JS_NewCClosure(ctx, quickJsNativeClosureCallback, namePtr, nil, argc, magic.rawValue, opaqueSelf)
            }
            _ = jsName.withCString { namePtr in
                JS_SetPropertyStr(ctx, global, namePtr, fn)
            }
        }

        bindClosure("marco_http_req", argc: 3, magic: .httpReq)
        bindClosure("__hostRequest", argc: 3, magic: .httpReq)
        bindClosure("__hostStorage", argc: 4, magic: .storage)
        bindClosure("__hostBase64", argc: 2, magic: .base64)
        bindClosure("__hostJoin", argc: 2, magic: .joinUrl)
        bindClosure("__hostRandom", argc: 1, magic: .cryptoRandom)
        bindClosure("__hostHash", argc: 2, magic: .cryptoHash)
        bindClosure("__hostRsaPkcs1", argc: 3, magic: .rsaPkcs1)
        bindClosure("__hostRsaPubEnc", argc: 2, magic: .rsaPubEnc)
        bindClosure("__hostZlib", argc: 3, magic: .zlibInflate)
        bindClosure("__hostCipher", argc: 6, magic: .nodeCipher)
        bindClosure("__hostParseUrl", argc: 2, magic: .parseUrl)
        bindClosure("__hostReadAsset", argc: 1, magic: .readAsset)
        bindClosure("__hostReadArtifact", argc: 0, magic: .readArtifact)

        let bootstrapJs = #"""
        globalThis.global = globalThis;
        globalThis.window = globalThis;
        globalThis.self = globalThis;
        globalThis.navigator = { appName: "Netscape" };
        globalThis.__proxyAddress = "http://127.0.0.1:0/proxy";
        globalThis.process = {
            env: {},
            versions: { node: "20.0.0" },
            nextTick: function(fn) { Promise.resolve().then(fn); }
        };
        globalThis.console = {
            log: function() {},
            info: function() {},
            warn: function() {},
            error: function() {},
            debug: function() {}
        };
        globalThis.log = globalThis.console.log;
        globalThis.print = globalThis.console.log;
        globalThis.unsupportedFeature = function(code) {
            globalThis.__drpyUnsupported = String(code || "drpy_source_failed");
            throw new Error(globalThis.__drpyUnsupported);
        };
        function __bridgeJson(raw) {
            var parsed = JSON.parse(raw);
            if (parsed && parsed.error) throw new Error(parsed.error);
            return parsed ? parsed.value : null;
        }
        globalThis.req = function(url, options) {
            var enc = (typeof rule === "object" && rule) ? (rule.encoding || rule["编码"] || "") : "";
            var raw = __hostRequest(String(url || ""), JSON.stringify(options || {}), typeof enc === "string" ? enc : "");
            return JSON.parse(raw);
        };
        globalThis.local = {
            get: function(space, key) {
                var raw = __hostStorage("get", String(space || ""), String(key || ""), "");
                return raw;
            },
            set: function(space, key, val) {
                var encoded = (typeof val === "string") ? val : JSON.stringify(val);
                return __hostStorage("set", String(space || ""), String(key || ""), encoded);
            },
            delete: function(space, key) {
                return __hostStorage("delete", String(space || ""), String(key || ""), "");
            }
        };
        globalThis.joinUrl = function(base, part) {
            return __hostJoin(String(base || ""), String(part || ""));
        };
        globalThis.getProxy = function() {
            return globalThis.__drpyProxy || globalThis.__proxyAddress;
        };
        globalThis.atob = function(s) { return __hostBase64(String(s || ""), false); };
        globalThis.btoa = function(s) { return __hostBase64(String(s || ""), true); };
        globalThis.crypto = {
            getRandomValues: function(array) {
                var bytes = __bridgeJson(__hostRandom(array.byteLength));
                new Uint8Array(array.buffer, array.byteOffset, array.byteLength).set(bytes);
                return array;
            }
        };
        globalThis.rsaPkcs1 = function(operation, key, input) {
            try { return __bridgeJson(__hostRsaPkcs1(String(operation || ""), String(key || ""), String(input || ""))); }
            catch (e) { unsupportedFeature("drpy_crypto_invalid"); }
        };
        globalThis.rsaPublicEncrypt = function(pem, dataB64) {
            try { return __bridgeJson(__hostRsaPubEnc(String(pem || ""), String(dataB64 || ""))); }
            catch (e) { unsupportedFeature("drpy_crypto_invalid"); }
        };
        globalThis.zlibInflate = function(mode, inputB64) {
            try { return __bridgeJson(__hostZlib(String(mode || ""), String(inputB64 || ""), 2 * 1024 * 1024)); }
            catch (e) { unsupportedFeature("drpy_crypto_invalid"); }
        };
        globalThis.nodeCipher = function(op, algo, keyB64, ivB64, dataB64, tagB64) {
            try {
                return __bridgeJson(__hostCipher(
                    String(op || ""),
                    String(algo || ""),
                    String(keyB64 || ""),
                    String(ivB64 || ""),
                    String(dataB64 || ""),
                    String(tagB64 || "")
                ));
            } catch (e) {
                unsupportedFeature("drpy_crypto_invalid");
            }
        };

        (function() {
            var B64_ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            var B64_LOOKUP = new Int16Array(128).fill(-1);
            for (var i = 0; i < B64_ALPHA.length; i++) B64_LOOKUP[B64_ALPHA.charCodeAt(i)] = i;
            B64_LOOKUP["-".charCodeAt(0)] = 62;
            B64_LOOKUP["_".charCodeAt(0)] = 63;

            function encodeUtf8(str) {
                var out = [];
                for (var i = 0; i < str.length; i++) {
                    var c = str.charCodeAt(i);
                    if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
                        var next = str.charCodeAt(i + 1);
                        if (next >= 0xdc00 && next <= 0xdfff) {
                            c = ((c - 0xd800) << 10) + (next - 0xdc00) + 0x10000;
                            i++;
                        }
                    }
                    if (c < 0x80) out.push(c);
                    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
                    else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
                    else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 0x3f), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
                }
                return new Uint8Array(out);
            }

            function decodeUtf8(bytes, fatal) {
                var chunks = [], part = "";
                for (var i = 0; i < bytes.length; ) {
                    var b0 = bytes[i++];
                    if (b0 < 0x80) {
                        part += String.fromCharCode(b0);
                    } else if ((b0 & 0xe0) === 0xc0) {
                        if (i >= bytes.length) { if (fatal) throw new TypeError("Invalid UTF-8"); part += "\ufffd"; break; }
                        var b1 = bytes[i++];
                        if ((b1 & 0xc0) !== 0x80) { if (fatal) throw new TypeError("Invalid UTF-8"); i--; part += "\ufffd"; continue; }
                        var cp = ((b0 & 0x1f) << 6) | (b1 & 0x3f);
                        if (cp < 0x80) { if (fatal) throw new TypeError("Invalid UTF-8"); part += "\ufffd"; }
                        else part += String.fromCharCode(cp);
                    } else if ((b0 & 0xf0) === 0xe0) {
                        if (i + 1 >= bytes.length) { if (fatal) throw new TypeError("Invalid UTF-8"); part += "\ufffd"; break; }
                        var b1e = bytes[i++], b2e = bytes[i++];
                        if ((b1e & 0xc0) !== 0x80 || (b2e & 0xc0) !== 0x80) { if (fatal) throw new TypeError("Invalid UTF-8"); i -= 2; part += "\ufffd"; continue; }
                        var cpe = ((b0 & 0x0f) << 12) | ((b1e & 0x3f) << 6) | (b2e & 0x3f);
                        if (cpe < 0x800 || (cpe >= 0xd800 && cpe <= 0xdfff)) { if (fatal) throw new TypeError("Invalid UTF-8"); part += "\ufffd"; }
                        else part += String.fromCharCode(cpe);
                    } else if ((b0 & 0xf8) === 0xf0) {
                        if (i + 2 >= bytes.length) { if (fatal) throw new TypeError("Invalid UTF-8"); part += "\ufffd"; break; }
                        var b1f = bytes[i++], b2f = bytes[i++], b3f = bytes[i++];
                        if ((b1f & 0xc0) !== 0x80 || (b2f & 0xc0) !== 0x80 || (b3f & 0xc0) !== 0x80) { if (fatal) throw new TypeError("Invalid UTF-8"); i -= 3; part += "\ufffd"; continue; }
                        var cpf = ((b0 & 0x07) << 18) | ((b1f & 0x3f) << 12) | ((b2f & 0x3f) << 6) | (b3f & 0x3f);
                        if (cpf < 0x10000 || cpf > 0x10ffff) { if (fatal) throw new TypeError("Invalid UTF-8"); part += "\ufffd"; }
                        else {
                            var v = cpf - 0x10000;
                            part += String.fromCharCode(0xd800 | (v >> 10), 0xdc00 | (v & 0x3ff));
                        }
                    } else {
                        if (fatal) throw new TypeError("Invalid UTF-8");
                        part += "\ufffd";
                    }
                    if (part.length >= 4096) { chunks.push(part); part = ""; }
                }
                chunks.push(part);
                return chunks.join("");
            }

            function encodeBase64(bytes) {
                var chunks = [], part = "";
                for (var i = 0; i < bytes.length; i += 3) {
                    var a = bytes[i], b = i + 1 < bytes.length ? bytes[i + 1] : 0, c = i + 2 < bytes.length ? bytes[i + 2] : 0;
                    part += B64_ALPHA[a >> 2] + B64_ALPHA[((a & 3) << 4) | (b >> 4)] +
                        (i + 1 < bytes.length ? B64_ALPHA[((b & 15) << 2) | (c >> 6)] : "=") +
                        (i + 2 < bytes.length ? B64_ALPHA[c & 63] : "=");
                    if (part.length >= 4096) { chunks.push(part); part = ""; }
                }
                chunks.push(part);
                return chunks.join("");
            }

            function decodeBase64(str) {
                var clean = String(str).replace(/[^A-Za-z0-9+/=_-]/g, "");
                var out = [], bits = 0, count = 0;
                for (var i = 0; i < clean.length; i++) {
                    var ch = clean.charCodeAt(i);
                    if (ch === 61) break;
                    var v = ch < 128 ? B64_LOOKUP[ch] : -1;
                    if (v < 0) continue;
                    bits = (bits << 6) | v;
                    count += 6;
                    if (count >= 8) {
                        count -= 8;
                        out.push((bits >> count) & 0xff);
                    }
                }
                return new Uint8Array(out);
            }

            function encodeHex(bytes) {
                var HEX = "0123456789abcdef", chunks = [], part = "";
                for (var i = 0; i < bytes.length; i++) {
                    var b = bytes[i];
                    part += HEX[b >> 4] + HEX[b & 15];
                    if (part.length >= 4096) { chunks.push(part); part = ""; }
                }
                chunks.push(part);
                return chunks.join("");
            }

            function decodeHex(str) {
                var s = String(str), len = s.length >> 1, out = new Uint8Array(len);
                for (var i = 0; i < len; i++) {
                    var hi = parseInt(s[i * 2], 16), lo = parseInt(s[i * 2 + 1], 16);
                    if (Number.isNaN(hi) || Number.isNaN(lo)) return out.subarray(0, i);
                    out[i] = (hi << 4) | lo;
                }
                return out;
            }

            function encodeString(str, encoding) {
                var enc = String(encoding || "utf8").toLowerCase().replace("-", "");
                if (enc === "utf8") return encodeUtf8(str);
                if (enc === "latin1" || enc === "binary" || enc === "ascii") {
                    var out = new Uint8Array(str.length);
                    for (var i = 0; i < str.length; i++) out[i] = str.charCodeAt(i) & 0xff;
                    return out;
                }
                if (enc === "hex") return decodeHex(str);
                if (enc === "base64" || enc === "base64url") return decodeBase64(str);
                if (enc === "utf16le" || enc === "ucs2") {
                    var u = new Uint8Array(str.length * 2);
                    for (var j = 0; j < str.length; j++) {
                        var ch = str.charCodeAt(j);
                        u[j * 2] = ch & 0xff;
                        u[j * 2 + 1] = ch >> 8;
                    }
                    return u;
                }
                return encodeUtf8(str);
            }

            class Buffer extends Uint8Array {
                static isBuffer(v) { return v instanceof Buffer; }
                static alloc(size, fill, encoding) {
                    var b = new Buffer(size >>> 0);
                    if (fill !== undefined && fill !== 0) b.fill(fill, 0, b.length, encoding);
                    return b;
                }
                static allocUnsafe(size) { return new Buffer(size >>> 0); }
                static allocUnsafeSlow(size) { return new Buffer(size >>> 0); }
                static byteLength(val, encoding) {
                    if (typeof val === "string") return encodeString(val, encoding).length;
                    if (val && typeof val.byteLength === "number") return val.byteLength;
                    return 0;
                }
                static concat(list, totalLength) {
                    var len = totalLength;
                    if (len === undefined) {
                        len = 0;
                        for (var i = 0; i < list.length; i++) len += list[i].length;
                    }
                    var out = new Buffer(len), offset = 0;
                    for (var j = 0; j < list.length && offset < len; j++) {
                        var item = list[j], copyLen = Math.min(item.length, len - offset);
                        out.set(item.subarray ? item.subarray(0, copyLen) : item.slice(0, copyLen), offset);
                        offset += copyLen;
                    }
                    return out;
                }
                static from(value, encodingOrOffset, length) {
                    if (typeof value === "string") {
                        var bytes = encodeString(value, encodingOrOffset);
                        var b = new Buffer(bytes.length);
                        b.set(bytes);
                        return b;
                    }
                    if (value instanceof ArrayBuffer) {
                        var off = encodingOrOffset || 0;
                        var len = length !== undefined ? length : (value.byteLength - off);
                        return new Buffer(value, off, len);
                    }
                    if (ArrayBuffer.isView(value)) {
                        var view = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
                        var c = new Buffer(view.length);
                        c.set(view);
                        return c;
                    }
                    if (Array.isArray(value) || (value && typeof value.length === "number")) {
                        var a = new Buffer(value.length);
                        for (var i = 0; i < value.length; i++) a[i] = value[i] & 0xff;
                        return a;
                    }
                    throw new TypeError("Unsupported Buffer.from input");
                }
                subarray(start, end) {
                    var view = super.subarray(start, end);
                    return new Buffer(view.buffer, view.byteOffset, view.byteLength);
                }
                slice(start, end) { return this.subarray(start, end); }
                toString(encoding, start, end) {
                    var s = start || 0, e = end !== undefined ? end : this.length;
                    var view = (s === 0 && e === this.length) ? this : super.subarray(s, e);
                    var enc = String(encoding || "utf8").toLowerCase().replace("-", "");
                    if (enc === "utf8") return decodeUtf8(view, false);
                    if (enc === "latin1" || enc === "binary" || enc === "ascii") {
                        var chunks = [], part = "";
                        for (var i = 0; i < view.length; i++) {
                            part += String.fromCharCode(enc === "ascii" ? (view[i] & 0x7f) : view[i]);
                            if (part.length >= 4096) { chunks.push(part); part = ""; }
                        }
                        chunks.push(part);
                        return chunks.join("");
                    }
                    if (enc === "hex") return encodeHex(view);
                    if (enc === "base64") return encodeBase64(view);
                    if (enc === "base64url") return encodeBase64(view).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
                    if (enc === "utf16le" || enc === "ucs2") {
                        var uc = [], up = "";
                        for (var j = 0; j + 1 < view.length; j += 2) {
                            up += String.fromCharCode(view[j] | (view[j + 1] << 8));
                            if (up.length >= 4096) { uc.push(up); up = ""; }
                        }
                        uc.push(up);
                        return uc.join("");
                    }
                    return decodeUtf8(view, false);
                }
                equals(other) {
                    if (!other || typeof other.length !== "number" || this.length !== other.length) return false;
                    for (var i = 0; i < this.length; i++) if (this[i] !== other[i]) return false;
                    return true;
                }
                copy(target, targetStart = 0, sourceStart = 0, sourceEnd = this.length) {
                    var src = super.subarray(sourceStart, sourceEnd);
                    var len = Math.min(src.length, Math.max(0, target.length - targetStart));
                    target.set(src.subarray(0, len), targetStart);
                    return len;
                }
                fill(value, offset = 0, end = this.length, encoding) {
                    if (typeof value === "string") {
                        var bytes = encodeString(value, encoding);
                        if (!bytes.length) return super.fill(0, offset, end);
                        for (var i = offset; i < end; i++) this[i] = bytes[(i - offset) % bytes.length];
                        return this;
                    }
                    return super.fill(value & 0xff, offset, end);
                }
                indexOf(val, byteOffset = 0, encoding) {
                    var start = byteOffset < 0 ? Math.max(0, this.length + byteOffset) : byteOffset;
                    if (typeof val === "number") {
                        var b = val & 0xff;
                        for (var i = start; i < this.length; i++) if (this[i] === b) return i;
                        return -1;
                    }
                    var needle = typeof val === "string" ? encodeString(val, encoding) : val;
                    if (!needle || needle.length === 0) return start <= this.length ? start : -1;
                    var limit = this.length - needle.length;
                    outer: for (var j = start; j <= limit; j++) {
                        for (var k = 0; k < needle.length; k++) if (this[j + k] !== needle[k]) continue outer;
                        return j;
                    }
                    return -1;
                }
                readUInt8(o = 0) { return this[o]; }
                readInt8(o = 0) { var v = this[o]; return v > 127 ? v - 256 : v; }
                readUInt16LE(o = 0) { return this[o] | (this[o + 1] << 8); }
                readUInt16BE(o = 0) { return (this[o] << 8) | this[o + 1]; }
                readInt16LE(o = 0) { var v = this.readUInt16LE(o); return v > 0x7fff ? v - 0x10000 : v; }
                readInt16BE(o = 0) { var v = this.readUInt16BE(o); return v > 0x7fff ? v - 0x10000 : v; }
                readUInt32LE(o = 0) { return ((this[o] | (this[o + 1] << 8) | (this[o + 2] << 16)) + this[o + 3] * 0x1000000); }
                readUInt32BE(o = 0) { return (this[o] * 0x1000000 + ((this[o + 1] << 16) | (this[o + 2] << 8) | this[o + 3])); }
                readInt32LE(o = 0) { return this[o] | (this[o + 1] << 8) | (this[o + 2] << 16) | (this[o + 3] << 24); }
                readInt32BE(o = 0) { return (this[o] << 24) | (this[o + 1] << 16) | (this[o + 2] << 8) | this[o + 3]; }
                writeUInt8(v, o = 0) { this[o] = v & 0xff; return o + 1; }
                writeUInt16LE(v, o = 0) { this[o] = v & 0xff; this[o + 1] = (v >>> 8) & 0xff; return o + 2; }
                writeUInt16BE(v, o = 0) { this[o] = (v >>> 8) & 0xff; this[o + 1] = v & 0xff; return o + 2; }
                writeUInt32LE(v, o = 0) { this[o] = v & 0xff; this[o + 1] = (v >>> 8) & 0xff; this[o + 2] = (v >>> 16) & 0xff; this[o + 3] = (v >>> 24) & 0xff; return o + 4; }
                writeUInt32BE(v, o = 0) { this[o] = (v >>> 24) & 0xff; this[o + 1] = (v >>> 16) & 0xff; this[o + 2] = (v >>> 8) & 0xff; this[o + 3] = v & 0xff; return o + 4; }
            }
            ["from", "alloc", "allocUnsafe", "allocUnsafeSlow", "isBuffer", "concat", "byteLength"].forEach(function(k) {
                var d = Object.getOwnPropertyDescriptor(Buffer, k);
                if (d) Object.defineProperty(Buffer, k, Object.assign({}, d, { enumerable: true }));
            });
            globalThis.Buffer = Buffer;

            globalThis.TextEncoder = class TextEncoder {
                get encoding() { return "utf-8"; }
                encode(str = "") { return encodeUtf8(String(str)); }
            };
            globalThis.TextDecoder = class TextDecoder {
                constructor(encoding = "utf-8", options = {}) {
                    this.encoding = String(encoding || "utf-8").toLowerCase();
                    this.fatal = Boolean(options && options.fatal);
                }
                decode(input) {
                    if (!input) return "";
                    var bytes = input instanceof ArrayBuffer
                        ? new Uint8Array(input)
                        : ArrayBuffer.isView(input)
                            ? new Uint8Array(input.buffer, input.byteOffset, input.byteLength)
                            : new Uint8Array(input);
                    var enc = this.encoding.replace(/[-_]/g, "");
                    if (enc === "utf8") return decodeUtf8(bytes, this.fatal);
                    if (enc === "latin1" || enc === "iso88591" || enc === "ascii" || enc === "windows1252") {
                        return Buffer.from(bytes).toString("latin1");
                    }
                    if (enc === "utf16le" || enc === "ucs2") return Buffer.from(bytes).toString("utf16le");
                    return decodeUtf8(bytes, this.fatal);
                }
            };

            class URLSearchParams {
                constructor(init) {
                    this._entries = [];
                    this._onChange = null;
                    if (typeof init === "string") {
                        var q = init.startsWith("?") ? init.slice(1) : init;
                        if (q) {
                            q.split("&").forEach((part) => {
                                if (!part) return;
                                var eq = part.indexOf("=");
                                var k = eq >= 0 ? part.slice(0, eq) : part;
                                var v = eq >= 0 ? part.slice(eq + 1) : "";
                                this._entries.push([
                                    decodeURIComponent(k.replace(/\+/g, " ")),
                                    decodeURIComponent(v.replace(/\+/g, " "))
                                ]);
                            });
                        }
                    } else if (init && typeof init === "object") {
                        if (Array.isArray(init)) {
                            init.forEach((p) => this._entries.push([String(p[0]), String(p[1])]));
                        } else {
                            Object.keys(init).forEach((k) => this._entries.push([k, String(init[k])]));
                        }
                    }
                }
                _notify() { if (this._onChange) this._onChange(); }
                append(n, v) { this._entries.push([String(n), String(v)]); this._notify(); }
                delete(n) { var k = String(n); this._entries = this._entries.filter((e) => e[0] !== k); this._notify(); }
                get(n) { var k = String(n); var f = this._entries.find((e) => e[0] === k); return f ? f[1] : null; }
                getAll(n) { var k = String(n); return this._entries.filter((e) => e[0] === k).map((e) => e[1]); }
                has(n) { var k = String(n); return this._entries.some((e) => e[0] === k); }
                set(n, v) {
                    var k = String(n), val = String(v), found = false, next = [];
                    for (var i = 0; i < this._entries.length; i++) {
                        if (this._entries[i][0] === k) { if (!found) { next.push([k, val]); found = true; } }
                        else next.push(this._entries[i]);
                    }
                    if (!found) next.push([k, val]);
                    this._entries = next;
                    this._notify();
                }
                entries() { return this._entries[Symbol.iterator](); }
                keys() { return this._entries.map((e) => e[0])[Symbol.iterator](); }
                values() { return this._entries.map((e) => e[1])[Symbol.iterator](); }
                forEach(cb, thisArg) { this._entries.forEach((e) => cb.call(thisArg, e[1], e[0], this)); }
                [Symbol.iterator]() { return this.entries(); }
                toString() {
                    return this._entries.map((e) => encodeURIComponent(e[0]) + "=" + encodeURIComponent(e[1])).join("&");
                }
            }
            globalThis.URLSearchParams = URLSearchParams;

            class URL {
                constructor(input, base) {
                    var parsed = JSON.parse(__hostParseUrl(String(input), base !== undefined ? String(base) : ""));
                    if (parsed.error) throw new TypeError(parsed.error);
                    this.protocol = parsed.protocol;
                    this.username = parsed.username;
                    this.password = parsed.password;
                    this.hostname = parsed.hostname;
                    this.port = parsed.port;
                    this.pathname = parsed.pathname;
                    this._search = parsed.search;
                    this.hash = parsed.hash;
                    this.searchParams = new URLSearchParams(this._search);
                    this.searchParams._onChange = () => {
                        var s = this.searchParams.toString();
                        this._search = s ? "?" + s : "";
                    };
                }
                get search() { return this._search; }
                set search(v) {
                    var s = String(v || "");
                    this._search = !s ? "" : (s.startsWith("?") ? s : "?" + s);
                    this.searchParams = new URLSearchParams(this._search);
                    this.searchParams._onChange = () => {
                        var qs = this.searchParams.toString();
                        this._search = qs ? "?" + qs : "";
                    };
                }
                get host() { return this.port ? this.hostname + ":" + this.port : this.hostname; }
                get origin() {
                    if (this.protocol === "http:" || this.protocol === "https:" || this.protocol === "pkg:") {
                        return this.protocol + "//" + this.host;
                    }
                    return "null";
                }
                get href() {
                    var auth = "";
                    if (this.username || this.password) {
                        auth = this.username + (this.password ? ":" + this.password : "") + "@";
                    }
                    return this.protocol + "//" + auth + this.host + this.pathname + this._search + this.hash;
                }
                toString() { return this.href; }
                toJSON() { return this.href; }
            }
            globalThis.URL = URL;
        })();
        """#
        var utf8 = Array(bootstrapJs.utf8)
        let len = utf8.count
        utf8.append(0)
        let res = utf8.withUnsafeBufferPointer { ptr in
            "bootstrap.js".withCString { fPtr in
                JS_Eval(ctx, ptr.baseAddress, len, fPtr, Int32(JS_EVAL_TYPE_GLOBAL))
            }
        }
        if JS_IsException(res) {
            let msg = extractExceptionMessage(ctx: ctx)
            throw MarcoError.scriptExecutionFailed("Bootstrap failed: \(msg)")
        }
        JS_FreeValue(ctx, res)
    }

    fileprivate func handleNativeCallback(
        ctx: OpaquePointer,
        argc: Int32,
        argv: UnsafeMutablePointer<JSValue>?,
        magic: Int32
    ) -> JSValue {
        func argString(_ index: Int) -> String {
            guard let argv = argv, index < Int(argc) else { return "" }
            return jsValueToString(ctx: ctx, value: argv[index])
        }
        func argInt(_ index: Int, fallback: Int = 0) -> Int {
            guard let argv = argv, index < Int(argc) else { return fallback }
            var out: Int64 = Int64(fallback)
            _ = JS_ToInt64(ctx, &out, argv[index])
            return Int(out)
        }
        func argArrayBuffer(_ index: Int) -> Data? {
            guard let argv = argv, index < Int(argc) else { return nil }
            var size: Int = 0
            guard let ptr = JS_GetArrayBuffer(ctx, &size, argv[index]) else { return nil }
            return Data(bytes: ptr, count: size)
        }
        func jsonBridgeOk(_ value: Any) -> JSValue {
            let payload: [String: Any] = ["value": value]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"value\":null}".utf8)
            return newJsString(ctx: ctx, String(decoding: data, as: UTF8.self))
        }
        func jsonBridgeError(_ code: String) -> JSValue {
            let payload: [String: Any] = ["error": code]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"error\":\"drpy_host_error\"}".utf8)
            return newJsString(ctx: ctx, String(decoding: data, as: UTF8.self))
        }

        switch NativeCallbackMagic(rawValue: magic) {
        case .httpReq:
            let rawUrlStr = argString(0)
            let optionsRaw = argString(1)
            let sourceEncoding = argString(2)
            let options = (try? JSONSerialization.jsonObject(with: Data(optionsRaw.utf8))) as? [String: Any] ?? [:]

            let resolvedUrlStr = originUrlString.isEmpty
                ? rawUrlStr
                : CmsParser.resolveUrl(base: originUrlString, relative: rawUrlStr)

            if resolvedUrlStr.lowercased().hasPrefix("pkg://") {
                let method = ((options["method"] as? String) ?? "GET").uppercased()
                if method == "GET", let text = localModules[resolvedUrlStr] {
                    let bufferMode = (options["buffer"] as? NSNumber)?.intValue ?? 0
                    let content = bufferMode == 2 ? Data(text.utf8).base64EncodedString() : text
                    let contentType = resolvedUrlStr.lowercased().hasSuffix(".json") ? "application/json" : "text/javascript"
                    let respObj: [String: Any] = [
                        "code": 200,
                        "content": content,
                        "headers": ["content-type": contentType],
                        "url": resolvedUrlStr,
                    ]
                    let jsonData = (try? JSONSerialization.data(withJSONObject: respObj)) ?? Data("{}".utf8)
                    return newJsString(ctx: ctx, String(decoding: jsonData, as: UTF8.self))
                }
                let errObj: [String: Any] = ["code": 0, "headers": [:], "content": "", "error": "drpy_local_module_missing"]
                let jsonData = (try? JSONSerialization.data(withJSONObject: errObj)) ?? Data("{}".utf8)
                return newJsString(ctx: ctx, String(decoding: jsonData, as: UTF8.self))
            }

            let method = ((options["method"] as? String) ?? "GET").uppercased()
            var headers: [String: String] = [:]
            if !defaultOriginHeaders.isEmpty,
               let targetHost = URL(string: CmsParser.normalizeUrl(resolvedUrlStr))?.host?.lowercased(),
               let originHost = URL(string: CmsParser.normalizeUrl(originUrlString))?.host?.lowercased(),
               targetHost == originHost
            {
                headers = defaultOriginHeaders
            }
            if let hObj = options["headers"] as? [String: Any] {
                for (k, v) in hObj where !(v is NSNull) {
                    headers[k] = String(describing: v)
                }
            }
            var bodyData: Data?
            if let bodyStr = options["body"] as? String {
                bodyData = Data(bodyStr.utf8)
            } else if let dataObj = options["data"] {
                if let s = dataObj as? String {
                    bodyData = Data(s.utf8)
                } else if JSONSerialization.isValidJSONObject(dataObj),
                          let encoded = try? JSONSerialization.data(withJSONObject: dataObj)
                {
                    bodyData = encoded
                    if headers.keys.allSatisfy({ $0.lowercased() != "content-type" }) {
                        headers["Content-Type"] = "application/json; charset=utf-8"
                    }
                }
            }
            let timeoutMs = (options["timeout"] as? NSNumber)?.doubleValue ?? 10_000
            let remainingSec: TimeInterval = {
                let d = deadlinePtr.pointee
                guard d > 0 else { return min(max(timeoutMs / 1000.0, 0.5), 15.0) }
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= d { return 0.05 }
                return min(Double(d - now) / 1_000_000_000.0, timeoutMs / 1000.0)
            }()

            let bufferMode = (options["buffer"] as? NSNumber)?.intValue ?? 0
            let explicitEncoding = (options["encoding"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let transport = self.httpTransport
            var responseDict: [String: Any] = ["code": 0, "headers": [:], "content": "", "url": resolvedUrlStr]
            let sema = DispatchSemaphore(value: 0)
            httpQueue.async {
                defer { sema.signal() }
                do {
                    let resp = try transport(resolvedUrlStr, method, headers, bodyData, max(0.1, remainingSec))
                    let contentVal: Any
                    if bufferMode == 2 {
                        contentVal = resp.body.base64EncodedString()
                    } else {
                        let contentType = resp.headers.first(where: { $0.key.lowercased() == "content-type" })?.value ?? ""
                        let headerCharset = Self.extractCharset(from: contentType)
                        let effectiveCharset = !explicitEncoding.isEmpty
                            ? explicitEncoding
                            : (!headerCharset.isEmpty ? headerCharset : (!sourceEncoding.isEmpty ? sourceEncoding : "utf-8"))
                        contentVal = Self.decodeText(resp.body, charset: effectiveCharset)
                    }
                    responseDict = [
                        "code": resp.statusCode,
                        "headers": resp.headers,
                        "content": contentVal,
                        "url": resp.finalUrl.isEmpty ? resolvedUrlStr : resp.finalUrl,
                    ]
                } catch {
                    responseDict = [
                        "code": 0,
                        "headers": [:],
                        "content": "",
                        "url": resolvedUrlStr,
                        "error": error.localizedDescription,
                    ]
                }
            }
            sema.wait()
            let jsonData = (try? JSONSerialization.data(withJSONObject: responseDict)) ?? Data("{}".utf8)
            return newJsString(ctx: ctx, String(decoding: jsonData, as: UTF8.self))

        case .storage:
            let op = argString(0)
            let space = argString(1)
            let key = argString(2)
            let val = argString(3)
            let compoundKey = "\(space)::\(key)"
            switch op {
            case "get":
                if let stored = kvStorage[compoundKey] as? String {
                    return newJsString(ctx: ctx, stored)
                }
                return newJsString(ctx: ctx, "")
            case "set":
                if kvStorage.count < 2048 {
                    kvStorage[compoundKey] = val
                    persistStorageIfConfigured()
                }
                return newJsString(ctx: ctx, "ok")
            case "delete":
                kvStorage.removeValue(forKey: compoundKey)
                persistStorageIfConfigured()
                return newJsString(ctx: ctx, "ok")
            default:
                return newJsString(ctx: ctx, "")
            }

        case .base64:
            let input = argString(0)
            let encodeFlag: Bool = {
                guard let argv = argv, argc >= 2 else { return false }
                return JS_ToBool(ctx, argv[1]) > 0
            }()
            if encodeFlag {
                let b64 = Data(input.utf8).base64EncodedString()
                return newJsString(ctx: ctx, b64)
            } else {
                var clean = input.components(separatedBy: .whitespacesAndNewlines).joined()
                while clean.count % 4 != 0 { clean.append("=") }
                let decoded = Data(base64Encoded: clean).map { String(decoding: $0, as: UTF8.self) } ?? ""
                return newJsString(ctx: ctx, decoded)
            }

        case .joinUrl:
            let base = argString(0)
            let part = argString(1)
            let effectiveBase = base.isEmpty ? originUrlString : base
            return newJsString(ctx: ctx, CmsParser.resolveUrl(base: effectiveBase, relative: part))

        case .cryptoRandom:
            let count = argInt(0, fallback: -1)
            do {
                let bytes = try CatPawCrypto.randomBytes(count: count)
                return jsonBridgeOk(bytes.map { Int($0) })
            } catch {
                return jsonBridgeError(error.localizedDescription)
            }

        case .cryptoHash:
            let algo = argString(0)
            guard let data = argArrayBuffer(1) ?? CatPawCrypto.decodeLooseBase64(argString(1)) else {
                return cquickjs_throw_plain_error(ctx, "drpy_crypto_invalid")
            }
            do {
                let digest = try CatPawCrypto.hash(algorithm: algo, data: data)
                return newArrayBuffer(ctx: ctx, data: digest)
            } catch {
                return cquickjs_throw_plain_error(ctx, "drpy_crypto_invalid")
            }

        case .rsaPkcs1:
            do {
                let out = try CatPawCrypto.rsaPkcs1(
                    operation: argString(0),
                    keyBase64: argString(1),
                    inputBase64: argString(2)
                )
                return jsonBridgeOk(out)
            } catch {
                return jsonBridgeError("drpy_crypto_invalid")
            }

        case .rsaPubEnc:
            do {
                let out = try CatPawCrypto.rsaPublicEncrypt(pem: argString(0), dataBase64: argString(1))
                return jsonBridgeOk(out)
            } catch {
                return jsonBridgeError("drpy_crypto_invalid")
            }

        case .zlibInflate:
            let mode = argString(0)
            let maxOut = argInt(2, fallback: CatPawCrypto.maxZlibOutputBytes)
            if let rawBuf = argArrayBuffer(1) {
                do {
                    let inflated = try CatPawCrypto.zlibInflate(mode: mode, input: rawBuf, maxOutputLength: maxOut)
                    return newArrayBuffer(ctx: ctx, data: inflated)
                } catch {
                    return cquickjs_throw_plain_error(ctx, "drpy_crypto_invalid")
                }
            } else {
                do {
                    let outB64 = try CatPawCrypto.zlibInflateBase64(mode: mode, inputBase64: argString(1))
                    return jsonBridgeOk(outB64)
                } catch {
                    return jsonBridgeError("drpy_crypto_invalid")
                }
            }

        case .nodeCipher:
            do {
                let result = try CatPawCrypto.nodeCipher(
                    op: argString(0),
                    algo: argString(1),
                    keyBase64: argString(2),
                    ivBase64: argString(3),
                    dataBase64: argString(4),
                    tagBase64: argString(5)
                )
                return jsonBridgeOk(result)
            } catch {
                return jsonBridgeError("drpy_crypto_invalid")
            }

        case .parseUrl:
            return newJsString(ctx: ctx, Self.parseUrlJson(input: argString(0), base: argString(1)))

        case .readAsset:
            let name = argString(0)
            guard let reader = assetReader, let content = reader(name) else {
                return cquickjs_throw_plain_error(ctx, "guard_artifact_invalid")
            }
            return newJsString(ctx: ctx, content)

        case .readArtifact:
            guard let bytes = artifactBytes else {
                return cquickjs_throw_plain_error(ctx, "guard_artifact_invalid")
            }
            return newArrayBuffer(ctx: ctx, data: bytes)

        case .none:
            return cquickjs_undefined()
        }
    }

    private func persistStorageIfConfigured() {
        guard let url = storageFileUrl else { return }
        guard JSONSerialization.isValidJSONObject(kvStorage),
              let data = try? JSONSerialization.data(withJSONObject: kvStorage),
              data.count <= 512 * 1024
        else {
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func extractCharset(from contentType: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"charset\s*=\s*["']?([^;\s"']+)"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: contentType, range: NSRange(contentType.startIndex..., in: contentType)),
              let range = Range(match.range(at: 1), in: contentType)
        else {
            return ""
        }
        return String(contentType[range])
    }

    private static func decodeText(_ data: Data, charset: String) -> String {
        let label = charset
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        if label.isEmpty || label == "utf8" || label == "unicode11utf8" {
            return String(decoding: data, as: UTF8.self)
        }
        let gbkLabels: Set<String> = [
            "gbk", "gb2312", "gb231280", "csgb2312", "csiso58gb231280",
            "chinese", "isoir58", "xgbk", "cp936", "ms936", "windows936", "gb18030",
        ]
        if gbkLabels.contains(label) {
            let cfEnc = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            let nsEnc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
            if let decoded = String(data: data, encoding: nsEnc) {
                return decoded
            }
        }
        let big5Labels: Set<String> = [
            "big5", "big5hkscs", "cnbig5", "csbig5", "xxbig5", "cp950", "windows950",
        ]
        if big5Labels.contains(label) {
            let cfEnc = CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)
            let nsEnc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
            if let decoded = String(data: data, encoding: nsEnc) {
                return decoded
            }
        }
        if label == "latin1" || label == "iso88591" || label == "windows1252" || label == "ascii" {
            return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        }
        if label == "utf16le" || label == "ucs2" {
            return String(data: data, encoding: .utf16LittleEndian) ?? String(decoding: data, as: UTF8.self)
        }
        if label == "utf16be" {
            return String(data: data, encoding: .utf16BigEndian) ?? String(decoding: data, as: UTF8.self)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func parseUrlJson(input: String, base: String) -> String {
        let resolved: String
        if !base.isEmpty {
            resolved = CmsParser.resolveUrl(base: base, relative: input)
        } else {
            resolved = input
        }
        guard let comps = URLComponents(string: resolved),
              let scheme = comps.scheme?.lowercased(),
              !scheme.isEmpty
        else {
            return "{\"error\":\"Invalid URL\"}"
        }
        let host = (comps.host ?? "").lowercased()
        var portStr = ""
        if let port = comps.port {
            let isDefault = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
            if !isDefault { portStr = String(port) }
        }
        let pathname = comps.percentEncodedPath.isEmpty ? "/" : comps.percentEncodedPath
        let search = comps.percentEncodedQuery.map { "?\($0)" } ?? ""
        let hash = comps.percentEncodedFragment.map { "#\($0)" } ?? ""
        let payload: [String: String] = [
            "protocol": "\(scheme):",
            "username": comps.user ?? "",
            "password": comps.password ?? "",
            "hostname": host,
            "port": portStr,
            "pathname": pathname,
            "search": search,
            "hash": hash,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return "{\"error\":\"Invalid URL\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func newArrayBuffer(ctx: OpaquePointer, data: Data) -> JSValue {
        if data.isEmpty {
            var emptyByte: UInt8 = 0
            return JS_NewArrayBufferCopy(ctx, &emptyByte, 0)
        }
        return data.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.bindMemory(to: UInt8.self).baseAddress else {
                var emptyByte: UInt8 = 0
                return JS_NewArrayBufferCopy(ctx, &emptyByte, 0)
            }
            return JS_NewArrayBufferCopy(ctx, ptr, data.count)
        }
    }

    private func drainJobs(rt: OpaquePointer) throws {
        var safety = 0
        while JS_IsJobPending(rt) {
            var jobCtx: OpaquePointer?
            let rc = JS_ExecutePendingJob(rt, &jobCtx)
            if rc < 0 {
                if let jobCtx = jobCtx {
                    let err = extractExceptionMessage(ctx: jobCtx)
                    throw MarcoError.scriptExecutionFailed(err)
                }
                throw MarcoError.scriptExecutionFailed("Promise microtask failed")
            }
            safety += 1
            if safety > 10_000 {
                throw MarcoError.scriptExecutionFailed("Promise microtask loop limit exceeded")
            }
        }
    }

    private func resolveAndStringifyValue(
        ctx: OpaquePointer,
        rt: OpaquePointer,
        value: JSValue
    ) throws -> String {
        if JS_IsException(value) {
            let err = extractExceptionMessage(ctx: ctx)
            throw MarcoError.scriptExecutionFailed(err)
        }
        defer { JS_FreeValue(ctx, value) }

        try drainJobs(rt: rt)

        if JS_IsPromise(value) {
            let state = JS_PromiseState(ctx, value)
            switch state {
            case JS_PROMISE_FULFILLED:
                let fulfilledVal = JS_PromiseResult(ctx, value)
                defer { JS_FreeValue(ctx, fulfilledVal) }
                return try convertJsValueToOutputString(ctx: ctx, value: fulfilledVal)
            case JS_PROMISE_REJECTED:
                let reasonVal = JS_PromiseResult(ctx, value)
                defer { JS_FreeValue(ctx, reasonVal) }
                let reason = jsValueToString(ctx: ctx, value: reasonVal)
                throw MarcoError.scriptExecutionFailed("Promise rejected: \(reason)")
            default:
                throw MarcoError.scriptExecutionFailed("Promise remained pending after draining microtasks")
            }
        }

        return try convertJsValueToOutputString(ctx: ctx, value: value)
    }

    private func convertJsValueToOutputString(ctx: OpaquePointer, value: JSValue) throws -> String {
        if JS_IsUndefined(value) || JS_IsNull(value) {
            return ""
        }
        if JS_IsString(value) {
            return jsValueToString(ctx: ctx, value: value)
        }
        if JS_IsObject(value) {
            let jsonVal = JS_JSONStringify(ctx, value, cquickjs_undefined(), cquickjs_undefined())
            if JS_IsException(jsonVal) {
                let err = extractExceptionMessage(ctx: ctx)
                throw MarcoError.scriptExecutionFailed(err)
            }
            defer { JS_FreeValue(ctx, jsonVal) }
            if !JS_IsUndefined(jsonVal) {
                return jsValueToString(ctx: ctx, value: jsonVal)
            }
        }
        return jsValueToString(ctx: ctx, value: value)
    }

    private func extractExceptionMessage(ctx: OpaquePointer) -> String {
        let exc = JS_GetException(ctx)
        defer { JS_FreeValue(ctx, exc) }
        var message = jsValueToString(ctx: ctx, value: exc)
        if JS_IsObject(exc) {
            let stackVal = "stack".withCString { JS_GetPropertyStr(ctx, exc, $0) }
            defer { JS_FreeValue(ctx, stackVal) }
            if JS_IsString(stackVal) {
                let stackStr = jsValueToString(ctx: ctx, value: stackVal)
                if !stackStr.isEmpty {
                    message += "\n\(stackStr)"
                }
            }
        }
        return message.isEmpty ? "Unknown JavaScript exception" : message
    }

    private func jsValueToString(ctx: OpaquePointer, value: JSValue) -> String {
        var len = 0
        guard let cPtr = JS_ToCStringLen2(ctx, &len, value, false) else {
            return ""
        }
        defer { JS_FreeCString(ctx, cPtr) }
        let rawBuf = UnsafeBufferPointer(start: UnsafeRawPointer(cPtr).assumingMemoryBound(to: UInt8.self), count: len)
        return String(decoding: rawBuf, as: UTF8.self)
    }

    private func newJsString(ctx: OpaquePointer, _ str: String) -> JSValue {
        let utf8 = Array(str.utf8)
        if utf8.isEmpty {
            return "".withCString { JS_NewStringLen(ctx, $0, 0) }
        }
        return utf8.withUnsafeBufferPointer { buf in
            JS_NewStringLen(ctx, UnsafeRawPointer(buf.baseAddress!).assumingMemoryBound(to: CChar.self), buf.count)
        }
    }

    private func makeJsValue(ctx: OpaquePointer, from any: Any) -> JSValue {
        if any is NSNull {
            return cquickjs_null()
        }
        if let s = any as? String {
            return newJsString(ctx: ctx, s)
        }
        if let b = any as? Bool {
            return JS_NewBool(ctx, b)
        }
        if let i = any as? Int {
            return JS_NewInt64(ctx, Int64(i))
        }
        if let d = any as? Double {
            return JS_NewFloat64(ctx, d)
        }
        if JSONSerialization.isValidJSONObject(any),
           let data = try? JSONSerialization.data(withJSONObject: any)
        {
            var bytes = Array(data)
            let len = bytes.count
            bytes.append(0)
            return bytes.withUnsafeBufferPointer { ptr in
                "<arg>".withCString { fPtr in
                    JS_ParseJSON(
                        ctx,
                        UnsafeRawPointer(ptr.baseAddress)?.assumingMemoryBound(to: CChar.self),
                        len,
                        fPtr
                    )
                }
            }
        }
        return newJsString(ctx: ctx, String(describing: any))
    }
}

private final class LockedResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?

    func store(_ value: Result<T, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func load() throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let result = result else {
            throw MarcoError.networkFailure("Empty HTTP transport result")
        }
        return try result.get()
    }
}
