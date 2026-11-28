// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Hosted iOS / iPadOS Simulator UI, Runtime & HD Screenshot Verification Suite

import Foundation
import XCTest
@testable import MarcoIOSCore

#if os(iOS)
import UIKit
@testable import MarcoMovieIOS

// MARK: - Orientation & Trait Override Host Container

private final class SimHostContainerViewController: UIViewController {
    let coordinator: RootNavigationCoordinator
    let targetOrientations: UIInterfaceOrientationMask
    let overrideTraits: UITraitCollection

    init(
        coordinator: RootNavigationCoordinator,
        targetOrientations: UIInterfaceOrientationMask,
        overrideTraits: UITraitCollection
    ) {
        self.coordinator = coordinator
        self.targetOrientations = targetOrientations
        self.overrideTraits = overrideTraits
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        targetOrientations
    }

    override var shouldAutorotate: Bool {
        true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MarcoColors.canvasBackground
        addChild(coordinator)
        setOverrideTraitCollection(overrideTraits, forChild: coordinator)
        coordinator.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(coordinator.view)
        NSLayoutConstraint.activate([
            coordinator.view.topAnchor.constraint(equalTo: view.topAnchor),
            coordinator.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            coordinator.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            coordinator.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        coordinator.didMove(toParent: self)
    }
}

// MARK: - Hosted iOS / iPadOS Simulator Verification Suite

@MainActor
final class IOSSimulatorVerificationTests: XCTestCase {
    // MARK: - Helpers

    private func settle(seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private func activeWindowScene() throws -> UIWindowScene {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else {
            throw NSError(
                domain: "IOSSimulatorVerificationTests",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "No active UIWindowScene in iOS Simulator"]
            )
        }
        return scene
    }

    private func activeSimulatorWindow(in scene: UIWindowScene) -> UIWindow {
        if let existing = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
            existing.makeKeyAndVisible()
            return existing
        }
        let created = UIWindow(windowScene: scene)
        created.makeKeyAndVisible()
        return created
    }

    private func findDescendant<T: UIViewController>(
        ofType type: T.Type,
        in root: UIViewController
    ) -> T? {
        if let matched = root as? T {
            return matched
        }
        if let presented = root.presentedViewController,
           let found = findDescendant(ofType: type, in: presented)
        {
            return found
        }
        for child in root.children {
            if let found = findDescendant(ofType: type, in: child) {
                return found
            }
        }
        return nil
    }

    private func findSubview<T: UIView>(ofType type: T.Type, in root: UIView) -> T? {
        if let matched = root as? T {
            return matched
        }
        for subview in root.subviews {
            if let found = findSubview(ofType: type, in: subview) {
                return found
            }
        }
        return nil
    }

    private func countNonBlackPixels(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let width = 128
        let height = 128
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return 0
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = 0
        for idx in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[idx] > 18 || pixels[idx + 1] > 18 || pixels[idx + 2] > 18 {
                count += 1
            }
        }
        return count
    }

    @discardableResult
    private func captureWindow(
        _ window: UIWindow,
        filename: String,
        settleSeconds: Double = 0.75
    ) async throws -> UIImage {
        window.setNeedsLayout()
        window.layoutIfNeeded()
        await settle(seconds: settleSeconds)
        window.setNeedsLayout()
        window.layoutIfNeeded()

        let renderSize = window.bounds.size
        XCTAssertGreaterThan(renderSize.width, 200, "Window width unexpectedly tiny for \(filename)")
        XCTAssertGreaterThan(renderSize.height, 200, "Window height unexpectedly tiny for \(filename)")

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = min(max(window.screen.scale, 1.0), 2.0)
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }

        let pngData = try XCTUnwrap(image.pngData(), "Failed to encode iOS Simulator screenshot \(filename)")
        XCTAssertGreaterThan(
            pngData.count,
            8_000,
            "Screenshot \(filename) unexpectedly small/blank (\(pngData.count) bytes)"
        )
        let nonBlack = countNonBlackPixels(image)
        XCTAssertGreaterThan(
            nonBlack,
            100,
            "Screenshot \(filename) appears blank/black (nonBlackPixels=\(nonBlack))"
        )

        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let shotDir = cachesDir.appendingPathComponent("sim-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
        try pngData.write(to: shotDir.appendingPathComponent(filename), options: .atomic)

        let attachment = XCTAttachment(image: image)
        attachment.name = filename
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    private func popAllNavigationStacks(under root: UIViewController) {
        if let nav = root as? UINavigationController {
            nav.popToRootViewController(animated: false)
        }
        for child in root.children {
            popAllNavigationStacks(under: child)
        }
    }

    // MARK: - Sim Test 1: Real iOS App Bundle, Assets.car, QuickJS-NG & Keychain

    func testSim01_BundleAssetsQuickJSAndKeychainOnIOS() throws {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.pilipala.marcoMovie")

        let resourceRoot = try XCTUnwrap(Bundle.main.resourceURL, "MarcoMovieIOS.app resourceURL missing")

        let jsHostDir = resourceRoot.appendingPathComponent("js-host", isDirectory: true)
        for required in [
            "bootstrap.js",
            "catvod.mjs",
            "crypto-js.js",
            "crypto.LICENSE",
            "drpy-core.js",
            "module-interop.js",
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: jsHostDir.appendingPathComponent(required).path),
                "Missing bundled js-host/\(required) inside MarcoMovieIOS.app on iOS Simulator"
            )
        }

