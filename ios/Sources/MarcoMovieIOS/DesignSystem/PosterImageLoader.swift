// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Privacy-Isolated Async Poster Image Loader & Studio Placeholder Generator

import CryptoKit
import ImageIO
import UIKit

/// Cancellation handle returned by `PosterImageLoader.loadImage(...)`.
public final class PosterImageLoadToken {
    private let lock = NSLock()
    private var cancelAction: (() -> Void)?
    private var isCancelledFlag = false

    init(cancelAction: @escaping () -> Void) {
        self.cancelAction = cancelAction
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelledFlag
    }

    public func cancel() {
        let action: (() -> Void)?
        lock.lock()
        if isCancelledFlag {
            action = nil
        } else {
            isCancelledFlag = true
            action = cancelAction
            cancelAction = nil
        }
        lock.unlock()
        action?()
    }
}

/// Thread-safe iOS 14–26 poster image loader featuring:
/// - Two-tier standard cache (memory `NSCache` + `<Caches>/marco_ios_poster_cache/` disk cache)
/// - Strict Privacy Space isolation (`isPrivate == true` never touches disk and purges instantly on demand)
/// - Request deduplication, token-based cancellation, and custom HTTP headers
/// - Dominant color caching for smooth `AmbientGlowView` transitions
/// - Built-in procedural studio poster generator (zero broken gray boxes)
public final class PosterImageLoader {
    public static let shared = PosterImageLoader()

    private static let diskDirectoryName = "marco_ios_poster_cache"
    private static let maxDiskCacheBytes: Int64 = 160 * 1024 * 1024
    private static let maxDiskAgeSeconds: TimeInterval = 14 * 24 * 3600

    private final class InFlightRequest {
        let isPrivate: Bool
        var task: URLSessionDataTask?
        var waiters: [(UUID, (UIImage?) -> Void)] = []

        init(isPrivate: Bool) {
            self.isPrivate = isPrivate
        }
    }

    private let stateQueue = DispatchQueue(label: "com.pilipala.marcomovie.ios.poster-loader.state")
    private let diskQueue = DispatchQueue(label: "com.pilipala.marcomovie.ios.poster-loader.disk", qos: .utility)

