// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Network

/// Origin-bound credential & header isolation policy for Netdisk media streams.
/// Ensures `Cookie` and `Authorization` are strictly confined to trusted provider origins/domains
/// and are stripped on cross-domain CDN redirect hops, while always enforcing `Accept-Encoding: identity`.
public struct NetdiskHeaderPolicy: Hashable, Sendable {
    public let originUrl: URL
    public let baseHeaders: [String: String]
    public let cookieDomains: [String]
    public let allowInsecureLoopbackCredentials: Bool
    public let defaultUserAgent: String

    private static let alwaysBlockedHeaderNames: Set<String> = [
        "accept-encoding",
        "range",
        "host",
        "content-length",
        "connection",
        "transfer-encoding",
        "x-ali-refresh-token",
        "refresh-token",
        "x-refresh-token",
    ]

    private static let crossDomainAllowedHeaderNames: Set<String> = [
        "user-agent",
        "accept",
        "accept-language",
    ]

    public init(
        originUrl: URL,
        baseHeaders: [String: String] = [:],
        cookieDomains: [String] = [],
        allowInsecureLoopbackCredentials: Bool = false,
        defaultUserAgent: String = NetdiskService.desktopChromeUA
    ) {
        self.originUrl = originUrl
        self.baseHeaders = baseHeaders
        self.cookieDomains = cookieDomains
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". \t\r\n")).lowercased() }
            .filter { $0.contains(".") && !$0.isEmpty }
        self.allowInsecureLoopbackCredentials = allowInsecureLoopbackCredentials
        self.defaultUserAgent = defaultUserAgent
    }

    public func shouldSendCredentials(to targetUrl: URL) -> Bool {
        if let user = targetUrl.user, !user.isEmpty { return false }
        if let pass = targetUrl.password, !pass.isEmpty { return false }

        guard let targetScheme = targetUrl.scheme?.lowercased(),
              let targetHost = targetUrl.host?.lowercased(),
              !targetHost.isEmpty
        else {
            return false
        }

        let isLoopback = (targetHost == "127.0.0.1" || targetHost == "localhost" || targetHost == "::1")
        if targetScheme != "https" {
            guard allowInsecureLoopbackCredentials && targetScheme == "http" && isLoopback else {
                return false
            }
        }

        let originScheme = originUrl.scheme?.lowercased() ?? ""
        let originHost = originUrl.host?.lowercased() ?? ""
        let sameOriginHostAndPort = (targetScheme == originScheme)
            && (targetHost == originHost)
            && (Self.effectivePort(for: targetUrl) == Self.effectivePort(for: originUrl))
        if sameOriginHostAndPort {
            return true
        }

        guard targetScheme == "https" else { return false }
        for domain in cookieDomains {
            let targetMatches = (targetHost == domain) || targetHost.hasSuffix(".\(domain)")
            let originMatches = (originHost == domain) || originHost.hasSuffix(".\(domain)")
            if targetMatches && originMatches {
                return true
            }
        }
        return false
    }

    public func headers(for targetUrl: URL, range: String? = nil) -> [String: String] {
        let includeSecrets = shouldSendCredentials(to: targetUrl)
        var out: [String: String] = [:]

        for (rawKey, rawVal) in baseHeaders {
            let cleanKey = Self.sanitizeHeaderToken(rawKey)
            let cleanVal = Self.sanitizeHeaderToken(rawVal)
            guard !cleanKey.isEmpty, !cleanVal.isEmpty else { continue }
            let lowerKey = cleanKey.lowercased()
            if Self.alwaysBlockedHeaderNames.contains(lowerKey) { continue }
            if !includeSecrets && !Self.crossDomainAllowedHeaderNames.contains(lowerKey) { continue }
            out[cleanKey] = cleanVal
        }

        if out.keys.allSatisfy({ $0.lowercased() != "user-agent" }) {
            out["User-Agent"] = defaultUserAgent
        }
        out["Accept-Encoding"] = "identity"
        if let range = range {
            let cleanRange = Self.sanitizeHeaderToken(range)
            if !cleanRange.isEmpty { out["Range"] = cleanRange }
        }
        return out
    }

    private static func effectivePort(for url: URL) -> Int {
        if let explicit = url.port { return explicit }
        return (url.scheme?.lowercased() == "https") ? 443 : 80
    }

    private static func sanitizeHeaderToken(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

public struct NetdiskProxyMetrics: Equatable, Sendable {
    public let currentBufferedBytes: Int
    public let peakBufferedBytes: Int
    public let preemptedWindowCount: Int
    public let upstreamChunkRequests: Int
    public let upstreamBytesRead: Int64
    public let cancelledUpstreamRequests: Int

    public init(
        currentBufferedBytes: Int,
        peakBufferedBytes: Int,
        preemptedWindowCount: Int,
        upstreamChunkRequests: Int,
        upstreamBytesRead: Int64 = 0,
        cancelledUpstreamRequests: Int = 0
    ) {
        self.currentBufferedBytes = currentBufferedBytes
        self.peakBufferedBytes = peakBufferedBytes
        self.preemptedWindowCount = preemptedWindowCount
        self.upstreamChunkRequests = upstreamChunkRequests
        self.upstreamBytesRead = upstreamBytesRead
        self.cancelledUpstreamRequests = cancelledUpstreamRequests
    }
}

private struct UpstreamRangeNotSupportedSignal: Error, Sendable {
    let totalSizeHint: Int64?
}

private struct StreamAbortedAfterHeadersSent: Error, Sendable {}

private struct OpenedUpstreamResponse: @unchecked Sendable {
    let statusCode: Int
    let finalUrl: URL
    let headers: [String: String]
    let bodyStream: UpstreamBodyStream?
}

private final class UpstreamBodyStream: @unchecked Sendable {
    private let transfer: ActiveUpstreamTransfer

    init(transfer: ActiveUpstreamTransfer) {
        self.transfer = transfer
    }

    deinit {
        transfer.cancel(countAsAbort: false)
    }

    func nextChunk() async throws -> Data? {
        try await transfer.nextChunk()
    }

    func cancel() {
        transfer.cancel(countAsAbort: true)
    }
}

private final class ActiveUpstreamTransfer: @unchecked Sendable {
    private static let highWaterMark = 128 * 1024
    private static let lowWaterMark = 32 * 1024

    let task: URLSessionDataTask
    let requestUrl: URL
    let discardBodyImmediately: Bool

    private let lock = NSLock()
    private let onBytesRead: @Sendable (Int64) -> Void
    private let onCancelled: @Sendable () -> Void

    private var headerContinuation: CheckedContinuation<OpenedUpstreamResponse, Error>?
    private var headerDelivered = false
    private var bodyQueue: [Data] = []
    private var bufferedBytes = 0
    private var isSuspended = false
    private var bodyWaiter: CheckedContinuation<Data?, Error>?
    private var isFinished = false
    private var completionError: Error?
    private var isCancelled = false
    private var countedAbort = false

    init(
        task: URLSessionDataTask,
        requestUrl: URL,
        discardBodyImmediately: Bool,
        onBytesRead: @escaping @Sendable (Int64) -> Void,
        onCancelled: @escaping @Sendable () -> Void
    ) {
        self.task = task
        self.requestUrl = requestUrl
        self.discardBodyImmediately = discardBodyImmediately
        self.onBytesRead = onBytesRead
        self.onCancelled = onCancelled
    }

    func attachHeaderContinuation(_ cont: CheckedContinuation<OpenedUpstreamResponse, Error>) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            cont.resume(throwing: CancellationError())
            return
        }
        if isFinished {
            let err = completionError ?? MarcoError.networkFailure("上游连接提前中断")
            lock.unlock()
            cont.resume(throwing: err)
            return
        }
        headerContinuation = cont
        lock.unlock()
    }

    func handleResponse(
        _ response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? 200
        let finalUrl = http?.url ?? requestUrl
        var respHeaders: [String: String] = [:]
        if let all = http?.allHeaderFields {
            for (rk, rv) in all {
                respHeaders[String(describing: rk)] = String(describing: rv)
            }
        }

        let isRedirect = [301, 302, 303, 307, 308].contains(statusCode)
        let shouldCancelBody = discardBodyImmediately || isRedirect

        lock.lock()
        if isCancelled {
            let cont = headerContinuation
            headerContinuation = nil
            headerDelivered = true
            lock.unlock()
            completionHandler(.cancel)
            cont?.resume(throwing: CancellationError())
            return
        }
        let cont = headerContinuation
        headerContinuation = nil
        headerDelivered = true
        if shouldCancelBody { isFinished = true }
        lock.unlock()

        if shouldCancelBody {
            completionHandler(.cancel)
            cont?.resume(
                returning: OpenedUpstreamResponse(
                    statusCode: statusCode,
                    finalUrl: finalUrl,
                    headers: respHeaders,
                    bodyStream: nil
                )
            )
        } else {
            let stream = UpstreamBodyStream(transfer: self)
            completionHandler(.allow)
            cont?.resume(
                returning: OpenedUpstreamResponse(
                    statusCode: statusCode,
                    finalUrl: finalUrl,
                    headers: respHeaders,
                    bodyStream: stream
                )
            )
        }
    }

    func handleData(_ data: Data) {
        guard !data.isEmpty else { return }
        onBytesRead(Int64(data.count))

        lock.lock()
        if isCancelled || discardBodyImmediately {
            lock.unlock()
            task.cancel()
            return
        }
        if let waiter = bodyWaiter {
            bodyWaiter = nil
            lock.unlock()
            waiter.resume(returning: data)
            return
        }
        bodyQueue.append(data)
        bufferedBytes += data.count
        let shouldSuspend = bufferedBytes >= Self.highWaterMark && !isSuspended
        if shouldSuspend { isSuspended = true }
        lock.unlock()

        if shouldSuspend { task.suspend() }
    }

    func handleCompletion(error: Error?) {
        lock.lock()
        isFinished = true
        let pendingHeader = headerContinuation
        headerContinuation = nil
        let pendingBody = bodyWaiter
        bodyWaiter = nil
        let cancelledNow = isCancelled
        let effectiveError: Error? = {
            if cancelledNow { return CancellationError() }
            if let error = error { return error }
            return nil
        }()
        if completionError == nil { completionError = effectiveError }
        let storedErr = completionError
        lock.unlock()

        if let cont = pendingHeader {
            cont.resume(throwing: storedErr ?? MarcoError.networkFailure("上游未返回响应头"))
        }
        if let waiter = pendingBody {
            if let err = storedErr { waiter.resume(throwing: err) }
            else { waiter.resume(returning: nil) }
        }
    }

    private enum ImmediateChunkPoll {
        case chunk(Data)
        case eof
        case wait
    }

    private func pollImmediateChunk() throws -> ImmediateChunkPoll {
        lock.lock()
        if isCancelled {
            lock.unlock()
            throw CancellationError()
        }
        if !bodyQueue.isEmpty {
            let chunk = bodyQueue.removeFirst()
            bufferedBytes = max(0, bufferedBytes - chunk.count)
            let shouldResume = isSuspended && bufferedBytes <= Self.lowWaterMark && !isFinished
            if shouldResume { isSuspended = false }
            lock.unlock()
            if shouldResume { task.resume() }
            return .chunk(chunk)
        }
        if isFinished {
            let err = completionError
            lock.unlock()
            if let err = err { throw err }
            return .eof
        }
        lock.unlock()
        return .wait
    }

    private func attachBodyWaiter(_ cont: CheckedContinuation<Data?, Error>) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            cont.resume(throwing: CancellationError())
            return
        }
        if !bodyQueue.isEmpty {
            let chunk = bodyQueue.removeFirst()
            bufferedBytes = max(0, bufferedBytes - chunk.count)
            let shouldResume = isSuspended && bufferedBytes <= Self.lowWaterMark && !isFinished
            if shouldResume { isSuspended = false }
            lock.unlock()
            if shouldResume { task.resume() }
            cont.resume(returning: chunk)
            return
        }
        if isFinished {
            let err = completionError
            lock.unlock()
            if let err = err { cont.resume(throwing: err) }
            else { cont.resume(returning: nil) }
            return
        }
        bodyWaiter = cont
        lock.unlock()
    }

    func nextChunk() async throws -> Data? {
        try Task.checkCancellation()
        switch try pollImmediateChunk() {
        case .chunk(let data): return data
        case .eof: return nil
        case .wait: break
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
                self.attachBodyWaiter(cont)
            }
        } onCancel: {
            self.cancel(countAsAbort: true)
        }
    }

    func cancel(countAsAbort: Bool) {
        lock.lock()
        let alreadyDone = isCancelled || isFinished
        let wasSuspended = isSuspended
        isSuspended = false
        let shouldCount = countAsAbort && !alreadyDone && !countedAbort
        if shouldCount { countedAbort = true }
        isCancelled = true
        bodyQueue.removeAll(keepingCapacity: false)
        bufferedBytes = 0
        let pendingHeader = headerContinuation
        headerContinuation = nil
        let pendingBody = bodyWaiter
        bodyWaiter = nil
        lock.unlock()

        if shouldCount { onCancelled() }
        if !alreadyDone {
            if wasSuspended { task.resume() }
            task.cancel()
        }
        pendingHeader?.resume(throwing: CancellationError())
        pendingBody?.resume(throwing: CancellationError())
    }
}

