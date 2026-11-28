// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Apple TV+ Cinema Home View Controller (iPhone Vertical Hero & iPad 16:9 Two-Column Hero)

import MarcoIOSCore
import UIKit

// MARK: - Supporting Home Cells

private final class HomeCinemaHeroCell: UICollectionViewCell {
    static let reuseIdentifier = "HomeCinemaHeroCell"

    private let cardView = UIView()
    private let artworkView = UIImageView()
    private let scrimLayer = CAGradientLayer()
    private let editorialContainer = UIView()
    private let badgePill = UILabel()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private let synopsisLabel = UILabel()
    private let playButton = MarcoPrimaryButton(title: "立即播放", symbolName: "play.fill", appearance: .heroWhite)
    private let detailButton = MarcoSecondaryGlassButton(title: "查看详情", symbolName: "info.circle", tone: .onDarkBackdrop)
    private let ctaStack = UIStackView()

    private var compactConstraints: [NSLayoutConstraint] = []
    private var regularConstraints: [NSLayoutConstraint] = []
    private var currentIsRegular: Bool?
    private var imageToken: PosterImageLoadToken?

    var onPlayTapped: (() -> Void)?
    var onDetailTapped: (() -> Void)?
    var onArtworkLoaded: ((UIImage) -> Void)?

    var zoomSourceView: UIView { artworkView }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        contentView.backgroundColor = .clear

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = MarcoColors.cardSurface
        cardView.applyContinuousCorners(MarcoRadii.hero)
        cardView.applyHairlineBorder()
        contentView.addSubview(cardView)

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.applyContinuousCorners(MarcoRadii.card)
        cardView.addSubview(artworkView)