    private let standardMemoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 320
        cache.totalCostLimit = 80 * 1024 * 1024
        return cache
    }()

    private let privateMemoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    private let standardColorCache: NSCache<NSString, UIColor> = {
        let cache = NSCache<NSString, UIColor>()
        cache.countLimit = 320
        return cache
    }()

    private let privateColorCache: NSCache<NSString, UIColor> = {
        let cache = NSCache<NSString, UIColor>()
        cache.countLimit = 120
        return cache
    }()

    private static let placeholderCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 96
        return cache
    }()

    private var inFlight: [String: InFlightRequest] = [:]
    private let standardSession: URLSession
    private let privateSession: URLSession
    private let diskCacheURL: URL?

    private init() {
        let stdConfig = URLSessionConfiguration.default
        stdConfig.timeoutIntervalForRequest = 15
        stdConfig.timeoutIntervalForResource = 25
        stdConfig.httpMaximumConnectionsPerHost = 8
        stdConfig.urlCache = nil
        self.standardSession = URLSession(configuration: stdConfig)

        let privConfig = URLSessionConfiguration.ephemeral
        privConfig.timeoutIntervalForRequest = 15
        privConfig.timeoutIntervalForResource = 25
        privConfig.httpMaximumConnectionsPerHost = 6
        privConfig.urlCache = nil
        privConfig.httpCookieStorage = nil
        privConfig.httpShouldSetCookies = false
        self.privateSession = URLSession(configuration: privConfig)

        if let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = cachesDir.appendingPathComponent(Self.diskDirectoryName, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.diskCacheURL = dir
        } else {
            self.diskCacheURL = nil
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )

        diskQueue.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            self?.pruneDiskCacheIfNeeded()
        }
    }

    @objc private func handleMemoryWarning() {
        standardMemoryCache.removeAllObjects()
        privateMemoryCache.removeAllObjects()
    }

    // MARK: - Public Loading APIs

    /// Loads an image asynchronously with deduplication, custom headers, and privacy isolation.
    /// `completion` is always invoked on the main queue.
    @discardableResult
    public func loadImage(
        urlString: String?,
        headers: [String: String] = [:],
        isPrivate: Bool = false,
        completion: @escaping (UIImage?) -> Void
    ) -> PosterImageLoadToken? {
        guard let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            DispatchQueue.main.async { completion(nil) }
            return nil
        }

        let cacheKey = Self.cacheKey(urlString: trimmed, headers: headers, isPrivate: isPrivate)
        let nsKey = cacheKey as NSString
        let targetMemoryCache = isPrivate ? privateMemoryCache : standardMemoryCache

        if let cached = targetMemoryCache.object(forKey: nsKey) {
            DispatchQueue.main.async { completion(cached) }
            return nil
        }

        let waiterID = UUID()
        var shouldStartNetwork = false

        stateQueue.sync {
            if let existing = inFlight[cacheKey] {
                existing.waiters.append((waiterID, completion))
            } else {
                let entry = InFlightRequest(isPrivate: isPrivate)
                entry.waiters.append((waiterID, completion))
                inFlight[cacheKey] = entry
                shouldStartNetwork = true
            }
        }

        if shouldStartNetwork {
            if isPrivate {
                startNetworkFetch(url: url, headers: headers, cacheKey: cacheKey, isPrivate: true)
            } else {
                diskQueue.async { [weak self] in
                    guard let self = self else { return }
                    if let diskImage = self.readFromDisk(cacheKey: cacheKey) {
                        self.standardMemoryCache.setObject(
                            diskImage,
                            forKey: nsKey,
                            cost: Self.imageMemoryCost(diskImage)
                        )
                        self.completeInFlight(cacheKey: cacheKey, image: diskImage)
                    } else {
                        self.startNetworkFetch(url: url, headers: headers, cacheKey: cacheKey, isPrivate: false)
                    }
                }
            }
        }

        return PosterImageLoadToken { [weak self] in
            self?.cancelWaiter(cacheKey: cacheKey, waiterID: waiterID)
        }
    }

    /// Returns a cached dominant color for a URL if already computed.
    public func cachedDominantColor(
        for urlString: String?,
        headers: [String: String] = [:],
        isPrivate: Bool = false
    ) -> UIColor? {
        guard let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let key = Self.cacheKey(urlString: trimmed, headers: headers, isPrivate: isPrivate) as NSString
        return (isPrivate ? privateColorCache : standardColorCache).object(forKey: key)
    }

    /// Computes (or retrieves cached) dominant color for an image off the main thread.
    public func dominantColor(
        for image: UIImage,
        urlString: String? = nil,
        headers: [String: String] = [:],
        isPrivate: Bool = false,
        completion: @escaping (UIColor?) -> Void
    ) {
        let nsKey: NSString? = urlString
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : Self.cacheKey(urlString: $0, headers: headers, isPrivate: isPrivate) as NSString }
        let cache = isPrivate ? privateColorCache : standardColorCache

        if let key = nsKey, let cached = cache.object(forKey: key) {
            DispatchQueue.main.async { completion(cached) }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let color = MarcoDominantColorExtractor.extractDominantColor(from: image)
            if let key = nsKey, let color = color {
                cache.setObject(color, forKey: key)
            }
            DispatchQueue.main.async {
                completion(color)
            }
        }
    }

    /// Immediately wipes all Privacy Space in-memory poster images, dominant colors, and in-flight requests.
    /// Safe to invoke whenever exiting Privacy Space or entering background.
    public func purgePrivateMemoryCache() {
        privateMemoryCache.removeAllObjects()
        privateColorCache.removeAllObjects()
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            let privateKeys = self.inFlight.compactMap { $0.value.isPrivate ? $0.key : nil }
            for key in privateKeys {
                if let entry = self.inFlight.removeValue(forKey: key) {
                    entry.task?.cancel()
                    let waiters = entry.waiters
                    DispatchQueue.main.async {
                        for (_, cb) in waiters { cb(nil) }
                    }
                }
            }
        }
    }

    /// Clears both memory and disk poster caches.
    public func clearAllCaches(completion: (() -> Void)? = nil) {
        standardMemoryCache.removeAllObjects()
        standardColorCache.removeAllObjects()
        Self.placeholderCache.removeAllObjects()
        purgePrivateMemoryCache()

        diskQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion?() }
                return
            }
            if let dir = self.diskCacheURL {
                let fm = FileManager.default
                if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    for file in contents {
                        try? fm.removeItem(at: file)
                    }
                }
            }
            DispatchQueue.main.async { completion?() }
        }
    }

    /// Computes total bytes currently occupied by the disk poster cache.
    public func diskCacheByteCount(completion: @escaping (Int64) -> Void) {
        diskQueue.async { [weak self] in
            var total: Int64 = 0
            if let dir = self?.diskCacheURL,
               let files = try? FileManager.default.contentsOfDirectory(
                   at: dir,
                   includingPropertiesForKeys: [.fileSizeKey],
                   options: .skipsHiddenFiles
               ) {
                for file in files {
                    if let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
                       let size = values.fileSize {
                        total += Int64(size)
                    }
                }
            }
            DispatchQueue.main.async { completion(total) }
        }
    }

    // MARK: - Networking & Disk Internals

    private func startNetworkFetch(
        url: URL,
        headers: [String: String],
        cacheKey: String,
        isPrivate: Bool
    ) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        var hasUserAgent = false
        for (k, v) in headers {
            if k.lowercased() == "user-agent" { hasUserAgent = true }
            request.setValue(v, forHTTPHeaderField: k)
        }
        if !hasUserAgent {
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )
        }

        let session = isPrivate ? privateSession : standardSession
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            guard error == nil,
                  let data = data,
                  !data.isEmpty,
                  data.count <= 16 * 1024 * 1024 else {
                self.completeInFlight(cacheKey: cacheKey, image: nil)
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                self.completeInFlight(cacheKey: cacheKey, image: nil)
                return
            }
            guard let decoded = Self.decodeDownsampledImage(from: data, maxPixelDimension: 1280) else {
                self.completeInFlight(cacheKey: cacheKey, image: nil)
                return
            }

            let nsKey = cacheKey as NSString
            let cost = Self.imageMemoryCost(decoded)
            if isPrivate {
                self.privateMemoryCache.setObject(decoded, forKey: nsKey, cost: cost)
            } else {
                self.standardMemoryCache.setObject(decoded, forKey: nsKey, cost: cost)
                self.diskQueue.async { [weak self] in
                    self?.writeToDisk(data: data, cacheKey: cacheKey)
                }
            }

            self.completeInFlight(cacheKey: cacheKey, image: decoded)
        }

        var shouldResume = false
        stateQueue.sync {
            if let entry = inFlight[cacheKey] {
                entry.task = task
                shouldResume = true
            }
        }
        if shouldResume {
            task.resume()
        } else {
            task.cancel()
        }
    }

    private func cancelWaiter(cacheKey: String, waiterID: UUID) {
        stateQueue.async { [weak self] in
            guard let self = self, let entry = self.inFlight[cacheKey] else { return }
            entry.waiters.removeAll { $0.0 == waiterID }
            if entry.waiters.isEmpty {
                entry.task?.cancel()
                self.inFlight.removeValue(forKey: cacheKey)
            }
        }
    }

    private func completeInFlight(cacheKey: String, image: UIImage?) {
        var callbacks: [(UIImage?) -> Void] = []
        stateQueue.sync {
            if let entry = inFlight.removeValue(forKey: cacheKey) {
                callbacks = entry.waiters.map { $0.1 }
            }
        }
        guard !callbacks.isEmpty else { return }
        DispatchQueue.main.async {
            for cb in callbacks {
                cb(image)
            }
        }
    }

    private static func cacheKey(urlString: String, headers: [String: String], isPrivate: Bool) -> String {
        let prefix = isPrivate ? "priv|" : "std|"
        if headers.isEmpty {
            return prefix + urlString
        }
        let sortedHeaders = headers
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { "\($0.key.lowercased())=\($0.value)" }
            .joined(separator: "&")
        return "\(prefix)\(urlString)|\(sortedHeaders)"
    }

    private static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func diskFileURL(for cacheKey: String) -> URL? {
        diskCacheURL?.appendingPathComponent(Self.sha256Hex(cacheKey) + ".img")
    }

    private func readFromDisk(cacheKey: String) -> UIImage? {
        guard let fileURL = diskFileURL(for: cacheKey),
              let data = try? Data(contentsOf: fileURL),
              !data.isEmpty else {
            return nil
        }
        // Touch modification date for LRU-style retention.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        return Self.decodeDownsampledImage(from: data, maxPixelDimension: 1280)
    }

    private func writeToDisk(data: Data, cacheKey: String) {
        guard let fileURL = diskFileURL(for: cacheKey) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    private func pruneDiskCacheIfNeeded() {
        guard let dir = diskCacheURL else { return }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: .skipsHiddenFiles
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-Self.maxDiskAgeSeconds)
        var entries: [(url: URL, size: Int64, modDate: Date)] = []
        var totalSize: Int64 = 0

        for file in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            let size = Int64(values?.fileSize ?? 0)
            let modDate = values?.contentModificationDate ?? Date.distantPast
            if modDate < cutoff {
                try? fm.removeItem(at: file)
            } else {
                entries.append((file, size, modDate))
                totalSize += size
            }
        }

        if totalSize > Self.maxDiskCacheBytes {
            entries.sort { $0.modDate < $1.modDate }
            for entry in entries where totalSize > Self.maxDiskCacheBytes {
                try? fm.removeItem(at: entry.url)
                totalSize -= entry.size
            }
        }
    }

    private static func imageMemoryCost(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else {
            return Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        }
        return cg.bytesPerRow * cg.height
    }

    private static func decodeDownsampledImage(from data: Data, maxPixelDimension: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
        ]
        if let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) {
            return UIImage(cgImage: cgThumb)
        }
        return UIImage(data: data)
    }

    // MARK: - Procedural Studio Poster Generator

    private struct StudioPalette {
        let top: UIColor
        let bottom: UIColor
        let glow: UIColor
        let accent: UIColor
    }

    private static let studioPalettes: [StudioPalette] = [
        // Midnight Slate
        StudioPalette(
            top: UIColor(red: 0.12, green: 0.16, blue: 0.24, alpha: 1.0),
            bottom: UIColor(red: 0.05, green: 0.06, blue: 0.10, alpha: 1.0),
            glow: UIColor(red: 0.34, green: 0.48, blue: 0.72, alpha: 0.42),
            accent: UIColor(red: 0.78, green: 0.85, blue: 0.96, alpha: 0.65)
        ),
        // Warm Amber Noir
        StudioPalette(
            top: UIColor(red: 0.24, green: 0.16, blue: 0.11, alpha: 1.0),
            bottom: UIColor(red: 0.07, green: 0.05, blue: 0.05, alpha: 1.0),
            glow: UIColor(red: 0.78, green: 0.50, blue: 0.25, alpha: 0.38),
            accent: UIColor(red: 0.95, green: 0.82, blue: 0.64, alpha: 0.68)
        ),
        // Deep Moss Cinema
        StudioPalette(
            top: UIColor(red: 0.11, green: 0.20, blue: 0.18, alpha: 1.0),
            bottom: UIColor(red: 0.05, green: 0.08, blue: 0.08, alpha: 1.0),
            glow: UIColor(red: 0.26, green: 0.56, blue: 0.48, alpha: 0.36),
            accent: UIColor(red: 0.74, green: 0.90, blue: 0.85, alpha: 0.65)
        ),
        // Velvet Burgundy
        StudioPalette(
            top: UIColor(red: 0.25, green: 0.11, blue: 0.15, alpha: 1.0),
            bottom: UIColor(red: 0.08, green: 0.04, blue: 0.06, alpha: 1.0),
            glow: UIColor(red: 0.66, green: 0.28, blue: 0.38, alpha: 0.38),
            accent: UIColor(red: 0.94, green: 0.76, blue: 0.80, alpha: 0.65)
        ),
        // Nordic Steel
        StudioPalette(
            top: UIColor(red: 0.14, green: 0.19, blue: 0.23, alpha: 1.0),
            bottom: UIColor(red: 0.06, green: 0.08, blue: 0.11, alpha: 1.0),
            glow: UIColor(red: 0.38, green: 0.56, blue: 0.64, alpha: 0.36),
            accent: UIColor(red: 0.80, green: 0.89, blue: 0.93, alpha: 0.65)
        ),
        // Obsidian Plum
        StudioPalette(
            top: UIColor(red: 0.19, green: 0.13, blue: 0.24, alpha: 1.0),
            bottom: UIColor(red: 0.07, green: 0.05, blue: 0.10, alpha: 1.0),
            glow: UIColor(red: 0.52, green: 0.38, blue: 0.68, alpha: 0.38),
            accent: UIColor(red: 0.86, green: 0.78, blue: 0.95, alpha: 0.65)
        ),
        // Sand Dune Dusk
        StudioPalette(
            top: UIColor(red: 0.23, green: 0.19, blue: 0.15, alpha: 1.0),
            bottom: UIColor(red: 0.09, green: 0.07, blue: 0.06, alpha: 1.0),
            glow: UIColor(red: 0.68, green: 0.56, blue: 0.40, alpha: 0.36),
            accent: UIColor(red: 0.93, green: 0.87, blue: 0.76, alpha: 0.65)
        ),
        // Graphite Noir
        StudioPalette(
            top: UIColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1.0),
            bottom: UIColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1.0),
            glow: UIColor(red: 0.45, green: 0.48, blue: 0.56, alpha: 0.34),
            accent: UIColor(red: 0.84, green: 0.86, blue: 0.90, alpha: 0.65)
        ),
    ]

    /// Generates an editorial studio-grade poster image for empty/demo/fallback states (never a flat gray box).
    /// Pass `includeText: false` when UIKit overlays or labels already display title/rating chrome over the artwork.
    public static func makeStudioPlaceholder(
        title: String,
        subtitle: String? = nil,
        seed: String? = nil,
        aspectRatio: CGFloat = 2.0 / 3.0,
        size: CGSize? = nil,
        includeText: Bool = true
    ) -> UIImage {
        let clampedRatio = min(max(aspectRatio, 0.5), 2.4)
        let targetSize: CGSize
        if let explicit = size {
            targetSize = explicit
        } else if clampedRatio >= 1.1 {
            targetSize = CGSize(width: 480, height: round(480 / clampedRatio))
        } else {
            targetSize = CGSize(width: 300, height: round(300 / clampedRatio))
        }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = cleanTitle.isEmpty ? "Marco Cinema" : cleanTitle
        let cleanSubtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let paletteSeed = (seed?.isEmpty == false ? seed! : displayTitle)

        let cacheKey = "\(displayTitle)|\(cleanSubtitle ?? "")|\(paletteSeed)|\(Int(targetSize.width))x\(Int(targetSize.height))|\(includeText ? 1 : 0)" as NSString
        if let cached = placeholderCache.object(forKey: cacheKey) {
            return cached
        }

        var hash: UInt64 = 14695981039346656037
        for byte in paletteSeed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        let palette = studioPalettes[Int(hash % UInt64(studioPalettes.count))]

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2.0
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let rect = CGRect(origin: .zero, size: targetSize)
            let space = CGColorSpaceCreateDeviceRGB()

            // Base vertical cinema gradient.
            if let gradient = CGGradient(
                colorsSpace: space,
                colors: [palette.top.cgColor, palette.bottom.cgColor] as CFArray,
                locations: [0.0, 1.0]
            ) {
                cg.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: rect.midX, y: 0),
                    end: CGPoint(x: rect.midX, y: rect.height),
                    options: []
                )
            }

            // Soft upper editorial spotlight radial bloom.
            let glowCenter = CGPoint(x: rect.width * 0.28, y: rect.height * 0.24)
            let glowRadius = max(rect.width, rect.height) * 0.85
            if let radial = CGGradient(
                colorsSpace: space,
                colors: [palette.glow.cgColor, UIColor.clear.cgColor] as CFArray,
                locations: [0.0, 1.0]
            ) {
                cg.drawRadialGradient(
                    radial,
                    startCenter: glowCenter,
                    startRadius: 0,
                    endCenter: glowCenter,
                    endRadius: glowRadius,
                    options: [.drawsAfterEndLocation]
                )
            }

            // Subtle lower-right companion ambient glow & light vignette depth.
            let secondaryCenter = CGPoint(x: rect.width * 0.82, y: rect.height * 0.78)
            let secondaryRadius = max(rect.width, rect.height) * 0.72
            if let secondaryRadial = CGGradient(
                colorsSpace: space,
                colors: [palette.accent.withAlphaComponent(0.16).cgColor, UIColor.clear.cgColor] as CFArray,
                locations: [0.0, 1.0]
            ) {
                cg.drawRadialGradient(
                    secondaryRadial,
                    startCenter: secondaryCenter,
                    startRadius: 0,
                    endCenter: secondaryCenter,
                    endRadius: secondaryRadius,
                    options: [.drawsAfterEndLocation]
                )
            }

            // Gentle edge vignette for true cinema depth.
            let vignetteCenter = CGPoint(x: rect.midX, y: rect.midY)
            if let vignette = CGGradient(
                colorsSpace: space,
                colors: [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.32).cgColor] as CFArray,
                locations: [0.55, 1.0]
            ) {
                cg.drawRadialGradient(
                    vignette,
                    startCenter: vignetteCenter,
                    startRadius: min(rect.width, rect.height) * 0.2,
                    endCenter: vignetteCenter,
                    endRadius: hypot(rect.width, rect.height) * 0.56,
                    options: [.drawsAfterEndLocation]
                )
            }

            // Subtle geometric cinema aperture ring.
            let ringInset = min(rect.width, rect.height) * 0.08
            let frameRect = rect.insetBy(dx: ringInset, dy: ringInset)
            let framePath = UIBezierPath(roundedRect: frameRect, cornerRadius: 8)
            palette.accent.withAlphaComponent(includeText ? 0.18 : 0.14).setStroke()
            framePath.lineWidth = 0.75
            framePath.stroke()

            let firstChar = String(displayTitle.prefix(1)).uppercased()
            if !includeText {
                // Tasteful large faded geometric watermark monogram centered cleanly with zero bottom text clash.
                let watermarkSize = min(rect.width, rect.height) * 0.44
                let monogramAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: watermarkSize, weight: .bold),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.085),
                ]
                let monoSize = (firstChar as NSString).size(withAttributes: monogramAttrs)
                let ringRadius = min(rect.width, rect.height) * 0.24
                let circleRect = CGRect(
                    x: rect.midX - ringRadius,
                    y: rect.midY - ringRadius,
                    width: ringRadius * 2,
                    height: ringRadius * 2
                )
                let circlePath = UIBezierPath(ovalIn: circleRect)
                palette.accent.withAlphaComponent(0.11).setStroke()
                circlePath.lineWidth = 1.0
                circlePath.stroke()

                (firstChar as NSString).draw(
                    at: CGPoint(
                        x: rect.midX - monoSize.width * 0.5,
                        y: rect.midY - monoSize.height * 0.5
                    ),
                    withAttributes: monogramAttrs
                )
                return
            }

            // Monogram watermark in upper right (when editorial text is enabled).
            let monogramAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: min(rect.width, rect.height) * 0.42, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.06),
            ]
            let monoSize = (firstChar as NSString).size(withAttributes: monogramAttrs)
            (firstChar as NSString).draw(
                at: CGPoint(x: rect.width - monoSize.width - ringInset * 0.9, y: ringInset * 0.4),
                withAttributes: monogramAttrs
            )

            // Editorial lower-third title & subtitle block.
            let horizontalPad = rect.width * 0.11
            let textWidth = rect.width - horizontalPad * 2
            let isLandscape = rect.width > rect.height

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            paragraph.lineSpacing = 3

            let titleFontSize: CGFloat = isLandscape ? 24 : 22
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: titleFontSize, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.95),
                .paragraphStyle: paragraph,
            ]
            let titleBounds = (displayTitle as NSString).boundingRect(
                with: CGSize(width: textWidth, height: titleFontSize * 2.8),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: titleAttrs,
                context: nil
            )

            var subtitleHeight: CGFloat = 0
            let subtitleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: palette.accent.withAlphaComponent(0.88),
                .paragraphStyle: paragraph,
            ]
            if let sub = cleanSubtitle, !sub.isEmpty {
                let subRect = (sub as NSString).boundingRect(
                    with: CGSize(width: textWidth, height: 22),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: subtitleAttrs,
                    context: nil
                )
                subtitleHeight = ceil(subRect.height) + 6
            }

            let bottomMargin = rect.height * 0.12
            let titleY = rect.height - bottomMargin - subtitleHeight - ceil(titleBounds.height)

            // Delicate horizontal accent bar above title.
            let barRect = CGRect(x: horizontalPad, y: titleY - 12, width: 28, height: 2.5)
            palette.accent.withAlphaComponent(0.75).setFill()
            UIBezierPath(roundedRect: barRect, cornerRadius: 1.25).fill()

            (displayTitle as NSString).draw(
                with: CGRect(x: horizontalPad, y: titleY, width: textWidth, height: ceil(titleBounds.height) + 4),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: titleAttrs,
                context: nil
            )

            if let sub = cleanSubtitle, !sub.isEmpty {
                (sub as NSString).draw(
                    with: CGRect(
                        x: horizontalPad,
                        y: titleY + ceil(titleBounds.height) + 6,
                        width: textWidth,
                        height: 22
                    ),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: subtitleAttrs,
                    context: nil
                )
            }
        }

        placeholderCache.setObject(image, forKey: cacheKey)
        return image
    }
}
