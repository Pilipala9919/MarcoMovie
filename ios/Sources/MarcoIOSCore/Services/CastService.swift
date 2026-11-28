// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation
import Network
import Security

public enum CastPlaybackState: String, Equatable, Sendable {
    case idle
    case connecting
    case playing
    case paused
    case stopped
    case error
}

public struct CastPositionInfo: Equatable, Sendable {
    public let positionSeconds: Int
    public let durationSeconds: Int

    public init(positionSeconds: Int, durationSeconds: Int) {
        self.positionSeconds = max(0, positionSeconds)
        self.durationSeconds = max(0, durationSeconds)
    }
}

// MARK: - On-Demand Token-Scoped LAN Media Relay

/// Token-scoped, LAN-only on-demand HTTP relay (`NWListener`) so loopback proxies (`127.0.0.1`
/// netdisk/range/local media proxies) and header-protected streams (`Referer` / `Cookie` / `User-Agent`)
/// can be played by LAN smart TVs / DLNA renderers without exposing local proxies permanently on `0.0.0.0`.
public final class CastMediaRelayServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.pilipala.marcoMovie.ios.cast-relay")
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var token: String = ""
    private var upstreamUrl: URL?
    private var upstreamHeaders: [String: String] = [:]
    private var lanHost: String = "127.0.0.1"
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 15
            cfg.timeoutIntervalForResource = 120
            cfg.httpShouldSetCookies = false
            cfg.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: cfg)
        }
    }

    deinit {
        stop()
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listener != nil && port > 0 && !token.isEmpty
    }

    public var listeningPort: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return port
    }

    /// Exposes `upstreamUrl` (and optional protected headers) on a newly generated random-token
    /// LAN HTTP endpoint. Call `stop()` when casting ends to immediately revoke access.
    public func expose(
        upstreamUrl: URL,
        headers: [String: String] = [:],
        lanIp: String? = nil,
        preferredExtension: String? = nil
    ) async throws -> URL {
        stop()

        let resolvedLan = (lanIp?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? lanIp!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (CastService.resolveLanIpv4() ?? "127.0.0.1")

        let randomToken = Self.generateRandomHex(byteCount: 16)
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let nwListener = try NWListener(using: params, on: .any)

        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = MarcoOnceFlag()
            nwListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.tryClaim() {
                        continuation.resume(returning: nwListener.port?.rawValue ?? 0)
                    }
                case .failed(let error):
                    if once.tryClaim() {
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    if once.tryClaim() {
                        continuation.resume(throwing: MarcoError.cancelled)
                    }
                default:
                    break
                }
            }
            nwListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            nwListener.start(queue: queue)
        }

        guard boundPort > 0 else {
            nwListener.cancel()
            throw MarcoError.networkFailure("投屏中继服务器未能分配有效监听端口")
        }

        lock.lock()
        self.listener = nwListener
        self.port = boundPort
        self.token = randomToken
        self.upstreamUrl = upstreamUrl
        self.upstreamHeaders = headers
        self.lanHost = resolvedLan
        lock.unlock()

        let ext = Self.normalizeExtension(preferredExtension ?? Self.inferExtension(upstreamUrl))
        guard let exposed = URL(string: "http://\(resolvedLan):\(boundPort)/s/\(randomToken)/video\(ext)") else {
            stop()
            throw MarcoError.networkFailure("无法构造投屏中继播放地址")
        }
        return exposed
    }

    public func stop() {
        lock.lock()
        let active = listener
        listener = nil
        port = 0
        token = ""
        upstreamUrl = nil
        upstreamHeaders = [:]
        lock.unlock()
        active?.cancel()
    }

    public static func rewriteLoopbackPlaylist(
        _ body: String,
        upstream: URL,
        lanHost: String,
        relayPort: UInt16,
        token: String
    ) -> String {
        guard let scheme = upstream.scheme else { return body }
        let upstreamPort = upstream.port ?? (scheme.lowercased() == "https" ? 443 : 80)
        let relayBase = "http://\(lanHost):\(relayPort)/p/\(token)/"
        var out = body
        let candidates = [
            "\(scheme)://\(upstream.host ?? "127.0.0.1"):\(upstreamPort)/",
            "\(scheme)://127.0.0.1:\(upstreamPort)/",
            "\(scheme)://localhost:\(upstreamPort)/",
        ]
        for prefix in candidates {
            out = out.replacingOccurrences(of: prefix, with: relayBase)
        }
        return out
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        let peerHost = extractPeerIpv4(from: connection.endpoint)
        if !peerHost.isEmpty
            && peerHost != "127.0.0.1"
            && peerHost != "::1"
            && !CastService.isPrivateLanIpv4(peerHost)
        {
            connection.start(queue: queue)
            sendSimpleHttpResponse(connection: connection, status: "403 Forbidden", body: Data())
            return
        }

        connection.start(queue: queue)
        receiveHttpHeaders(connection: connection, buffer: Data())
    }

    private func receiveHttpHeaders(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }
            var nextBuf = buffer
            if let data = data, !data.isEmpty {
                nextBuf.append(data)
            }
            let delimiter = Data("\r\n\r\n".utf8)
            if let range = nextBuf.range(of: delimiter) {
                let headerText = String(decoding: nextBuf[..<range.lowerBound], as: UTF8.self)
                Task {
                    await self.processHttpRequest(headerText: headerText, connection: connection)
                }
                return
            }
            if isComplete || nextBuf.count > 65_536 {
                connection.cancel()
                return
            }
            self.receiveHttpHeaders(connection: connection, buffer: nextBuf)
        }
    }

    private func processHttpRequest(headerText: String, connection: NWConnection) async {
        let lines = headerText.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            sendSimpleHttpResponse(connection: connection, status: "400 Bad Request", body: Data())
            return
        }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            sendSimpleHttpResponse(connection: connection, status: "400 Bad Request", body: Data())
            return
        }
        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])

        guard method == "GET" || method == "HEAD" else {
            sendSimpleHttpResponse(connection: connection, status: "405 Method Not Allowed", body: Data())
            return
        }

        var reqHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            reqHeaders[k] = v
        }

        lock.lock()
        let currentToken = token
        let rootUpstream = upstreamUrl
        let baseHeaders = upstreamHeaders
        let currentLanHost = lanHost
        let currentPort = port
        lock.unlock()

        guard !currentToken.isEmpty, let rootUpstream = rootUpstream else {
            sendSimpleHttpResponse(connection: connection, status: "404 Not Found", body: Data())
            return
        }

        let targetUrl: URL
        let directPrefix = "/s/\(currentToken)/"
        let proxyPrefix = "/p/\(currentToken)/"
        let pathOnly = rawTarget.components(separatedBy: "?").first ?? rawTarget
        let queryPart = rawTarget.contains("?") ? String(rawTarget.split(separator: "?", maxSplits: 1)[1]) : ""

        if pathOnly.hasPrefix(directPrefix) {
            targetUrl = rootUpstream
        } else if pathOnly.hasPrefix(proxyPrefix) {
            let sub = String(pathOnly.dropFirst(proxyPrefix.count))
            let scheme = rootUpstream.scheme ?? "http"
            let host = rootUpstream.host ?? "127.0.0.1"
            let p = rootUpstream.port.map { ":\($0)" } ?? ""
            let q = queryPart.isEmpty ? "" : "?\(queryPart)"
            guard let built = URL(string: "\(scheme)://\(host)\(p)/\(sub)\(q)") else {
                sendSimpleHttpResponse(connection: connection, status: "400 Bad Request", body: Data())
                return
            }
            targetUrl = built
        } else {
            sendSimpleHttpResponse(connection: connection, status: "404 Not Found", body: Data())
            return
        }

        var outReq = URLRequest(url: targetUrl, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        outReq.httpMethod = method
        for (k, v) in baseHeaders {
            let lk = k.lowercased()
            if lk == "host" || lk == "connection" || lk == "content-length" { continue }
            if !v.isEmpty { outReq.setValue(v, forHTTPHeaderField: k) }
        }
        if let rangeVal = reqHeaders["range"], !rangeVal.isEmpty {
            outReq.setValue(rangeVal, forHTTPHeaderField: "Range")
        }

        do {
            let (data, resp) = try await session.marcoData(for: outReq)
            let http = resp as? HTTPURLResponse
            let statusCode = http?.statusCode ?? 200
            let contentType = http?.value(forHTTPHeaderField: "Content-Type")
                ?? CastService.inferDlnaMimeType(for: targetUrl.absoluteString)
            let isPlaylist = contentType.lowercased().contains("mpegurl")
                || targetUrl.path.lowercased().hasSuffix(".m3u8")

            var payload = data
            var finalContentType = contentType
            if isPlaylist && method == "GET" {
                let text = String(decoding: data, as: UTF8.self)
                let rewritten = Self.rewriteLoopbackPlaylist(
                    text,
                    upstream: rootUpstream,
                    lanHost: currentLanHost,
                    relayPort: currentPort,
                    token: currentToken
                )
                payload = Data(rewritten.utf8)
                finalContentType = "application/vnd.apple.mpegurl; charset=utf-8"
            }

            let statusText = statusCode == 206 ? "206 Partial Content" : (statusCode == 200 ? "200 OK" : "\(statusCode) Status")
            var respLines = [
                "HTTP/1.1 \(statusText)",
                "Content-Type: \(finalContentType)",
                "Accept-Ranges: bytes",
                "Content-Length: \(method == "HEAD" ? (http?.expectedContentLength ?? Int64(payload.count)) : Int64(payload.count))",
                "Connection: close",
            ]
            if let cr = http?.value(forHTTPHeaderField: "Content-Range"), !cr.isEmpty {
                respLines.append("Content-Range: \(cr)")
            }
            respLines.append("")
            respLines.append("")
            var fullResp = Data(respLines.joined(separator: "\r\n").utf8)
            if method != "HEAD" {
                fullResp.append(payload)
            }
            connection.send(content: fullResp, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } catch {
            sendSimpleHttpResponse(connection: connection, status: "502 Bad Gateway", body: Data())
        }
    }

    private func sendSimpleHttpResponse(connection: NWConnection, status: String, body: Data) {
        let header = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var raw = Data(header.utf8)
        raw.append(body)
        connection.send(content: raw, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func extractPeerIpv4(from endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "" }
        switch host {
        case .ipv4(let v4):
            return v4.debugDescription.components(separatedBy: "%").first ?? ""
        case .ipv6(let v6):
            let s = v6.debugDescription.components(separatedBy: "%").first ?? ""
            if s.hasPrefix("::ffff:") { return String(s.dropFirst(7)) }
            return s
        case .name(let name, _):
            return name
        @unknown default:
            return ""
        }
    }

    private static func inferExtension(_ url: URL) -> String {
        let lower = url.path.lowercased()
        for ext in [".m3u8", ".mp4", ".mkv", ".ts", ".webm", ".flv", ".mov", ".avi"] {
            if lower.hasSuffix(ext) { return ext }
        }
        let q = (url.query ?? "").lowercased()
        if q.contains("m3u8") { return ".m3u8" }
        if q.contains(".mkv") { return ".mkv" }
        return ".mp4"
    }

    private static func normalizeExtension(_ raw: String) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if clean.hasPrefix("."), clean.count >= 3, clean.count <= 6,
           clean.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber })
        {
            return clean
        }
        return ".mp4"
    }

    private static func generateRandomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 4-Layer DLNA / UPnP Cast Service

