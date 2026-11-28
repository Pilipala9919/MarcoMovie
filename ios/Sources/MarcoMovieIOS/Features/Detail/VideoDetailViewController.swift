// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Video Detail (iPhone Vertical Backdrop & iPad Two-Column Header + Multi-Column 16:9 Episode Stills)

import MarcoIOSCore
import UIKit

// MARK: - Detail Header Cell

private final class VideoDetailHeaderCell: UICollectionViewCell {
    static let reuseIdentifier = "VideoDetailHeaderCell"

    private let posterContainer = UIView()
    private let posterImageView = UIImageView()
    private let infoStack = UIStackView()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private let castLabel = UILabel()
    private let synopsisLabel = UILabel()

    private let primaryPlayButton = MarcoPrimaryButton(title: "立即播放", symbolName: "play.fill")
    private let favoriteButton = MarcoSecondaryGlassButton(title: "收藏", symbolName: "heart")
    private let downloadButton = MarcoSecondaryGlassButton(title: "离线", symbolName: "arrow.down.circle")
    private let aiBriefButton = MarcoSecondaryGlassButton(title: "AI 导览", symbolName: "sparkles")

    private let lineSelectorButton = UIButton(type: .system)
    private let sortButton = UIButton(type: .system)

    private var compactConstraints: [NSLayoutConstraint] = []
    private var regularConstraints: [NSLayoutConstraint] = []
    private var currentIsRegular: Bool?
    private var imageToken: PosterImageLoadToken?

    var onPlayTapped: (() -> Void)?
    var onFavoriteTapped: (() -> Void)?
    var onDownloadTapped: (() -> Void)?
    var onAiBriefTapped: (() -> Void)?
    var onSelectLine: ((Int) -> Void)?
    var onToggleSort: (() -> Void)?
    var onArtworkLoaded: ((UIImage) -> Void)?

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

        posterContainer.translatesAutoresizingMaskIntoConstraints = false
        posterContainer.backgroundColor = MarcoColors.posterPlaceholderBase
        posterContainer.applyContinuousCorners(MarcoRadii.hero)
        posterContainer.applyHairlineBorder()
        contentView.addSubview(posterContainer)

        posterImageView.translatesAutoresizingMaskIntoConstraints = false
        posterImageView.contentMode = .scaleAspectFill
        posterImageView.clipsToBounds = true
        posterContainer.addSubview(posterImageView)

        infoStack.translatesAutoresizingMaskIntoConstraints = false
        infoStack.axis = .vertical
        infoStack.spacing = 10
        infoStack.alignment = .fill
        contentView.addSubview(infoStack)

        titleLabel.font = MarcoTypography.heroTitle
        titleLabel.textColor = MarcoColors.primaryText
        titleLabel.numberOfLines = 2

        metaLabel.font = MarcoTypography.cardSubtitle
        metaLabel.textColor = MarcoColors.secondaryText
        metaLabel.numberOfLines = 2

        castLabel.font = MarcoTypography.caption
        castLabel.textColor = MarcoColors.tertiaryText
        castLabel.numberOfLines = 2

        synopsisLabel.font = MarcoTypography.body
        synopsisLabel.textColor = MarcoColors.secondaryText
        synopsisLabel.numberOfLines = 4

