// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Adaptive iPadOS Double-Column Sidebar & iPhone TabBar Root Coordinator

import MarcoIOSCore
import UIKit

// MARK: - Primary App Sections

public enum AppSection: Int, CaseIterable, Hashable, Sendable {
    case home = 0
    case discover = 1
    case search = 2
    case live = 3
    case library = 4
    case settings = 5

    public var title: String {
        switch self {
        case .home: return "首页"
        case .discover: return "精选"
        case .search: return "搜索"
        case .live: return "直播"
        case .library: return "片库"
        case .settings: return "设置"
        }
    }

    public var sidebarTitle: String {
        switch self {
        case .home: return "首页"
        case .discover: return "精选发现"
        case .search: return "搜索"
        case .live: return "电视直播"
        case .library: return "我的片库"
        case .settings: return "设置"
        }
    }

    public var symbolName: String {
        switch self {
        case .home: return "house"
        case .discover: return "sparkles.tv"
        case .search: return "magnifyingglass"
        case .live: return "tv"
        case .library: return "rectangle.stack"
        case .settings: return "gearshape"
        }
    }

    public var selectedSymbolName: String {
        switch self {
        case .home: return "house.fill"
        case .discover: return "sparkles.tv.fill"
        case .search: return "magnifyingglass"
        case .live: return "tv.fill"
        case .library: return "rectangle.stack.fill"
        case .settings: return "gearshape.fill"
        }
    }

    /// 5 compact-width iPhone tabs (Search is accessible via nav bar icon and Cmd+F).
    public static let compactTabs: [AppSection] = [.home, .discover, .live, .library, .settings]
}

// MARK: - iPadOS Collapsible Left Sidebar Controller

private final class SidebarNavigationViewController: UIViewController, UICollectionViewDelegate {
    private enum SectionKind: Int, CaseIterable {
        case main
        case quickSites
        case system
    }

    private enum SidebarItem: Hashable {
        case nav(AppSection)
        case site(key: String, title: String, isSelected: Bool)
        case privacyStatus(unlocked: Bool)
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<SectionKind, SidebarItem>!

    var selectedSection: AppSection = .home
    var onSelectSection: ((AppSection) -> Void)?
    var onSelectSite: ((CmsSite) -> Void)?
    var onPrivacyTapped: (() -> Void)?

    private var sitesSnapshot: [CmsSite] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Marco Movie"
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .clear