/// Pure-Swift DLNA / UPnP AVTransport & RenderingControl controller with 4-layer LAN discovery
/// (remembered devices + SSDP multicast + `NWBrowser` Bonjour + paced `/24` unicast SSDP & TCP
/// port 18652 probing) plus on-demand `CastMediaRelayServer` for loopback/header-protected streams.
public final class CastService: @unchecked Sendable {
    public static let avTransportServiceType = "urn:schemas-upnp-org:service:AVTransport:1"
    public static let renderingControlServiceType = "urn:schemas-upnp-org:service:RenderingControl:1"
    public static let ssdpAddress = "239.255.255.250"
    public static let ssdpPort: UInt16 = 1900
    public static let marcoTvPreferredPort: UInt16 = 18652

    public static let commonDlnaPorts: [UInt16] = [
        18652, 18653, 49152, 49153, 49154, 49595, 57645, 38400, 52235, 60606,
        8200, 9197, 1990, 9999, 56789, 2870, 1400, 8008, 5000, 15678,
    ]

    public static let commonDlnaXmlPaths: [String] = [
        "/dlna/device.xml",
        "/description.xml",
        "/desc.xml",
        "/dmr/description.xml",
        "/dmr",
        "/upnp/desc.xml",
        "/devicedesc.xml",
        "/MediaRenderer/desc.xml",
        "/xml/device_description.xml",
        "/rootDesc.xml",
        "/",
    ]