        primaryPlayButton.addTarget(self, action: #selector(handlePlay), for: .touchUpInside)
        favoriteButton.addTarget(self, action: #selector(handleFavorite), for: .touchUpInside)
        downloadButton.addTarget(self, action: #selector(handleDownload), for: .touchUpInside)
        aiBriefButton.addTarget(self, action: #selector(handleAiBrief), for: .touchUpInside)

        let actionRow = UIStackView(arrangedSubviews: [primaryPlayButton, favoriteButton, downloadButton, aiBriefButton])
        actionRow.axis = .horizontal
        actionRow.spacing = 10
        actionRow.alignment = .center
        actionRow.distribution = .fillProportionally

        let toolbarRow = UIStackView()
        toolbarRow.axis = .horizontal
        toolbarRow.spacing = 10
        toolbarRow.alignment = .center

        lineSelectorButton.showsMenuAsPrimaryAction = true
        lineSelectorButton.titleLabel?.font = MarcoTypography.cardTitle
        lineSelectorButton.setTitleColor(MarcoColors.primaryText, for: .normal)
        lineSelectorButton.backgroundColor = MarcoColors.subtleFill
        lineSelectorButton.applyContinuousCorners(12)
        lineSelectorButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)

        sortButton.titleLabel?.font = MarcoTypography.caption
        sortButton.setTitleColor(MarcoColors.secondaryText, for: .normal)
        sortButton.backgroundColor = MarcoColors.subtleFill
        sortButton.applyContinuousCorners(12)
        sortButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        sortButton.addTarget(self, action: #selector(handleSort), for: .touchUpInside)

        let spacer = UIView()
        toolbarRow.addArrangedSubview(lineSelectorButton)
        toolbarRow.addArrangedSubview(spacer)
        toolbarRow.addArrangedSubview(sortButton)

        infoStack.addArrangedSubview(titleLabel)
        infoStack.addArrangedSubview(metaLabel)
        infoStack.addArrangedSubview(castLabel)
        infoStack.addArrangedSubview(synopsisLabel)
        infoStack.addArrangedSubview(actionRow)
        infoStack.addArrangedSubview(toolbarRow)

        NSLayoutConstraint.activate([
            posterImageView.topAnchor.constraint(equalTo: posterContainer.topAnchor),
            posterImageView.leadingAnchor.constraint(equalTo: posterContainer.leadingAnchor),
            posterImageView.trailingAnchor.constraint(equalTo: posterContainer.trailingAnchor),
            posterImageView.bottomAnchor.constraint(equalTo: posterContainer.bottomAnchor),
        ])

        compactConstraints = [
            posterContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            posterContainer.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            posterContainer.widthAnchor.constraint(equalToConstant: 210),
            posterContainer.heightAnchor.constraint(equalToConstant: 315),

            infoStack.topAnchor.constraint(equalTo: posterContainer.bottomAnchor, constant: 18),
            infoStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            infoStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            infoStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ]

        regularConstraints = [
            posterContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            posterContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            posterContainer.widthAnchor.constraint(equalToConstant: 224),
            posterContainer.heightAnchor.constraint(equalToConstant: 336),
            posterContainer.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),

            infoStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            infoStack.leadingAnchor.constraint(equalTo: posterContainer.trailingAnchor, constant: 26),
            infoStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            infoStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),
        ]
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageToken?.cancel()
        imageToken = nil
    }

    func configure(
        video: CmsVideo,
        lines: [CmsLine],
        selectedLineIndex: Int,
        isFavorite: Bool,
        isDescending: Bool,
        isRegularWidth: Bool,
        isPrivate: Bool,
        resumeLabel: String?
    ) {
        if currentIsRegular != isRegularWidth {
            currentIsRegular = isRegularWidth
            NSLayoutConstraint.deactivate(isRegularWidth ? compactConstraints : regularConstraints)
            NSLayoutConstraint.activate(isRegularWidth ? regularConstraints : compactConstraints)
            titleLabel.textAlignment = isRegularWidth ? .left : .center
            metaLabel.textAlignment = isRegularWidth ? .left : .center
            castLabel.textAlignment = isRegularWidth ? .left : .center
        }

        titleLabel.text = video.title
        var meta: [String] = []
        if let score = video.doubanScore, score > 0 { meta.append(String(format: "★ %.1f", score)) }
        if !video.year.isEmpty { meta.append(video.year) }
        if !video.area.isEmpty { meta.append(video.area) }
        if !video.remarks.isEmpty { meta.append(video.remarks) }
        metaLabel.text = meta.joined(separator: " · ")

        var credits: [String] = []
        if !video.director.isEmpty { credits.append("导演：\(video.director)") }
        if !video.actor.isEmpty { credits.append("主演：\(video.actor)") }
        castLabel.text = credits.joined(separator: "  ")
        castLabel.isHidden = credits.isEmpty

        synopsisLabel.text = video.description.isEmpty ? "暂无剧情简介" : video.description
        primaryPlayButton.setContent(title: resumeLabel ?? "立即播放", symbolName: "play.fill")
        favoriteButton.setContent(
            title: isFavorite ? "已收藏" : "收藏",
            symbolName: isFavorite ? "heart.fill" : "heart"
        )
        aiBriefButton.isHidden = isPrivate

        let activeLineName = (selectedLineIndex < lines.count) ? lines[selectedLineIndex].name : "暂无线路"
        lineSelectorButton.setTitle("线路：\(activeLineName) ▾", for: .normal)
        lineSelectorButton.menu = UIMenu(
            title: "选择播放线路",
            children: lines.enumerated().map { idx, line in
                UIAction(
                    title: "\(line.name)（\(line.episodes.count)集）",
                    state: idx == selectedLineIndex ? .on : .off
                ) { [weak self] _ in
                    self?.onSelectLine?(idx)
                }
            }
        )
        sortButton.setTitle(isDescending ? "倒序 ↓" : "正序 ↑", for: .normal)

        let placeholder = PosterImageLoader.makeStudioPlaceholder(
            title: video.title,
            subtitle: video.remarks,
            seed: video.id,
            aspectRatio: 2.0 / 3.0
        )
        posterImageView.image = placeholder
        onArtworkLoaded?(placeholder)

        imageToken?.cancel()
        imageToken = PosterImageLoader.shared.loadImage(urlString: video.poster, isPrivate: isPrivate) { [weak self] img in
            guard let self = self, let img = img else { return }
            self.posterImageView.image = img
            self.onArtworkLoaded?(img)
        }
    }

    func bounceFavoriteIcon() {
        if let iv = favoriteButton.imageView {
            MarcoSymbols.bounce(iv)
        }
    }

    @objc private func handlePlay() { MarcoHaptics.medium(); onPlayTapped?() }
    @objc private func handleFavorite() { MarcoHaptics.light(); bounceFavoriteIcon(); onFavoriteTapped?() }
    @objc private func handleDownload() { MarcoHaptics.selection(); onDownloadTapped?() }
    @objc private func handleAiBrief() { MarcoHaptics.selection(); onAiBriefTapped?() }
    @objc private func handleSort() { MarcoHaptics.selection(); onToggleSort?() }
}

// MARK: - 16:9 Episode Still & Plot Card Cell

private final class EpisodeStillCardCell: UICollectionViewCell, UIPointerInteractionDelegate {
    static let reuseIdentifier = "EpisodeStillCardCell"