        let catpawDir = resourceRoot.appendingPathComponent("catpaw", isDirectory: true)
        for required in ["drpy-assets.json", "host.cjs", "fetch.cjs"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: catpawDir.appendingPathComponent(required).path),
                "Missing bundled catpaw/\(required) inside MarcoMovieIOS.app on iOS Simulator"
            )
        }

        let shaderManifest = resourceRoot
            .appendingPathComponent("shaders", isDirectory: true)
            .appendingPathComponent("anime4k", isDirectory: true)
            .appendingPathComponent("manifest.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: shaderManifest.path),
            "Missing bundled shaders/anime4k/manifest.json inside MarcoMovieIOS.app"
        )

        let brandLogo = UIImage(named: "BrandLogoMark")
        XCTAssertNotNil(brandLogo, "BrandLogoMark missing from compiled Assets.car")
        if let logo = brandLogo {
            XCTAssertGreaterThan(logo.size.width, 0)
            XCTAssertGreaterThan(logo.size.height, 0)
        }

        // Live QuickJS-NG evaluation on iOS Simulator
        let bridge = try QuickJSBridge()
        defer { bridge.close() }
        let arithmetic = try bridge.evaluate("String(21 * 2)")
        XCTAssertEqual(arithmetic, "42")
        let encoded = try bridge.evaluate("JSON.stringify({ ok: true, engine: 'quickjs-ng', platform: 'ios' })")
        XCTAssertTrue(encoded.contains("quickjs-ng"), "Unexpected QuickJS JSON output: \(encoded)")

        // SystemKeychainStore write / read / delete roundtrip on iOS Simulator
        let keychain = SystemKeychainStore(service: "com.pilipala.marcoMovie.simverify")
        let account = "sim_verify_\(UUID().uuidString)"
        let secretPayload = Data("marco-ios-keychain-roundtrip-\(UUID().uuidString)".utf8)
        defer { try? keychain.removeData(forAccount: account) }

        try keychain.setData(secretPayload, forAccount: account)
        let fetched = try keychain.data(forAccount: account)
        XCTAssertEqual(fetched, secretPayload, "SystemKeychainStore readback mismatch")

        try keychain.removeData(forAccount: account)
        let afterDelete = try keychain.data(forAccount: account)
        XCTAssertNil(afterDelete, "SystemKeychainStore entry must be nil after deletion")
    }

    // MARK: - Sim Test 2: Full Walkthrough & HD Screenshot Capture (iPhone + iPad Portrait + iPad Landscape)

    func testSim02_WalkthroughAndCaptureAllKeyScreens() async throws {
        let env = ProcessInfo.processInfo.environment
        let rawPrefix = (env["MARCO_SIM_CAPTURE_PREFIX"] ?? "sim").trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = rawPrefix.isEmpty ? "sim" : rawPrefix
        let orientationRaw = (env["MARCO_SIM_ORIENTATION"] ?? "portrait")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let wantLandscape = isPad && orientationRaw == "landscape"

        let scene = try activeWindowScene()
        let window = activeSimulatorWindow(in: scene)

        let prevDemoMode = AppStateStore.shared.isSimulatorDemoMode
        let prevRoot = window.rootViewController
        let prevFrame = window.frame
        defer {
            AppStateStore.shared.isSimulatorDemoMode = prevDemoMode
            AppStateStore.shared.reloadConfig()
            window.rootViewController = prevRoot
            window.frame = prevFrame
        }

        // Enable deterministic offline studio demo fixtures
        AppStateStore.shared.isSimulatorDemoMode = true
        AppStateStore.shared.applyThemeMode(.dark, animated: false)
        AppStateStore.shared.reloadConfig()

        let screenBounds = window.screen.bounds
        let shortSide = min(screenBounds.width, screenBounds.height)
        let longSide = max(screenBounds.width, screenBounds.height)
        let targetSize: CGSize = wantLandscape
            ? CGSize(width: longSide, height: shortSide)
            : CGSize(width: shortSide, height: longSide)

        let targetMask: UIInterfaceOrientationMask = wantLandscape ? .landscapeRight : .portrait
        let overrideTraits: UITraitCollection = isPad
            ? UITraitCollection(traitsFrom: [
                UITraitCollection(horizontalSizeClass: .regular),
                UITraitCollection(verticalSizeClass: .regular),
                UITraitCollection(userInterfaceIdiom: .pad),
            ])
            : UITraitCollection(traitsFrom: [
                UITraitCollection(horizontalSizeClass: .compact),
                UITraitCollection(verticalSizeClass: .regular),
                UITraitCollection(userInterfaceIdiom: .phone),
            ])

        let coordinator = RootNavigationCoordinator()
        let host = SimHostContainerViewController(
            coordinator: coordinator,
            targetOrientations: targetMask,
            overrideTraits: overrideTraits
        )
        window.rootViewController = host
        window.makeKeyAndVisible()

        if #available(iOS 16.0, *) {
            host.setNeedsUpdateOfSupportedInterfaceOrientations()
            let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: targetMask)
            scene.requestGeometryUpdate(prefs) { _ in }
            await settle(seconds: 0.45)
        }

        // Guarantee exact requested orientation bounds even on headless simulators
        if (wantLandscape && window.bounds.width < window.bounds.height)
            || (!wantLandscape && window.bounds.width > window.bounds.height)
        {
            window.frame = CGRect(origin: .zero, size: targetSize)
            window.bounds = CGRect(origin: .zero, size: targetSize)
        }
        host.view.frame = window.bounds
        window.setNeedsLayout()
        window.layoutIfNeeded()
        await settle(seconds: 0.35)

        if wantLandscape {
            XCTAssertGreaterThan(
                window.bounds.width,
                window.bounds.height,
                "Expected landscape bounds on iPad landscape pass"
            )
        }

        // 1. 01_home.png — Home hero + shelves & shell verification
        coordinator.presentDemoScreen("home")
        await settle(seconds: 0.85)
        if isPad {
            let split = findDescendant(ofType: UISplitViewController.self, in: coordinator)
            XCTAssertNotNil(split, "iPad must mount UISplitViewController sidebar shell")
            XCTAssertNil(
                findDescendant(ofType: UITabBarController.self, in: coordinator),
                "iPad must not fall back to compact UITabBarController"
            )
        } else {
            let tabBar = findDescendant(ofType: UITabBarController.self, in: coordinator)
            XCTAssertNotNil(tabBar, "iPhone must mount UITabBarController shell")
            XCTAssertNil(
                findDescendant(ofType: UISplitViewController.self, in: coordinator),
                "iPhone must not mount regular UISplitViewController"
            )
        }
        try await captureWindow(window, filename: "\(prefix)_01_home.png", settleSeconds: 0.45)

        // 2. 02_sidebar_or_discover.png — iPad collapsible sidebar expanded / iPhone Curated Discovery
        if isPad {
            let split = try XCTUnwrap(
                findDescendant(ofType: UISplitViewController.self, in: coordinator),
                "Expected UISplitViewController on iPad"
            )
            split.show(.primary)
            await settle(seconds: 0.6)
            let primaryView = split.viewController(for: .primary)?.view
            XCTAssertNotNil(primaryView, "iPad primary sidebar controller view missing")
            if let pv = primaryView {
                XCTAssertGreaterThanOrEqual(
                    pv.bounds.width,
                    200,
                    "Expanded iPad sidebar width unexpectedly narrow (\(pv.bounds.width))"
                )
            }
            try await captureWindow(window, filename: "\(prefix)_02_sidebar_or_discover.png", settleSeconds: 0.35)
        } else {
            coordinator.presentDemoScreen("discover")
            await settle(seconds: 0.8)
            XCTAssertNotNil(
                findDescendant(ofType: CuratedDiscoveryViewController.self, in: coordinator),
                "Expected CuratedDiscoveryViewController on iPhone discover tab"
            )
            try await captureWindow(window, filename: "\(prefix)_02_sidebar_or_discover.png", settleSeconds: 0.45)
        }

        // 3. 03_search.png — Search screen (assert iPad width-bounded search bar <= 480pt)
        coordinator.presentDemoScreen("search")
        await settle(seconds: 0.75)
        let searchVC = try XCTUnwrap(
            findDescendant(ofType: SearchViewController.self, in: coordinator),
            "SearchViewController missing after navigating to search"
        )
        window.layoutIfNeeded()
        let searchBar = try XCTUnwrap(
            findSubview(ofType: UISearchBar.self, in: searchVC.view),
            "UISearchBar missing in SearchViewController"
        )
        XCTAssertGreaterThan(searchBar.bounds.width, 160, "UISearchBar width unexpectedly collapsed")
        if isPad {
            XCTAssertLessThanOrEqual(
                searchBar.bounds.width,
                480,
                "iPad search bar must stay width-bounded <= 480pt (got \(searchBar.bounds.width)pt)"
            )
        }
        try await captureWindow(window, filename: "\(prefix)_03_search.png", settleSeconds: 0.4)
        if !isPad {
            popAllNavigationStacks(under: coordinator)
        }

        // 4. 04_detail.png — Video Detail with 16:9 episode stills & plots
        coordinator.presentDemoScreen("detail")
        await settle(seconds: 0.85)
        XCTAssertNotNil(
            findDescendant(ofType: VideoDetailViewController.self, in: coordinator),
            "VideoDetailViewController missing after presentDemoScreen(\"detail\")"
        )
        try await captureWindow(window, filename: "\(prefix)_04_detail.png", settleSeconds: 0.45)
        popAllNavigationStacks(under: coordinator)

        // 5. 05_live.png — Live TV EPG screen
        coordinator.presentDemoScreen("live")
        await settle(seconds: 0.85)
        XCTAssertNotNil(
            findDescendant(ofType: LiveTvViewController.self, in: coordinator),
            "LiveTvViewController missing after presentDemoScreen(\"live\")"
        )
        try await captureWindow(window, filename: "\(prefix)_05_live.png", settleSeconds: 0.45)

        // 6. 06_settings.png — Settings (iPad asserts master + detail side-by-side simultaneously)
        coordinator.presentDemoScreen("settings")
        await settle(seconds: 0.65)
        let settingsVC = try XCTUnwrap(
            findDescendant(ofType: SettingsSplitViewController.self, in: coordinator),
            "SettingsSplitViewController missing after navigating to settings"
        )
        if isPad {
            if let split = findDescendant(ofType: UISplitViewController.self, in: coordinator),
               settingsVC.traitCollection.horizontalSizeClass != .regular
            {
                // On iPad Portrait when outer sidebar tiles beside secondary, collapse outer sidebar
                // so SettingsSplitViewController receives full regular width for its two-column split.
                split.hide(.primary)
                await settle(seconds: 0.55)
            }
            window.layoutIfNeeded()
            settingsVC.view.layoutIfNeeded()
            XCTAssertEqual(
                settingsVC.traitCollection.horizontalSizeClass,
                .regular,
                "SettingsSplitViewController must resolve regular horizontal size class on iPad"
            )

            let masterTable = try XCTUnwrap(
                settingsVC.view.subviews.compactMap { $0 as? UITableView }.first,
                "Master category UITableView missing in SettingsSplitViewController"
            )
            let detailNav = try XCTUnwrap(
                settingsVC.children.compactMap { $0 as? UINavigationController }.first,
                "Right detail UINavigationController missing in SettingsSplitViewController"
            )
            let detailContainer = try XCTUnwrap(
                detailNav.view.superview,
                "Right detail container missing in SettingsSplitViewController"
            )

            let masterFrame = masterTable.convert(masterTable.bounds, to: settingsVC.view)
            let detailFrame = detailContainer.convert(detailContainer.bounds, to: settingsVC.view)

            XCTAssertFalse(masterTable.isHidden, "iPad Settings left category column must be visible")
            XCTAssertFalse(detailContainer.isHidden, "iPad Settings right detail column must be visible")
            XCTAssertFalse(detailNav.view.isHidden, "iPad Settings right detail nav must be visible")
            XCTAssertGreaterThanOrEqual(masterFrame.width, 260, "Left category column width too small: \(masterFrame)")
            XCTAssertGreaterThanOrEqual(detailFrame.width, 260, "Right detail column width too small: \(detailFrame)")
            XCTAssertGreaterThanOrEqual(
                detailFrame.minX,
                masterFrame.maxX - 2.0,
                "Settings master (\(masterFrame)) and detail (\(detailFrame)) must render side-by-side simultaneously"
            )
        }
        try await captureWindow(window, filename: "\(prefix)_06_settings.png", settleSeconds: 0.45)

        // 7. 07_player.png — CinemaPlayerViewController in demoPreviewMode = true with HUD & 120Hz danmaku
        coordinator.presentDemoScreen("player")
        await settle(seconds: 1.0)
        let playerVC = try XCTUnwrap(
            findDescendant(ofType: CinemaPlayerViewController.self, in: host),
            "CinemaPlayerViewController was not presented for demoPreviewMode"
        )
        XCTAssertNotNil(playerVC.view.window, "CinemaPlayerViewController must be attached to active window")
        try await captureWindow(window, filename: "\(prefix)_07_player.png", settleSeconds: 0.55)

        // Cleanly dismiss player so demo timer & CADisplayLink tear down before test ends
        playerVC.dismiss(animated: false)
        await settle(seconds: 0.3)
    }
}
#endif