    public static let bonjourServiceTypes: [String] = [
        "_marcomovie-cast._tcp",
        "_airplay._tcp",
        "_raop._tcp",
        "_lelink._tcp",
        "_lebo._tcp",
        "_googlecast._tcp",
        "_dlna._tcp",
        "_upnp._tcp",
    ]

    private let session: URLSession
    public let relayServer: CastMediaRelayServer

    public init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 10
            cfg.timeoutIntervalForResource = 20
            cfg.httpShouldSetCookies = false
            self.session = URLSession(configuration: cfg)
        }
        self.relayServer = CastMediaRelayServer(session: self.session)
    }

    // MARK: - Network Interface & Subnet Utilities

    /// Returns `true` for RFC 1918 and CGNAT private LAN IPv4 addresses.
    public static func isPrivateLanIpv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 >= 0 && $0 <= 255 }) else { return false }
        let a = octets[0]
        let b = octets[1]
        if a == 10 { return true }
        if a == 172 && b >= 16 && b <= 31 { return true }
        if a == 192 && b == 168 { return true }
        if a == 100 && b >= 64 && b <= 127 { return true }
        return false
    }

    /// Returns `true` for VPN tunnels, cellular data, loopback, or virtual bridge interfaces.
    public static func isSkippedInterfaceName(_ name: String) -> Bool {
        let lower = name.lowercased()
        let skippedPrefixes = [
            "utun", "ipsec", "ppp", "tun", "tap", "wg", "pdp_ip",
            "rmnet", "ccmni", "awdl", "llw", "anpi", "bridge", "lo",
        ]
        if skippedPrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        let skippedTokens = [
            "clash", "mihomo", "vethernet", "wsl", "docker", "vmware",
            "virtual", "tailscale", "zerotier", "wireguard", "vpn", "loopback",
        ]
        if skippedTokens.contains(where: { lower.contains($0) }) { return true }
        return lower == "meta" || lower.hasPrefix("meta ")
    }

    /// Resolves the active Wi-Fi / Ethernet private LAN IPv4 address using `getifaddrs`,
    /// preferring an interface on the same `/24` (then `/16`) subnet as `peerHost`.
    public static func resolveLanIpv4(peerHost: String? = nil) -> String? {
        let cleanPeer = (peerHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleanPeer == "127.0.0.1" || cleanPeer == "localhost" {
            return "127.0.0.1"
        }

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var candidates: [(priority: Int, ip: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard !isSkippedInterfaceName(name) else { continue }

            var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &sin, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                let ip = String(cString: buf)
                if !ip.hasPrefix("169.254.") && isPrivateLanIpv4(ip) {
                    candidates.append((interfacePriority(name), ip))
                }
            }
        }

        candidates.sort { $0.priority < $1.priority }
        let ips = candidates.map(\.ip)
        if !cleanPeer.isEmpty {
            if let p24 = prefix24(cleanPeer), let hit = ips.first(where: { prefix24($0) == p24 }) {
                return hit
            }
            if let p16 = prefix16(cleanPeer), let hit = ips.first(where: { prefix16($0) == p16 }) {
                return hit
            }
        }
        return ips.first
    }

    /// Generates all 253 peer host IPv4 addresses on the same `/24` subnet as `lanIp`.
    public static func buildSubnetScanIps(lanIp: String) -> [String] {
        guard isPrivateLanIpv4(lanIp) else { return [] }
        let parts = lanIp.split(separator: ".")
        guard parts.count == 4, let selfLast = Int(parts[3]) else { return [] }
        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])"
        var out: [String] = []
        out.reserveCapacity(253)
        for i in 1...254 where i != selfLast {
            out.append("\(prefix).\(i)")
        }
        return out
    }

    public static func parseManualTargetInput(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: withScheme), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    // MARK: - SSDP & Descriptor Parsing

    public static func buildSsdpSearchPacket(searchTarget: String = avTransportServiceType) -> Data {
        let lines = [
            "M-SEARCH * HTTP/1.1",
            "HOST: \(ssdpAddress):\(ssdpPort)",
            "MAN: \"ssdp:discover\"",
            "MX: 2",
            "ST: \(searchTarget)",
            "",
            "",
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    public static func parseSsdpLocation(from responseText: String) -> URL? {
        for line in responseText.components(separatedBy: CharacterSet.newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("location:") {
                let raw = String(trimmed.dropFirst("location:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: raw),
                   let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https")
                {
                    return url
                }
            }
        }
        return nil
    }

    public func fetchDeviceDescription(from locationUrl: URL) async throws -> CastDevice? {
        var req = URLRequest(url: locationUrl, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        req.httpMethod = "GET"
        let (data, resp) = try await session.marcoData(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return nil
        }
        let xml = String(decoding: data, as: UTF8.self)
        return Self.parseDeviceDescriptorXml(xml, locationUrl: locationUrl)
    }

    public static func parseDeviceDescriptorXml(_ xml: String, locationUrl: URL) -> CastDevice? {
        guard xml.contains("AVTransport") else { return nil }
        let friendlyName = extractXmlTag(xml, tag: "friendlyName")
        let udn = extractXmlTag(xml, tag: "UDN")

        guard let serviceRe = try? NSRegularExpression(pattern: #"<service\b[^>]*>([\s\S]*?)</service>"#, options: [.caseInsensitive]) else {
            return nil
        }
        var controlPath = ""
        for m in serviceRe.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let r = Range(m.range(at: 1), in: xml) else { continue }
            let block = String(xml[r])
            let sType = extractXmlTag(block, tag: "serviceType")
            if sType.contains("AVTransport") {
                controlPath = extractXmlTag(block, tag: "controlURL")
                break
            }
        }
        guard !controlPath.isEmpty else { return nil }
        let resolvedControl = CmsParser.resolveUrl(base: locationUrl.absoluteString, relative: controlPath)
        let host = locationUrl.host ?? ""
        return CastDevice(
            id: udn.isEmpty ? resolvedControl : udn,
            name: friendlyName.isEmpty ? host : friendlyName,
            host: host,
            controlUrl: resolvedControl,
            serviceType: avTransportServiceType,
            protocolKind: "dlna"
        )
    }

    /// Extracts optional `RenderingControl` URL from UPnP device XML descriptor.
    public static func parseRenderingControlUrl(_ xml: String, locationUrl: URL) -> String? {
        guard let serviceRe = try? NSRegularExpression(pattern: #"<service\b[^>]*>([\s\S]*?)</service>"#, options: [.caseInsensitive]) else {
            return nil
        }
        for m in serviceRe.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let r = Range(m.range(at: 1), in: xml) else { continue }
            let block = String(xml[r])
            if extractXmlTag(block, tag: "serviceType").contains("RenderingControl") {
                let path = extractXmlTag(block, tag: "controlURL")
                if !path.isEmpty {
                    return CmsParser.resolveUrl(base: locationUrl.absoluteString, relative: path)
                }
            }
        }
        return nil
    }

    // MARK: - 4-Layer LAN Discovery

    /// Runs all 4 discovery layers concurrently:
    /// 0. Remembered recent device descriptor URLs
    /// 1. Multi-burst SSDP multicast (`239.255.255.250:1900`)
    /// 2. Native `NWBrowser` Bonjour scan (`_marcomovie-cast._tcp`, `_dlna._tcp`, `_airplay._tcp`, ...)
    /// 3. Paced unicast `/24` UDP M-SEARCH + Marco Movie TV TCP port `18652` probe
    public func discoverDevices(
        timeoutSeconds: TimeInterval = 3.2,
        rememberedLocations: [String] = []
    ) async -> [CastDevice] {
        let lanIp = Self.resolveLanIpv4()
        let clampedTimeout = min(max(timeoutSeconds, 0.5), 10.0)
        let locationBag = ThreadSafeStringSet()

        await withTaskGroup(of: Void.self) { group in
            // Layer 0: Remembered locations
            if !rememberedLocations.isEmpty {
                group.addTask {
                    for loc in rememberedLocations.prefix(8) {
                        locationBag.insert(loc)
                    }
                }
            }

            // Layer 1: Multicast SSDP
            group.addTask {
                let locs = Self.runUdpSsdpScan(
                    lanIp: lanIp,
                    targets: [Self.ssdpAddress],
                    timeoutSeconds: clampedTimeout
                )
                for l in locs { locationBag.insert(l) }
            }

            // Layer 2: Bonjour NWBrowser
            group.addTask {
                let bonjourLocs = await self.runBonjourDiscovery(timeoutSeconds: min(clampedTimeout, 2.2))
                for l in bonjourLocs { locationBag.insert(l) }
            }

            // Layer 3: Paced unicast /24 SSDP + Marco Movie TV TCP port 18652
            if let lanIp = lanIp, Self.isPrivateLanIpv4(lanIp) {
                let peers = Self.buildSubnetScanIps(lanIp: lanIp)
                if !peers.isEmpty {
                    group.addTask {
                        let locs = Self.runUdpSsdpScan(
                            lanIp: lanIp,
                            targets: peers,
                            timeoutSeconds: clampedTimeout
                        )
                        for l in locs { locationBag.insert(l) }
                    }
                    group.addTask {
                        let tvLocs = await self.probeMarcoTvSubnet(peers: peers)
                        for l in tvLocs { locationBag.insert(l) }
                    }
                }
            }
        }

        let uniqueLocations = locationBag.allItems()
        var discovered: [CastDevice] = []
        var seenIds = Set<String>()

        await withTaskGroup(of: CastDevice?.self) { group in
            for loc in uniqueLocations {
                guard let url = URL(string: loc) else { continue }
                group.addTask {
                    try? await self.fetchDeviceDescription(from: url)
                }
            }
            for await maybeDevice in group {
                if let dev = maybeDevice, seenIds.insert(dev.controlUrl).inserted {
                    discovered.append(dev)
                }
            }
        }
        return discovered
    }

    /// Probes a user-entered TV IP, `IP:Port`, or full descriptor URL directly.
    public func probeManualTarget(_ rawInput: String) async -> CastDevice? {
        guard let parsed = Self.parseManualTargetInput(rawInput), let host = parsed.host else {
            return nil
        }

        if !parsed.path.isEmpty && parsed.path != "/" {
            if let dev = try? await fetchDeviceDescription(from: parsed) {
                return dev
            }
        }

        let portsToProbe: [UInt16] = parsed.port.map { [UInt16($0)] } ?? Self.commonDlnaPorts
        for port in portsToProbe {
            let reachable = await Self.tcpProbe(host: host, port: port, timeoutSeconds: 0.4)
            guard reachable else { continue }
            for path in Self.commonDlnaXmlPaths {
                if let url = URL(string: "http://\(host):\(port)\(path)"),
                   let dev = try? await fetchDeviceDescription(from: url)
                {
                    return dev
                }
            }
        }

        let ssdpLocs = Self.runUdpSsdpScan(
            lanIp: Self.resolveLanIpv4(peerHost: host),
            targets: [host],
            timeoutSeconds: 1.2
        )
        for loc in ssdpLocs {
            if let url = URL(string: loc), let dev = try? await fetchDeviceDescription(from: url) {
                return dev
            }
        }
        return nil
    }

    // MARK: - SOAP Transport & Playback Control

    public static func inferDlnaMimeType(for mediaUrl: String) -> String {
        let lower = mediaUrl.lowercased()
        if lower.contains(".m3u8") || lower.contains("m3u8") { return "application/vnd.apple.mpegurl" }
        if lower.contains(".mkv") { return "video/x-matroska" }
        if lower.contains(".ts") { return "video/mp2t" }
        if lower.contains(".webm") { return "video/webm" }
        if lower.contains(".flv") { return "video/x-flv" }
        return "video/mp4"
    }

    public static func buildDidlLiteMetadata(
        title: String,
        mediaUrl: String,
        mimeType: String? = nil
    ) -> String {
        let safeTitle = escapeXml(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Marco Movie" : title.trimmingCharacters(in: .whitespacesAndNewlines))
        let safeUrl = escapeXml(mediaUrl.trimmingCharacters(in: .whitespacesAndNewlines))
        let mime = mimeType ?? inferDlnaMimeType(for: mediaUrl)
        return "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" "
            + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
            + "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">"
            + "<item id=\"1\" parentID=\"0\" restricted=\"1\">"
            + "<dc:title>\(safeTitle)</dc:title>"
            + "<upnp:class>object.item.videoItem</upnp:class>"
            + "<res protocolInfo=\"http-get:*:\(mime):*\">\(safeUrl)</res>"
            + "</item></DIDL-Lite>"
    }

    public func castMedia(
        to device: CastDevice,
        mediaUrl: URL,
        title: String = "Marco Movie"
    ) async throws {
        try await castMedia(to: device, mediaUrl: mediaUrl, title: title, headers: [:])
    }

    /// Casts media to `device`, automatically routing loopback (`127.0.0.1` / `localhost`) or
    /// header-protected streams through `relayServer` on the matching Wi-Fi LAN interface.
    public func castMedia(
        to device: CastDevice,
        mediaUrl: URL,
        title: String = "Marco Movie",
        headers: [String: String],
        lanIpOverride: String? = nil
    ) async throws {
        let host = (mediaUrl.host ?? "").lowercased()
        let isLoopback = host == "127.0.0.1" || host == "localhost"
        let hasProtectedHeaders = headers.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let targetPlayUrl: URL
        if isLoopback || hasProtectedHeaders {
            let lanIp = lanIpOverride ?? Self.resolveLanIpv4(peerHost: device.host)
            targetPlayUrl = try await relayServer.expose(
                upstreamUrl: mediaUrl,
                headers: headers,
                lanIp: lanIp
            )
        } else {
            relayServer.stop()
            targetPlayUrl = mediaUrl
        }

        let escapedUrl = Self.escapeXml(targetPlayUrl.absoluteString)
        let didlRaw = Self.buildDidlLiteMetadata(title: title, mediaUrl: targetPlayUrl.absoluteString)
        let escapedDidl = Self.escapeXml(didlRaw)
        let setUriBody = """
        <u:SetAVTransportURI xmlns:u="\(device.serviceType)">
          <InstanceID>0</InstanceID>
          <CurrentURI>\(escapedUrl)</CurrentURI>
          <CurrentURIMetaData>\(escapedDidl)</CurrentURIMetaData>
        </u:SetAVTransportURI>
        """
        _ = try await sendSoapAction(
            controlUrl: device.controlUrl,
            serviceType: device.serviceType,
            action: "SetAVTransportURI",
            innerBody: setUriBody
        )
        try await play(on: device)
    }

    public func play(on device: CastDevice) async throws {
        let body = "<u:Play xmlns:u=\"\(device.serviceType)\"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play>"
        _ = try await sendSoapAction(controlUrl: device.controlUrl, serviceType: device.serviceType, action: "Play", innerBody: body)
    }

    public func pause(on device: CastDevice) async throws {
        let body = "<u:Pause xmlns:u=\"\(device.serviceType)\"><InstanceID>0</InstanceID></u:Pause>"
        _ = try await sendSoapAction(controlUrl: device.controlUrl, serviceType: device.serviceType, action: "Pause", innerBody: body)
    }

    public func stop(on device: CastDevice) async throws {
        relayServer.stop()
        let body = "<u:Stop xmlns:u=\"\(device.serviceType)\"><InstanceID>0</InstanceID></u:Stop>"
        _ = try await sendSoapAction(controlUrl: device.controlUrl, serviceType: device.serviceType, action: "Stop", innerBody: body)
    }

    public func seek(on device: CastDevice, seconds: Int) async throws {
        let target = Self.formatHms(max(0, seconds))
        let body = "<u:Seek xmlns:u=\"\(device.serviceType)\"><InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>\(target)</Target></u:Seek>"
        _ = try await sendSoapAction(controlUrl: device.controlUrl, serviceType: device.serviceType, action: "Seek", innerBody: body)
    }

    public func getPositionInfo(on device: CastDevice) async throws -> CastPositionInfo {
        let body = "<u:GetPositionInfo xmlns:u=\"\(device.serviceType)\"><InstanceID>0</InstanceID></u:GetPositionInfo>"
        let xml = try await sendSoapAction(controlUrl: device.controlUrl, serviceType: device.serviceType, action: "GetPositionInfo", innerBody: body)
        let rel = Self.parseHms(Self.extractXmlTag(xml, tag: "RelTime"))
        let dur = Self.parseHms(Self.extractXmlTag(xml, tag: "TrackDuration"))
        return CastPositionInfo(positionSeconds: rel, durationSeconds: dur)
    }

    public func setVolume(on device: CastDevice, renderingControlUrl: String, volume: Int) async throws {
        let clamped = min(max(volume, 0), 100)
        let body = "<u:SetVolume xmlns:u=\"\(Self.renderingControlServiceType)\"><InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>\(clamped)</DesiredVolume></u:SetVolume>"
        _ = try await sendSoapAction(
            controlUrl: renderingControlUrl,
            serviceType: Self.renderingControlServiceType,
            action: "SetVolume",
            innerBody: body
        )
    }

    public func setMute(on device: CastDevice, renderingControlUrl: String, muted: Bool) async throws {
        let body = "<u:SetMute xmlns:u=\"\(Self.renderingControlServiceType)\"><InstanceID>0</InstanceID><Channel>Master</Channel><DesiredMute>\(muted ? 1 : 0)</DesiredMute></u:SetMute>"
        _ = try await sendSoapAction(
            controlUrl: renderingControlUrl,
            serviceType: Self.renderingControlServiceType,
            action: "SetMute",
            innerBody: body
        )
    }

    // MARK: - Discovery Layer Internals

    private static func runUdpSsdpScan(
        lanIp: String?,
        targets: [String],
        timeoutSeconds: TimeInterval
    ) -> [String] {
        guard !targets.isEmpty else { return [] }
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { Darwin.close(fd) }

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        if let lanIp = lanIp, isPrivateLanIpv4(lanIp) {
            var ifAddr = in_addr()
            if inet_pton(AF_INET, lanIp, &ifAddr) == 1 {
                _ = setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &ifAddr, socklen_t(MemoryLayout<in_addr>.size))
            }
        }

        let payloads = [
            buildSsdpSearchPacket(searchTarget: avTransportServiceType),
            buildSsdpSearchPacket(searchTarget: "urn:schemas-upnp-org:device:MediaRenderer:1"),
            buildSsdpSearchPacket(searchTarget: "upnp:rootdevice"),
        ]

        let batchSize = 16
        var idx = 0
        while idx < targets.count {
            let end = min(idx + batchSize, targets.count)
            for j in idx..<end {
                var dest = sockaddr_in()
                dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                dest.sin_family = sa_family_t(AF_INET)
                dest.sin_port = ssdpPort.bigEndian
                guard inet_pton(AF_INET, targets[j], &dest.sin_addr) == 1 else { continue }
                for payload in payloads {
                    payload.withUnsafeBytes { rawBuf in
                        guard let base = rawBuf.baseAddress else { return }
                        withUnsafePointer(to: &dest) { destPtr in
                            destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                                _ = Darwin.sendto(fd, base, payload.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                }
            }
            idx = end
            if idx < targets.count {
                usleep(12_000)
            }
        }

        var locations: [String] = []
        var seen = Set<String>()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var recvBuf = [UInt8](repeating: 0, count: 4096)

        while Date() < deadline {
            let remMs = max(10, Int32(deadline.timeIntervalSinceNow * 1000))
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&pfd, 1, min(remMs, 150))
            if ready <= 0 { continue }
            let n = recvBuf.withUnsafeMutableBytes { bufPtr -> Int in
                guard let base = bufPtr.baseAddress else { return -1 }
                return Darwin.recv(fd, base, bufPtr.count, 0)
            }
            if n <= 0 { continue }
            let text = String(decoding: recvBuf[0..<n], as: UTF8.self)
            if let loc = parseSsdpLocation(from: text), seen.insert(loc.absoluteString).inserted {
                locations.append(loc.absoluteString)
            }
        }
        return locations
    }

    private func runBonjourDiscovery(timeoutSeconds: TimeInterval) async -> [String] {
        let locBag = ThreadSafeStringSet()
        let browseQueue = DispatchQueue(label: "com.pilipala.marcoMovie.ios.cast-bonjour")
        let browsers: [NWBrowser] = Self.bonjourServiceTypes.map { serviceType in
            let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: "local.")
            let browser = NWBrowser(for: descriptor, using: .tcp)
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    if case .service(let name, let type, _, _) = result.endpoint {
                        if type.contains("_marcomovie-cast") {
                            locBag.insert("bonjour://\(name)")
                        }
                    }
                }
            }
            browser.start(queue: browseQueue)
            return browser
        }

        let sleepNs = UInt64(max(0.2, timeoutSeconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: sleepNs)
        for b in browsers { b.cancel() }
        return locBag.allItems().filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
    }

    private func probeMarcoTvSubnet(peers: [String]) async -> [String] {
        let bag = ThreadSafeStringSet()
        let chunkSize = 48
        var start = 0
        while start < peers.count {
            let end = min(start + chunkSize, peers.count)
            let slice = Array(peers[start..<end])
            await withTaskGroup(of: Void.self) { group in
                for ip in slice {
                    group.addTask {
                        if await Self.tcpProbe(host: ip, port: Self.marcoTvPreferredPort, timeoutSeconds: 0.35) {
                            bag.insert("http://\(ip):\(Self.marcoTvPreferredPort)/dlna/device.xml")
                        }
                    }
                }
            }
            start = end
        }
        return bag.allItems()
    }

    private static func tcpProbe(host: String, port: UInt16, timeoutSeconds: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let probeQueue = DispatchQueue(label: "com.pilipala.marcoMovie.ios.cast-probe")
        return await withCheckedContinuation { continuation in
            let once = MarcoOnceFlag()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.tryClaim() {
                        conn.cancel()
                        continuation.resume(returning: true)
                    }
                case .failed, .cancelled:
                    if once.tryClaim() {
                        conn.cancel()
                        continuation.resume(returning: false)
                    }
                default:
                    break
                }
            }
            conn.start(queue: probeQueue)
            probeQueue.asyncAfter(deadline: .now() + timeoutSeconds) {
                if once.tryClaim() {
                    conn.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // MARK: - SOAP Transport & Formatting Helpers

    private func sendSoapAction(
        controlUrl: String,
        serviceType: String,
        action: String,
        innerBody: String
    ) async throws -> String {
        guard let url = URL(string: controlUrl) else {
            throw MarcoError.invalidFormat("投屏设备控制地址无效")
        }
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>\(innerBody)</s:Body>
        </s:Envelope>
        """
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(serviceType)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        req.httpBody = Data(envelope.utf8)

        let (data, resp) = try await session.marcoData(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MarcoError.networkFailure("投屏指令 \(action) 失败 (HTTP \(http.statusCode))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func formatHms(_ totalSeconds: Int) -> String {
        let s = max(0, totalSeconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }

    public static func parseHms(_ text: String) -> Int {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ":")
            .compactMap { Int($0.components(separatedBy: ".").first ?? $0) }
        guard parts.count == 3 else { return 0 }
        return max(0, parts[0] * 3600 + parts[1] * 60 + parts[2])
    }

    private static func interfacePriority(_ name: String) -> Int {
        let lower = name.lowercased()
        if lower == "en0" || lower == "wlan0" || lower == "wi-fi" { return 0 }
        if lower.contains("wlan") || lower.contains("wi-fi") || lower.contains("wireless") { return 1 }
        if lower.hasPrefix("en") { return 2 }
        if lower.hasPrefix("eth") || lower.contains("ethernet") { return 3 }
        return 4
    }

    private static func prefix24(_ ip: String) -> String? {
        let p = ip.split(separator: ".")
        return p.count == 4 ? "\(p[0]).\(p[1]).\(p[2])" : nil
    }

    private static func prefix16(_ ip: String) -> String? {
        let p = ip.split(separator: ".")
        return p.count == 4 ? "\(p[0]).\(p[1])" : nil
    }

    private static func extractXmlTag(_ xml: String, tag: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: "<\(tag)\\b[^>]*>([\\s\\S]*?)</\(tag)>",
            options: [.caseInsensitive]
        ),
            let m = re.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
            let r = Range(m.range(at: 1), in: xml)
        else { return "" }
        return String(xml[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escapeXml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private final class ThreadSafeStringSet: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private var seen = Set<String>()

    func insert(_ value: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        lock.lock()
        if seen.insert(clean).inserted {
            items.append(clean)
        }
        lock.unlock()
    }

    func allItems() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