    private let card = UIView()
    private let stillView = UIImageView()
    private let badgePill = UILabel()
    private let numberTitleLabel = UILabel()
    private let overviewLabel = UILabel()
    private var imageToken: PosterImageLoadToken?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
        addInteraction(UIPointerInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = MarcoColors.cardSurface
        card.applyContinuousCorners(MarcoRadii.card)
        card.applyHairlineBorder()
        contentView.addSubview(card)

        stillView.translatesAutoresizingMaskIntoConstraints = false
        stillView.contentMode = .scaleAspectFill
        stillView.clipsToBounds = true
        stillView.backgroundColor = MarcoColors.posterPlaceholderBase
        card.addSubview(stillView)

        badgePill.translatesAutoresizingMaskIntoConstraints = false
        badgePill.font = MarcoTypography.badge
        badgePill.textColor = .white
        badgePill.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        badgePill.applyContinuousCorners(6)
        badgePill.isHidden = true
        stillView.addSubview(badgePill)

        numberTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        numberTitleLabel.font = MarcoTypography.cardTitle
        numberTitleLabel.textColor = MarcoColors.primaryText
        numberTitleLabel.numberOfLines = 1
        card.addSubview(numberTitleLabel)

        overviewLabel.translatesAutoresizingMaskIntoConstraints = false
        overviewLabel.font = MarcoTypography.cardSubtitle
        overviewLabel.textColor = MarcoColors.secondaryText
        overviewLabel.numberOfLines = 2
        card.addSubview(overviewLabel)

        let aspect = stillView.heightAnchor.constraint(equalTo: stillView.widthAnchor, multiplier: 9.0 / 16.0)
        aspect.priority = .defaultHigh

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            stillView.topAnchor.constraint(equalTo: card.topAnchor),
            stillView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stillView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            aspect,

            badgePill.topAnchor.constraint(equalTo: stillView.topAnchor, constant: 8),
            badgePill.trailingAnchor.constraint(equalTo: stillView.trailingAnchor, constant: -8),
            badgePill.heightAnchor.constraint(equalToConstant: 20),

            numberTitleLabel.topAnchor.constraint(equalTo: stillView.bottomAnchor, constant: 10),
            numberTitleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            numberTitleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),

