// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation

private final class MarcoDataTaskCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func attachAndResume(_ dataTask: URLSessionDataTask) {
        lock.lock()
        let shouldCancel = cancelled
        task = dataTask
        lock.unlock()
        if shouldCancel {
            dataTask.cancel()
        } else {
            dataTask.resume()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let active = task
        lock.unlock()
        active?.cancel()
    }

    func wasCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

extension URLSession {
    /// iOS 14.0+ & macOS 13.0+ async/await replacement for URLSession async request tasks.
    /// Propagates structured Swift Task cancellation directly to the underlying `URLSessionDataTask`.
    public func marcoData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let box = MarcoDataTaskCancellationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let dataTask = self.dataTask(with: request) { data, response, error in
                    if let error = error {
                        let nsError = error as NSError
                        if box.wasCancelled()
                            || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
                        {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: error)
                        }
                        return
                    }
                    guard let response = response else {
                        continuation.resume(
                            throwing: URLError(.badServerResponse)
                        )
                        return
                    }
                    continuation.resume(returning: (data ?? Data(), response))
                }
                box.attachAndResume(dataTask)
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// iOS 14.0+ & macOS 13.0+ async/await replacement for URLSession async URL fetch tasks.
    public func marcoData(from url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try await marcoData(for: request)
    }
}

/// Thread-safe one-shot claim flag for `@Sendable` callback-to-continuation bridges.
public final class MarcoOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    public init() {}

    public func tryClaim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Compile-time native runtime capabilities for Marco Movie iOS builds.
public enum MarcoBuildCapabilities {
    #if MARCO_HAS_CPYTHON
    public static let hasCPython: Bool = true
    #else
    public static let hasCPython: Bool = false
    #endif

    #if MARCO_HAS_CATPAW
    public static let hasCatpaw: Bool = true
    #else
    public static let hasCatpaw: Bool = false
    #endif

    #if MARCO_HAS_MPV
    public static let hasMpv: Bool = true
    #else
    public static let hasMpv: Bool = false
    #endif

    public static let hasQuickJS: Bool = true
}
