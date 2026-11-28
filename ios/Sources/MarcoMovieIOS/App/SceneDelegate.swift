// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Multi-Scene Window Delegate (iPhone & iPadOS Stage Manager / Split View)

import UIKit

public final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    public var window: UIWindow?
    private var rootCoordinator: RootNavigationCoordinator?

    public func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        MarcoThemeManager.shared.apply(to: window)
        window.tintColor = MarcoColors.accentTint

        let coordinator = RootNavigationCoordinator()
        window.rootViewController = coordinator
        window.makeKeyAndVisible()

        self.window = window
        self.rootCoordinator = coordinator

        if let urlContext = connectionOptions.urlContexts.first {
            handleIncomingDeepLink(urlContext.url)
        }

        SimulatorVerificationHook.applyIfNeeded(to: coordinator)
    }

    public func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        handleIncomingDeepLink(url)
    }

    public func sceneDidBecomeActive(_ scene: UIScene) {
        AppStateStore.shared.handleSceneDidBecomeActive()
    }

    public func sceneDidEnterBackground(_ scene: UIScene) {
        AppStateStore.shared.handleSceneDidEnterBackground()
    }

    private func handleIncomingDeepLink(_ url: URL) {
        guard let message = AppStateStore.shared.handleDeepLink(url),
              let root = rootCoordinator
        else { return }
        let alert = UIAlertController(title: "配置绑定", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好的", style: .default))
        MarcoModalPresenter.topPresenter(from: root).present(alert, animated: true)
    }
}
