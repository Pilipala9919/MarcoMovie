// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Unified Library Hub (Favorites, History, Grouped Downloads, 5 Personal Netdisks, Media Libraries)

import MarcoIOSCore
import UIKit

// MARK: - Download Row Cell

private final class DownloadGroupRowCell: UICollectionViewCell {
    static let reuseIdentifier = "DownloadGroupRowCell"

    private let card = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let privacyPill = UILabel()
    private let progressBar = UIProgressView(progressViewStyle: .default)
    private let actionButton = UIButton(type: .system)

    var onActionTapped: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = MarcoColors.cardSurface
        card.applyContinuousCorners(MarcoRadii.card)
        card.applyHairlineBorder()
        contentView.addSubview(card)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = MarcoTypography.cardTitle
        titleLabel.textColor = MarcoColors.primaryText

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = MarcoTypography.caption
        subtitleLabel.textColor = MarcoColors.secondaryText

        privacyPill.translatesAutoresizingMaskIntoConstraints = false
        privacyPill.font = MarcoTypography.badge
        privacyPill.textColor = MarcoColors.ratingGold
        privacyPill.text = "隐私隔离"
        privacyPill.isHidden = true

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.progressTintColor = MarcoColors.accentTint
        progressBar.trackTintColor = MarcoColors.subtleFill

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.titleLabel?.font = MarcoTypography.caption
        actionButton.setTitleColor(MarcoColors.accentTint, for: .normal)
        actionButton.addTarget(self, action: #selector(handleAction), for: .touchUpInside)

        card.addSubview(titleLabel)
        card.addSubview(subtitleLabel)
        card.addSubview(privacyPill)
        card.addSubview(progressBar)
        card.addSubview(actionButton)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: privacyPill.leadingAnchor, constant: -8),

            privacyPill.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            privacyPill.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -10),

            actionButton.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            actionButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -10),

            progressBar.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 10),
            progressBar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -14),
            progressBar.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(task: DownloadTask) {
        titleLabel.text = "\(task.title) · \(task.episodeName)"
        privacyPill.isHidden = !task.isPrivate
        progressBar.setProgress(Float(min(max(task.progress, 0), 1)), animated: false)

        let pct = Int((task.progress * 100).rounded())
        let statusText: String
        let buttonTitle: String
        switch task.status {
        case .completed:
            statusText = "已完成 · 可离线播放"
            buttonTitle = "播放"
        case .downloading:
            statusText = "缓存中 \(pct)%"
            buttonTitle = "暂停"
        case .queued:
            statusText = "排队等待中"
            buttonTitle = "暂停"
        case .paused:
            statusText = "已暂停 \(pct)%"
            buttonTitle = "继续"
        case .failed:
            statusText = task.error.isEmpty ? "下载失败" : task.error
            buttonTitle = "重试"
        }
        subtitleLabel.text = "\(task.siteName) · \(statusText)"
        actionButton.setTitle(buttonTitle, for: .normal)
    }

    @objc private func handleAction() {
        MarcoHaptics.selection()
        onActionTapped?()
    }
}

// MARK: - Provider / Media Library Tile Cell

private final class HubTileCardCell: UICollectionViewCell, UIPointerInteractionDelegate {
    static let reuseIdentifier = "HubTileCardCell"

    private let card = UIView()
    private let iconBadge = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let badgeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = MarcoColors.cardSurface
        card.applyContinuousCorners(MarcoRadii.card)
        card.applyHairlineBorder()
        contentView.addSubview(card)

        iconBadge.translatesAutoresizingMaskIntoConstraints = false
        iconBadge.backgroundColor = MarcoColors.subtleFill
        iconBadge.applyContinuousCorners(12)
        card.addSubview(iconBadge)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconBadge.addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = MarcoTypography.cardTitle
        titleLabel.textColor = MarcoColors.primaryText

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = MarcoTypography.caption
        subtitleLabel.textColor = MarcoColors.secondaryText
        subtitleLabel.numberOfLines = 1

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = MarcoTypography.badge
        badgeLabel.textAlignment = .right