        scrimLayer.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.35).cgColor,
            UIColor.black.withAlphaComponent(0.86).cgColor,
        ]
        scrimLayer.locations = [0.22, 0.56, 1.0]
        artworkView.layer.addSublayer(scrimLayer)

        editorialContainer.translatesAutoresizingMaskIntoConstraints = false
        editorialContainer.backgroundColor = .clear
        cardView.addSubview(editorialContainer)

        badgePill.translatesAutoresizingMaskIntoConstraints = false
        badgePill.font = MarcoTypography.badge
        badgePill.textColor = .white
        badgePill.backgroundColor = MarcoColors.accentTint.withAlphaComponent(0.88)
        badgePill.applyContinuousCorners(6)
        badgePill.textAlignment = .center

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = MarcoTypography.heroTitle
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = MarcoTypography.cardSubtitle
        metaLabel.numberOfLines = 1

        synopsisLabel.translatesAutoresizingMaskIntoConstraints = false
        synopsisLabel.font = MarcoTypography.body
        synopsisLabel.numberOfLines = 3
        synopsisLabel.lineBreakMode = .byTruncatingTail

        ctaStack.translatesAutoresizingMaskIntoConstraints = false
        ctaStack.axis = .horizontal
        ctaStack.spacing = 12
        ctaStack.alignment = .center
        ctaStack.addArrangedSubview(playButton)
        ctaStack.addArrangedSubview(detailButton)

        playButton.addTarget(self, action: #selector(handlePlay), for: .touchUpInside)
        detailButton.addTarget(self, action: #selector(handleDetail), for: .touchUpInside)

        editorialContainer.addSubview(badgePill)
        editorialContainer.addSubview(titleLabel)
        editorialContainer.addSubview(metaLabel)
        editorialContainer.addSubview(synopsisLabel)
        editorialContainer.addSubview(ctaStack)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            badgePill.topAnchor.constraint(equalTo: editorialContainer.topAnchor),
            badgePill.leadingAnchor.constraint(equalTo: editorialContainer.leadingAnchor),
            badgePill.heightAnchor.constraint(equalToConstant: 22),

            titleLabel.topAnchor.constraint(equalTo: badgePill.bottomAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: editorialContainer.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: editorialContainer.trailingAnchor),

            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            metaLabel.leadingAnchor.constraint(equalTo: editorialContainer.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: editorialContainer.trailingAnchor),

            synopsisLabel.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: 10),
            synopsisLabel.leadingAnchor.constraint(equalTo: editorialContainer.leadingAnchor),
            synopsisLabel.trailingAnchor.constraint(equalTo: editorialContainer.trailingAnchor),

            ctaStack.topAnchor.constraint(equalTo: synopsisLabel.bottomAnchor, constant: 16),
            ctaStack.leadingAnchor.constraint(equalTo: editorialContainer.leadingAnchor),
            ctaStack.trailingAnchor.constraint(lessThanOrEqualTo: editorialContainer.trailingAnchor),
            ctaStack.bottomAnchor.constraint(equalTo: editorialContainer.bottomAnchor),
        ])

        compactConstraints = [
            artworkView.topAnchor.constraint(equalTo: cardView.topAnchor),
            artworkView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            artworkView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),

            editorialContainer.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            editorialContainer.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),
            editorialContainer.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -20),
        ]

        regularConstraints = [
            artworkView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 14),
            artworkView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 14),
            artworkView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -14),
            artworkView.widthAnchor.constraint(equalTo: cardView.widthAnchor, multiplier: 0.56),

            editorialContainer.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 24),
            editorialContainer.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -24),
            editorialContainer.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
        ]
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageToken?.cancel()
        imageToken = nil
        artworkView.image = nil
        onPlayTapped = nil
        onDetailTapped = nil
        onArtworkLoaded = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrimLayer.frame = artworkView.bounds
        CATransaction.commit()
    }

    func configure(video: CmsVideo, isRegularWidth: Bool, isPrivate: Bool) {
        if currentIsRegular != isRegularWidth {
            currentIsRegular = isRegularWidth
            NSLayoutConstraint.deactivate(isRegularWidth ? compactConstraints : regularConstraints)
            NSLayoutConstraint.activate(isRegularWidth ? regularConstraints : compactConstraints)

            scrimLayer.isHidden = isRegularWidth
            artworkView.layer.cornerRadius = isRegularWidth ? MarcoRadii.card : MarcoRadii.hero
            titleLabel.textColor = isRegularWidth ? MarcoColors.primaryText : .white
            metaLabel.textColor = isRegularWidth ? MarcoColors.secondaryText : UIColor.white.withAlphaComponent(0.84)
            synopsisLabel.textColor = isRegularWidth ? MarcoColors.secondaryText : UIColor.white.withAlphaComponent(0.76)
            synopsisLabel.numberOfLines = isRegularWidth ? 4 : 2
            playButton.setAppearance(isRegularWidth ? .adaptiveSolid : .heroWhite)
            detailButton.setTone(isRegularWidth ? .adaptive : .onDarkBackdrop)
        }

        let badge = video.remarks.isEmpty ? "影院推荐" : video.remarks
        badgePill.text = "  \(badge)  "
        titleLabel.text = video.title

        var metaParts: [String] = []
        if let score = video.doubanScore, score > 0 {
            metaParts.append(String(format: "★ %.1f", score))
        }
        if !video.year.isEmpty { metaParts.append(video.year) }
        if !video.area.isEmpty { metaParts.append(video.area) }
        if !video.tag.isEmpty { metaParts.append(video.tag) }
        metaLabel.text = metaParts.isEmpty ? "高清影院" : metaParts.joined(separator: " · ")
        synopsisLabel.text = video.description.isEmpty ? "点击立即播放或查看完整分集与线路。" : video.description

        let ratio: CGFloat = isRegularWidth ? (16.0 / 9.0) : (4.0 / 5.0)
        let placeholder = PosterImageLoader.makeStudioPlaceholder(
            title: video.title,
            subtitle: video.remarks,
            seed: video.id,
            aspectRatio: ratio
        )
        artworkView.image = placeholder
        onArtworkLoaded?(placeholder)

        imageToken?.cancel()
        imageToken = PosterImageLoader.shared.loadImage(
            urlString: video.poster,
            isPrivate: isPrivate
        ) { [weak self] loaded in
            guard let self = self, let loaded = loaded else { return }
            self.artworkView.image = loaded
            self.onArtworkLoaded?(loaded)
        }
    }

    @objc private func handlePlay() {
        MarcoHaptics.medium()
        onPlayTapped?()
    }

    @objc private func handleDetail() {
        MarcoHaptics.selection()
        onDetailTapped?()
    }
}

private final class HomeDisclaimerCardCell: UICollectionViewCell {
    static let reuseIdentifier = "HomeDisclaimerCardCell"

    private let card = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let importButton = MarcoPrimaryButton(title: "导入订阅源", symbolName: "plus.circle.fill")
    private let qrButton = MarcoSecondaryGlassButton(title: "局域网扫码配置", symbolName: "qrcode.viewfinder")

    var onImportTapped: (() -> Void)?
    var onQrTapped: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = MarcoColors.cardSurface
        card.applyContinuousCorners(MarcoRadii.hero)
        card.applyHairlineBorder()
        contentView.addSubview(card)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = MarcoSymbols.image(
            "film.stack.fill",
            pointSize: 28,
            weight: .semibold,
            hierarchicalColor: MarcoColors.accentTint
        )
        card.addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "欢迎使用 Marco Movie"
        titleLabel.font = MarcoTypography.sectionHeader
        titleLabel.textColor = MarcoColors.primaryText
        card.addSubview(titleLabel)

        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.text = "本工具不内置、不提供、不托管任何影视内容或片源。请先导入您自有的合规订阅源、连接个人网盘或局域网媒体库（Emby / Jellyfin / Plex / WebDAV / SMB）。"
        bodyLabel.font = MarcoTypography.body
        bodyLabel.textColor = MarcoColors.secondaryText
        bodyLabel.numberOfLines = 0
        card.addSubview(bodyLabel)