        var listConfig = UICollectionLayoutListConfiguration(appearance: .sidebar)
        listConfig.headerMode = .none
        listConfig.backgroundColor = .clear
        let layout = UICollectionViewCompositionalLayout.list(using: listConfig)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.backgroundColor = .clear
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        configureDataSource()
        reloadSidebar()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStateChanged),
            name: .marcoStateDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStateChanged),
            name: .marcoPrivacyDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func configureDataSource() {
        let navReg = UICollectionView.CellRegistration<UICollectionViewListCell, SidebarItem> { cell, _, item in
            var content = cell.defaultContentConfiguration()
            switch item {
            case .nav(let section):
                content.text = section.sidebarTitle
                content.textProperties.font = MarcoTypography.bodySemibold
                content.image = MarcoSymbols.image(
                    section.selectedSymbolName,
                    pointSize: 16,
                    weight: .medium,
                    hierarchicalColor: MarcoColors.accentTint
                ) ?? MarcoSymbols.image(
                    section.symbolName,
                    pointSize: 16,
                    weight: .medium,
                    hierarchicalColor: MarcoColors.accentTint
                )
            case .site(_, let title, let isSelected):
                content.text = title
                content.textProperties.font = isSelected ? MarcoTypography.cardTitle : MarcoTypography.cardSubtitle
                content.image = MarcoSymbols.image(
                    isSelected ? "checkmark.circle.fill" : "globe",
                    pointSize: 14,
                    weight: .medium,
                    hierarchicalColor: isSelected ? MarcoColors.accentTint : MarcoColors.secondaryText
                )
            case .privacyStatus(let unlocked):
                content.text = unlocked ? "隐私空间已解锁（轻点锁定）" : "隐私空间已锁定"
                content.textProperties.font = MarcoTypography.cardSubtitle
                content.textProperties.color = unlocked ? MarcoColors.ratingGold : MarcoColors.secondaryText
                content.image = MarcoSymbols.image(
                    unlocked ? "lock.open.fill" : "lock.shield",
                    pointSize: 15,
                    weight: .medium,
                    hierarchicalColor: unlocked ? MarcoColors.ratingGold : MarcoColors.secondaryText
                )
            }
            cell.contentConfiguration = content
            cell.accessories = []
        }

        dataSource = UICollectionViewDiffableDataSource<SectionKind, SidebarItem>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: navReg, for: indexPath, item: item)
        }
    }

    @objc private func handleStateChanged() {
        reloadSidebar()
    }

    func reloadSidebar() {
        let store = AppStateStore.shared
        sitesSnapshot = Array(store.visibleAvailableSites().prefix(6))
        let activeKey = store.activeSite?.key

        var snapshot = NSDiffableDataSourceSnapshot<SectionKind, SidebarItem>()
        snapshot.appendSections([.main])
        snapshot.appendItems([
            .nav(.home),
            .nav(.discover),
            .nav(.search),
            .nav(.live),
            .nav(.library),
        ], toSection: .main)

        if !sitesSnapshot.isEmpty {
            snapshot.appendSections([.quickSites])
            snapshot.appendItems(
                sitesSnapshot.map { .site(key: $0.key, title: $0.name, isSelected: $0.key == activeKey) },
                toSection: .quickSites
            )
        }

        snapshot.appendSections([.system])
        snapshot.appendItems([
            .nav(.settings),
            .privacyStatus(unlocked: store.isPrivacySpaceUnlocked),
        ], toSection: .system)

        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            self?.highlightSelectedSection()
        }
    }

    func selectSectionVisually(_ section: AppSection) {
        selectedSection = section
        highlightSelectedSection()
    }

    private func highlightSelectedSection() {
        guard let indexPath = dataSource.indexPath(for: .nav(selectedSection)) else { return }
        collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        MarcoHaptics.selection()
        switch item {
        case .nav(let section):
            selectedSection = section
            onSelectSection?(section)
        case .site(let key, _, _):
            if let site = sitesSnapshot.first(where: { $0.key == key }) {
                onSelectSite?(site)
                selectedSection = .home
                onSelectSection?(.home)
            }
        case .privacyStatus:
            collectionView.deselectItem(at: indexPath, animated: true)
            onPrivacyTapped?()
        }
    }
}

// MARK: - Root Navigation Coordinator (True iPadOS SplitView <-> iPhone TabBar)

/// Adaptive application shell:
/// - **iPad / Regular Width**: `UISplitViewController(style: .doubleColumn)` with collapsible native `.sidebar`
///   and zero floating right-edge bars.
/// - **iPhone / Compact Width**: 5-tab `UITabBarController` with Large Titles and smooth scroll-edge appearance.
/// - Seamlessly re-adapts on iPad Split View / Slide Over transitions and supports Magic Keyboard shortcuts.
public final class RootNavigationCoordinator: UIViewController, UITabBarControllerDelegate {
    private enum ShellMode {
        case regularSplit
        case compactTabs
    }

    public private(set) var activeSection: AppSection = .home

    private var currentShellMode: ShellMode?
    private var embeddedShellController: UIViewController?
    private var splitController: UISplitViewController?
    private var sidebarController: SidebarNavigationViewController?
    private var tabBarControllerRef: UITabBarController?