        card.addSubview(titleLabel)
        card.addSubview(subtitleLabel)
        card.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            iconBadge.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            iconBadge.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            iconBadge.widthAnchor.constraint(equalToConstant: 44),
            iconBadge.heightAnchor.constraint(equalToConstant: 44),

            iconView.centerXAnchor.constraint(equalTo: iconBadge.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBadge.centerYAnchor),

            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: iconBadge.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeLabel.leadingAnchor, constant: -8),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),

            badgeLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            badgeLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])
        addInteraction(UIPointerInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, subtitle: String, symbol: String, statusText: String, active: Bool) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        badgeLabel.text = statusText
        badgeLabel.textColor = active ? MarcoColors.success : MarcoColors.tertiaryText
        iconView.image = MarcoSymbols.image(
            symbol,
            pointSize: 20,
            weight: .semibold,
            hierarchicalColor: active ? MarcoColors.accentTint : MarcoColors.secondaryText
        )
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(effect: .lift(UITargetedPreview(view: card)))
    }
}

// MARK: - Unified Library Hub View Controller

public final class LibraryViewController: UIViewController, UICollectionViewDelegate {
    private enum HubTab: Int, CaseIterable {
        case favorites = 0
        case history = 1
        case downloads = 2
        case netdisks = 3
        case mediaServers = 4

        var title: String {
            switch self {
            case .favorites: return "收藏"
            case .history: return "历史"
            case .downloads: return "下载"
            case .netdisks: return "网盘"
            case .mediaServers: return "媒体库"
            }
        }
    }

    private enum SectionKind: Hashable {
        case main
        case downloadSeries(String)
    }

    private enum HubItem: Hashable {
        case favorite(FavoriteItem)
        case history(WatchHistoryItem)
        case download(DownloadTask)
        case netdisk(NetdiskProvider)
        case emby(EmbyAccount)
        case mediaAccount(MediaLibraryAccount)
        case blurayInfo
    }

    private let segmentContainer = UIView()
    private let segmentedControl = UISegmentedControl(items: HubTab.allCases.map(\.title))
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<SectionKind, HubItem>!

    private var activeTab: HubTab = .favorites
    private var cachedDownloads: [DownloadTask] = []

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "我的片库"
        view.backgroundColor = MarcoColors.canvasBackground

        setupSegmentHeader()
        setupCollectionView()
        configureDataSource()
        observeUpdates()
        reloadData()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupSegmentHeader() {
        segmentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(segmentContainer)

        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
        segmentContainer.addSubview(segmentedControl)

        let guide = view.safeAreaLayoutGuide
        let prefW = segmentContainer.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -32)
        prefW.priority = .defaultHigh

        NSLayoutConstraint.activate([
            segmentContainer.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            segmentContainer.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            prefW,
            segmentContainer.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 16),
            segmentContainer.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -16),
            segmentContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            segmentContainer.heightAnchor.constraint(equalToConstant: 36),