        importButton.addTarget(self, action: #selector(handleImport), for: .touchUpInside)
        qrButton.addTarget(self, action: #selector(handleQr), for: .touchUpInside)

        let btnStack = UIStackView(arrangedSubviews: [importButton, qrButton])
        btnStack.translatesAutoresizingMaskIntoConstraints = false
        btnStack.axis = .horizontal
        btnStack.spacing = 12
        btnStack.alignment = .center
        card.addSubview(btnStack)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            iconView.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            iconView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),

            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),

            bodyLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 14),
            bodyLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            bodyLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),

            btnStack.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 18),
            btnStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            btnStack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -22),
            btnStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
        ])
    }

    @objc private func handleImport() {
        MarcoHaptics.medium()
        onImportTapped?()
    }

    @objc private func handleQr() {
        MarcoHaptics.selection()
        onQrTapped?()
    }
}

private final class CategoryChipCell: UICollectionViewCell, UIPointerInteractionDelegate {
    static let reuseIdentifier = "CategoryChipCell"

    private let pill = UIView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.applyContinuousCorners(16)
        contentView.addSubview(pill)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = MarcoTypography.cardTitle
        label.textAlignment = .center
        pill.addSubview(label)

        NSLayoutConstraint.activate([
            pill.topAnchor.constraint(equalTo: contentView.topAnchor),
            pill.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            pill.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -7),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -14),
        ])
        addInteraction(UIPointerInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, selected: Bool) {
        label.text = title
        if selected {
            pill.backgroundColor = MarcoColors.primaryActionFill
            label.textColor = MarcoColors.primaryActionForeground
            pill.layer.borderWidth = 0
        } else {
            pill.backgroundColor = MarcoColors.subtleFill
            label.textColor = MarcoColors.primaryText
            pill.applyHairlineBorder()
        }
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(effect: .highlight(UITargetedPreview(view: pill)))
    }
}

// MARK: - Home View Controller

public final class HomeViewController: UIViewController, UICollectionViewDelegate {
    private enum SectionKind: Hashable {
        case disclaimer
        case hero
        case continueWatching
        case categories
        case curatedModule(String)
        case catalogGrid
    }

    private enum HomeItem: Hashable {
        case disclaimer
        case hero(CmsVideo)
        case history(WatchHistoryItem)
        case category(id: String, name: String, selected: Bool)
        case curatedVideo(moduleId: String, video: CmsVideo)
        case gridVideo(CmsVideo)
    }

    public var onRequestSearch: (() -> Void)?
    public var onRequestOpenSettings: (() -> Void)?
    public var onRequestOpenCurated: (() -> Void)?

    private let ambientGlowView = AmbientGlowView()
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<SectionKind, HomeItem>!
    private let refreshControl = UIRefreshControl()

    private var categories: [CmsCategory] = []
    private var selectedCategoryId: String = ""
    private var catalogVideos: [CmsVideo] = []
    private var curatedModules: [CuratedModule] = []
    private var watchHistory: [WatchHistoryItem] = []
    private var currentPage = 1
    private var pageCount = 1
    private var isLoadingMore = false
    private var loadTask: Task<Void, Never>?