    private var cachedControllers: [AppSection: UIViewController] = [:]

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MarcoColors.canvasBackground
        installShellIfNeeded(for: traitCollection)
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.horizontalSizeClass != traitCollection.horizontalSizeClass {
            installShellIfNeeded(for: traitCollection)
        }
    }

    public override func willTransition(
        to newCollection: UITraitCollection,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.willTransition(to: newCollection, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.installShellIfNeeded(for: newCollection)
        }
    }

    // MARK: - Magic Keyboard Shortcuts

    public override var canBecomeFirstResponder: Bool { true }

    public override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "搜索影片", action: #selector(shortcutSearch), input: "f", modifierFlags: .command),
            UIKeyCommand(title: "打开设置", action: #selector(shortcutSettings), input: ",", modifierFlags: .command),
            UIKeyCommand(title: "首页", action: #selector(shortcutTab1), input: "1", modifierFlags: .command),
            UIKeyCommand(title: "精选发现", action: #selector(shortcutTab2), input: "2", modifierFlags: .command),
            UIKeyCommand(title: "电视直播", action: #selector(shortcutTab3), input: "3", modifierFlags: .command),
            UIKeyCommand(title: "我的片库", action: #selector(shortcutTab4), input: "4", modifierFlags: .command),
            UIKeyCommand(title: "设置", action: #selector(shortcutTab5), input: "5", modifierFlags: .command),
            UIKeyCommand(title: "关闭弹窗或锁定隐私", action: #selector(shortcutEscape), input: UIKeyCommand.inputEscape, modifierFlags: []),
        ]
    }

    @objc private func shortcutSearch() { navigate(to: .search) }
    @objc private func shortcutSettings() { navigate(to: .settings) }
    @objc private func shortcutTab1() { navigate(to: .home) }
    @objc private func shortcutTab2() { navigate(to: .discover) }
    @objc private func shortcutTab3() { navigate(to: .live) }
    @objc private func shortcutTab4() { navigate(to: .library) }
    @objc private func shortcutTab5() { navigate(to: .settings) }

    @objc private func shortcutEscape() {
        if let presented = presentedViewController {
            presented.dismiss(animated: true)
        } else if AppStateStore.shared.isPrivacySpaceUnlocked {
            AppStateStore.shared.lockPrivacySpace()
        }
    }

    // MARK: - Public Navigation & Demo Routing

    public func navigate(to section: AppSection) {
        activeSection = section
        switch currentShellMode {
        case .regularSplit:
            let secondary = controllerForSection(section, forRegularSplit: true)
            splitController?.setViewController(secondary, for: .secondary)
            sidebarController?.selectSectionVisually(section)
        case .compactTabs:
            if section == .search {
                let searchVC = makeSearchController()
                if let activeNav = tabBarControllerRef?.selectedViewController as? UINavigationController {
                    activeNav.pushViewController(searchVC, animated: true)
                } else {
                    MarcoModalPresenter.present(
                        searchVC,
                        from: self,
                        options: MarcoModalOptions(detents: [.large], wrapInNavigationController: true)
                    )
                }
                return
            }
            if let tabIndex = AppSection.compactTabs.firstIndex(of: section) {
                tabBarControllerRef?.selectedIndex = tabIndex
            }
        case .none:
            break
        }
    }

    /// Deterministic routing hook for `SimulatorVerificationHook` and hosted UI tests.
    public func presentDemoScreen(_ rawScreen: String) {
        let screen = rawScreen.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch screen {
        case "home":
            navigate(to: .home)
        case "discover":
            navigate(to: .discover)
        case "search":
            navigate(to: .search)
        case "live":
            navigate(to: .live)
        case "library":
            navigate(to: .library)
        case "settings":
            navigate(to: .settings)
        case "detail":
            navigate(to: .home)
            let detail = VideoDetailViewController(
                video: SimulatorDemoFixtures.featuredVideo,
                site: SimulatorDemoFixtures.demoSite
            )
            if let nav = currentActiveNavigationController() {
                nav.pushViewController(detail, animated: false)
            } else {
                MarcoModalPresenter.present(
                    detail,
                    from: self,
                    options: MarcoModalOptions(detents: [.large], wrapInNavigationController: true),
                    animated: false
                )
            }
        case "player":
            navigate(to: .home)
            AppStateStore.shared.presentPlayer(
                from: self,
                video: SimulatorDemoFixtures.featuredVideo,
                site: SimulatorDemoFixtures.demoSite,
                lines: SimulatorDemoFixtures.featuredVideo.lines,
                initialLineIndex: 0,
                initialEpisodeIndex: 0,
                startPositionMs: 185_000,
                isLive: false,
                demoPreviewMode: true
            )
        default:
            navigate(to: .home)
        }
    }

    // MARK: - Shell Construction

    private func installShellIfNeeded(for traits: UITraitCollection) {
        let targetMode: ShellMode = (traits.horizontalSizeClass == .regular) ? .regularSplit : .compactTabs
        guard targetMode != currentShellMode else { return }

        if let existing = embeddedShellController {
            existing.willMove(toParent: nil)
            existing.view.removeFromSuperview()
            existing.removeFromParent()
        }
        splitController = nil
        sidebarController = nil
        tabBarControllerRef = nil
        cachedControllers.removeAll()
        currentShellMode = targetMode

        let nextShell: UIViewController
        switch targetMode {
        case .regularSplit:
            nextShell = buildRegularSplitShell()
        case .compactTabs:
            nextShell = buildCompactTabShell()
        }

        addChild(nextShell)
        nextShell.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nextShell.view)
        NSLayoutConstraint.activate([
            nextShell.view.topAnchor.constraint(equalTo: view.topAnchor),
            nextShell.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nextShell.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            nextShell.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        nextShell.didMove(toParent: self)
        embeddedShellController = nextShell
    }

    private func buildRegularSplitShell() -> UIViewController {
        let split = UISplitViewController(style: .doubleColumn)
        split.preferredDisplayMode = .oneBesideSecondary
        split.preferredSplitBehavior = .tile
        split.presentsWithGesture = true
        split.primaryBackgroundStyle = .sidebar
        split.preferredPrimaryColumnWidth = 260
        split.minimumPrimaryColumnWidth = 228
        split.maximumPrimaryColumnWidth = 296

        let sidebar = SidebarNavigationViewController()
        sidebar.selectedSection = activeSection
        sidebar.onSelectSection = { [weak self] section in
            self?.navigate(to: section)
        }
        sidebar.onSelectSite = { site in
            AppStateStore.shared.selectSite(site)
        }
        sidebar.onPrivacyTapped = { [weak self] in
            guard let self = self else { return }
            if AppStateStore.shared.isPrivacySpaceUnlocked {
                AppStateStore.shared.lockPrivacySpace()
            } else {
                AppStateStore.shared.promptUnlockPrivacySpace(from: self)
            }
        }
        let sidebarNav = makeStyledNavigationController(root: sidebar, prefersLargeTitles: false)
        split.setViewController(sidebarNav, for: .primary)

        let initialSecondary = controllerForSection(activeSection, forRegularSplit: true)
        split.setViewController(initialSecondary, for: .secondary)

        self.splitController = split
        self.sidebarController = sidebar
        return split
    }

    private func buildCompactTabShell() -> UIViewController {
        let tabBar = UITabBarController()
        tabBar.delegate = self
        configureTabBarAppearance(tabBar.tabBar)

        let viewControllers: [UIViewController] = AppSection.compactTabs.map { section in
            let vc = controllerForSection(section, forRegularSplit: false)
            vc.tabBarItem = UITabBarItem(
                title: section.title,
                image: MarcoSymbols.image(section.symbolName, pointSize: 18, weight: .medium),
                selectedImage: MarcoSymbols.image(section.selectedSymbolName, pointSize: 18, weight: .semibold)
            )
            vc.tabBarItem.tag = section.rawValue
            return vc
        }

        tabBar.viewControllers = viewControllers
        if let selectedIdx = AppSection.compactTabs.firstIndex(of: activeSection) {
            tabBar.selectedIndex = selectedIdx
        } else {
            tabBar.selectedIndex = 0
        }

        self.tabBarControllerRef = tabBar
        return tabBar
    }

    private func configureTabBarAppearance(_ tabBar: UITabBar) {
        tabBar.tintColor = MarcoColors.accentTint
        tabBar.unselectedItemTintColor = MarcoColors.secondaryText

        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemChromeMaterial)
        appearance.shadowColor = MarcoColors.separator

        tabBar.standardAppearance = appearance
        if #available(iOS 15.0, *) {
            tabBar.scrollEdgeAppearance = appearance
        }
    }

    private func makeStyledNavigationController(
        root: UIViewController,
        prefersLargeTitles: Bool
    ) -> UINavigationController {
        let nav = UINavigationController(rootViewController: root)
        nav.navigationBar.prefersLargeTitles = prefersLargeTitles
        nav.navigationBar.tintColor = MarcoColors.accentTint

        let standard = UINavigationBarAppearance()
        standard.configureWithDefaultBackground()
        standard.backgroundEffect = UIBlurEffect(style: .systemChromeMaterial)
        standard.titleTextAttributes = [.foregroundColor: MarcoColors.primaryText]
        standard.largeTitleTextAttributes = [.foregroundColor: MarcoColors.primaryText]
        standard.shadowColor = MarcoColors.separator

        let scrollEdge = UINavigationBarAppearance()
        scrollEdge.configureWithTransparentBackground()
        scrollEdge.titleTextAttributes = [.foregroundColor: MarcoColors.primaryText]
        scrollEdge.largeTitleTextAttributes = [.foregroundColor: MarcoColors.primaryText]

        nav.navigationBar.standardAppearance = standard
        nav.navigationBar.compactAppearance = standard
        nav.navigationBar.scrollEdgeAppearance = scrollEdge
        return nav
    }

    private func controllerForSection(_ section: AppSection, forRegularSplit: Bool) -> UIViewController {
        if let cached = cachedControllers[section] {
            return cached
        }
        let vc: UIViewController
        switch section {
        case .home:
            let home = HomeViewController()
            home.onRequestSearch = { [weak self] in self?.navigate(to: .search) }
            home.onRequestOpenSettings = { [weak self] in self?.navigate(to: .settings) }
            home.onRequestOpenCurated = { [weak self] in self?.navigate(to: .discover) }
            vc = makeStyledNavigationController(root: home, prefersLargeTitles: !forRegularSplit)
        case .discover:
            let discover = CuratedDiscoveryViewController()
            discover.onRequestSearch = { [weak self] keyword in
                self?.openSearch(withQuery: keyword)
            }
            vc = makeStyledNavigationController(root: discover, prefersLargeTitles: true)
        case .search:
            vc = makeStyledNavigationController(root: makeSearchController(), prefersLargeTitles: !forRegularSplit)
        case .live:
            let live = LiveTvViewController()
            vc = makeStyledNavigationController(root: live, prefersLargeTitles: !forRegularSplit)
        case .library:
            let library = LibraryViewController()
            vc = makeStyledNavigationController(root: library, prefersLargeTitles: true)
        case .settings:
            // Genuine iPadOS permanent Master-Detail Settings on regular width; push navigation on iPhone!
            let settings = SettingsSplitViewController()
            vc = forRegularSplit ? settings : makeStyledNavigationController(root: settings, prefersLargeTitles: true)
        }
        cachedControllers[section] = vc
        return vc
    }

    private func makeSearchController(initialQuery: String? = nil) -> SearchViewController {
        let search = SearchViewController(initialQuery: initialQuery)
        return search
    }

    public func openSearch(withQuery query: String?) {
        if currentShellMode == .regularSplit {
            navigate(to: .search)
            if let nav = cachedControllers[.search] as? UINavigationController,
               let searchVC = nav.viewControllers.first as? SearchViewController,
               let q = query, !q.isEmpty
            {
                searchVC.executeExternalQuery(q)
            }
        } else {
            let searchVC = makeSearchController(initialQuery: query)
            if let activeNav = currentActiveNavigationController() {
                activeNav.pushViewController(searchVC, animated: true)
            } else {
                MarcoModalPresenter.present(
                    searchVC,
                    from: self,
                    options: MarcoModalOptions(detents: [.large], wrapInNavigationController: true)
                )
            }
        }
    }

    private func currentActiveNavigationController() -> UINavigationController? {
        if let tab = tabBarControllerRef {
            return tab.selectedViewController as? UINavigationController
        }
        if let split = splitController {
            return split.viewController(for: .secondary) as? UINavigationController
        }
        return nil
    }

    public func tabBarController(
        _ tabBarController: UITabBarController,
        didSelect viewController: UIViewController
    ) {
        if let section = AppSection(rawValue: viewController.tabBarItem.tag) {
            activeSection = section
        }
        MarcoHaptics.selection()
    }
}
