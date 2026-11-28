// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — 8-Module Curated Editorial Discovery Shelves with Ambient Mesh Glow

import MarcoIOSCore
import UIKit

public final class CuratedDiscoveryViewController: UIViewController, UICollectionViewDelegate {
    private struct CuratedItem: Hashable {
        let moduleId: String
        let video: CmsVideo
    }

    public var onRequestSearch: ((String) -> Void)?

    private let ambientGlowView = AmbientGlowView()
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, CuratedItem>!
    private let refreshControl = UIRefreshControl()

    private var modules: [CuratedModule] = []
    private var loadTask: Task<Void, Never>?

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "精选发现"
        view.backgroundColor = MarcoColors.canvasBackground

        ambientGlowView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(ambientGlowView)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        collectionView.refreshControl = refreshControl

        collectionView.register(PosterCardCell.self, forCellWithReuseIdentifier: PosterCardCell.reuseIdentifier)
        collectionView.register(LandscapeCardCell.self, forCellWithReuseIdentifier: LandscapeCardCell.reuseIdentifier)
        collectionView.register(
            ShelfHeaderReusableView.self,
            forSupplementaryViewOfKind: ShelfHeaderReusableView.elementKind,
            withReuseIdentifier: ShelfHeaderReusableView.reuseIdentifier
        )

        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            ambientGlowView.topAnchor.constraint(equalTo: view.topAnchor),
            ambientGlowView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            ambientGlowView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ambientGlowView.heightAnchor.constraint(equalToConstant: 440),

            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        configureDataSource()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStateChanged),
            name: .marcoStateDidChange,
            object: nil
        )
        reloadDiscovery()
    }

    deinit {
        loadTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, env in
            guard let self = self, sectionIndex < self.modules.count else { return nil }
            let module = self.modules[sectionIndex]
            let isRegular = env.traitCollection.horizontalSizeClass == .regular
            let margin = MarcoSpacing.horizontalMargin(for: env.traitCollection)
            let isWidescreen = module.layout == "widescreen_carousel" || module.layout == "studio_galleries"

            let cardW: CGFloat
            let cardH: CGFloat
            if isWidescreen {
                cardW = isRegular ? 316 : 268
                cardH = cardW * (9.0 / 16.0) + 52
            } else {
                cardW = isRegular ? 168 : 132
                cardH = cardW * 1.5 + 58
            }

            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .fractionalHeight(1.0))
            )
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .absolute(cardW), heightDimension: .absolute(cardH)),
                subitems: [item]
            )
            let section = NSCollectionLayoutSection(group: group)
            section.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
            section.interGroupSpacing = isRegular ? 16 : 12
            section.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: margin, bottom: 24, trailing: margin)
            section.boundarySupplementaryItems = [
                NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(46)),
                    elementKind: ShelfHeaderReusableView.elementKind,
                    alignment: .top
                ),
            ]
            return section
        }
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<String, CuratedItem>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item in
            guard let self = self else { return nil }
            let module = self.modules.first(where: { $0.id == item.moduleId })
            let isWidescreen = module?.layout == "widescreen_carousel" || module?.layout == "studio_galleries"
            let isPrivate = AppStateStore.shared.activeSite?.isEffectivelyPrivate ?? false
            let rating = item.video.doubanScore.flatMap { $0 > 0 ? String(format: "%.1f", $0) : nil }
            let sub = [item.video.year, item.video.area, item.video.tag]
                .filter { !$0.isEmpty }
                .prefix(2)
                .joined(separator: " · ")

            let model = PosterCardModel(
                id: "\(item.moduleId)|\(item.video.id)",
                title: item.video.title,
                subtitle: sub.isEmpty ? nil : sub,
                badge: item.video.remarks.isEmpty ? nil : item.video.remarks,
                rating: rating,
                posterURL: item.video.poster,
                isPrivate: isPrivate
            )

            if isWidescreen {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: LandscapeCardCell.reuseIdentifier,
                    for: indexPath
                ) as! LandscapeCardCell
                cell.configure(with: model, showPlayGlyph: false)
                return cell
            } else {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: PosterCardCell.reuseIdentifier,
                    for: indexPath
                ) as! PosterCardCell
                cell.configure(with: model)
                return cell
            }
        }

        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            guard kind == ShelfHeaderReusableView.elementKind,
                  let self = self,
                  indexPath.section < self.modules.count,
                  let header = collectionView.dequeueReusableSupplementaryView(
                      ofKind: kind,
                      withReuseIdentifier: ShelfHeaderReusableView.reuseIdentifier,
                      for: indexPath
                  ) as? ShelfHeaderReusableView
            else { return nil }

            let mod = self.modules[indexPath.section]
            header.configure(title: mod.title, subtitle: mod.subtitle, actionTitle: "跨源搜索") { [weak self] in
                let seedTitle = mod.items.first?.title ?? mod.title
                self?.onRequestSearch?(seedTitle)
            }
            return header
        }
    }

    @objc private func handleStateChanged() {
        reloadDiscovery()
    }

    @objc private func handleRefresh() {
        reloadDiscovery()
    }

    private func reloadDiscovery() {
        loadTask?.cancel()
        let store = AppStateStore.shared
        let prefs = store.storage.preferences()
        ambientGlowView.isHidden = !prefs.ambientGlowEnabled

        if store.isSimulatorDemoMode {
            modules = composeEightCuratedModules(from: SimulatorDemoFixtures.videos, prefs: prefs)
            applyModules()
            refreshControl.endRefreshing()
            return
        }

        guard let site = store.activeSite else {
            modules = []
            applyModules()
            refreshControl.endRefreshing()
            return
        }

        loadTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let home = try await store.cmsClient.fetchHome(site: site, storage: store.storage)
                guard !Task.isCancelled else { return }
                self.modules = self.composeEightCuratedModules(from: home.listing.videos, prefs: prefs)
                self.applyModules()
            } catch {
                // Keep existing discovery state on error.
            }
            self.refreshControl.endRefreshing()
        }
    }

    /// Expands `CuratedDiscoveryService` core shelves into all 8 editorial discovery modules
    /// strictly from the user's loaded catalog (zero embedded third-party media sources).
    private func composeEightCuratedModules(
        from videos: [CmsVideo],
        prefs: PlaybackPreferences
    ) -> [CuratedModule] {
        guard !videos.isEmpty else { return [] }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var base = CuratedDiscoveryService.buildModules(from: videos, preferences: prefs, nowMs: nowMs)
        let existingIds = Set(base.map(\.id))

        let moodItems = videos.filter { $0.tag.contains("科幻") || $0.tag.contains("悬疑") || $0.tag.contains("治愈") }
        let studioItems = videos.filter { $0.remarks.contains("4K") || $0.remarks.contains("HDR") || $0.remarks.contains("IMAX") || $0.remarks.contains("杜比") }
        let docAndAnime = videos.filter { $0.tag.contains("纪录") || $0.tag.contains("动画") }
        let regionalPicks = videos.filter { !$0.area.isEmpty }

        let supplemental: [CuratedModule] = [
            CuratedModule(
                id: "disc_mood_capsules",
                title: "氛围片单",
                subtitle: "科幻悬疑与治愈佳作沉浸精选",
                layout: "poster_row",
                items: Array((moodItems.isEmpty ? videos : moodItems).prefix(10)),
                updatedAt: nowMs
            ),
            CuratedModule(
                id: "disc_studio_galleries",
                title: "视听画廊 · 4K HDR",
                subtitle: "高规格原画、HDR 与影院音画体验",
                layout: "studio_galleries",
                items: Array((studioItems.isEmpty ? videos : studioItems).prefix(8)),
                updatedAt: nowMs
            ),
            CuratedModule(
                id: "disc_doc_anime_spotlight",
                title: "纪录片与高分动画",
                subtitle: "跨越现实与想象的视觉艺术",
                layout: "poster_row",
                items: Array((docAndAnime.isEmpty ? videos.reversed() : docAndAnime).prefix(10)),
                updatedAt: nowMs
            ),
            CuratedModule(
                id: "disc_global_showcase",
                title: "世界银幕漫游",
                subtitle: "按地区与风格精选的年度口碑片单",
                layout: "poster_row",
                items: Array((regionalPicks.isEmpty ? videos : regionalPicks).prefix(12)),
                updatedAt: nowMs
            ),
        ]

        for extra in supplemental where !existingIds.contains(extra.id) && !extra.items.isEmpty {
            base.append(extra)
        }
        return Array(base.prefix(8))
    }

    private func applyModules() {
        var snapshot = NSDiffableDataSourceSnapshot<String, CuratedItem>()
        for mod in modules where !mod.items.isEmpty {
            snapshot.appendSections([mod.id])
            snapshot.appendItems(mod.items.map { CuratedItem(moduleId: mod.id, video: $0) }, toSection: mod.id)
        }
        dataSource.apply(snapshot, animatingDifferences: false)

        if let firstVideo = modules.first?.items.first {
            let placeholder = PosterImageLoader.makeStudioPlaceholder(
                title: firstVideo.title,
                subtitle: firstVideo.remarks,
                seed: firstVideo.id
            )
            ambientGlowView.updateFromImage(placeholder, animated: true)
            if !firstVideo.poster.isEmpty {
                PosterImageLoader.shared.loadImage(
                    urlString: firstVideo.poster,
                    isPrivate: AppStateStore.shared.activeSite?.isEffectivelyPrivate ?? false
                ) { [weak self] img in
                    if let img = img {
                        self?.ambientGlowView.updateFromImage(img, animated: true)
                    }
                }
            }
        }
        updateEmptyState()
    }

    private func updateEmptyState() {
        if modules.isEmpty {
            let label = UILabel()
            label.text = "导入订阅片源后，将在此自动生成 8 组 Apple TV+ 风格精选发现片单。"
            label.font = MarcoTypography.body
            label.textColor = MarcoColors.secondaryText
            label.textAlignment = .center
            label.numberOfLines = 0
            collectionView.backgroundView = label
        } else {
            collectionView.backgroundView = nil
        }
    }

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        MarcoHaptics.selection()

        let store = AppStateStore.shared
        let site = store.activeSite ?? SimulatorDemoFixtures.demoSite
        let detail = VideoDetailViewController(video: item.video, site: site)
        let sourceView: UIView?
        if let posterCell = collectionView.cellForItem(at: indexPath) as? PosterCardCell {
            sourceView = posterCell.zoomSourceView
        } else if let landCell = collectionView.cellForItem(at: indexPath) as? LandscapeCardCell {
            sourceView = landCell.zoomSourceView
        } else {
            sourceView = nil
        }
        MarcoZoomTransitionHelper.push(
            detail,
            on: navigationController,
            from: { [weak sourceView] in sourceView }
        )
    }
}