private final class StreamingUpstreamSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var transfers: [Int: ActiveUpstreamTransfer] = [:]
    private var totalBytesRead: Int64 = 0
    private var totalCancelledRequests: Int = 0

    func metricsSnapshot() -> (bytesRead: Int64, cancelled: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (totalBytesRead, totalCancelledRequests)
    }

    func openStream(
        session: URLSession,
        request: URLRequest,
        discardBodyImmediately: Bool
    ) async throws -> OpenedUpstreamResponse {
        try Task.checkCancellation()
        let task = session.dataTask(with: request)
        let transfer = ActiveUpstreamTransfer(
            task: task,
            requestUrl: request.url ?? URL(string: "http://127.0.0.1")!,
            discardBodyImmediately: discardBodyImmediately,
            onBytesRead: { [weak self] count in
                guard let self = self else { return }
                self.lock.lock()
                self.totalBytesRead += count
                self.lock.unlock()
            },
            onCancelled: { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                self.totalCancelledRequests += 1
                self.lock.unlock()
            }
        )

        storeTransfer(transfer, for: task.taskIdentifier)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                transfer.attachHeaderContinuation(cont)
                task.resume()
            }
        } onCancel: {
            transfer.cancel(countAsAbort: true)
            self.removeTransfer(for: task.taskIdentifier)
        }
    }

    private func storeTransfer(_ transfer: ActiveUpstreamTransfer, for taskIdentifier: Int) {
        lock.lock()
        transfers[taskIdentifier] = transfer
        lock.unlock()
    }

    private func transfer(for taskIdentifier: Int) -> ActiveUpstreamTransfer? {
        lock.lock()
        defer { lock.unlock() }
        return transfers[taskIdentifier]
    }

    private func removeTransfer(for taskIdentifier: Int) {
        lock.lock()
        transfers.removeValue(forKey: taskIdentifier)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let transfer = transfer(for: dataTask.taskIdentifier) else {
            completionHandler(.cancel)
            return
        }
        transfer.handleResponse(response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfer(for: dataTask.taskIdentifier) else {
            dataTask.cancel()
            return
        }
        transfer.handleData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let transfer = transfer(for: task.taskIdentifier)
        removeTransfer(for: task.taskIdentifier)
        transfer?.handleCompletion(error: error)
    }
}