    private let sitePickerButton = UIButton(type: .system)

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MarcoColors.canvasBackground
        title = "首页"
        setupNavigationBar()
        setupAmbientAndCollectionView()
        configureDataSource()
        observeStore()
        loadInitialData()
    }

    deinit {
        loadTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.horizontalSizeClass != traitCollection.horizontalSizeClass {
            collectionView.collectionViewLayout.invalidateLayout()
            applySnapshot()
        }
    }

    // MARK: - Navigation Bar & 5-Tap Logo Privacy Gesture

    private func setupNavigationBar() {
        let logoButton = UIButton(type: .custom)
        logoButton.translatesAutoresizingMaskIntoConstraints = false
        logoButton.addTarget(self, action: #selector(handleBrandLogoTap), for: .touchUpInside)

        let logoStack = UIStackView()
        logoStack.axis = .horizontal
        logoStack.spacing = 8
        logoStack.alignment = .center
        logoStack.isUserInteractionEnabled = false
        logoStack.translatesAutoresizingMaskIntoConstraints = false

        let mark = UIImageView()
        mark.image = UIImage(named: "BrandLogoMark")
            ?? MarcoSymbols.image("film.stack.fill", pointSize: 18, weight: .semibold, hierarchicalColor: MarcoColors.accentTint)
        mark.contentMode = .scaleAspectFit
        mark.applyContinuousCorners(6)
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 24),
            mark.heightAnchor.constraint(equalToConstant: 24),
        ])

        let brandLabel = UILabel()
        brandLabel.font = MarcoTypography.bodySemibold
        brandLabel.textColor = MarcoColors.primaryText
        brandLabel.tag = 9001
        brandLabel.text = AppStateStore.shared.isPrivacySpaceUnlocked ? "私密影院" : "Marco Movie"

        logoStack.addArrangedSubview(mark)
        logoStack.addArrangedSubview(brandLabel)
        logoButton.addSubview(logoStack)
        NSLayoutConstraint.activate([
            logoStack.topAnchor.constraint(equalTo: logoButton.topAnchor, constant: 4),
            logoStack.bottomAnchor.constraint(equalTo: logoButton.bottomAnchor, constant: -4),
            logoStack.leadingAnchor.constraint(equalTo: logoButton.leadingAnchor),
            logoStack.trailingAnchor.constraint(equalTo: logoButton.trailingAnchor),
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: logoButton)

        sitePickerButton.showsMenuAsPrimaryAction = true
        sitePickerButton.setTitleColor(MarcoColors.primaryText, for: .normal)
        sitePickerButton.titleLabel?.font = MarcoTypography.caption
        sitePickerButton.backgroundColor = MarcoColors.subtleFill
        sitePickerButton.applyContinuousCorners(14)
        sitePickerButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        rebuildSitePickerMenu()

        let searchItem = UIBarButtonItem(
            image: MarcoSymbols.image("magnifyingglass", pointSize: 16, weight: .medium),
            style: .plain,
            target: self,
            action: #selector(handleSearchTapped)
        )
        let addItem = UIBarButtonItem(
            image: MarcoSymbols.image("plus.circle", pointSize: 16, weight: .medium),
            style: .plain,
            target: self,
            action: #selector(handleImportSourceTapped)
        )
        navigationItem.rightBarButtonItems = [
            searchItem,
            addItem,
            UIBarButtonItem(customView: sitePickerButton),
        ]
    }

    private func rebuildSitePickerMenu() {
        let store = AppStateStore.shared
        let sites = store.visibleAvailableSites()
        let current = store.activeSite

        let title = current?.name ?? (sites.isEmpty ? "未配置片源" : "选择片源")
        sitePickerButton.setTitle("\(title) ▾", for: .normal)

        var actions: [UIAction] = sites.prefix(25).map { site in
            let label = site.group.isEmpty ? site.name : "\(site.name) · \(site.group)"
            return UIAction(
                title: label,
                image: site.isEffectivelyPrivate ? UIImage(systemName: "lock.fill") : nil,
                state: (site.key == current?.key) ? .on : .off
            ) { _ in
                AppStateStore.shared.selectSite(site)
            }
        }
        actions.append(UIAction(
            title: "导入或管理订阅源…",
            image: UIImage(systemName: "plus.circle")
        ) { [weak self] _ in
            self?.handleImportSourceTapped()
        })
        sitePickerButton.menu = UIMenu(title: "切换片源", children: actions)

        if let brandLabel = navigationItem.leftBarButtonItem?.customView?.viewWithTag(9001) as? UILabel {
            brandLabel.text = store.isPrivacySpaceUnlocked ? "私密影院" : "Marco Movie"
            brandLabel.textColor = store.isPrivacySpaceUnlocked ? MarcoColors.ratingGold : MarcoColors.primaryText
        }
    }

    @objc private func handleBrandLogoTap() {
        MarcoHaptics.light()
        AppStateStore.shared.recordLogoTap(from: self)
    }

    @objc private func handleSearchTapped() {
        MarcoHaptics.selection()
        onRequestSearch?()
    }

    @objc private func handleImportSourceTapped() {
        MarcoHaptics.selection()
        presentQuickImportAlert()
    }

    // MARK: - Ambient Glow & Compositional Layout

    private func setupAmbientAndCollectionView() {
        ambientGlowView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(ambientGlowView)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true

        refreshControl.addTarget(self, action: #selector(handlePullToRefresh), for: .valueChanged)
        collectionView.refreshControl = refreshControl

        collectionView.register(HomeCinemaHeroCell.self, forCellWithReuseIdentifier: HomeCinemaHeroCell.reuseIdentifier)
        collectionView.register(HomeDisclaimerCardCell.self, forCellWithReuseIdentifier: HomeDisclaimerCardCell.reuseIdentifier)
        collectionView.register(CategoryChipCell.self, forCellWithReuseIdentifier: CategoryChipCell.reuseIdentifier)
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
            ambientGlowView.heightAnchor.constraint(equalToConstant: 480),

            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, env in
            guard let self = self else { return nil }
            let sections = self.dataSource?.snapshot().sectionIdentifiers ?? []
            guard sectionIndex < sections.count else { return nil }
            let kind = sections[sectionIndex]
            let isRegular = env.traitCollection.horizontalSizeClass == .regular
            let margin = MarcoSpacing.horizontalMargin(for: env.traitCollection)

            switch kind {
            case .disclaimer:
                let item = NSCollectionLayoutItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(190))
                )
                let group = NSCollectionLayoutGroup.vertical(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(190)),
                    subitems: [item]
                )
                let sec = NSCollectionLayoutSection(group: group)
                sec.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: margin, bottom: 20, trailing: margin)
                return sec

            case .hero:
                let height: CGFloat = isRegular ? 340 : 420
                let item = NSCollectionLayoutItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(height))
                )
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(height)),
                    subitems: [item]
                )
                let sec = NSCollectionLayoutSection(group: group)
                sec.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: margin, bottom: 22, trailing: margin)
                return sec

            case .continueWatching:
                let cardW: CGFloat = isRegular ? 286 : 244
                let cardH: CGFloat = cardW * (9.0 / 16.0) + 52
                let item = NSCollectionLayoutItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .fractionalHeight(1.0))
                )
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .absolute(cardW), heightDimension: .absolute(cardH)),
                    subitems: [item]
                )
                let sec = NSCollectionLayoutSection(group: group)
                sec.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
                sec.interGroupSpacing = 14
                sec.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: margin, bottom: 22, trailing: margin)
                sec.boundarySupplementaryItems = [Self.makeHeaderItem()]
                return sec

            case .categories:
                let item = NSCollectionLayoutItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .estimated(84), heightDimension: .absolute(34))
                )
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .estimated(84), heightDimension: .absolute(34)),
                    subitems: [item]
                )
                let sec = NSCollectionLayoutSection(group: group)
                sec.orthogonalScrollingBehavior = .continuous
                sec.interGroupSpacing = 10
                sec.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: margin, bottom: 18, trailing: margin)
                return sec

            case .curatedModule:
                let cardW: CGFloat = isRegular ? 168 : 132
                let cardH: CGFloat = cardW * 1.5 + 58
                let item = NSCollectionLayoutItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .fractionalHeight(1.0))
                )
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .absolute(cardW), heightDimension: .absolute(cardH)),
                    subitems: [item]
                )
                let sec = NSCollectionLayoutSection(group: group)
                sec.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
                sec.interGroupSpacing = 14
                sec.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: margin, bottom: 24, trailing: margin)
                sec.boundarySupplementaryItems = [Self.makeHeaderItem()]
                return sec

            case .catalogGrid:
                let containerWidth = max(env.container.effectiveContentSize.width - margin * 2, 300)
                let cols: Int = isRegular ? max(4, min(6, Int(containerWidth / 168))) : 3
                let spacing: CGFloat = isRegular ? 16 : 12
                let itemWidth = (containerWidth - spacing * CGFloat(cols - 1)) / CGFloat(cols)
                let itemHeight = itemWidth * 1.5 + 58

                let item = NSCollectionLayoutItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0 / CGFloat(cols)), heightDimension: .absolute(itemHeight))
                )
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(itemHeight)),
                    subitem: item,
                    count: cols
                )
                group.interItemSpacing = .fixed(spacing)

                let sec = NSCollectionLayoutSection(group: group)
                sec.interGroupSpacing = 18
                sec.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: margin, bottom: 32, trailing: margin)
                sec.boundarySupplementaryItems = [Self.makeHeaderItem()]
                return sec
            }
        }
    }

    private static func makeHeaderItem() -> NSCollectionLayoutBoundarySupplementaryItem {
        NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(44)),
            elementKind: ShelfHeaderReusableView.elementKind,
            alignment: .top
        )
    }

    // MARK: - Data Source

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<SectionKind, HomeItem>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item in
            guard let self = self else { return nil }
            let isPrivate = AppStateStore.shared.activeSite?.isEffectivelyPrivate ?? false

            switch item {
            case .disclaimer:
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: HomeDisclaimerCardCell.reuseIdentifier,
                    for: indexPath
                ) as! HomeDisclaimerCardCell
                cell.onImportTapped = { [weak self] in self?.presentQuickImportAlert() }
                cell.onQrTapped = { [weak self] in self?.presentQrBindScanner() }
                return cell

            case .hero(let video):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: HomeCinemaHeroCell.reuseIdentifier,
                    for: indexPath
                ) as! HomeCinemaHeroCell
                let isRegular = self.traitCollection.horizontalSizeClass == .regular
                cell.configure(video: video, isRegularWidth: isRegular, isPrivate: isPrivate)
                cell.onArtworkLoaded = { [weak self] img in
                    guard AppStateStore.shared.storage.preferences().ambientGlowEnabled else { return }
                    self?.ambientGlowView.updateFromImage(img, animated: true)
                }
                cell.onPlayTapped = { [weak self] in self?.quickPlay(video: video) }
                cell.onDetailTapped = { [weak self, weak cell] in
                    self?.openDetail(for: video, sourceView: cell?.zoomSourceView)
                }
                return cell

            case .history(let hist):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: LandscapeCardCell.reuseIdentifier,
                    for: indexPath
                ) as! LandscapeCardCell
                let model = PosterCardModel(
                    id: hist.key,
                    title: hist.title,
                    subtitle: hist.episode.isEmpty ? "继续观看" : "续播 · \(hist.episode)",
                    badge: hist.line.isEmpty ? nil : hist.line,
                    posterURL: hist.poster,
                    isPrivate: AppStateStore.shared.config.isPrivateSiteKey(hist.site),
                    progressFraction: hist.progressFraction > 0.01 ? hist.progressFraction : 0.08
                )
                cell.configure(with: model, showPlayGlyph: true)
                return cell

            case .category(_, let name, let selected):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: CategoryChipCell.reuseIdentifier,
                    for: indexPath
                ) as! CategoryChipCell
                cell.configure(title: name, selected: selected)
                return cell

            case .curatedVideo(_, let video), .gridVideo(let video):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: PosterCardCell.reuseIdentifier,
                    for: indexPath
                ) as! PosterCardCell
                let rating = video.doubanScore.flatMap { $0 > 0 ? String(format: "%.1f", $0) : nil }
                let subtitle = [video.year, video.area].filter { !$0.isEmpty }.joined(separator: " · ")
                cell.configure(with: PosterCardModel(
                    id: video.id,
                    title: video.title,
                    subtitle: subtitle.isEmpty ? video.tag : subtitle,
                    badge: video.remarks.isEmpty ? nil : video.remarks,
                    rating: rating,
                    posterURL: video.poster,
                    isPrivate: isPrivate
                ))
                return cell
            }
        }

        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            guard kind == ShelfHeaderReusableView.elementKind,
                  let self = self,
                  let header = collectionView.dequeueReusableSupplementaryView(
                      ofKind: kind,
                      withReuseIdentifier: ShelfHeaderReusableView.reuseIdentifier,
                      for: indexPath
                  ) as? ShelfHeaderReusableView
            else { return nil }

            let sections = self.dataSource.snapshot().sectionIdentifiers
            guard indexPath.section < sections.count else { return header }
            switch sections[indexPath.section] {
            case .continueWatching:
                header.configure(title: "继续观看", subtitle: "从上次中断的位置无缝续播")
            case .curatedModule(let modId):
                if let mod = self.curatedModules.first(where: { $0.id == modId }) {
                    header.configure(title: mod.title, subtitle: mod.subtitle, actionTitle: "查看全部") { [weak self] in
                        self?.onRequestOpenCurated?()
                    }
                }
            case .catalogGrid:
                let catName = self.categories.first(where: { $0.id == self.selectedCategoryId })?.name ?? "最新片库"
                header.configure(
                    title: catName,
                    subtitle: AppStateStore.shared.activeSite?.name
                )
            default:
                header.configure(title: "")
            }
            return header
        }
    }

    // MARK: - Data Loading & State Observation

    private func observeStore() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleStoreChanged), name: .marcoStateDidChange, object: nil)
        nc.addObserver(self, selector: #selector(handleSiteChanged), name: .marcoSiteDidChange, object: nil)
        nc.addObserver(self, selector: #selector(handleStoreChanged), name: .marcoPrivacyDidChange, object: nil)
    }

    @objc private func handleStoreChanged() {
        rebuildSitePickerMenu()
        refreshHistoryOnly()
        if catalogVideos.isEmpty && AppStateStore.shared.activeSite != nil {
            loadInitialData()
        } else {
            applySnapshot()
        }
    }

    @objc private func handleSiteChanged() {
        rebuildSitePickerMenu()
        selectedCategoryId = ""
        loadInitialData()
    }

    @objc private func handlePullToRefresh() {
        loadInitialData()
    }

    private func refreshHistoryOnly() {
        let store = AppStateStore.shared
        if store.isSimulatorDemoMode {
            watchHistory = SimulatorDemoFixtures.watchHistory
        } else {
            let all = store.storage.watchHistory()
            watchHistory = all.filter { item in
                store.isPrivacySpaceUnlocked || !store.config.isPrivateSiteKey(item.site)
            }
        }
    }

    private func loadInitialData() {
        loadTask?.cancel()
        let store = AppStateStore.shared
        refreshHistoryOnly()

        if store.isSimulatorDemoMode {
            categories = SimulatorDemoFixtures.categories
            if selectedCategoryId.isEmpty { selectedCategoryId = "all" }
            catalogVideos = SimulatorDemoFixtures.videos
            curatedModules = CuratedDiscoveryService.buildModules(
                from: catalogVideos,
                preferences: store.storage.preferences()
            )
            refreshControl.endRefreshing()
            applySnapshot()
            return
        }

        guard let site = store.activeSite else {
            categories = []
            catalogVideos = []
            curatedModules = []
            ambientGlowView.resetToDefault(animated: true)
            refreshControl.endRefreshing()
            applySnapshot()
            return
        }

        loadTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let payload = try await store.cmsClient.fetchHome(site: site, storage: store.storage)
                guard !Task.isCancelled else { return }
                self.categories = payload.categories
                self.selectedCategoryId = ""
                self.catalogVideos = payload.listing.videos
                self.currentPage = payload.listing.page
                self.pageCount = payload.listing.pageCount
                self.curatedModules = CuratedDiscoveryService.buildModules(
                    from: payload.listing.videos,
                    preferences: store.storage.preferences()
                )
                self.refreshControl.endRefreshing()
                self.applySnapshot()
            } catch {
                guard !Task.isCancelled else { return }
                self.refreshControl.endRefreshing()
                self.applySnapshot()
            }
        }
    }

    private func loadCategory(categoryId: String, page: Int = 1) {
        let store = AppStateStore.shared
        selectedCategoryId = categoryId

        if store.isSimulatorDemoMode {
            if categoryId == "all" || categoryId.isEmpty {
                catalogVideos = SimulatorDemoFixtures.videos
            } else {
                catalogVideos = SimulatorDemoFixtures.videos.filter { video in
                    switch categoryId {
                    case "movie": return !video.tag.contains("剧集") && !video.tag.contains("纪录片") && !video.tag.contains("动画")
                    case "series": return video.tag.contains("剧集")
                    case "doc": return video.tag.contains("纪录片")
                    case "anime": return video.tag.contains("动画")
                    default: return true
                    }
                }
            }
            applySnapshot()
            return
        }

        guard let site = store.activeSite else { return }
        if page == 1 {
            loadTask?.cancel()
        }
        isLoadingMore = true
        loadTask = Task { [weak self] in
            guard let self = self else { return }
            defer { self.isLoadingMore = false }
            do {
                let listing = try await store.cmsClient.fetchCategory(
                    site: site,
                    categoryId: categoryId,
                    page: page,
                    storage: store.storage
                )
                guard !Task.isCancelled else { return }
                self.currentPage = listing.page
                self.pageCount = listing.pageCount
                if page == 1 {
                    self.catalogVideos = listing.videos
                } else {
                    let existing = Set(self.catalogVideos.map(\.id))
                    let merged = listing.videos.filter { !existing.contains($0.id) }
                    self.catalogVideos.append(contentsOf: merged)
                }
                self.applySnapshot()
            } catch {
                // Keep existing listing visible on transient network failure.
            }
        }
    }

    private func applySnapshot() {
        let store = AppStateStore.shared
        let prefs = store.storage.preferences()
        var snapshot = NSDiffableDataSourceSnapshot<SectionKind, HomeItem>()

        let hasConfiguredSources = !store.visibleAvailableSites().isEmpty || store.isSimulatorDemoMode
        if !hasConfiguredSources {
            snapshot.appendSections([.disclaimer])
            snapshot.appendItems([.disclaimer], toSection: .disclaimer)
        } else if prefs.showHeroBanner, let hero = catalogVideos.first {
            snapshot.appendSections([.hero])
            snapshot.appendItems([.hero(hero)], toSection: .hero)
        }

        if prefs.showContinueWatching && !watchHistory.isEmpty {
            snapshot.appendSections([.continueWatching])
            snapshot.appendItems(watchHistory.prefix(12).map { .history($0) }, toSection: .continueWatching)
        }

        if !categories.isEmpty {
            snapshot.appendSections([.categories])
            var catItems: [HomeItem] = [
                .category(id: "", name: "全部", selected: selectedCategoryId.isEmpty || selectedCategoryId == "all"),
            ]
            for cat in categories where cat.id != "all" {
                catItems.append(.category(id: cat.id, name: cat.name, selected: cat.id == selectedCategoryId))
            }
            snapshot.appendItems(catItems, toSection: .categories)
        }

        if prefs.showCuratedDiscovery && (selectedCategoryId.isEmpty || selectedCategoryId == "all") {
            for mod in curatedModules.prefix(2) where !mod.items.isEmpty {
                let sec = SectionKind.curatedModule(mod.id)
                snapshot.appendSections([sec])
                snapshot.appendItems(mod.items.map { .curatedVideo(moduleId: mod.id, video: $0) }, toSection: sec)
            }
        }

        if !catalogVideos.isEmpty {
            snapshot.appendSections([.catalogGrid])
            snapshot.appendItems(catalogVideos.map { .gridVideo($0) }, toSection: .catalogGrid)
        }

        ambientGlowView.isHidden = !prefs.ambientGlowEnabled
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Selection & Pagination

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        MarcoHaptics.selection()

        switch item {
        case .disclaimer:
            break
        case .hero(let video):
            let cell = collectionView.cellForItem(at: indexPath) as? HomeCinemaHeroCell
            openDetail(for: video, sourceView: cell?.zoomSourceView)
        case .history(let hist):
            resumeHistory(hist)
        case .category(let id, _, _):
            if id.isEmpty {
                selectedCategoryId = ""
                loadInitialData()
            } else {
                loadCategory(categoryId: id, page: 1)
            }
        case .curatedVideo(_, let video), .gridVideo(let video):
            let cell = collectionView.cellForItem(at: indexPath) as? PosterCardCell
            openDetail(for: video, sourceView: cell?.zoomSourceView)
        }
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        let sections = dataSource.snapshot().sectionIdentifiers
        guard indexPath.section < sections.count,
              sections[indexPath.section] == .catalogGrid,
              !isLoadingMore,
              currentPage < pageCount,
              !selectedCategoryId.isEmpty,
              !AppStateStore.shared.isSimulatorDemoMode
        else { return }

        if indexPath.item >= max(0, catalogVideos.count - 6) {
            loadCategory(categoryId: selectedCategoryId, page: currentPage + 1)
        }
    }

    // MARK: - Navigation Actions

    private func openDetail(for video: CmsVideo, sourceView: UIView?) {
        let store = AppStateStore.shared
        let site = store.activeSite ?? SimulatorDemoFixtures.demoSite
        let detail = VideoDetailViewController(video: video, site: site)
        MarcoZoomTransitionHelper.push(
            detail,
            on: navigationController,
            from: { [weak sourceView] in sourceView }
        )
    }

    private func quickPlay(video: CmsVideo) {
        let store = AppStateStore.shared
        let site = store.activeSite ?? SimulatorDemoFixtures.demoSite
        if !video.lines.isEmpty {
            store.presentPlayer(from: self, video: video, site: site, lines: video.lines)
            return
        }
        openDetail(for: video, sourceView: nil)
    }

    private func resumeHistory(_ item: WatchHistoryItem) {
        let store = AppStateStore.shared
        let site = store.visibleAvailableSites().first(where: { $0.key == item.site })
            ?? store.activeSite
            ?? AppStateStore.makeSyntheticPlaybackSite(key: item.site, name: "续播片源")
        let video = SimulatorDemoFixtures.videos.first(where: { $0.id == item.id })
            ?? CmsVideo(id: item.id, title: item.title, poster: item.poster)
        let detail = VideoDetailViewController(video: video, site: site, autoResumeHistory: item)
        navigationController?.pushViewController(detail, animated: true)
    }

    // MARK: - Quick Import & QR Bind

    private func presentQuickImportAlert() {
        let alert = UIAlertController(
            title: "导入订阅源",
            message: "输入您的合规 TVBox / CatVod JSON 订阅地址，工具本身不内置或托管任何内容。",
            preferredStyle: .alert
        )
        alert.addTextField { tf in
            tf.placeholder = "订阅名称（选填）"
        }
        alert.addTextField { tf in
            tf.placeholder = "https:// 订阅配置地址"
            tf.keyboardType = .URL
            tf.autocorrectionType = .no
            tf.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "导入", style: .default) { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text ?? ""
            let url = alert?.textFields?.last?.text ?? ""
            guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { [weak self] in
                do {
                    _ = try await AppStateStore.shared.addSubscriptionFromUrl(url, name: name)
                    self?.loadInitialData()
                } catch {
                    self?.showToastAlert(title: "导入失败", message: error.localizedDescription)
                }
            }
        })
        present(alert, animated: true)
    }

    private func presentQrBindScanner() {
        QrScannerViewController.present(
            from: self,
            title: "扫码导入配置",
            subtitle: "扫描电视或电脑端接收码 / 订阅二维码"
        ) { [weak self] scanned in
            guard let self = self, let raw = scanned, !raw.isEmpty else { return }
            if let url = URL(string: raw), let msg = AppStateStore.shared.handleDeepLink(url) {
                self.showToastAlert(title: "扫码绑定成功", message: msg)
                return
            }
            Task { [weak self] in
                do {
                    _ = try await AppStateStore.shared.addSubscriptionFromUrl(raw)
                    self?.loadInitialData()
                } catch {
                    self?.showToastAlert(title: "导入失败", message: error.localizedDescription)
                }
            }
        }
    }

    private func showToastAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好的", style: .default))
        present(alert, animated: true)
    }
}