            segmentedControl.topAnchor.constraint(equalTo: segmentContainer.topAnchor),
            segmentedControl.leadingAnchor.constraint(equalTo: segmentContainer.leadingAnchor),
            segmentedControl.trailingAnchor.constraint(equalTo: segmentContainer.trailingAnchor),
            segmentedControl.bottomAnchor.constraint(equalTo: segmentContainer.bottomAnchor),
        ])
    }

    private func setupCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] _, env in
            guard let self = self else { return nil }
            let isRegular = env.traitCollection.horizontalSizeClass == .regular
            let margin = MarcoSpacing.horizontalMargin(for: env.traitCollection)
            let availW = max(env.container.effectiveContentSize.width - margin * 2, 300)

            switch self.activeTab {
            case .favorites:
                let cols = isRegular ? max(4, min(6, Int(availW / 168))) : 3
                let spacing: CGFloat = isRegular ? 16 : 12
                let itemW = (availW - spacing * CGFloat(cols - 1)) / CGFloat(cols)
                let itemH = itemW * 1.5 + 58
                let item = NSCollectionLayoutItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0 / CGFloat(cols)), heightDimension: .absolute(itemH))
                )
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(itemH)),
                    subitem: item,
                    count: cols
                )
                group.interItemSpacing = .fixed(spacing)
                let sec = NSCollectionLayoutSection(group: group)
                sec.interGroupSpacing = 18
                sec.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: margin, bottom: 28, trailing: margin)
                return sec

            case .history:
                let cols = isRegular ? max(2, min(3, Int(availW / 270))) : 1
                let spacing: CGFloat = 14
                let itemW = (availW - spacing * CGFloat(cols - 1)) / CGFloat(cols)
                let itemH = itemW * (9.0 / 16.0) + 56
                let item = NSCollectionLayoutItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0 / CGFloat(cols)), heightDimension: .absolute(itemH))
                )
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(itemH)),
                    subitem: item,
                    count: cols
                )
                group.interItemSpacing = .fixed(spacing)
                let sec = NSCollectionLayoutSection(group: group)
                sec.interGroupSpacing = 16
                sec.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: margin, bottom: 28, trailing: margin)
                return sec

            case .downloads:
                let item = NSCollectionLayoutItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(82))
                )
                let group = NSCollectionLayoutGroup.vertical(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(82)),
                    subitems: [item]
                )
                let sec = NSCollectionLayoutSection(group: group)
                sec.interGroupSpacing = 10
                sec.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: margin, bottom: 20, trailing: margin)
                sec.boundarySupplementaryItems = [
                    NSCollectionLayoutBoundarySupplementaryItem(
                        layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(38)),
                        elementKind: ShelfHeaderReusableView.elementKind,
                        alignment: .top
                    ),
                ]
                return sec

            case .netdisks, .mediaServers:
                let cols = isRegular ? 2 : 1
                let item = NSCollectionLayoutItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0 / CGFloat(cols)), heightDimension: .absolute(74))
                )
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(74)),
                    subitem: item,
                    count: cols
                )
                group.interItemSpacing = .fixed(14)
                let sec = NSCollectionLayoutSection(group: group)
                sec.interGroupSpacing = 12
                sec.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: margin, bottom: 28, trailing: margin)
                return sec
            }
        }

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.register(PosterCardCell.self, forCellWithReuseIdentifier: PosterCardCell.reuseIdentifier)
        collectionView.register(LandscapeCardCell.self, forCellWithReuseIdentifier: LandscapeCardCell.reuseIdentifier)
        collectionView.register(DownloadGroupRowCell.self, forCellWithReuseIdentifier: DownloadGroupRowCell.reuseIdentifier)
        collectionView.register(HubTileCardCell.self, forCellWithReuseIdentifier: HubTileCardCell.reuseIdentifier)
        collectionView.register(
            ShelfHeaderReusableView.self,
            forSupplementaryViewOfKind: ShelfHeaderReusableView.elementKind,
            withReuseIdentifier: ShelfHeaderReusableView.reuseIdentifier
        )
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: segmentContainer.bottomAnchor, constant: 6),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<SectionKind, HubItem>(
            collectionView: collectionView
        ) { [weak self] cv, ip, item in
            guard let self = self else { return nil }
            let store = AppStateStore.shared

            switch item {
            case .favorite(let fav):
                let cell = cv.dequeueReusableCell(withReuseIdentifier: PosterCardCell.reuseIdentifier, for: ip) as! PosterCardCell
                cell.configure(with: PosterCardModel(
                    id: fav.key,
                    title: fav.title,
                    subtitle: fav.remarks.isEmpty ? nil : fav.remarks,
                    badge: store.isPrivacySpaceUnlocked && store.config.isPrivateSiteKey(fav.site) ? "私密" : nil,
                    posterURL: fav.poster,
                    isPrivate: store.config.isPrivateSiteKey(fav.site)
                ))
                return cell

            case .history(let hist):
                let cell = cv.dequeueReusableCell(withReuseIdentifier: LandscapeCardCell.reuseIdentifier, for: ip) as! LandscapeCardCell
                cell.configure(
                    with: PosterCardModel(
                        id: hist.key,
                        title: hist.title,
                        subtitle: hist.episode.isEmpty ? "上次观看" : "续播 · \(hist.episode)",
                        badge: hist.line.isEmpty ? nil : hist.line,
                        posterURL: hist.poster,
                        isPrivate: store.config.isPrivateSiteKey(hist.site),
                        progressFraction: max(hist.progressFraction, 0.06)
                    ),
                    showPlayGlyph: true
                )
                return cell

            case .download(let task):
                let cell = cv.dequeueReusableCell(withReuseIdentifier: DownloadGroupRowCell.reuseIdentifier, for: ip) as! DownloadGroupRowCell
                cell.configure(task: task)
                cell.onActionTapped = { [weak self] in self?.handleDownloadAction(task) }
                return cell

            case .netdisk(let provider):
                let cell = cv.dequeueReusableCell(withReuseIdentifier: HubTileCardCell.reuseIdentifier, for: ip) as! HubTileCardCell
                let loggedIn = store.storage.isNetdiskLoggedIn(provider.rawValue)
                cell.configure(
                    title: provider.displayName,
                    subtitle: loggedIn ? "已授权 · 点击浏览个人云盘目录树" : "未登录 · 点击打开原生网页登录",
                    symbol: "externaldrive.fill.badge.icloud",
                    statusText: loggedIn ? "已登录" : "去登录",
                    active: loggedIn
                )
                return cell

            case .emby(let acc):
                let cell = cv.dequeueReusableCell(withReuseIdentifier: HubTileCardCell.reuseIdentifier, for: ip) as! HubTileCardCell
                cell.configure(
                    title: acc.label.isEmpty ? "Emby 服务器" : acc.label,
                    subtitle: acc.baseUrl,
                    symbol: "server.rack",
                    statusText: "Emby",
                    active: true
                )
                return cell

            case .mediaAccount(let acc):
                let cell = cv.dequeueReusableCell(withReuseIdentifier: HubTileCardCell.reuseIdentifier, for: ip) as! HubTileCardCell
                let target = acc.baseUrl.isEmpty ? acc.host : acc.baseUrl
                cell.configure(
                    title: acc.label.isEmpty ? acc.kind.displayName : acc.label,
                    subtitle: target.isEmpty ? acc.path : target,
                    symbol: Self.symbol(for: acc.kind),
                    statusText: acc.kind.displayName,
                    active: true
                )
                return cell

            case .blurayInfo:
                let cell = cv.dequeueReusableCell(withReuseIdentifier: HubTileCardCell.reuseIdentifier, for: ip) as! HubTileCardCell
                cell.configure(
                    title: "蓝光 ISO / 局域网原盘",
                    subtitle: "连接 SMB2 / WebDAV / Emby 后自动识别 BDMV 与 ISO 蓝光原盘",
                    symbol: "opticaldisc.fill",
                    statusText: "已就绪",
                    active: true
                )
                return cell
            }
        }

        dataSource.supplementaryViewProvider = { [weak self] cv, kind, ip in
            guard kind == ShelfHeaderReusableView.elementKind,
                  let self = self,
                  let header = cv.dequeueReusableSupplementaryView(
                      ofKind: kind,
                      withReuseIdentifier: ShelfHeaderReusableView.reuseIdentifier,
                      for: ip
                  ) as? ShelfHeaderReusableView
            else { return nil }
            let sections = self.dataSource.snapshot().sectionIdentifiers
            if ip.section < sections.count, case .downloadSeries(let seriesTitle) = sections[ip.section] {
                header.configure(title: seriesTitle)
            }
            return header
        }
    }

    private static func symbol(for kind: MediaLibraryKind) -> String {
        switch kind {
        case .emby, .jellyfin, .plex: return "server.rack"
        case .webdav: return "globe"
        case .alist: return "folder.badge.gearshape"
        case .smb2: return "externaldrive.connected.to.line.below"
        case .local: return "folder.fill"
        case .personalCloud: return "icloud.fill"
        }
    }

    private func observeUpdates() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleStateChanged), name: .marcoStateDidChange, object: nil)
        nc.addObserver(self, selector: #selector(handleStateChanged), name: .marcoPrivacyDidChange, object: nil)
        nc.addObserver(self, selector: #selector(handleStateChanged), name: .marcoDownloadsDidChange, object: nil)
    }

    @objc private func handleStateChanged() {
        reloadData()
    }

    @objc private func segmentChanged() {
        MarcoHaptics.selection()
        activeTab = HubTab(rawValue: segmentedControl.selectedSegmentIndex) ?? .favorites
        collectionView.collectionViewLayout.invalidateLayout()
        reloadData()
    }

    private func reloadData() {
        let store = AppStateStore.shared
        Task {
            if store.isSimulatorDemoMode {
                cachedDownloads = SimulatorDemoFixtures.downloads
            } else {
                cachedDownloads = await store.downloadManager.allTasks(includePrivate: store.isPrivacySpaceUnlocked)
            }
            applySnapshot()
        }
    }

    private func applySnapshot() {
        let store = AppStateStore.shared
        var snapshot = NSDiffableDataSourceSnapshot<SectionKind, HubItem>()

        switch activeTab {
        case .favorites:
            let items: [FavoriteItem]
            if store.isSimulatorDemoMode {
                items = SimulatorDemoFixtures.favorites
            } else if store.isPrivacySpaceUnlocked {
                items = store.storage.privateFavorites() + store.storage.favorites()
            } else {
                items = store.storage.favorites().filter { !store.config.isPrivateSiteKey($0.site) }
            }
            snapshot.appendSections([.main])
            snapshot.appendItems(items.map { .favorite($0) }, toSection: .main)

        case .history:
            let items: [WatchHistoryItem]
            if store.isSimulatorDemoMode {
                items = SimulatorDemoFixtures.watchHistory
            } else {
                items = store.storage.watchHistory().filter {
                    store.isPrivacySpaceUnlocked || !store.config.isPrivateSiteKey($0.site)
                }
            }
            snapshot.appendSections([.main])
            snapshot.appendItems(items.map { .history($0) }, toSection: .main)

        case .downloads:
            let grouped = Dictionary(grouping: cachedDownloads, by: { $0.title.isEmpty ? "未命名缓存" : $0.title })
            for seriesTitle in grouped.keys.sorted() {
                let sec = SectionKind.downloadSeries(seriesTitle)
                snapshot.appendSections([sec])
                let tasks = (grouped[seriesTitle] ?? []).sorted { $0.episodeIndex < $1.episodeIndex }
                snapshot.appendItems(tasks.map { .download($0) }, toSection: sec)
            }

        case .netdisks:
            snapshot.appendSections([.main])
            snapshot.appendItems(NetdiskProvider.defaultOrder.map { .netdisk($0) }, toSection: .main)

        case .mediaServers:
            snapshot.appendSections([.main])
            var items: [HubItem] = store.storage.embyAccounts().map { .emby($0) }
            items.append(contentsOf: store.storage.mediaLibraryAccounts().map { .mediaAccount($0) })
            items.append(.blurayInfo)
            snapshot.appendItems(items, toSection: .main)
        }

        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Selection & Actions

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        MarcoHaptics.selection()
        let store = AppStateStore.shared

        switch item {
        case .favorite(let fav):
            let site = store.visibleAvailableSites().first(where: { $0.key == fav.site })
                ?? AppStateStore.makeSyntheticPlaybackSite(key: fav.site, name: "收藏片源")
            let video = SimulatorDemoFixtures.videos.first(where: { $0.id == fav.id })
                ?? CmsVideo(id: fav.id, title: fav.title, poster: fav.poster, remarks: fav.remarks)
            let detail = VideoDetailViewController(video: video, site: site)
            let cell = collectionView.cellForItem(at: indexPath) as? PosterCardCell
            MarcoZoomTransitionHelper.push(detail, on: navigationController, from: { [weak cell] in cell?.zoomSourceView })

        case .history(let hist):
            let site = store.visibleAvailableSites().first(where: { $0.key == hist.site })
                ?? AppStateStore.makeSyntheticPlaybackSite(key: hist.site, name: "续播片源")
            let video = SimulatorDemoFixtures.videos.first(where: { $0.id == hist.id })
                ?? CmsVideo(id: hist.id, title: hist.title, poster: hist.poster)
            let detail = VideoDetailViewController(video: video, site: site, autoResumeHistory: hist)
            navigationController?.pushViewController(detail, animated: true)

        case .download(let task):
            handleDownloadAction(task)

        case .netdisk(let provider):
            if store.storage.isNetdiskLoggedIn(provider.rawValue) {
                let browser = NetdiskAndMediaBrowserViewController(mode: .personalNetdisk(provider: provider, folderId: provider.rootFolderId, driveId: "", title: provider.displayName))
                navigationController?.pushViewController(browser, animated: true)
            } else if let kind = NetdiskDriveKind(identifier: provider.rawValue) {
                NetdiskWebAuthViewController.present(from: self, drive: kind) { [weak self] result in
                    if case .credential(let cred) = result {
                        try? AppStateStore.shared.storage.setNetdiskCredential(cred, for: provider.rawValue)
                        self?.reloadData()
                    }
                }
            }

        case .emby(let acc):
            let site = CmsSite(
                key: "emby_\(acc.key)",
                name: acc.label.isEmpty ? "Emby" : acc.label,
                type: 3,
                api: "\(ExternalMediaLibraryDispatcher.embyPrefix)\(acc.key)"
            )
            let browser = NetdiskAndMediaBrowserViewController(mode: .mediaLibrary(site: site, categoryId: nil, title: site.name))
            navigationController?.pushViewController(browser, animated: true)

        case .mediaAccount(let acc):
            let prefix: String
            switch acc.kind {
            case .emby: prefix = ExternalMediaLibraryDispatcher.embyPrefix
            case .jellyfin: prefix = ExternalMediaLibraryDispatcher.jellyfinPrefix
            case .plex: prefix = ExternalMediaLibraryDispatcher.plexPrefix
            case .webdav: prefix = ExternalMediaLibraryDispatcher.webdavPrefix
            case .alist: prefix = ExternalMediaLibraryDispatcher.alistPrefix
            case .smb2: prefix = ExternalMediaLibraryDispatcher.smbPrefix
            case .local, .personalCloud: prefix = ExternalMediaLibraryDispatcher.localPrefix
            }
            let site = CmsSite(
                key: "\(acc.kind.rawValue)_\(acc.key)",
                name: acc.label.isEmpty ? acc.kind.displayName : acc.label,
                type: 3,
                api: "\(prefix)\(acc.key)"
            )
            let browser = NetdiskAndMediaBrowserViewController(mode: .mediaLibrary(site: site, categoryId: nil, title: site.name))
            navigationController?.pushViewController(browser, animated: true)

        case .blurayInfo:
            let alert = UIAlertController(
                title: "蓝光 ISO 与原盘播放",
                message: "前往「设置 → 媒体库与局域网」添加 SMB2 / WebDAV / Emby 后，即可直接浏览与播放 BDMV / ISO 蓝光原盘。",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "好的", style: .default))
            present(alert, animated: true)
        }
    }

    private func handleDownloadAction(_ task: DownloadTask) {
        let store = AppStateStore.shared
        switch task.status {
        case .completed:
            let ep = CmsEpisode(name: task.episodeName, url: task.filePath.isEmpty ? task.sourceUrl : task.filePath, headers: task.headers)
            let line = CmsLine(name: task.lineName.isEmpty ? "本地离线" : task.lineName, episodes: [ep])
            let video = CmsVideo(id: task.videoId, title: task.title, poster: task.poster, lines: [line])
            let site = task.sourceSite ?? AppStateStore.makeSyntheticPlaybackSite(key: task.siteKey, name: task.siteName, isPrivate: task.isPrivate)
            store.presentPlayer(from: self, video: video, site: site, lines: [line])
        case .downloading, .queued:
            Task {
                await store.downloadManager.pause(taskId: task.id)
                reloadData()
            }
        case .paused, .failed:
            Task {
                await store.downloadManager.resume(taskId: task.id)
                reloadData()
            }
        }
    }
}