private actor ProxyMemoryBudgetActor {
    private let limitBytes: Int
    private var allocatedBytes: Int = 0
    private var peakBytes: Int = 0
    private var waiters: [(id: UUID, bytes: Int, continuation: CheckedContinuation<Bool, Never>)] = []

    init(limitBytes: Int) {
        self.limitBytes = max(65_536, limitBytes)
    }

    func acquire(bytes requested: Int) async -> Bool {
        if Task.isCancelled { return false }
        let needed = min(max(1, requested), limitBytes)
        if allocatedBytes + needed <= limitBytes && waiters.isEmpty {
            allocatedBytes += needed
            if allocatedBytes > peakBytes { peakBytes = allocatedBytes }
            return true
        }

        let waiterId = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                if allocatedBytes + needed <= limitBytes && waiters.isEmpty {
                    allocatedBytes += needed
                    if allocatedBytes > peakBytes { peakBytes = allocatedBytes }
                    continuation.resume(returning: true)
                } else {
                    waiters.append((id: waiterId, bytes: needed, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterId) }
        }
    }

    func release(bytes released: Int) {
        let amount = min(max(1, released), limitBytes)
        allocatedBytes = max(0, allocatedBytes - amount)
        drainWaiters()
    }

    func resetAll() {
        allocatedBytes = 0
        let pending = waiters
        waiters.removeAll()
        for w in pending { w.continuation.resume(returning: false) }
    }

    func snapshot() -> (current: Int, peak: Int) {
        (allocatedBytes, peakBytes)
    }

    private func cancelWaiter(id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let removed = waiters.remove(at: idx)
            removed.continuation.resume(returning: false)
        }
    }

    private func drainWaiters() {
        while let first = waiters.first, allocatedBytes + first.bytes <= limitBytes {
            waiters.removeFirst()
            allocatedBytes += first.bytes
            if allocatedBytes > peakBytes { peakBytes = allocatedBytes }
            first.continuation.resume(returning: true)
        }
    }
}

private struct UpstreamMediaMetadata: Sendable {
    let totalSize: Int64
    let contentType: String
    let supportsRange: Bool
}

private struct BufferedChunkEntry: Sendable {
    let data: Data
    let reservedBytes: Int
}

private typealias UpstreamStreamOpener = @Sendable (
    _ url: URL,
    _ method: String,
    _ range: String?,
    _ policy: NetdiskHeaderPolicy,
    _ discardBodyImmediately: Bool
) async throws -> OpenedUpstreamResponse