            overviewLabel.topAnchor.constraint(equalTo: numberTitleLabel.bottomAnchor, constant: 4),
            overviewLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            overviewLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            overviewLabel.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -10),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageToken?.cancel()
        imageToken = nil
        stillView.image = nil
    }

    func configure(
        episode: CmsEpisode,
        lineName: String,
        meta: EpisodeRichMetadata?,
        videoTitle: String,
        isActive: Bool,
        isPrivate: Bool
    ) {
        let parsed = EpisodeScraperService.parseEpisodeBadges(
            name: episode.name,
            url: episode.url,
            lineName: lineName
        )
        let epTitle = (meta?.title.isEmpty == false) ? "\(episode.name) · \(meta!.title)" : episode.name
        numberTitleLabel.text = epTitle
        numberTitleLabel.textColor = isActive ? MarcoColors.accentTint : MarcoColors.primaryText

        if let overview = meta?.overview, !overview.isEmpty {
            overviewLabel.text = overview
        } else if let mins = meta?.runtimeMinutes {
            overviewLabel.text = "约 \(mins) 分钟 · \(lineName)"
        } else {
            overviewLabel.text = "点击立即播放 · \(lineName)"
        }

        let techTags = [parsed.resolution, parsed.hdrBadge, parsed.audioBadge].filter { !$0.isEmpty }
        if !techTags.isEmpty {
            badgePill.text = "  \(techTags.joined(separator: " · "))  "
            badgePill.isHidden = false
        } else {
            badgePill.isHidden = true
        }

        let placeholder = PosterImageLoader.makeStudioPlaceholder(
            title: episode.name,
            subtitle: videoTitle,
            seed: "\(videoTitle)|\(episode.name)",
            aspectRatio: 16.0 / 9.0
        )
        stillView.image = placeholder

        if let stillUrl = meta?.stillUrl, !stillUrl.isEmpty {
            imageToken = PosterImageLoader.shared.loadImage(urlString: stillUrl, isPrivate: isPrivate) { [weak self] img in
                if let img = img { self?.stillView.image = img }
            }
        }
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(effect: .lift(UITargetedPreview(view: card)))
    }
}

// MARK: - Video Detail View Controller