private actor ResourceStreamCoordinator {
    let url: URL
    let policy: NetdiskHeaderPolicy
    let workers: Int
    let chunkSize: Int
    let contentTypeHint: String?
    private let memoryBudget: ProxyMemoryBudgetActor
    private let streamOpener: UpstreamStreamOpener

    private var cachedMetadata: UpstreamMediaMetadata?
    private var generation: UInt64 = 0
    private var isRevoked: Bool = false
    private var activeWindowChunks: ClosedRange<Int>?
    private var inFlightTasks: [Int: (task: Task<Data, Error>, reservedBytes: Int)] = [:]
    private var failedChunks: [Int: Error] = [:]
    private var readyChunks: [Int: BufferedChunkEntry] = [:]
    private var activeNonRangeTask: Task<Void, Never>?
    private var activeNonRangeSessionId: UUID?
    private var activeServeCancels: [UUID: @Sendable () -> Void] = [:]
    private var preemptedWindows: Int = 0
    private var totalChunkRequests: Int = 0

    init(
        url: URL,
        policy: NetdiskHeaderPolicy,
        workers: Int,
        chunkSize: Int,
        contentTypeHint: String?,
        memoryBudget: ProxyMemoryBudgetActor,
        streamOpener: @escaping UpstreamStreamOpener
    ) {
        self.url = url
        self.policy = policy
        self.workers = workers
        self.chunkSize = chunkSize
        self.contentTypeHint = contentTypeHint
        self.memoryBudget = memoryBudget
        self.streamOpener = streamOpener
    }

    func metricsSnapshot() -> (preempted: Int, chunkRequests: Int) {
        (preemptedWindows, totalChunkRequests)
    }

    func registerServeSession(id: UUID, onCancel: @escaping @Sendable () -> Void) {
        if isRevoked {
            onCancel()
            return
        }
        activeServeCancels[id] = onCancel
    }

    func unregisterServeSession(id: UUID) {
        activeServeCancels.removeValue(forKey: id)
    }

    func cancelAndPurgeAll() async {
        generation &+= 1
        activeWindowChunks = nil
        failedChunks.removeAll()
        let nonRange = activeNonRangeTask
        activeNonRangeTask = nil
        activeNonRangeSessionId = nil
        nonRange?.cancel()

        let tasks = Array(inFlightTasks.values.map(\.task))
        inFlightTasks.removeAll()
        for t in tasks { t.cancel() }

        let ready = Array(readyChunks.values)
        readyChunks.removeAll()
        for entry in ready { await memoryBudget.release(bytes: entry.reservedBytes) }
    }

    func revokeAndPurgeAll() async {
        isRevoked = true
        generation &+= 1
        activeWindowChunks = nil
        failedChunks.removeAll()

        let serveCancels = Array(activeServeCancels.values)
        activeServeCancels.removeAll()
        for cancelServe in serveCancels { cancelServe() }

        let nonRange = activeNonRangeTask
        activeNonRangeTask = nil
        activeNonRangeSessionId = nil
        nonRange?.cancel()

        let tasks = Array(inFlightTasks.values.map(\.task))
        inFlightTasks.removeAll()
        for t in tasks { t.cancel() }

        let ready = Array(readyChunks.values)
        readyChunks.removeAll()
        for entry in ready { await memoryBudget.release(bytes: entry.reservedBytes) }

        for t in tasks { _ = await t.result }
        if let nonRange = nonRange { await nonRange.value }
    }

    func cancelGenerationIfCurrent(_ expectedGen: UInt64) async {
        guard generation == expectedGen else { return }
        await cancelAndPurgeAll()
    }

    func registerNonRangeSession(sessionId: UUID, task: Task<Void, Never>) {
        if isRevoked {
            task.cancel()
            return
        }
        if let prev = activeNonRangeTask {
            preemptedWindows += 1
            prev.cancel()
        }
        activeNonRangeSessionId = sessionId
        activeNonRangeTask = task
    }

    func clearNonRangeSession(sessionId: UUID) {
        if activeNonRangeSessionId == sessionId {
            activeNonRangeSessionId = nil
            activeNonRangeTask = nil
        }
    }

    func markRangeUnsupported(totalSizeHint: Int64?) -> UpstreamMediaMetadata {
        let prev = cachedMetadata
        let total = totalSizeHint ?? prev?.totalSize ?? -1
        let ct = prev?.contentType ?? resolvedContentType(from: [:])
        let updated = UpstreamMediaMetadata(totalSize: total, contentType: ct, supportsRange: false)
        cachedMetadata = updated
        return updated
    }

    func openUpstreamStream(
        method: String,
        range: String?,
        discardBodyImmediately: Bool = false
    ) async throws -> OpenedUpstreamResponse {
        guard !isRevoked else { throw CancellationError() }
        return try await streamOpener(url, method, range, policy, discardBodyImmediately)
    }

    func resolveMetadata() async throws -> UpstreamMediaMetadata {
        guard !isRevoked else { throw CancellationError() }
        if let existing = cachedMetadata { return existing }

        let probe = try await streamOpener(url, "GET", "bytes=0-0", policy, true)
        guard !isRevoked else { throw CancellationError() }
        if probe.statusCode == 206,
           let contentRange = headerValue(probe.headers, name: "content-range"),
           let parsedCR = Self.parseByteContentRange(contentRange),
           parsedCR.start == 0,
           let total = parsedCR.total,
           total > 0
        {
            let ct = resolvedContentType(from: probe.headers)
            let meta = UpstreamMediaMetadata(totalSize: total, contentType: ct, supportsRange: true)
            cachedMetadata = meta
            return meta
        }
        if probe.statusCode == 200 {
            let lenHeader = headerValue(probe.headers, name: "content-length").flatMap { Int64($0) }
            let ct = resolvedContentType(from: probe.headers)
            let meta = UpstreamMediaMetadata(totalSize: lenHeader ?? -1, contentType: ct, supportsRange: false)
            cachedMetadata = meta
            return meta
        }

        let headResp = try await streamOpener(url, "HEAD", nil, policy, true)
        guard !isRevoked else { throw CancellationError() }
        guard (200...299).contains(headResp.statusCode) else {
            throw MarcoError.networkFailure("上游媒体探测失败 (HTTP \(headResp.statusCode))")
        }
        let total = headerValue(headResp.headers, name: "content-length").flatMap { Int64($0) } ?? -1
        let acceptRanges = headerValue(headResp.headers, name: "accept-ranges")?.lowercased() ?? ""
        let ct = resolvedContentType(from: headResp.headers)
        let meta = UpstreamMediaMetadata(
            totalSize: total,
            contentType: ct,
            supportsRange: acceptRanges.contains("bytes") && total > 0
        )
        cachedMetadata = meta
        return meta
    }

    func beginStreamSession(startByte: Int64, endByte: Int64, totalSize: Int64) async throws -> UInt64 {
        guard !isRevoked else { throw CancellationError() }
        let firstChunk = Int(startByte / Int64(chunkSize))
        let lastChunk = Int(endByte / Int64(chunkSize))
        let totalChunks = max(1, Int((totalSize + Int64(chunkSize) - 1) / Int64(chunkSize)))
        failedChunks.removeAll()

        let isDisjointSeek: Bool = {
            guard let prev = activeWindowChunks else { return false }
            let hasActiveWork = !inFlightTasks.isEmpty || !readyChunks.isEmpty
            guard hasActiveWork else { return false }
            return firstChunk < prev.lowerBound || firstChunk > prev.upperBound + 1
        }()

        if isDisjointSeek {
            preemptedWindows += 1
            await cancelAndPurgeAll()
        } else {
            let obsoleteReady = readyChunks.keys.filter { $0 < firstChunk }
            for idx in obsoleteReady {
                if let entry = readyChunks.removeValue(forKey: idx) {
                    await memoryBudget.release(bytes: entry.reservedBytes)
                }
            }
            let obsoleteInFlight = inFlightTasks.keys.filter { $0 < firstChunk }
            for idx in obsoleteInFlight {
                if let entry = inFlightTasks.removeValue(forKey: idx) {
                    entry.task.cancel()
                }
            }
        }

        guard !isRevoked else { throw CancellationError() }
        let currentGen = generation
        let windowEnd = min(totalChunks - 1, max(lastChunk, firstChunk + workers - 1))
        activeWindowChunks = firstChunk...windowEnd
        scheduleWindowUpTo(
            cursorChunk: firstChunk,
            maxTargetChunk: min(totalChunks - 1, lastChunk + 1),
            totalSize: totalSize,
            expectedGen: currentGen
        )
        return currentGen
    }

    func consumeChunk(
        chunkIndex: Int,
        maxTargetChunk: Int,
        totalSize: Int64,
        expectedGen: UInt64
    ) async throws -> Data {
        guard !isRevoked, generation == expectedGen, !Task.isCancelled else {
            throw CancellationError()
        }
        if let failure = failedChunks.removeValue(forKey: chunkIndex) {
            throw failure
        }

        let totalChunks = max(1, Int((totalSize + Int64(chunkSize) - 1) / Int64(chunkSize)))
        scheduleWindowUpTo(
            cursorChunk: chunkIndex,
            maxTargetChunk: min(totalChunks - 1, maxTargetChunk),
            totalSize: totalSize,
            expectedGen: expectedGen
        )

        if let ready = readyChunks.removeValue(forKey: chunkIndex) {
            await memoryBudget.release(bytes: ready.reservedBytes)
            advancePrefetchAfterConsumption(
                consumedChunk: chunkIndex,
                maxTargetChunk: min(totalChunks - 1, maxTargetChunk),
                totalSize: totalSize,
                expectedGen: expectedGen
            )
            return ready.data
        }

        guard let inFlight = inFlightTasks[chunkIndex] else {
            if let failure = failedChunks.removeValue(forKey: chunkIndex) { throw failure }
            throw CancellationError()
        }
        let data = try await inFlight.task.value
        guard !isRevoked, generation == expectedGen, !Task.isCancelled else {
            throw CancellationError()
        }
        if let stored = readyChunks.removeValue(forKey: chunkIndex) {
            await memoryBudget.release(bytes: stored.reservedBytes)
        }
        advancePrefetchAfterConsumption(
            consumedChunk: chunkIndex,
            maxTargetChunk: min(totalChunks - 1, maxTargetChunk),
            totalSize: totalSize,
            expectedGen: expectedGen
        )
        return data
    }

    private func advancePrefetchAfterConsumption(
        consumedChunk: Int,
        maxTargetChunk: Int,
        totalSize: Int64,
        expectedGen: UInt64
    ) {
        let nextCursor = consumedChunk + 1
        guard nextCursor <= maxTargetChunk else { return }
        scheduleWindowUpTo(cursorChunk: nextCursor, maxTargetChunk: maxTargetChunk, totalSize: totalSize, expectedGen: expectedGen)
    }

    private func scheduleWindowUpTo(
        cursorChunk: Int,
        maxTargetChunk: Int,
        totalSize: Int64,
        expectedGen: UInt64
    ) {
        guard !isRevoked, generation == expectedGen, cursorChunk <= maxTargetChunk else { return }
        let upper = min(maxTargetChunk, cursorChunk + workers - 1)
        guard cursorChunk <= upper else { return }
        activeWindowChunks = cursorChunk...upper

        for cIdx in cursorChunk...upper {
            if readyChunks[cIdx] != nil || inFlightTasks[cIdx] != nil || failedChunks[cIdx] != nil { continue }
            if inFlightTasks.count >= workers { break }
            let cStart = Int64(cIdx) * Int64(chunkSize)
            let cEnd = min(totalSize - 1, cStart + Int64(chunkSize) - 1)
            let expectedLen = Int(cEnd - cStart + 1)
            guard expectedLen > 0 else { continue }

            totalChunkRequests += 1
            let mediaUrl = self.url
            let hdrPolicy = self.policy
            let opener = self.streamOpener
            let budget = self.memoryBudget
            let coordinator = self

            let task = Task.detached(priority: .userInitiated) { () throws -> Data in
                let acquired = await budget.acquire(bytes: expectedLen)
                guard acquired, !Task.isCancelled else {
                    if acquired { await budget.release(bytes: expectedLen) }
                    await coordinator.recordFailedInFlight(chunkIndex: cIdx, error: CancellationError(), expectedGen: expectedGen)
                    throw CancellationError()
                }
                do {
                    let rangeHdr = "bytes=\(cStart)-\(cEnd)"
                    let opened = try await opener(mediaUrl, "GET", rangeHdr, hdrPolicy, false)
                    let bodyStream = opened.bodyStream
                    defer { bodyStream?.cancel() }
                    try Task.checkCancellation()

                    if opened.statusCode == 206 {
                        guard let contentRangeRaw = opened.headers.first(where: { $0.key.lowercased() == "content-range" })?.value,
                              let parsedCR = ResourceStreamCoordinator.parseByteContentRange(contentRangeRaw)
                        else {
                            bodyStream?.cancel()
                            throw MarcoError.networkFailure("上游 206 响应缺少或包含非法 Content-Range")
                        }
                        guard parsedCR.start == cStart, parsedCR.end == cEnd else {
                            bodyStream?.cancel()
                            throw MarcoError.networkFailure("上游 206 区间不匹配")
                        }
                        if let reportedTotal = parsedCR.total, reportedTotal != totalSize {
                            bodyStream?.cancel()
                            throw MarcoError.networkFailure("上游 206 文件总长度变化")
                        }
                        if let clRaw = opened.headers.first(where: { $0.key.lowercased() == "content-length" })?.value
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           !clRaw.isEmpty
                        {
                            guard let clVal = Int64(clRaw), clVal == Int64(expectedLen) else {
                                bodyStream?.cancel()
                                throw MarcoError.networkFailure("上游 206 Content-Length 与分片长度不匹配")
                            }
                        }

                        guard let stream = bodyStream else {
                            throw MarcoError.networkFailure("上游 206 响应缺少正文流")
                        }
                        var payload = Data()
                        payload.reserveCapacity(expectedLen)
                        while payload.count < expectedLen {
                            try Task.checkCancellation()
                            guard let piece = try await stream.nextChunk() else { break }
                            if piece.isEmpty { continue }
                            let remaining = expectedLen - payload.count
                            if piece.count > remaining {
                                stream.cancel()
                                throw MarcoError.networkFailure("上游 206 分片正文超出声明区间长度")
                            }
                            payload.append(piece)
                        }
                        try Task.checkCancellation()
                        guard payload.count == expectedLen else {
                            throw MarcoError.networkFailure("上游 206 分片正文提前结束 (\(payload.count)/\(expectedLen))")
                        }
                        await coordinator.storeCompletedChunk(
                            chunkIndex: cIdx,
                            data: payload,
                            reservedBytes: expectedLen,
                            expectedGen: expectedGen
                        )
                        return payload
                    } else if opened.statusCode == 200 {
                        bodyStream?.cancel()
                        let lenHint = opened.headers.first(where: { $0.key.lowercased() == "content-length" })
                            .flatMap { Int64($0.value) }
                        _ = await coordinator.markRangeUnsupported(totalSizeHint: lenHint)
                        throw UpstreamRangeNotSupportedSignal(totalSizeHint: lenHint)
                    } else {
                        bodyStream?.cancel()
                        throw MarcoError.networkFailure("上游分片请求失败 (HTTP \(opened.statusCode))")
                    }
                } catch {
                    await budget.release(bytes: expectedLen)
                    await coordinator.recordFailedInFlight(chunkIndex: cIdx, error: error, expectedGen: expectedGen)
                    throw error
                }
            }
            inFlightTasks[cIdx] = (task: task, reservedBytes: expectedLen)
        }
    }

    private func storeCompletedChunk(
        chunkIndex: Int,
        data: Data,
        reservedBytes: Int,
        expectedGen: UInt64
    ) async {
        guard !isRevoked, generation == expectedGen, inFlightTasks[chunkIndex] != nil else {
            await memoryBudget.release(bytes: reservedBytes)
            return
        }
        inFlightTasks.removeValue(forKey: chunkIndex)
        readyChunks[chunkIndex] = BufferedChunkEntry(data: data, reservedBytes: reservedBytes)
    }

    private func recordFailedInFlight(chunkIndex: Int, error: Error, expectedGen: UInt64) {
        guard !isRevoked, generation == expectedGen else { return }
        inFlightTasks.removeValue(forKey: chunkIndex)
        if !(error is CancellationError) {
            failedChunks[chunkIndex] = error
        }
    }

    private func headerValue(_ headers: [String: String], name: String) -> String? {
        let lower = name.lowercased()
        return headers.first(where: { $0.key.lowercased() == lower })?.value
    }

    private func resolvedContentType(from headers: [String: String]) -> String {
        if let hint = contentTypeHint, !hint.isEmpty { return hint }
        if let upstream = headerValue(headers, name: "content-type"), !upstream.isEmpty { return upstream }
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mkv": return "video/x-matroska"
        case "mov": return "video/quicktime"
        case "ts": return "video/mp2t"
        case "m3u8": return "application/vnd.apple.mpegurl"
        default: return "application/octet-stream"
        }
    }

    static func parseByteContentRange(_ header: String) -> (start: Int64, end: Int64, total: Int64?)? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let body = String(trimmed.dropFirst("bytes ".count)).trimmingCharacters(in: .whitespaces)
        let slashParts = body.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard slashParts.count == 2 else { return nil }
        let rangePart = String(slashParts[0]).trimmingCharacters(in: .whitespaces)
        let totalPart = String(slashParts[1]).trimmingCharacters(in: .whitespaces)
        let dashParts = rangePart.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard dashParts.count == 2,
              let start = Int64(dashParts[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(dashParts[1].trimmingCharacters(in: .whitespaces)),
              start >= 0, end >= start
        else { return nil }
        let total: Int64?
        if totalPart == "*" { total = nil }
        else if let parsedTotal = Int64(totalPart), parsedTotal > end { total = parsedTotal }
        else { return nil }
        return (start: start, end: end, total: total)
    }
}

/// Loopback (`127.0.0.1:<ephemeral>`) 6-worker Range proxy server for iOS 4K Netdisk playback.
/// 100% iOS 14.0+ compatible (uses `URLSessionDataDelegate` streaming, never iOS 15 `URLSession.bytes`).
public final class NetdiskRangeProxyServer: @unchecked Sendable {
    public static let defaultWorkers = 6
    public static let defaultChunkSize = 1_048_576
    public static let defaultMemoryLimit = 24 * 1024 * 1024
    public static let defaultMaxNonRangeSkipBytes: Int64 = 8 * 1024 * 1024
    private static let maxRedirects = 8

    public let workers: Int
    public let chunkSize: Int
    public let memoryLimit: Int
    public let maxNonRangeSkipBytes: Int64

    private let queue = DispatchQueue(label: "com.pilipala.marcoMovie.ios.range-proxy", qos: .userInitiated)
    private let stateLock = NSLock()
    private var serverToken: String
    private var resources: [String: ResourceStreamCoordinator] = [:]
    private var retiredPreemptedWindows: Int = 0
    private var retiredChunkRequests: Int = 0
    private var listener: NWListener?
    private(set) public var port: UInt16 = 0

    private let memoryBudget: ProxyMemoryBudgetActor
    private let streamingDelegate: StreamingUpstreamSessionDelegate
    private let urlSession: URLSession
    private let streamOpener: UpstreamStreamOpener

    public init(
        workers: Int = NetdiskRangeProxyServer.defaultWorkers,
        chunkSize: Int = NetdiskRangeProxyServer.defaultChunkSize,
        memoryLimit: Int = NetdiskRangeProxyServer.defaultMemoryLimit,
        maxNonRangeSkipBytes: Int64 = NetdiskRangeProxyServer.defaultMaxNonRangeSkipBytes,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.workers = min(max(1, workers), 6)
        self.chunkSize = min(max(65_536, chunkSize), 2 * 1024 * 1024)
        self.memoryLimit = max(self.chunkSize * 2, memoryLimit)
        self.maxNonRangeSkipBytes = max(65_536, maxNonRangeSkipBytes)
        self.serverToken = Self.randomHex(byteCount: 16)
        self.memoryBudget = ProxyMemoryBudgetActor(limitBytes: self.memoryLimit)

        let cfg = sessionConfiguration ?? {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 20
            c.timeoutIntervalForResource = 180
            c.httpMaximumConnectionsPerHost = 8
            c.httpShouldSetCookies = false
            c.httpCookieAcceptPolicy = .never
            return c
        }()
        let delegate = StreamingUpstreamSessionDelegate()
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        self.streamingDelegate = delegate
        self.urlSession = session
        self.streamOpener = { targetUrl, method, rangeHeader, policy, discardBodyImmediately in
            try await Self.openStreamFollowingRedirects(
                session: session,
                delegate: delegate,
                initialUrl: targetUrl,
                method: method,
                range: rangeHeader,
                policy: policy,
                discardBodyImmediately: discardBodyImmediately
            )
        }
    }

    deinit {
        stop()
    }

    public var currentToken: String {
        withStateLock { serverToken }
    }