public final class VideoDetailViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Int {
        case header
        case episodes
    }

    private enum DetailItem: Hashable {
        case header(videoId: String, lineIdx: Int, fav: Bool, desc: Bool, epCount: Int)
        case episode(lineIdx: Int, originalEpIdx: Int, episode: CmsEpisode)
    }

    private var video: CmsVideo
    private let site: CmsSite
    private let autoResumeHistory: WatchHistoryItem?

    private let ambientGlowView = AmbientGlowView()
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, DetailItem>!

    private var selectedLineIndex = 0
    private var isDescending = false
    private var episodeMeta: [EpisodeRichMetadata] = []
    private var loadTask: Task<Void, Never>?

    public init(
        video: CmsVideo,
        site: CmsSite,
        autoResumeHistory: WatchHistoryItem? = nil
    ) {
        self.video = video
        self.site = site
        self.autoResumeHistory = autoResumeHistory
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTask?.cancel()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MarcoColors.canvasBackground
        navigationItem.largeTitleDisplayMode = .never
        isDescending = AppStateStore.shared.storage.preferences().episodesDescending

        ambientGlowView.translatesAutoresizingMaskIntoConstraints = false
        ambientGlowView.isHidden = !AppStateStore.shared.storage.preferences().ambientGlowEnabled
        view.addSubview(ambientGlowView)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.register(VideoDetailHeaderCell.self, forCellWithReuseIdentifier: VideoDetailHeaderCell.reuseIdentifier)
        collectionView.register(EpisodeStillCardCell.self, forCellWithReuseIdentifier: EpisodeStillCardCell.reuseIdentifier)
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
            ambientGlowView.heightAnchor.constraint(equalToConstant: 460),

            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        configureDataSource()
        hydrateDetail()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.horizontalSizeClass != traitCollection.horizontalSizeClass {
            collectionView.collectionViewLayout.invalidateLayout()
            applySnapshot()
        }
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { sectionIndex, env in
            let isRegular = env.traitCollection.horizontalSizeClass == .regular
            let margin = MarcoSpacing.horizontalMargin(for: env.traitCollection)

            if sectionIndex == 0 {
                let estH: CGFloat = isRegular ? 370 : 590
                let item = NSCollectionLayoutItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(estH))
                )
                let group = NSCollectionLayoutGroup.vertical(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(estH)),
                    subitems: [item]
                )
                let sec = NSCollectionLayoutSection(group: group)
                sec.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: margin, bottom: 18, trailing: margin)
                return sec
            }

            // Multi-column 16:9 episode still & plot cards (3 cols on wide iPad, 2 on compact iPad, 1 on iPhone).
            let availW = max(env.container.effectiveContentSize.width - margin * 2, 300)
            let cols: Int = isRegular ? (availW >= 820 ? 3 : 2) : 1
            let spacing: CGFloat = 14
            let cardW = (availW - spacing * CGFloat(cols - 1)) / CGFloat(cols)
            let cardH = cardW * (9.0 / 16.0) + 78

            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0 / CGFloat(cols)), heightDimension: .absolute(cardH))
            )
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(cardH)),
                subitem: item,
                count: cols
            )
            group.interItemSpacing = .fixed(spacing)

            let sec = NSCollectionLayoutSection(group: group)
            sec.interGroupSpacing = 14
            sec.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: margin, bottom: 32, trailing: margin)
            sec.boundarySupplementaryItems = [
                NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(42)),
                    elementKind: ShelfHeaderReusableView.elementKind,
                    alignment: .top
                ),
            ]
            return sec
        }
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Section, DetailItem>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item in
            guard let self = self else { return nil }
            let store = AppStateStore.shared
            let isPrivate = self.site.isEffectivelyPrivate

            switch item {
            case .header:
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: VideoDetailHeaderCell.reuseIdentifier,
                    for: indexPath
                ) as! VideoDetailHeaderCell
                let hist = self.matchingWatchHistory()
                let resumeTitle: String? = hist.map { h in
                    h.episode.isEmpty ? "继续播放" : "续播 \(h.episode)"
                }
                cell.configure(
                    video: self.video,
                    lines: self.video.lines,
                    selectedLineIndex: self.selectedLineIndex,
                    isFavorite: store.storage.isFavorite(site: self.site.key, id: self.video.id),
                    isDescending: self.isDescending,
                    isRegularWidth: self.traitCollection.horizontalSizeClass == .regular,
                    isPrivate: isPrivate,
                    resumeLabel: resumeTitle
                )
                cell.onArtworkLoaded = { [weak self] img in
                    guard AppStateStore.shared.storage.preferences().ambientGlowEnabled else { return }
                    self?.ambientGlowView.updateFromImage(img, animated: true)
                }
                cell.onPlayTapped = { [weak self] in self?.playPrimaryAction() }
                cell.onFavoriteTapped = { [weak self] in self?.toggleFavorite() }
                cell.onDownloadTapped = { [weak self] in self?.enqueueCurrentLineDownload() }
                cell.onAiBriefTapped = { [weak self] in self?.presentAiWatchBrief() }
                cell.onSelectLine = { [weak self] idx in
                    self?.selectedLineIndex = idx
                    self?.rebuildEpisodeMetadata()
                    self?.applySnapshot()
                }
                cell.onToggleSort = { [weak self] in
                    self?.isDescending.toggle()
                    self?.applySnapshot()
                }
                return cell

            case .episode(let lineIdx, let originalEpIdx, let ep):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: EpisodeStillCardCell.reuseIdentifier,
                    for: indexPath
                ) as! EpisodeStillCardCell
                let lineName = lineIdx < self.video.lines.count ? self.video.lines[lineIdx].name : ""
                let meta = originalEpIdx < self.episodeMeta.count ? self.episodeMeta[originalEpIdx] : nil
                let isActive = self.matchingWatchHistory()?.index == originalEpIdx
                cell.configure(
                    episode: ep,
                    lineName: lineName,
                    meta: meta,
                    videoTitle: self.video.title,
                    isActive: isActive,
                    isPrivate: isPrivate
                )
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

            let count = (self.selectedLineIndex < self.video.lines.count)
                ? self.video.lines[self.selectedLineIndex].episodes.count
                : 0
            header.configure(title: "选集与分集剧情", subtitle: "共 \(count) 集")
            return header
        }
    }

    // MARK: - Hydration & Snapshot

    private func hydrateDetail() {
        let store = AppStateStore.shared
        rebuildEpisodeMetadata()
        applySnapshot()

        if store.isSimulatorDemoMode {
            if let rich = SimulatorDemoFixtures.videos.first(where: { $0.id == video.id }) {
                video = rich
            }
            rebuildEpisodeMetadata()
            applySnapshot()
            return
        }

        loadTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let hydrated = try await store.cmsClient.fetchDetailWithSameSiteRecovery(
                    site: self.site,
                    video: self.video,
                    storage: store.storage
                )
                guard !Task.isCancelled else { return }
                self.video = hydrated
                if let hist = self.matchingWatchHistory(),
                   let matchedLine = hydrated.lines.firstIndex(where: { $0.id == hist.lineId || $0.name == hist.line })
                {
                    self.selectedLineIndex = matchedLine
                }
                self.rebuildEpisodeMetadata()
                self.applySnapshot()
            } catch {
                // Retain initial preview metadata cleanly.
            }
        }
    }

    private func rebuildEpisodeMetadata() {
        guard selectedLineIndex < video.lines.count else {
            episodeMeta = []
            return
        }
        let line = video.lines[selectedLineIndex]
        if AppStateStore.shared.isSimulatorDemoMode {
            episodeMeta = SimulatorDemoFixtures.episodeMetadata(for: video, count: line.episodes.count)
        } else {
            episodeMeta = EpisodeScraperService.buildLineMetadata(for: line)
        }
    }

    private func matchingWatchHistory() -> WatchHistoryItem? {
        if let explicit = autoResumeHistory { return explicit }
        return AppStateStore.shared.storage.watchHistory().first {
            $0.site == site.key && $0.id == video.id
        }
    }

    private func applySnapshot() {
        let fav = AppStateStore.shared.storage.isFavorite(site: site.key, id: video.id)
        let activeEpisodes = (selectedLineIndex < video.lines.count) ? video.lines[selectedLineIndex].episodes : []

        var snapshot = NSDiffableDataSourceSnapshot<Section, DetailItem>()
        snapshot.appendSections([.header])
        snapshot.appendItems([
            .header(
                videoId: video.id,
                lineIdx: selectedLineIndex,
                fav: fav,
                desc: isDescending,
                epCount: activeEpisodes.count
            ),
        ], toSection: .header)

        if !activeEpisodes.isEmpty {
            snapshot.appendSections([.episodes])
            var indexed = activeEpisodes.enumerated().map { (idx: $0.offset, ep: $0.element) }
            if isDescending {
                indexed.reverse()
            }
            snapshot.appendItems(
                indexed.map { .episode(lineIdx: selectedLineIndex, originalEpIdx: $0.idx, episode: $0.ep) },
                toSection: .episodes
            )
        }

        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Actions

    private func playPrimaryAction() {
        guard !video.lines.isEmpty else { return }
        let hist = matchingWatchHistory()
        let epIdx = hist?.index ?? 0
        let posMs = hist?.resumePosition ?? 0
        launchPlayer(lineIndex: selectedLineIndex, episodeIndex: epIdx, startPositionMs: posMs)
    }

    private func launchPlayer(lineIndex: Int, episodeIndex: Int, startPositionMs: Int) {
        AppStateStore.shared.presentPlayer(
            from: self,
            video: video,
            site: site,
            lines: video.lines,
            initialLineIndex: lineIndex,
            initialEpisodeIndex: episodeIndex,
            startPositionMs: startPositionMs
        )
    }

    private func toggleFavorite() {
        let store = AppStateStore.shared
        _ = store.storage.toggleFavorite(
            site: site.key,
            video: video,
            isPrivateSpace: site.isEffectivelyPrivate
        )
        NotificationCenter.default.post(name: .marcoStateDidChange, object: store)
        applySnapshot()
    }

    private func enqueueCurrentLineDownload() {
        guard selectedLineIndex < video.lines.count,
              let firstEp = video.lines[selectedLineIndex].episodes.first
        else { return }
        let line = video.lines[selectedLineIndex]
        let task = DownloadTask(
            id: "\(site.key)_\(video.id)_\(line.id)_0",
            siteKey: site.key,
            siteName: site.name,
            siteApi: site.api,
            siteType: site.type,
            videoId: video.id,
            title: video.title,
            poster: video.poster,
            lineName: line.name,
            episodeName: firstEp.name,
            episodeIndex: 0,
            sourceUrl: firstEp.url,
            headers: firstEp.headers,
            sourceSite: site,
            isPrivate: site.isEffectivelyPrivate,
            subscriptionId: site.subscriptionId
        )
        Task {
            _ = await AppStateStore.shared.downloadManager.enqueue(task)
            await MainActor.run {
                let alert = UIAlertController(
                    title: "已加入离线缓存",
                    message: "《\(video.title)》\(firstEp.name) 已加入片库下载队列。",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "好的", style: .default))
                self.present(alert, animated: true)
            }
        }
    }

    private func presentAiWatchBrief() {
        let store = AppStateStore.shared
        guard !site.isEffectivelyPrivate && !store.isPrivacySpaceUnlocked else {
            let alert = UIAlertController(
                title: "隐私保护",
                message: "隐私空间已自动熔断外部 AI 网络调用。",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "好的", style: .default))
            present(alert, animated: true)
            return
        }

        let loading = UIAlertController(title: "AI 观影导览", message: "正在生成无剧透观影看点…", preferredStyle: .alert)
        present(loading, animated: true)

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let res = try await store.aiService.complete(
                    systemPrompt: "你是一位克制专业的影评人，请用不超过120字的中文生成无剧透观影导览。",
                    userPrompt: "片名：\(self.video.title)\n年份：\(self.video.year)\n类型：\(self.video.tag)\n简介：\(self.video.description)",
                    preferFastModel: true,
                    isPrivateSpace: false
                )
                loading.message = res.text
                loading.addAction(UIAlertAction(title: "关闭", style: .default))
            } catch {
                loading.message = error.localizedDescription
                loading.addAction(UIAlertAction(title: "关闭", style: .default))
            }
        }
    }

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard case .episode(let lineIdx, let originalEpIdx, _) = dataSource.itemIdentifier(for: indexPath) else {
            return
        }
        MarcoHaptics.medium()
        launchPlayer(lineIndex: lineIdx, episodeIndex: originalEpIdx, startPositionMs: 0)
    }
}