    public func startIfNeeded() async throws -> UInt16 {
        if let existing = withStateLock({ () -> UInt16? in
            (listener != nil && port > 0) ? port : nil
        }) {
            return existing
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

        let nwListener = try NWListener(using: params)
        nwListener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }

        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = MarcoOnceFlag()
            nwListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.tryClaim() else { return }
                    if let p = nwListener.port?.rawValue, p > 0 {
                        continuation.resume(returning: p)
                    } else {
                        continuation.resume(throwing: MarcoError.networkFailure("分片代理端口分配失败"))
                    }
                case .failed(let err):
                    guard once.tryClaim() else { return }
                    continuation.resume(throwing: MarcoError.networkFailure("分片代理启动失败：\(err)"))
                case .cancelled:
                    guard once.tryClaim() else { return }
                    continuation.resume(throwing: MarcoError.networkFailure("分片代理已关闭"))
                default:
                    break
                }
            }
            nwListener.start(queue: self.queue)
        }

        withStateLock {
            self.listener = nwListener
            self.port = boundPort
        }
        return boundPort
    }

    public func stop() {
        let (activeListener, oldResources) = withStateLock { () -> (NWListener?, [ResourceStreamCoordinator]) in
            let current = listener
            listener = nil
            port = 0
            let all = Array(resources.values)
            resources.removeAll()
            serverToken = Self.randomHex(byteCount: 16)
            return (current, all)
        }
        activeListener?.cancel()
        urlSession.invalidateAndCancel()
        let budget = self.memoryBudget
        Task {
            for coord in oldResources { await coord.revokeAndPurgeAll() }
            await budget.resetAll()
        }
    }

    public func activeResourceCount() -> Int { withStateLock { resources.count } }
    public func hasActiveResource(_ resourceId: String) -> Bool { withStateLock { resources[resourceId] != nil } }

    public func revokeAll() async {
        let oldResources = withStateLock { () -> [ResourceStreamCoordinator] in
            serverToken = Self.randomHex(byteCount: 16)
            let all = Array(resources.values)
            resources.removeAll()
            return all
        }
        for coord in oldResources {
            let snap = await coord.metricsSnapshot()
            recordRetiredMetrics(preempted: snap.preempted, chunkRequests: snap.chunkRequests)
            await coord.revokeAndPurgeAll()
        }
        await memoryBudget.resetAll()
    }

    public func revokeResource(_ resourceId: String) async {
        let removed = withStateLock { resources.removeValue(forKey: resourceId) }
        if let coord = removed {
            let snap = await coord.metricsSnapshot()
            recordRetiredMetrics(preempted: snap.preempted, chunkRequests: snap.chunkRequests)
            await coord.revokeAndPurgeAll()
        }
    }

    private func recordRetiredMetrics(preempted: Int, chunkRequests: Int) {
        withStateLock {
            retiredPreemptedWindows += preempted
            retiredChunkRequests += chunkRequests
        }
    }

    public func registerStream(
        url: URL,
        policy: NetdiskHeaderPolicy,
        contentTypeHint: String? = nil
    ) async throws -> (resourceId: String, proxyUrl: URL) {
        let activePort = try await startIfNeeded()
        let resourceId = Self.randomHex(byteCount: 12)
        let coordinator = ResourceStreamCoordinator(
            url: url,
            policy: policy,
            workers: workers,
            chunkSize: chunkSize,
            contentTypeHint: contentTypeHint,
            memoryBudget: memoryBudget,
            streamOpener: streamOpener
        )

        let (tokenSnapshot, evictedCoord) = withStateLock { () -> (String, ResourceStreamCoordinator?) in
            var evicted: ResourceStreamCoordinator?
            if resources.count >= 32, let evictedKey = resources.keys.first {
                evicted = resources.removeValue(forKey: evictedKey)
            }
            resources[resourceId] = coordinator
            return (serverToken, evicted)
        }
        if let evictedCoord = evictedCoord {
            let snap = await evictedCoord.metricsSnapshot()
            recordRetiredMetrics(preempted: snap.preempted, chunkRequests: snap.chunkRequests)
            await evictedCoord.revokeAndPurgeAll()
        }

        guard let proxyUrl = URL(string: "http://127.0.0.1:\(activePort)/\(tokenSnapshot)/\(resourceId)/media") else {
            throw MarcoError.networkFailure("无法构造分片代理播放地址")
        }
        return (resourceId, proxyUrl)
    }

    public func metrics() async -> NetdiskProxyMetrics {
        let (coords, basePreempted, baseChunkReqs) = withStateLock {
            (Array(resources.values), retiredPreemptedWindows, retiredChunkRequests)
        }
        var totalPreempted = basePreempted
        var totalChunkReqs = baseChunkReqs
        for c in coords {
            let snap = await c.metricsSnapshot()
            totalPreempted += snap.preempted
            totalChunkReqs += snap.chunkRequests
        }
        let mem = await memoryBudget.snapshot()
        let streamSnap = streamingDelegate.metricsSnapshot()
        return NetdiskProxyMetrics(
            currentBufferedBytes: mem.current,
            peakBufferedBytes: mem.peak,
            preemptedWindowCount: totalPreempted,
            upstreamChunkRequests: totalChunkReqs,
            upstreamBytesRead: streamSnap.bytesRead,
            cancelledUpstreamRequests: streamSnap.cancelled
        )
    }

    // MARK: - Redirect-Filtered Header-First Upstream Streamers (iOS 14.0+ Safe)

    private static func openStreamFollowingRedirects(
        session: URLSession,
        delegate: StreamingUpstreamSessionDelegate,
        initialUrl: URL,
        method: String,
        range: String?,
        policy: NetdiskHeaderPolicy,
        discardBodyImmediately: Bool
    ) async throws -> OpenedUpstreamResponse {
        var currentUrl = initialUrl
        var currentMethod = method.uppercased()

        for _ in 0...maxRedirects {
            try Task.checkCancellation()
            guard let scheme = currentUrl.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                throw MarcoError.networkFailure("不支持的重定向协议")
            }

            var req = URLRequest(url: currentUrl, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            req.httpMethod = currentMethod
            req.httpShouldHandleCookies = false
            let filteredHeaders = policy.headers(for: currentUrl, range: range)
            for (k, v) in filteredHeaders {
                req.setValue(v, forHTTPHeaderField: k)
            }

            let opened = try await delegate.openStream(
                session: session,
                request: req,
                discardBodyImmediately: discardBodyImmediately || currentMethod == "HEAD"
            )
            let status = opened.statusCode
            if [301, 302, 303, 307, 308].contains(status),
               let location = opened.headers.first(where: { $0.key.lowercased() == "location" })?.value
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !location.isEmpty,
               let nextUrl = URL(string: location, relativeTo: currentUrl)?.absoluteURL
            {
                opened.bodyStream?.cancel()
                if status == 303 && currentMethod != "HEAD" { currentMethod = "GET" }
                currentUrl = nextUrl
                continue
            }

            return opened
        }
        throw MarcoError.networkFailure("上游重定向次数超过上限 (\(maxRedirects))")
    }

    /// iOS 14.0+ compatible redirect-isolated helper with strict upper body bound (never uses iOS 15 `URLSession.bytes`).
    public static func fetchFollowingRedirects(
        sessionConfiguration: URLSessionConfiguration? = nil,
        initialUrl: URL,
        method: String,
        range: String?,
        policy: NetdiskHeaderPolicy,
        maxBodyBytes: Int = 4 * 1024 * 1024
    ) async throws -> ProxyUpstreamResponse {
        let byteCap = max(0, maxBodyBytes)
        let cfg = sessionConfiguration ?? {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 20
            c.timeoutIntervalForResource = 60
            c.httpShouldSetCookies = false
            c.httpCookieAcceptPolicy = .never
            return c
        }()
        let delegate = StreamingUpstreamSessionDelegate()
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let opened = try await openStreamFollowingRedirects(
            session: session,
            delegate: delegate,
            initialUrl: initialUrl,
            method: method,
            range: range,
            policy: policy,
            discardBodyImmediately: (method.uppercased() == "HEAD" || byteCap == 0)
        )
        guard let bodyStream = opened.bodyStream, byteCap > 0 else {
            return ProxyUpstreamResponse(statusCode: opened.statusCode, headers: opened.headers, body: Data())
        }
        defer { bodyStream.cancel() }

        var collected = Data()
        while collected.count < byteCap, let chunk = try await bodyStream.nextChunk() {
            try Task.checkCancellation()
            if chunk.isEmpty { continue }
            let remaining = byteCap - collected.count
            if chunk.count >= remaining {
                collected.append(chunk.prefix(remaining))
                bodyStream.cancel()
                break
            }
            collected.append(chunk)
        }
        return ProxyUpstreamResponse(statusCode: opened.statusCode, headers: opened.headers, body: collected)
    }

    // MARK: - Loopback HTTP Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeader(connection: connection, accumulated: Data())
    }

    private func receiveHeader(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] chunk, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let chunk = chunk, !chunk.isEmpty { buffer.append(chunk) }
            if buffer.count > 65_536 {
                self.sendSimpleResponse(connection: connection, status: 413, headers: [:], body: Data("Header Too Large".utf8))
                return
            }
            if let sep = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                let headerSlice = buffer.subdata(in: 0..<sep.lowerBound)
                self.dispatchRequest(headerData: headerSlice, connection: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                self.receiveHeader(connection: connection, accumulated: buffer)
            }
        }
    }

    private enum ParsedRangeResult {
        case none
        case valid(start: Int64, end: Int64)
        case unsatisfiable
    }

    private static func parseByteRange(_ rawHeader: String?, totalSize: Int64) -> ParsedRangeResult {
        guard let raw = rawHeader?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return .none }
        guard raw.lowercased().hasPrefix("bytes=") else { return .unsatisfiable }
        let spec = String(raw.dropFirst("bytes=".count)).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(","), let dashIdx = spec.firstIndex(of: "-"), totalSize > 0 else { return .unsatisfiable }

        let startPart = String(spec[..<dashIdx]).trimmingCharacters(in: .whitespaces)
        let endPart = String(spec[spec.index(after: dashIdx)...]).trimmingCharacters(in: .whitespaces)

        if startPart.isEmpty {
            guard let suffixLen = Int64(endPart), suffixLen > 0 else { return .unsatisfiable }
            return .valid(start: max(0, totalSize - suffixLen), end: totalSize - 1)
        }
        guard let start = Int64(startPart), start >= 0, start < totalSize else { return .unsatisfiable }
        if endPart.isEmpty { return .valid(start: start, end: totalSize - 1) }
        guard let requestedEnd = Int64(endPart), requestedEnd >= start else { return .unsatisfiable }
        return .valid(start: start, end: min(requestedEnd, totalSize - 1))
    }

    private func dispatchRequest(headerData: Data, connection: NWConnection) {
        let text = String(decoding: headerData, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendSimpleResponse(connection: connection, status: 400, headers: [:], body: Data("Bad Request".utf8))
            return
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            sendSimpleResponse(connection: connection, status: 400, headers: [:], body: Data("Bad Request".utf8))
            return
        }
        let method = parts[0].uppercased()
        guard method == "GET" || method == "HEAD" else {
            sendSimpleResponse(connection: connection, status: 405, headers: ["Allow": "GET, HEAD"], body: Data("Method Not Allowed".utf8))
            return
        }

        let rawPath = parts[1].components(separatedBy: "?").first ?? parts[1]
        let segments = rawPath.split(separator: "/").map(String.init)
        guard segments.count == 3, segments[2].hasPrefix("media") else {
            sendSimpleResponse(connection: connection, status: 404, headers: [:], body: Data("Not Found".utf8))
            return
        }

        let reqToken = segments[0]
        let resourceId = segments[1]

        let lookup = withStateLock { () -> (tokenValid: Bool, coordinator: ResourceStreamCoordinator?) in
            guard reqToken == serverToken else { return (false, nil) }
            return (true, resources[resourceId])
        }

        guard lookup.tokenValid else {
            sendSimpleResponse(connection: connection, status: 403, headers: [:], body: Data("Forbidden".utf8))
            return
        }
        guard let coordinator = lookup.coordinator else {
            sendSimpleResponse(connection: connection, status: 404, headers: [:], body: Data("Expired Resource".utf8))
            return
        }

        var clientHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            clientHeaders[k] = v
        }
        let rangeHeader = clientHeaders["range"]

        let serveId = UUID()
        let serveTask = Task { [weak self] in
            guard let self = self else {
                connection.cancel()
                return
            }
            defer { Task { await coordinator.unregisterServeSession(id: serveId) } }
            await self.serveMediaRequest(
                method: method,
                rangeHeader: rangeHeader,
                coordinator: coordinator,
                connection: connection
            )
        }
        Task {
            await coordinator.registerServeSession(id: serveId) {
                serveTask.cancel()
                connection.cancel()
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: serveTask.cancel()
            default: break
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
            if isComplete || error != nil { serveTask.cancel() }
        }
    }

    private func serveMediaRequest(
        method: String,
        rangeHeader: String?,
        coordinator: ResourceStreamCoordinator,
        connection: NWConnection
    ) async {
        do {
            var meta = try await coordinator.resolveMetadata()
            if !meta.supportsRange {
                try await handleNonRangeMediaRequest(
                    method: method,
                    rangeHeader: rangeHeader,
                    meta: meta,
                    coordinator: coordinator,
                    connection: connection
                )
                return
            }

            let parsedRange = Self.parseByteRange(rangeHeader, totalSize: meta.totalSize)
            switch parsedRange {
            case .unsatisfiable:
                sendSimpleResponse(
                    connection: connection,
                    status: 416,
                    headers: [
                        "Accept-Ranges": "bytes",
                        "Content-Range": "bytes */\(meta.totalSize)",
                        "Cache-Control": "no-store",
                    ],
                    body: method == "HEAD" ? Data() : Data("Range Not Satisfiable".utf8)
                )
            case .none:
                let baseHeaders: [String: String] = [
                    "Accept-Ranges": "bytes",
                    "Content-Type": meta.contentType,
                    "Content-Length": "\(meta.totalSize)",
                    "Cache-Control": "no-store",
                ]
                if method == "HEAD" || meta.totalSize == 0 {
                    sendSimpleResponse(connection: connection, status: 200, headers: baseHeaders, body: Data())
                    return
                }
                do {
                    try await streamRangeBody(
                        status: 200,
                        headers: baseHeaders,
                        startByte: 0,
                        endByte: meta.totalSize - 1,
                        totalSize: meta.totalSize,
                        coordinator: coordinator,
                        connection: connection
                    )
                } catch let fallback as UpstreamRangeNotSupportedSignal {
                    meta = await coordinator.markRangeUnsupported(totalSizeHint: fallback.totalSizeHint)
                    try await handleNonRangeMediaRequest(
                        method: method,
                        rangeHeader: rangeHeader,
                        meta: meta,
                        coordinator: coordinator,
                        connection: connection
                    )
                }
            case .valid(let startByte, let endByte):
                let contentLen = endByte - startByte + 1
                let rangeHeaders: [String: String] = [
                    "Accept-Ranges": "bytes",
                    "Content-Type": meta.contentType,
                    "Content-Range": "bytes \(startByte)-\(endByte)/\(meta.totalSize)",
                    "Content-Length": "\(contentLen)",
                    "Cache-Control": "no-store",
                ]
                if method == "HEAD" {
                    sendSimpleResponse(connection: connection, status: 206, headers: rangeHeaders, body: Data())
                    return
                }
                do {
                    try await streamRangeBody(
                        status: 206,
                        headers: rangeHeaders,
                        startByte: startByte,
                        endByte: endByte,
                        totalSize: meta.totalSize,
                        coordinator: coordinator,
                        connection: connection
                    )
                } catch let fallback as UpstreamRangeNotSupportedSignal {
                    meta = await coordinator.markRangeUnsupported(totalSizeHint: fallback.totalSizeHint)
                    try await handleNonRangeMediaRequest(
                        method: method,
                        rangeHeader: rangeHeader,
                        meta: meta,
                        coordinator: coordinator,
                        connection: connection
                    )
                }
            }
        } catch is CancellationError {
            connection.cancel()
        } catch is StreamAbortedAfterHeadersSent {
            return
        } catch {
            sendSimpleResponse(
                connection: connection,
                status: 502,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: method == "HEAD" ? Data() : Data("Upstream Stream Error".utf8)
            )
        }
    }

    private func streamRangeBody(
        status: Int,
        headers: [String: String],
        startByte: Int64,
        endByte: Int64,
        totalSize: Int64,
        coordinator: ResourceStreamCoordinator,
        connection: NWConnection
    ) async throws {
        let sessionGen = try await coordinator.beginStreamSession(
            startByte: startByte,
            endByte: endByte,
            totalSize: totalSize
        )
        let firstChunk = Int(startByte / Int64(chunkSize))
        let lastChunk = Int(endByte / Int64(chunkSize))
        var headersSent = false

        do {
            for cIdx in firstChunk...lastChunk {
                try Task.checkCancellation()
                let chunkData = try await coordinator.consumeChunk(
                    chunkIndex: cIdx,
                    maxTargetChunk: lastChunk + 1,
                    totalSize: totalSize,
                    expectedGen: sessionGen
                )
                let chunkGlobalStart = Int64(cIdx) * Int64(chunkSize)
                let chunkGlobalEnd = min(totalSize - 1, chunkGlobalStart + Int64(chunkSize) - 1)
                let expectedChunkLen = Int(chunkGlobalEnd - chunkGlobalStart + 1)
                guard chunkData.count == expectedChunkLen else {
                    throw MarcoError.networkFailure("分片数据长度与预期不匹配")
                }
                let sliceStart = Int(max(0, startByte - chunkGlobalStart))
                let sliceEnd = Int(min(Int64(chunkData.count), endByte - chunkGlobalStart + 1))
                guard sliceStart < sliceEnd, sliceEnd <= chunkData.count else {
                    throw MarcoError.networkFailure("分片数据长度与请求范围不匹配")
                }
                if !headersSent {
                    headersSent = true
                    let headerPacket = Data(Self.formatHttpHeaderBlock(status: status, headers: headers).utf8)
                    try await Self.sendPacket(connection: connection, data: headerPacket)
                }
                let slice = (sliceStart == 0 && sliceEnd == chunkData.count)
                    ? chunkData
                    : chunkData.subdata(in: sliceStart..<sliceEnd)
                try await Self.sendPacket(connection: connection, data: slice)
            }
            Self.closeConnectionAfterBody(connection)
        } catch is CancellationError {
            await coordinator.cancelGenerationIfCurrent(sessionGen)
            if headersSent {
                Self.closeConnectionAfterBody(connection)
                throw StreamAbortedAfterHeadersSent()
            }
            throw CancellationError()
        } catch {
            await coordinator.cancelGenerationIfCurrent(sessionGen)
            if headersSent {
                Self.closeConnectionAfterBody(connection)
                throw StreamAbortedAfterHeadersSent()
            }
            if let fallback = error as? UpstreamRangeNotSupportedSignal { throw fallback }
            throw error
        }
    }

    private func handleNonRangeMediaRequest(
        method: String,
        rangeHeader: String?,
        meta: UpstreamMediaMetadata,
        coordinator: ResourceStreamCoordinator,
        connection: NWConnection
    ) async throws {
        if method == "HEAD" {
            var headHeaders: [String: String] = [
                "Accept-Ranges": "none",
                "Content-Type": meta.contentType,
                "Cache-Control": "no-store",
            ]
            if meta.totalSize >= 0 { headHeaders["Content-Length"] = "\(meta.totalSize)" }
            sendSimpleResponse(connection: connection, status: 200, headers: headHeaders, body: Data())
            return
        }

        let parsedRange: ParsedRangeResult = meta.totalSize > 0
            ? Self.parseByteRange(rangeHeader, totalSize: meta.totalSize)
            : .none
        if case .unsatisfiable = parsedRange {
            sendSimpleResponse(
                connection: connection,
                status: 416,
                headers: [
                    "Accept-Ranges": "none",
                    "Content-Range": "bytes */\(meta.totalSize)",
                    "Cache-Control": "no-store",
                ],
                body: Data("Range Not Satisfiable".utf8)
            )
            return
        }

        let sessionId = UUID()
        let streamTask = Task { [weak self] in
            guard let self = self else { return }
            let bufferReservation = min(self.chunkSize, 65_536)
            let acquired = await self.memoryBudget.acquire(bytes: bufferReservation)
            guard acquired, !Task.isCancelled else {
                if acquired { await self.memoryBudget.release(bytes: bufferReservation) }
                await coordinator.clearNonRangeSession(sessionId: sessionId)
                connection.cancel()
                return
            }

            var headersSent = false
            do {
                let opened = try await coordinator.openUpstreamStream(method: "GET", range: nil, discardBodyImmediately: false)
                guard (200...299).contains(opened.statusCode), let bodyStream = opened.bodyStream else {
                    opened.bodyStream?.cancel()
                    self.sendSimpleResponse(
                        connection: connection,
                        status: 502,
                        headers: ["Content-Type": "text/plain; charset=utf-8"],
                        body: Data("Upstream Stream Error".utf8)
                    )
                    await self.memoryBudget.release(bytes: bufferReservation)
                    await coordinator.clearNonRangeSession(sessionId: sessionId)
                    return
                }
                defer { bodyStream.cancel() }

                let upstreamTotal: Int64 = opened.headers.first(where: { $0.key.lowercased() == "content-length" })
                    .flatMap { Int64($0.value) } ?? meta.totalSize
                let contentType = opened.headers.first(where: { $0.key.lowercased() == "content-type" })?.value ?? meta.contentType

                if case .valid(let reqStart, let reqEnd) = parsedRange,
                   upstreamTotal > 0,
                   reqStart <= self.maxNonRangeSkipBytes
                {
                    let clampedEnd = min(reqEnd, upstreamTotal - 1)
                    let contentLen = clampedEnd - reqStart + 1
                    let respHeaders: [String: String] = [
                        "Accept-Ranges": "none",
                        "Content-Type": contentType,
                        "Content-Range": "bytes \(reqStart)-\(clampedEnd)/\(upstreamTotal)",
                        "Content-Length": "\(contentLen)",
                        "Cache-Control": "no-store",
                    ]
                    headersSent = true
                    try await Self.sendPacket(connection: connection, data: Data(Self.formatHttpHeaderBlock(status: 206, headers: respHeaders).utf8))

                    var cursor: Int64 = 0
                    var bytesSent: Int64 = 0
                    while let chunk = try await bodyStream.nextChunk() {
                        try Task.checkCancellation()
                        guard !chunk.isEmpty else { continue }
                        let chunkStart = cursor
                        let chunkEnd = cursor + Int64(chunk.count) - 1
                        cursor += Int64(chunk.count)
                        if chunkEnd < reqStart { continue }
                        let overlapStart = max(chunkStart, reqStart)
                        let overlapEnd = min(chunkEnd, clampedEnd)
                        if overlapStart <= overlapEnd {
                            let localStart = Int(overlapStart - chunkStart)
                            let localEnd = Int(overlapEnd - chunkStart) + 1
                            let outSlice = (localStart == 0 && localEnd == chunk.count)
                                ? chunk
                                : chunk.subdata(in: localStart..<localEnd)
                            try await Self.sendPacket(connection: connection, data: outSlice)
                            bytesSent += Int64(outSlice.count)
                        }
                        if cursor > clampedEnd {
                            bodyStream.cancel()
                            break
                        }
                    }
                    if bytesSent < contentLen {
                        connection.cancel()
                        await self.memoryBudget.release(bytes: bufferReservation)
                        await coordinator.clearNonRangeSession(sessionId: sessionId)
                        return
                    }
                } else {
                    var respHeaders: [String: String] = [
                        "Accept-Ranges": "none",
                        "Content-Type": contentType,
                        "Cache-Control": "no-store",
                    ]
                    if upstreamTotal >= 0 { respHeaders["Content-Length"] = "\(upstreamTotal)" }
                    headersSent = true
                    try await Self.sendPacket(connection: connection, data: Data(Self.formatHttpHeaderBlock(status: 200, headers: respHeaders).utf8))

                    var bytesSent: Int64 = 0
                    while let chunk = try await bodyStream.nextChunk() {
                        try Task.checkCancellation()
                        guard !chunk.isEmpty else { continue }
                        try await Self.sendPacket(connection: connection, data: chunk)
                        bytesSent += Int64(chunk.count)
                    }
                    if upstreamTotal > 0 && bytesSent < upstreamTotal {
                        connection.cancel()
                        await self.memoryBudget.release(bytes: bufferReservation)
                        await coordinator.clearNonRangeSession(sessionId: sessionId)
                        return
                    }
                }
                connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            } catch is CancellationError {
                connection.cancel()
            } catch {
                if headersSent {
                    connection.cancel()
                } else {
                    self.sendSimpleResponse(
                        connection: connection,
                        status: 502,
                        headers: ["Content-Type": "text/plain; charset=utf-8"],
                        body: Data("Upstream Stream Error".utf8)
                    )
                }
            }
            await self.memoryBudget.release(bytes: bufferReservation)
            await coordinator.clearNonRangeSession(sessionId: sessionId)
        }

        await coordinator.registerNonRangeSession(sessionId: sessionId, task: streamTask)
        await withTaskCancellationHandler {
            await streamTask.value
        } onCancel: {
            streamTask.cancel()
        }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private static func formatHttpHeaderBlock(status: Int, headers: [String: String]) -> String {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 206: reason = "Partial Content"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 413: reason = "Payload Too Large"
        case 416: reason = "Range Not Satisfiable"
        case 502: reason = "Bad Gateway"
        default: reason = "Response"
        }
        var lines = ["HTTP/1.1 \(status) \(reason)", "Connection: close"]
        for (k, v) in headers { lines.append("\(k): \(v)") }
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    private func sendSimpleResponse(
        connection: NWConnection,
        status: Int,
        headers: [String: String],
        body: Data
    ) {
        var merged = headers
        if merged.keys.allSatisfy({ $0.lowercased() != "content-length" }) {
            merged["Content-Length"] = "\(body.count)"
        }
        var packet = Data(Self.formatHttpHeaderBlock(status: status, headers: merged).utf8)
        packet.append(body)
        connection.send(content: packet, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func closeConnectionAfterBody(_ connection: NWConnection) {
        connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func sendPacket(connection: NWConnection, data: Data) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error = error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: ()) }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
